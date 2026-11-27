using System.Collections.Concurrent;
using System.Diagnostics;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.Digi;
using FTX1RemoteWindows.Services.FreeDv;
using NAudio.Wave;
using Xunit;
using Xunit.Abstractions;

namespace FTX1RemoteWindows.Tests;

/// Tools → FreeDV — the Mac's FreeDVKitTests, on the same fixture:
/// rade_offair_50s.wav is the first 50 s of rade_c's own off-air sample
/// (FDV_offair.wav, BSD-2), resampled to 8 kHz. Two overs end in it: VK5KVA at
/// ~10.6 s and VK3TPM at ~46.1 s, both callsigns carried in the end-of-over.
public class FreeDvTests(ITestOutputHelper output)
{
    private static string FixturePath => Path.Combine(AppContext.BaseDirectory, "FreeDvFixtures", "rade_offair_50s.wav");

    private static float[] Fixture() => ReadWave(FixturePath, 8000);

    private static float[] ReadWave(string path, int expectedRate)
    {
        using var reader = new WaveFileReader(path);
        var provider = reader.ToSampleProvider();
        Assert.Equal(expectedRate, provider.WaveFormat.SampleRate);
        var samples = new List<float>();
        var buffer = new float[4096];
        int read;
        while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
        {
            samples.AddRange(buffer.AsSpan(0, read));
        }
        return [.. samples];
    }

    private sealed record Decoded(float[] Speech, List<RadeEndOfOver> Ends, float MaxSnr, float MaxOffset)
    {
        public string[] Callsigns => [.. Ends.Where(e => e.Callsign is not null).Select(e => e.Callsign!)];
    }

    private static Decoded Decode(IEnumerable<float[]> chunks)
    {
        using var decoder = new RadeDecoder();
        var speech = new List<float>();
        var ends = new List<RadeEndOfOver>();
        var maxSnr = float.NegativeInfinity;
        var maxOffset = 0f;
        foreach (var chunk in chunks)
        {
            var result = decoder.Process(chunk);
            speech.AddRange(result.Speech);
            ends.AddRange(result.EndsOfOver);
            if (result.Status.Sync)
            {
                maxSnr = Math.Max(maxSnr, result.Status.SnrDb);
                maxOffset = Math.Max(maxOffset, Math.Abs(result.Status.FrequencyOffsetHz));
            }
        }
        return new Decoded([.. speech], ends, maxSnr, maxOffset);
    }

    private static IEnumerable<float[]> Chunked(float[] samples, int size) => samples.Chunk(size);

    private static float[] Noise(int count, float amplitude, int seed)
    {
        var random = new Random(seed);
        return [.. Enumerable.Range(0, count).Select(_ => (float)(random.NextDouble() * 2 - 1) * amplitude)];
    }

    /// Real speech: the receiver's output for the off-air clip, from where the
    /// first over is in sync.
    private static float[] DecodedSpeech(double seconds)
    {
        var speech = Decode([Fixture()]).Speech;
        var count = (int)(seconds * RadeDecoder.SpeechSampleRate);
        Assert.True(speech.Length > count + 16000);
        return speech[16000..(16000 + count)];
    }

    // Receive

    [Fact]
    public void DecodesTheOffAirClip()
    {
        var samples = Fixture();
        var watch = Stopwatch.StartNew();
        var result = Decode(Chunked(samples, 160));
        watch.Stop();
        output.WriteLine($"50 s decoded in {watch.Elapsed.TotalSeconds:0.00} s ({watch.Elapsed.TotalSeconds / 50:P1} of a core), "
            + $"speech {result.Speech.Length / 16000.0:0.0} s, max SNR {result.MaxSnr:0.0} dB, max offset {result.MaxOffset:0.0} Hz");

        Assert.Equal(["VK5KVA", "VK3TPM"], result.Callsigns);
        Assert.Equal(2, result.Ends.Count);
        Assert.InRange(result.Ends[0].SampleTime / 8000.0, 10.1, 11.1);
        Assert.InRange(result.Ends[1].SampleTime / 8000.0, 45.6, 46.6);
        // ~43 s of the 50 are speech (the gap between overs isn't).
        Assert.InRange(result.Speech.Length / 16000.0, 38, 50);
        Assert.True(result.MaxSnr > 10);
        Assert.True(result.MaxOffset < 5);
        // Real speech, not silence or a stuck output.
        Assert.True(Math.Sqrt(result.Speech.Average(s => (double)s * s)) > 0.01);
    }

    [Fact]
    public void ChunkSizeDoesNotChangeTheResult()
    {
        var samples = Fixture();
        var whole = Decode([samples]);
        var odd = Decode(Chunked(samples, 1237));
        Assert.Equal(whole.Speech, odd.Speech);
        Assert.Equal(whole.Ends, odd.Ends);
    }

    /// The Pi's stream is 44.1 kHz in 2048-sample chunks, resampled with one
    /// long-lived resampler.
    [Fact]
    public void StreamingResampleFrom44100StillDecodes()
    {
        var up = new DigiResampler(44100).Convert(Fixture(), 8000);
        var down = new DigiResampler(8000);
        var result = Decode(Chunked(up, 2048).Select(chunk => down.Convert(chunk, 44100)));
        Assert.Equal(["VK5KVA", "VK3TPM"], result.Callsigns);
        Assert.True(result.Speech.Length / 16000.0 > 38);
    }

    [Fact]
    public void NoiseAloneDecodesNothing()
    {
        var result = Decode(Chunked(Noise(30 * 8000, 0.2f, 1), 1024));
        Assert.Empty(result.Callsigns);
        Assert.True(result.Speech.Length / 16000.0 < 2);
    }

    // Transmit

    [Fact]
    public void LoopbackDecodesSpeechAndCallsign()
    {
        var speech = DecodedSpeech(8);
        using var encoder = new RadeEncoder();
        var modem = new List<float>();
        var watch = Stopwatch.StartNew();
        // Microphone-sized pieces (~21 ms), not whole frames.
        foreach (var chunk in Chunked(speech, 341))
        {
            modem.AddRange(encoder.Process(chunk));
        }
        modem.AddRange(encoder.Finish("te5t"));
        watch.Stop();
        output.WriteLine($"8 s encoded in {watch.Elapsed.TotalSeconds:0.00} s");
        Assert.Empty(encoder.Finish("TE5T"));

        // 120 ms frames: ~8 s of speech is ~8 s of modem audio.
        Assert.InRange(modem.Count / 8000.0, 7.6, 8.8);
        var peak = modem.Max(Math.Abs);
        Assert.True(peak > 0.3f);
        // At FreeDV's output scale the peaks stay under full scale.
        Assert.True(peak * RadeEncoder.NominalOutputScale < 1);

        // Received as an SSB receiver would hand it over.
        var silence = new float[4000];
        float[] received = [.. silence, .. modem.Select(s => s * RadeEncoder.NominalOutputScale), .. silence, .. silence];
        var result = Decode([received]);
        Assert.Equal(["TE5T"], result.Callsigns);
        Assert.True(result.Speech.Length / 16000.0 > 5);
    }

    [Fact]
    public void NoCallsignSendsAnEmptyEndOfOver()
    {
        var speech = DecodedSpeech(4);
        using var encoder = new RadeEncoder();
        float[] modem = [.. encoder.Process(speech), .. encoder.Finish(null)];
        var silence = new float[8000];
        float[] received = [.. silence, .. modem.Select(s => s * RadeEncoder.NominalOutputScale), .. silence];
        Assert.Empty(Decode([received]).Callsigns);
    }

    // Sideband

    [Theory]
    [InlineData(3_643_000L, FreeDvSideband.Lower)]
    [InlineData(7_177_000L, FreeDvSideband.Lower)]
    [InlineData(9_999_999L, FreeDvSideband.Lower)]
    [InlineData(10_000_000L, FreeDvSideband.Upper)]
    [InlineData(14_236_000L, FreeDvSideband.Upper)]
    [InlineData(28_330_000L, FreeDvSideband.Upper)]
    [InlineData(null, FreeDvSideband.Either)]
    [InlineData(0L, FreeDvSideband.Either)]
    public void SidebandFollowsTheBand(long? hz, FreeDvSideband expected) =>
        Assert.Equal(expected, FreeDvSidebands.For(hz));

    // Receiver

    /// A single-threaded stand-in for the UI thread: posted work and await
    /// continuations run when the test pumps them.
    private sealed class Pump : SynchronizationContext
    {
        private readonly BlockingCollection<Action> _work = new();

        public void Post(Action action) => _work.Add(action);

        public override void Post(SendOrPostCallback d, object? state) => _work.Add(() => d(state));

        public void RunUntil(Func<bool> condition, double timeoutSeconds = 30)
        {
            var watch = Stopwatch.StartNew();
            while (!condition())
            {
                Assert.True(watch.Elapsed.TotalSeconds < timeoutSeconds, "timed out");
                if (_work.TryTake(out var action, 10))
                {
                    action();
                }
            }
        }

        /// Runs <paramref name="test"/> with this as the current context.
        public static void Run(Action<Pump> test)
        {
            var previous = Current;
            var pump = new Pump();
            SetSynchronizationContext(pump);
            try
            {
                test(pump);
            }
            finally
            {
                SetSynchronizationContext(previous);
            }
        }
    }

    private sealed class FakeOutput : IFreeDvSpeechOutput
    {
        public long Samples;
        public float Volume { get; set; }
        public string? Problem => null;
        public void Push(float[] speech) => Samples += speech.Length;
        public void Dispose()
        {
        }
    }

    private static string TempDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), $"FreeDvTests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return path;
    }

    private static FreeDvReceiver Receiver(Pump pump, string directory, FreeDvData? settings = null, FakeOutput? speech = null) =>
        new(pump.Post, settings ?? new FreeDvData(), () => { }, () => speech, _ => null,
            label => Path.Combine(directory, label + ".wav"), path => new WaveFileReader(path));

    [Fact]
    public void DecodingAFileFillsTheHeardListAndSavesTheSpeech() => Pump.Run(pump =>
    {
        var directory = TempDirectory();
        try
        {
            using var receiver = Receiver(pump, directory);
            string? error = null;
            receiver.Error += message => error = message;
            receiver.DecodeFile(FixturePath);
            Assert.True(receiver.IsDecodingFile);
            pump.RunUntil(() => !receiver.IsDecodingFile);

            Assert.Null(error);
            Assert.Equal(["VK3TPM", "VK5KVA"], receiver.Heard.Select(h => h.Callsign));
            Assert.All(receiver.Heard, h => Assert.True(h.FromFile && h.SnrDb > 5 && h.FrequencyHz is null));
            var saved = receiver.LastDecodedFile!;
            Assert.Contains("FreeDV rade_offair_50s", saved);
            using var reader = new WaveFileReader(saved);
            Assert.Equal(16000, reader.WaveFormat.SampleRate);
            Assert.True(reader.TotalTime.TotalSeconds > 38);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    });

    [Fact]
    public void AFileWithoutFreeDvSaysSo() => Pump.Run(pump =>
    {
        var directory = TempDirectory();
        try
        {
            var noise = Path.Combine(directory, "noise.wav");
            using (var writer = new WaveFileWriter(noise, new WaveFormat(44100, 16, 1)))
            {
                var pcm = FreeDvPcm.From(Noise(44100 * 5, 0.1f, 2));
                writer.Write(pcm, 0, pcm.Length);
            }
            using var receiver = Receiver(pump, directory);
            string? error = null;
            receiver.Error += message => error = message;
            receiver.DecodeFile(noise);
            pump.RunUntil(() => !receiver.IsDecodingFile);
            Assert.NotNull(error);
            Assert.Null(receiver.LastDecodedFile);
            Assert.Empty(receiver.Heard);
            // Only the noise file is left: the empty speech file was removed.
            Assert.Equal([noise], Directory.GetFiles(directory));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    });

    /// Live audio through the receiver: voice on while in sync, the speech
    /// played, the callsigns listed with the source's dial.
    [Fact]
    public void LiveAudioPlaysSpeechAndListsCallsigns() => Pump.Run(pump =>
    {
        var directory = TempDirectory();
        try
        {
            var speech = new FakeOutput();
            using var receiver = Receiver(pump, directory, speech: speech);
            var voice = false;
            receiver.VoiceChanged += () => voice |= receiver.IsReceivingVoice;
            receiver.RigInfoChanged(new FreeDvRigInfo(MainMode: RigMode.Usb, MainHz: 14_236_000));
            receiver.Start();
            var silentSub = new float[1024];
            var sent = 0;
            foreach (var chunk in Chunked(Fixture(), 1024))
            {
                receiver.Ingest(chunk, silentSub, 8000);
                // Paced so the receiver's bounded queue never drops any.
                if (++sent % 64 == 0)
                {
                    Thread.Sleep(200);
                }
            }
            pump.RunUntil(() => receiver.Heard.Count == 2);
            Assert.True(voice);
            Assert.True(speech.Samples > 38 * 16000);
            Assert.Equal(["VK3TPM", "VK5KVA"], receiver.Heard.Select(h => h.Callsign));
            Assert.All(receiver.Heard, h => Assert.Equal(14_236_000, h.FrequencyHz));
            Assert.False(receiver.IsSubAudioAvailable);
            receiver.Stop();
            Assert.False(receiver.IsReceivingVoice);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    });

    [Fact]
    public void ModeHintFollowsTheBand() => Pump.Run(pump =>
    {
        using var receiver = Receiver(pump, Path.GetTempPath());
        void Rig(RigMode? mode, long? hz, bool c4fm = false) =>
            receiver.RigInfoChanged(new FreeDvRigInfo(MainMode: mode, MainHz: hz, MainIsC4fm: c4fm));

        // 20 m: USB or DATA-U.
        Rig(RigMode.Usb, 14_236_000);
        Assert.Null(receiver.ModeHint);
        Rig(RigMode.DataUsb, 14_236_000);
        Assert.Null(receiver.ModeHint);
        Rig(RigMode.Lsb, 14_236_000);
        Assert.Equal(new FreeDvModeHint("LSB", FreeDvSideband.Upper), receiver.ModeHint);
        // 40 m: LSB.
        Rig(RigMode.Lsb, 7_177_000);
        Assert.Null(receiver.ModeHint);
        Rig(RigMode.Usb, 7_177_000);
        Assert.Equal(new FreeDvModeHint("USB", FreeDvSideband.Lower), receiver.ModeHint);
        Rig(RigMode.DataUsb, 7_177_000);
        Assert.Equal(new FreeDvModeHint("DATA-U", FreeDvSideband.Lower), receiver.ModeHint);
        // No frequency yet: either sideband, but not FM or C4FM.
        Rig(RigMode.Lsb, null);
        Assert.Null(receiver.ModeHint);
        Rig(RigMode.Fm, null);
        Assert.Equal(new FreeDvModeHint("FM", FreeDvSideband.Either), receiver.ModeHint);
        Rig(null, 145_000_000, c4fm: true);
        Assert.Equal(new FreeDvModeHint("C4FM", FreeDvSideband.Upper), receiver.ModeHint);
        // SUB uses SUB's own frequency.
        receiver.RigInfoChanged(new FreeDvRigInfo(MainMode: RigMode.Usb, SubMode: RigMode.Lsb,
            MainHz: 14_236_000, SubHz: 3_643_000));
        receiver.Channel = CwAudioChannel.Sub;
        Assert.Null(receiver.ModeHint);
    });

    // Sender

    private sealed class FakeLink : IFreeDvTransmitLink
    {
        public string? Block;
        public string? BlockWhileKeyed;
        public bool ReportsKeyed = true;
        public List<bool> KeyedCalls { get; } = [];
        public List<byte> Audio { get; } = [];
        public int FirstSendBytes;

        public string? TransmitBlock(bool keyedBySender) => keyedBySender ? BlockWhileKeyed : Block;
        public bool RigIsKeyed => ReportsKeyed && KeyedCalls.LastOrDefault();
        public void SetKeyed(bool keyed) => KeyedCalls.Add(keyed);

        public void SendAudio(byte[] pcm)
        {
            if (Audio.Count == 0)
            {
                FirstSendBytes = pcm.Length;
            }
            Audio.AddRange(pcm);
        }
    }

    private sealed class FakeMicrophone : IFreeDvMicrophone
    {
        public bool Running;
        public string? Failure;
        public Action<float[], int>? Samples;
        public Action<string>? Failed;

        public void Start(Action<float[], int> onSamples, Action<string> onFailed)
        {
            if (Failure is not null)
            {
                throw new InvalidOperationException(Failure);
            }
            Samples = onSamples;
            Failed = onFailed;
            Running = true;
        }

        public void Stop() => Running = false;
    }

    /// Real time, 20× faster: the sender's waits keep their proportions.
    private sealed class FastClock : IDigiSenderClock
    {
        private const double Speedup = 20;
        public double Now() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency * Speedup;

        public async Task SleepAsync(double seconds, CancellationToken cancellationToken)
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(Math.Max(0, seconds) / Speedup), cancellationToken);
            }
            catch (OperationCanceledException)
            {
            }
        }
    }

    private static FreeDvSender Sender(Pump pump, FakeLink link, FakeMicrophone microphone) =>
        new(link, microphone, () => "TE5T", pump.Post, 0, clock: new FastClock());

    [Fact]
    public void ARefusedStartKeysNothing() => Pump.Run(pump =>
    {
        var link = new FakeLink { Block = "transmit is off" };
        var microphone = new FakeMicrophone();
        var sender = Sender(pump, link, microphone);
        sender.Start(FreeDvSender.Trigger.Toggle);
        Assert.Equal(FreeDvSender.SenderState.Idle, sender.State);
        Assert.Equal("transmit is off", sender.Message);
        Assert.Empty(link.KeyedCalls);
        Assert.False(microphone.Running);
    });

    [Fact]
    public void AMicrophoneThatWontStartUnkeys() => Pump.Run(pump =>
    {
        var link = new FakeLink();
        var sender = Sender(pump, link, new FakeMicrophone { Failure = "no microphone" });
        sender.Start(FreeDvSender.Trigger.Toggle);
        Assert.Equal(FreeDvSender.SenderState.Idle, sender.State);
        Assert.Equal([true, false], link.KeyedCalls);
        Assert.Equal("no microphone", sender.Message);
    });

    [Fact]
    public void AMicrophoneThatStopsMidOverUnkeys() => Pump.Run(pump =>
    {
        var link = new FakeLink();
        var microphone = new FakeMicrophone();
        var sender = Sender(pump, link, microphone);
        sender.Start(FreeDvSender.Trigger.Toggle);
        microphone.Failed!("unplugged");
        pump.RunUntil(() => sender.State == FreeDvSender.SenderState.Idle, 5);
        Assert.Equal("unplugged", sender.Message);
        Assert.Equal([true, false], link.KeyedCalls);
    });

    /// A whole over: key, microphone at 48 kHz in 10 ms pieces, RX,
    /// end-of-over, unkey after play-out — and what went to the link decodes,
    /// callsign included.
    [Fact]
    public void AnOverDecodesWithItsCallsign() => Pump.Run(pump =>
    {
        var speech48k = new DigiResampler(48000).Convert(DecodedSpeech(4), 16000);
        var link = new FakeLink();
        var microphone = new FakeMicrophone();
        var sender = Sender(pump, link, microphone);
        var states = new List<FreeDvSender.SenderState>();
        sender.StateChanged += states.Add;

        sender.Start(FreeDvSender.Trigger.Toggle);
        Assert.Equal(FreeDvSender.SenderState.Transmitting, sender.State);
        Assert.True(microphone.Running);
        Assert.Equal([true], link.KeyedCalls);

        foreach (var chunk in Chunked(speech48k, 480))
        {
            microphone.Samples!(chunk, 48000);
        }
        // Let the chunks through before RX, as they would have been.
        var delivered = false;
        pump.Post(() => delivered = true);
        pump.RunUntil(() => delivered, 5);
        // The meter shows the last chunk's peak.
        Assert.Equal(20 * Math.Log10(Chunked(speech48k, 480).Last().Max(Math.Abs)), sender.MicPeakDb, 0.01);
        sender.Finish();
        Assert.Equal(FreeDvSender.SenderState.Finishing, sender.State);
        Assert.False(microphone.Running);
        pump.RunUntil(() => sender.State == FreeDvSender.SenderState.Idle, 10);
        Assert.Equal([true, false], link.KeyedCalls);
        Assert.Equal([FreeDvSender.SenderState.Transmitting, FreeDvSender.SenderState.Finishing,
            FreeDvSender.SenderState.Idle], states);

        // The 200 ms of silence ahead of the first modem frame.
        const int leadSamples = 1600;
        Assert.True(link.FirstSendBytes >= (leadSamples + 960) * 2);
        Assert.All(link.Audio.Take(leadSamples * 2), b => Assert.Equal(0, b));

        var audio = link.Audio.ToArray();
        var samples = new float[audio.Length / 2];
        for (var i = 0; i < samples.Length; i++)
        {
            samples[i] = BitConverter.ToInt16(audio, i * 2) / 32767f;
        }
        // Lead + 4 s of speech + the end-of-over + 200 ms tail.
        Assert.InRange(samples.Length / 8000.0, 4.2, 5.2);
        Assert.InRange(samples.Max(Math.Abs), 0.15f, 0.9999f);
        float[] received = [.. new float[4000], .. samples, .. new float[8000]];
        var result = Decode([received]);
        Assert.Equal(["TE5T"], result.Callsigns);
        Assert.True(result.Speech.Length / 16000.0 > 2);
    });

    [Fact]
    public void ReleasingSpaceEndsOnlyAMomentaryOver() => Pump.Run(pump =>
    {
        var sender = Sender(pump, new FakeLink(), new FakeMicrophone());
        sender.Start(FreeDvSender.Trigger.Toggle);
        sender.ReleaseMomentary();
        Assert.Equal(FreeDvSender.SenderState.Transmitting, sender.State);
        sender.Stop();
        Assert.Equal(FreeDvSender.SenderState.Idle, sender.State);

        sender.Start(FreeDvSender.Trigger.Momentary);
        sender.ReleaseMomentary();
        Assert.Equal(FreeDvSender.SenderState.Finishing, sender.State);
        pump.RunUntil(() => sender.State == FreeDvSender.SenderState.Idle, 10);
    });

    [Fact]
    public void StopsWhenTheRigUnkeysElsewhere() => Pump.Run(pump =>
    {
        var link = new FakeLink { ReportsKeyed = false };
        var microphone = new FakeMicrophone();
        var sender = Sender(pump, link, microphone);
        sender.Start(FreeDvSender.Trigger.Toggle);
        // 2 s grace + 1 s off, at 20×.
        pump.RunUntil(() => sender.State == FreeDvSender.SenderState.Idle, 5);
        Assert.NotNull(sender.Message);
        Assert.Equal([true, false], link.KeyedCalls);
        Assert.False(microphone.Running);
    });

    [Fact]
    public void StopsWhenTheGateCloses() => Pump.Run(pump =>
    {
        var link = new FakeLink();
        var sender = Sender(pump, link, new FakeMicrophone());
        sender.Start(FreeDvSender.Trigger.Toggle);
        link.BlockWhileKeyed = "outside your privileges";
        pump.RunUntil(() => sender.State == FreeDvSender.SenderState.Idle, 5);
        Assert.Equal("outside your privileges", sender.Message);
        Assert.Equal([true, false], link.KeyedCalls);
    });

    [Fact]
    public void LevelIsRelativeToFreeDvsScale()
    {
        Assert.Equal(RadeEncoder.NominalOutputScale, FreeDvSender.Gain(0), 1e-6);
        Assert.Equal(RadeEncoder.NominalOutputScale * 0.501, FreeDvSender.Gain(-6), 1e-3);
    }
}
