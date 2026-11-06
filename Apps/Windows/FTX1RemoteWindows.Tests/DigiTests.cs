using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services.Digi;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// RTTY/PSK (Services/Digi/): the Windows port of the Mac's FTX1DigiTests —
/// code tables, modulator → demodulator round trips on synthesized signals,
/// and the sender's pacing/keying with a fake link and clock.
public class DigiTests
{
    // Code tables

    [Fact]
    public void VaricodeRoundTrips()
    {
        var decoder = new Varicode.Decoder();
        var text = new System.Text.StringBuilder();
        foreach (var bit in Varicode.Encode("CQ de W1AW 73 k\n"))
        {
            if (decoder.Push(bit) is { } ascii)
            {
                text.Append((char)ascii);
            }
        }
        Assert.Equal("CQ de W1AW 73 k\n", text.ToString());
    }

    [Fact]
    public void VaricodeCodesAreWellFormed()
    {
        // Each code starts and ends with 1 and never contains "00".
        foreach (var code in Varicode.Codes)
        {
            Assert.StartsWith("1", code);
            Assert.EndsWith("1", code);
            Assert.DoesNotContain("00", code);
        }
        Assert.Equal(128, Varicode.Codes.Distinct().Count());
    }

    [Fact]
    public void BaudotRoundTrips()
    {
        var decoder = new Baudot.Decoder();
        var text = new System.Text.StringBuilder();
        foreach (var code in Baudot.Encode("CQ DE W1AW 599 73"))
        {
            var c = decoder.Decode(code);
            if (c != '\0')
            {
                text.Append(c);
            }
        }
        Assert.Equal("CQ DE W1AW 599 73", text.ToString());
    }

    // Round trips

    private static float[] Modulate(IDigiModulator modulator, string text)
    {
        var queue = new Queue<char>(text);
        var audio = new List<float>(new float[4000]); // half a second of silence first
        var tail = false;
        while (!modulator.IsFinished)
        {
            if (queue.Count == 0 && !tail)
            {
                modulator.BeginTail();
                tail = true;
            }
            audio.AddRange(modulator.Render(160, () => queue.Count > 0 ? queue.Dequeue() : '\0'));
        }
        audio.AddRange(new float[4000]);
        return [.. audio];
    }

    private static string Decode(DigiDecoder decoder, float[] audio)
    {
        var text = new System.Text.StringBuilder();
        for (var i = 0; i < audio.Length; i += 2048)
        {
            text.Append(decoder.Process(audio[i..Math.Min(audio.Length, i + 2048)], 8000).Text);
        }
        return text.ToString();
    }

    private static float[] AddNoise(float[] audio, float amplitude, int seed)
    {
        var random = new Random(seed);
        var noisy = new float[audio.Length];
        for (var i = 0; i < audio.Length; i++)
        {
            // Sum of uniforms: close enough to Gaussian for a test.
            var n = (float)(random.NextDouble() + random.NextDouble() + random.NextDouble() + random.NextDouble() - 2);
            noisy[i] = audio[i] + n * amplitude;
        }
        return noisy;
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void RttyRoundTrips(bool upperSideband)
    {
        var settings = new RttySettings();
        var tones = settings.Tones(2210, upperSideband);
        var audio = Modulate(new RttyModulator(tones.MarkHz, tones.SpaceHz, settings.Baud, 0.5f), "CQ CQ DE W1AW 599 73");
        var decoderSettings = settings with { Reverse = settings.EffectiveReverse(upperSideband) };
        var decoder = new DigiDecoder(DigiMode.Rtty, decoderSettings, 2210, afc: true, squelch: 0.3f);
        Assert.Contains("CQ CQ DE W1AW 599 73", Decode(decoder, audio));
    }

    [Fact]
    public void RttyDecodesInNoise()
    {
        var settings = new RttySettings();
        var tones = settings.Tones(2210, upperSideband: false);
        var clean = Modulate(new RttyModulator(tones.MarkHz, tones.SpaceHz, settings.Baud, 0.5f), "RYRYRY CQ DE K1ABC K");
        var decoder = new DigiDecoder(DigiMode.Rtty, settings, 2210, afc: true, squelch: 0.3f);
        Assert.Contains("CQ DE K1ABC K", Decode(decoder, AddNoise(clean, 0.15f, 1)));
    }

    [Fact]
    public void RttyFollowsADriftedSignalWithAfc()
    {
        var settings = new RttySettings();
        // Sent 12 Hz higher than the decoder is told.
        var tones = settings.Tones(2222, upperSideband: false);
        var audio = Modulate(new RttyModulator(tones.MarkHz, tones.SpaceHz, settings.Baud, 0.5f), "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 1234567890");
        var decoder = new DigiDecoder(DigiMode.Rtty, settings, 2210, afc: true, squelch: 0.3f);
        Assert.Contains("LAZY DOG", Decode(decoder, audio));
    }

    [Theory]
    [InlineData(DigiMode.Bpsk31)]
    [InlineData(DigiMode.Bpsk63)]
    public void PskRoundTrips(DigiMode mode)
    {
        var audio = Modulate(new PskModulator(1000, mode.PskBaud(), 0.5f), "CQ CQ de W1AW pse k\n");
        var decoder = new DigiDecoder(mode, new RttySettings(), 1000, afc: true, squelch: 0.3f);
        Assert.Contains("CQ CQ de W1AW pse k", Decode(decoder, audio));
    }

    [Fact]
    public void PskDecodesInNoise()
    {
        var clean = Modulate(new PskModulator(1000, 31.25, 0.5f), "CQ CQ de K1ABC pse k\n");
        var decoder = new DigiDecoder(DigiMode.Bpsk31, new RttySettings(), 1000, afc: true, squelch: 0.3f);
        Assert.Contains("de K1ABC pse k", Decode(decoder, AddNoise(clean, 0.2f, 2)));
    }

    [Fact]
    public void PskResamplesFrom44100()
    {
        var audio = Modulate(new PskModulator(1000, 31.25, 0.5f), "CQ de W1AW k\n");
        // Linear-interpolated up to 44.1 kHz; the decoder resamples back.
        var ratio = 44100.0 / 8000;
        var up = new float[(int)(audio.Length * ratio)];
        for (var i = 0; i < up.Length; i++)
        {
            var position = i / ratio;
            var index = (int)position;
            var fraction = (float)(position - index);
            var next = index + 1 < audio.Length ? audio[index + 1] : audio[index];
            up[i] = audio[index] * (1 - fraction) + next * fraction;
        }
        var decoder = new DigiDecoder(DigiMode.Bpsk31, new RttySettings(), 1000, afc: true, squelch: 0.3f);
        var text = new System.Text.StringBuilder();
        for (var i = 0; i < up.Length; i += 2048)
        {
            text.Append(decoder.Process(up[i..Math.Min(up.Length, i + 2048)], 44100).Text);
        }
        Assert.Contains("de W1AW k", text.ToString());
    }

    [Theory]
    [InlineData(DigiMode.Rtty)]
    [InlineData(DigiMode.Bpsk31)]
    public void NoiseAloneDecodesNothing(DigiMode mode)
    {
        var decoder = new DigiDecoder(mode, new RttySettings(), mode == DigiMode.Rtty ? 2210 : 1000, afc: true, squelch: 0.3f);
        var noise = AddNoise(new float[8000 * 20], 0.2f, 3);
        Assert.Equal("", Decode(decoder, noise).Trim());
    }

    [Fact]
    public void DecoderEmitsSpectrumRowsOfTheStripSpan()
    {
        var decoder = new DigiDecoder(DigiMode.Bpsk31, new RttySettings(), 1000, afc: false, squelch: 0.3f);
        var tone = Enumerable.Range(0, 8000).Select(i => 0.5f * (float)Math.Sin(2 * Math.PI * 1500 * i / 8000)).ToArray();
        float[]? row = null;
        for (var i = 0; i < tone.Length; i += 2048)
        {
            row = decoder.Process(tone[i..Math.Min(tone.Length, i + 2048)], 8000).SpectrumRow ?? row;
        }
        Assert.NotNull(row);
        // 0–3 kHz at 3.9 Hz a bin; the tone's bin is the brightest.
        Assert.Equal(768, row!.Length);
        var peakBin = Array.IndexOf(row, row.Max());
        Assert.InRange(peakBin * 8000.0 / 2048, 1480, 1520);
    }

    // Settings and modes

    [Fact]
    public void RttyTonesFollowTheSideband()
    {
        var settings = new RttySettings(); // 170 Hz
        Assert.Equal((2125.0, 2295.0), settings.Tones(2210, upperSideband: false));
        Assert.Equal((2295.0, 2125.0), settings.Tones(2210, upperSideband: true));
        // "Reverse" means this station sends upside down, whatever the sideband.
        Assert.Equal((2295.0, 2125.0), (settings with { Reverse = true }).Tones(2210, upperSideband: false));
        Assert.Equal((2125.0, 2295.0), (settings with { Reverse = true }).Tones(2210, upperSideband: true));
    }

    // Sender

    private sealed class FakeLink : IDigiTransmitLink
    {
        public string? Block { get; set; }
        public RigMode? TransmitMode { get; set; } = RigMode.DataUsb;
        public bool RigIsKeyed { get; set; }
        public bool KeyReads { get; set; } = true;
        public List<bool> KeyChanges { get; } = [];
        public int AudioBytes { get; set; }
        public string? TransmitBlock(bool keyedBySender) => Block;
        public bool ReadsKeyed => KeyChanges.Count > 0 && KeyChanges[^1] && KeyReads;
        public void SetKeyed(bool keyed)
        {
            KeyChanges.Add(keyed);
            RigIsKeyed = keyed && KeyReads;
        }
        public void SendAudio(byte[] pcm) => AudioBytes += pcm.Length;
    }

    private sealed class FakeSource : IDigiTxSource
    {
        public DigiMode Mode { get; set; } = DigiMode.Bpsk31;
        public double TrackedHz { get; set; } = 1000;
        public double CenterHz { get; set; } = 1000;
        public RttySettings Rtty { get; set; } = new();
    }

    /// Virtual time: sleeping advances it, then yields so the test can
    /// interleave.
    private sealed class FakeClock : IDigiSenderClock
    {
        private double _now;
        public double Now() => _now;
        public async Task SleepAsync(double seconds, CancellationToken cancellationToken)
        {
            _now += seconds;
            await Task.Yield();
        }
    }

    private static DigiSender MakeSender(FakeLink link, FakeSource? source = null, List<string>? echo = null)
    {
        var sender = new DigiSender(link, source ?? new FakeSource(), () => "W1AW", () => "FN31", -6, clock: new FakeClock());
        if (echo is not null)
        {
            sender.Echo += echo.Add;
        }
        return sender;
    }

    private static async Task WaitUntil(Func<bool> condition)
    {
        for (var i = 0; i < 5000 && !condition(); i++)
        {
            await Task.Delay(1);
        }
        Assert.True(condition(), "timed out");
    }

    [Theory]
    [InlineData(DigiMode.Bpsk31)]
    [InlineData(DigiMode.Rtty)]
    public async Task TypedTextGoesOutThenTheRigUnkeys(DigiMode mode)
    {
        var link = new FakeLink();
        var echo = new List<string>();
        var sender = MakeSender(link, new FakeSource { Mode = mode, TrackedHz = mode == DigiMode.Rtty ? 2210 : 1000 }, echo);
        sender.Edit("HI");
        sender.Transmit();
        Assert.Equal(DigiSender.SenderState.Transmitting, sender.State);
        sender.Finish();
        await WaitUntil(() => sender.State == DigiSender.SenderState.Idle);

        Assert.Equal([true, false], link.KeyChanges);
        Assert.True(link.AudioBytes > 0);
        Assert.Equal("HI\n", string.Concat(echo));
        Assert.Equal("", sender.Text);
        Assert.Null(sender.TransmitStartedAt);
    }

    [Fact]
    public async Task TextTypedWhileTransmittingGoesOutToo()
    {
        var link = new FakeLink();
        var echo = new List<string>();
        var sender = MakeSender(link, echo: echo);
        sender.Transmit();
        sender.Append("AB");
        await WaitUntil(() => sender.SentCount == 2);
        sender.Append("C");
        await WaitUntil(() => sender.SentCount == 3);
        sender.Finish();
        await WaitUntil(() => sender.State == DigiSender.SenderState.Idle);
        Assert.Equal("ABC\n", string.Concat(echo));
    }

    [Fact]
    public async Task SentTextCantBeEdited()
    {
        var link = new FakeLink();
        var sender = MakeSender(link);
        sender.Transmit();
        sender.Append("ABC");
        await WaitUntil(() => sender.SentCount == 3);
        Assert.Equal("ABC", sender.Edit("XBC"));
        Assert.Equal("ABCD", sender.Edit("ABCD"));
        sender.Stop();
    }

    [Fact]
    public void StopUnkeysAtOnceAndDropsUnsentText()
    {
        var link = new FakeLink();
        var sender = MakeSender(link);
        sender.Edit("A LONG MESSAGE THAT WON'T FINISH");
        sender.Transmit();
        sender.Stop();
        Assert.Equal(DigiSender.SenderState.Idle, sender.State);
        Assert.Equal([true, false], link.KeyChanges);
        Assert.Equal("", sender.Text);
    }

    [Fact]
    public void ABlockedTransmitNeverKeys()
    {
        var link = new FakeLink { Block = "Transmit disabled" };
        var sender = MakeSender(link);
        sender.Transmit();
        Assert.Equal(DigiSender.SenderState.Idle, sender.State);
        Assert.Empty(link.KeyChanges);
        Assert.Equal("Transmit disabled", sender.Message);
    }

    [Fact]
    public void OnlyAudioPassingModesTransmit()
    {
        var link = new FakeLink { TransmitMode = RigMode.Fm };
        var sender = MakeSender(link);
        Assert.NotNull(sender.BlockReason);
        sender.Transmit();
        Assert.Empty(link.KeyChanges);
        foreach (var mode in new[] { RigMode.DataUsb, RigMode.Usb, RigMode.Lsb })
        {
            link.TransmitMode = mode;
            Assert.Null(sender.BlockReason);
        }
    }

    [Fact]
    public async Task TheGateClosingMidTransmissionUnkeys()
    {
        var link = new FakeLink();
        var sender = MakeSender(link);
        sender.Edit("CQ");
        sender.Transmit();
        link.Block = "Transmit disabled";
        await WaitUntil(() => sender.State == DigiSender.SenderState.Idle);
        Assert.Equal([true, false], link.KeyChanges);
        Assert.Equal("Transmit disabled", sender.Message);
    }

    [Fact]
    public async Task ThreeMinutesIsTheLimit()
    {
        var link = new FakeLink();
        var sender = MakeSender(link);
        sender.Transmit(); // idles on reversals forever
        await WaitUntil(() => sender.State == DigiSender.SenderState.Idle);
        Assert.Equal([true, false], link.KeyChanges);
        Assert.NotNull(sender.Message);
    }

    [Fact]
    public async Task LosingThePttReadingStopsIt()
    {
        var link = new FakeLink { KeyReads = false };
        var sender = MakeSender(link);
        sender.Transmit();
        await WaitUntil(() => sender.State == DigiSender.SenderState.Idle);
        Assert.Equal([true, false], link.KeyChanges);
        Assert.NotNull(sender.Message);
    }

    // Macros

    [Fact]
    public void MacrosExpandTheirPlaceholders()
    {
        var macro = new DigiMacro("Answer", "{TX}\n{CALL} de {MYCALL} k\n{RX}");
        var result = macro.Expand("W1AW", "FN31", "K6NA");
        Assert.Null(result.Problem);
        Assert.True(result.StartsTransmit);
        Assert.True(result.EndsTransmit);
        Assert.Equal("\nK6NA de W1AW k\n", result.Text);
    }

    [Fact]
    public void AMacroNeedsTheValuesItUses()
    {
        var macro = new DigiMacro("73", "{CALL} 73 de {MYCALL}");
        Assert.NotNull(macro.Expand("W1AW", "FN31", "").Problem);
        Assert.NotNull(macro.Expand("", "FN31", "K6NA").Problem);
        Assert.Null(new DigiMacro("QRZ", "QRZ?").Expand("", "", "").Problem);
    }

    [Fact]
    public async Task RunningAMacroStartsAndEndsTheTransmission()
    {
        var link = new FakeLink();
        var echo = new List<string>();
        var sender = MakeSender(link, echo: echo);
        sender.TheirCall = "K6NA";
        sender.Run(new DigiMacro("Answer", "{TX}K6NA de W1AW{RX}"));
        await WaitUntil(() => sender.State == DigiSender.SenderState.Idle);
        Assert.Equal([true, false], link.KeyChanges);
        Assert.Equal("K6NA de W1AW\n", string.Concat(echo));
    }
}
