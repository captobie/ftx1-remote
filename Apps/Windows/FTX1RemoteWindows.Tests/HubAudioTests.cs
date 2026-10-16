using FTX1RemoteWindows.Services.Hub;
using Xunit;
using Xunit.Abstractions;

namespace FTX1RemoteWindows.Tests;

/// Phase 3's receive audio (Apps/Windows/README.md, "Desktop hub for the
/// iPad"): HubAudioEncoder's rate, length, level and anti-alias filter,
/// fed in the sources' real chunk size, and the two frames committed to
/// Tests/WireFixtures/windows/ for the Mac's HubWireFixtureTests.
public class HubAudioTests(ITestOutputHelper output)
{
    /// RemoteAudioStreamClient and LocalAudioCapture both deliver 2048.
    private const int ChunkSize = 2048;
    private const float HalfScale = 0.5011872f; // −6 dBFS

    private static float[] Sine(double hz, int rate, double seconds, float amplitude = HalfScale)
    {
        var samples = new float[(int)(rate * seconds)];
        for (var i = 0; i < samples.Length; i++)
        {
            samples[i] = amplitude * (float)Math.Sin(2 * Math.PI * hz * i / rate);
        }
        return samples;
    }

    /// Every chunk through one encoder, as the hub does; returns the frames.
    private static List<byte[]> EncodeChunks(HubAudioEncoder encoder, float[] input, int rate, byte? tag = null)
    {
        var frames = new List<byte[]>();
        for (var offset = 0; offset < input.Length; offset += ChunkSize)
        {
            var count = Math.Min(ChunkSize, input.Length - offset);
            frames.Add(encoder.Encode(input.AsSpan(offset, count), rate, tag));
        }
        return frames;
    }

    private static float[] Pcm(IEnumerable<byte[]> frames, int header = 0)
    {
        var samples = new List<float>();
        foreach (var frame in frames)
        {
            for (var i = header; i + 1 < frame.Length; i += 2)
            {
                samples.Add((short)(frame[i] | (frame[i + 1] << 8)) / 32768f);
            }
        }
        return [.. samples];
    }

    private static double Rms(ReadOnlySpan<float> samples)
    {
        double sum = 0;
        foreach (var s in samples)
        {
            sum += s * s;
        }
        return Math.Sqrt(sum / samples.Length);
    }

    /// Frequency from rising zero crossings (interpolated), over a span.
    private static double ToneHz(ReadOnlySpan<float> samples, int rate)
    {
        double first = -1, last = -1;
        var crossings = 0;
        for (var i = 1; i < samples.Length; i++)
        {
            if (samples[i - 1] < 0 && samples[i] >= 0)
            {
                var t = i - 1 + samples[i - 1] / (samples[i - 1] - samples[i]);
                if (first < 0)
                {
                    first = t;
                }
                last = t;
                crossings++;
            }
        }
        return (crossings - 1) * rate / (last - first);
    }

    /// Gain at <paramref name="hz"/> through the encoder, steady state, in dB.
    private static double GainDb(double hz, int rate)
    {
        var encoder = new HubAudioEncoder();
        var pcm = Pcm(EncodeChunks(encoder, Sine(hz, rate, 1.5, 0.5f), rate));
        var steady = pcm.AsSpan(pcm.Length / 3);
        return 20 * Math.Log10(Rms(steady) / (0.5 / Math.Sqrt(2)));
    }

    [Theory]
    [InlineData(44100)]
    [InlineData(48000)]
    public void OutputIs8kHzAtTheInputLevel(int rate)
    {
        var encoder = new HubAudioEncoder();
        var seconds = 3.0;
        var frames = EncodeChunks(encoder, Sine(1000, rate, seconds), rate);
        var pcm = Pcm(frames);

        // One frame per chunk, ~46 ms (44.1 kHz) / ~43 ms (48 kHz) of audio each.
        Assert.Equal((int)Math.Ceiling(rate * seconds / ChunkSize), frames.Count);
        var expected = HubAudioEncoder.OutputSampleRate * seconds;
        output.WriteLine($"{rate} Hz: {pcm.Length} samples out for {seconds} s (expected ~{expected})");
        // Only the filter's latency is missing.
        Assert.InRange(pcm.Length, expected - 200, expected + 2);
        // After the first frame, each frame's length is the chunk's share of 8 kHz.
        var perChunk = (double)ChunkSize * HubAudioEncoder.OutputSampleRate / rate;
        foreach (var frame in frames.Skip(1).SkipLast(1))
        {
            Assert.InRange(frame.Length / 2, Math.Floor(perChunk) - 1, Math.Ceiling(perChunk) + 1);
        }

        var steady = pcm.AsSpan(HubAudioEncoder.OutputSampleRate / 2);
        var tone = ToneHz(steady, HubAudioEncoder.OutputSampleRate);
        output.WriteLine($"tone {tone:F2} Hz");
        Assert.InRange(tone, 999, 1001);
        var peak = 0f;
        foreach (var s in steady)
        {
            peak = Math.Max(peak, Math.Abs(s));
        }
        output.WriteLine($"peak {peak:F4} (input {HalfScale:F4})");
        Assert.InRange(peak, HalfScale * 0.97, HalfScale * 1.03);
    }

    [Theory]
    [InlineData(44100)]
    [InlineData(48000)]
    public void PassbandIsFlatAndAboveNyquistIsRemoved(int rate)
    {
        foreach (var hz in new[] { 300.0, 1000, 2000, 3000, 3500 })
        {
            var db = GainDb(hz, rate);
            output.WriteLine($"{rate}: {hz} Hz → {db:F2} dB");
            Assert.InRange(db, -1.0, 0.5);
        }
        // Above 4 kHz aliases back into 0–4 kHz at 8 kHz output, so it has to go.
        foreach (var hz in new[] { 4400.0, 5000, 6000, 8000, 12000 })
        {
            var db = GainDb(hz, rate);
            output.WriteLine($"{rate}: {hz} Hz → {db:F2} dB (alias)");
            Assert.True(db < -40, $"{hz} Hz at {rate} Hz input only down {db:F1} dB");
        }
    }

    [Fact]
    public void ARateChangeRebuildsTheResampler()
    {
        var encoder = new HubAudioEncoder();
        EncodeChunks(encoder, Sine(1000, 44100, 1), 44100);
        var pcm = Pcm(EncodeChunks(encoder, Sine(1000, 48000, 2), 48000));
        var tone = ToneHz(pcm.AsSpan(pcm.Length / 2), HubAudioEncoder.OutputSampleRate);
        Assert.InRange(tone, 999, 1001);
    }

    [Fact]
    public void FramesStartWithTheTag()
    {
        var encoder = new HubAudioEncoder();
        var frames = EncodeChunks(encoder, Sine(1000, 44100, 0.5), 44100, tag: 0x01);
        Assert.All(frames, f => Assert.Equal(0x01, f[0]));
        Assert.All(frames, f => Assert.Equal(1, f.Length % 2));
    }

    /// One whole frame per file: the tag, then all the PCM from 1 s of a
    /// −6 dBFS 1000 Hz sine fed in production-sized chunks through the real
    /// encoder, concatenated. Commit both files; the Mac's
    /// HubWireFixtureTests checks the tag, ~8000 samples, the tone and the
    /// level.
    [Theory]
    [InlineData("audio-main-1000hz-from44100.bin", 44100, 0x00)]
    [InlineData("audio-sub-1000hz-from48000.bin", 48000, 0x01)]
    public void WritesWindowsAudioFixture(string fileName, int rate, byte tag)
    {
        var encoder = new HubAudioEncoder();
        var frames = EncodeChunks(encoder, Sine(1000, rate, 1), rate, tag);
        using var file = new MemoryStream();
        file.WriteByte(tag);
        foreach (var frame in frames)
        {
            Assert.Equal(tag, frame[0]);
            file.Write(frame, 1, frame.Length - 1);
        }
        var bytes = file.ToArray();
        var samples = (bytes.Length - 1) / 2;
        output.WriteLine($"{fileName}: {samples} samples");
        Assert.InRange(samples, 7800, 8002);

        var dir = Path.Combine(HubWireTests.FixturesDir, "windows");
        Directory.CreateDirectory(dir);
        File.WriteAllBytes(Path.Combine(dir, fileName), bytes);
    }
}
