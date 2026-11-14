using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.Ft8;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// The Windows counterpart of Tests/FT8KitTests: real off-air FT8 captures
/// (and the synthetic FT4 one) vendored from ft8_lib, run through the same
/// ft8_lib via ft8lib.dll. Expected sets are what ft8_lib's own decode_ft8
/// demo finds in the same files (see FT8ReferenceVectorTests.swift).
public class Ft8Tests
{
    public static IEnumerable<object[]> Ft8Vectors() =>
    [
        ["191111_110130", new[] { "CQ R7IW LN35", "CQ DX R6WA LN32", "CQ TA6CQ KN70", "OH3NIV ZS6S -03" }],
        ["191111_110145", new[] { "GJ0KYZ RK9AX MO05", "<...> RY8CAA" }],
        ["191111_110200", new[] { "CQ DX R6WA LN32", "CQ TA6CQ KN70", "CQ R7IW LN35", "CQ LZ1JZ KN22" }],
    ];

    [Theory]
    [MemberData(nameof(Ft8Vectors))]
    public void ReferenceVectorsDecodeExpectedMessages(string name, string[] expected)
    {
        var decoded = Decode(name, Ft8Mode.Ft8).Select(m => m.Text).ToHashSet();
        foreach (var message in expected)
        {
            Assert.True(decoded.Contains(message), $"{name}: \"{message}\" not among {string.Join(" | ", decoded.Order())}");
        }
    }

    [Fact]
    public void SyntheticFt4VectorDecodesExpectedMessages()
    {
        var decoded = Decode("ft4_synthetic", Ft8Mode.Ft4).Select(m => m.Text).ToHashSet();
        foreach (var message in new[] { "W9XYZ K1ABC -11", "CQ K1ABC FN42", "CQ DX VE3ZZ EN93", "K1ABC W9XYZ R-09" })
        {
            Assert.True(decoded.Contains(message), $"\"{message}\" not among {string.Join(" | ", decoded.Order())}");
        }
    }

    [Fact]
    public void Ft4RecordingDecodesNothingAsFt8()
    {
        Assert.Empty(Decode("ft4_synthetic", Ft8Mode.Ft8));
    }

    /// The live path end to end: 44.1 kHz chunks (the app's capture rate) into
    /// the coordinator, resampled to 12 kHz, accumulated in blocks and decoded
    /// at the next UTC slot boundary. Waits for real slot boundaries (FT4's
    /// 7.5 s), so it takes up to ~15 s.
    [Fact]
    public async Task CoordinatorDecodesAFeedAt44100()
    {
        var (samples, rate) = LoadWav(Path.Combine(AppContext.BaseDirectory, "Ft8Fixtures", "ft4_synthetic.wav"));
        var upsampled = new FTX1RemoteWindows.Services.Digi.DigiResampler(44100).Convert(samples, rate);

        var spots = new TaskCompletionSource<IReadOnlyList<Ft8CoordinatorSpot>>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var coordinator = new Ft8DecodeCoordinator(Ft8Mode.Ft4, work => work())
        {
            DialFrequencyProvider = _ => 14_080_000,
        };
        coordinator.SpotsDecoded += decoded => spots.TrySetResult(decoded);

        // Start just after a slot boundary, so the whole recording lands in one slot.
        while ((DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0) % 7.5 > 0.4)
        {
            await Task.Delay(20);
        }
        coordinator.Start();
        await Task.Delay(100);
        for (var offset = 0; offset < upsampled.Length; offset += 2048)
        {
            var chunk = upsampled[offset..Math.Min(offset + 2048, upsampled.Length)];
            coordinator.Ingest(chunk, 44100, CwAudioChannel.Main);
        }
        // Another source's audio is ignored.
        coordinator.Ingest(new float[2048], 44100, CwAudioChannel.Sub);

        var decoded = await spots.Task.WaitAsync(TimeSpan.FromSeconds(14));
        var texts = decoded.Select(s => s.Message.Text).ToHashSet();
        foreach (var message in new[] { "W9XYZ K1ABC -11", "CQ K1ABC FN42", "CQ DX VE3ZZ EN93", "K1ABC W9XYZ R-09" })
        {
            Assert.Contains(message, texts);
        }
        Assert.All(decoded, s => Assert.Equal(14_080_000, s.DialFrequencyHz));
        Assert.All(decoded, s => Assert.Equal(CwAudioChannel.Main, s.Channel));
        coordinator.Stop();
    }
    [Fact]
    public void FieldsAreClassifiedAndPositioned()
    {
        var message = Decode("191111_110130", Ft8Mode.Ft8).Single(m => m.Text == "CQ TA6CQ KN70");
        Assert.Equal(
            [Ft8FieldKind.Token, Ft8FieldKind.Call, Ft8FieldKind.Grid],
            message.Fields.Select(f => f.Kind).ToArray());
        Assert.Equal(["CQ", "TA6CQ", "KN70"], message.Fields.Select(f => f.Text).ToArray());
        // The truth file has it at 683 Hz.
        Assert.InRange(message.FrequencyOffsetHz, 670, 700);
    }

    [Fact]
    public void GridFieldsAreCorrected()
    {
        var split = Ft8Decoder.Classified(new Ft8MessageField(Ft8FieldKind.Grid, "R FN42")).ToList();
        Assert.Equal([new Ft8MessageField(Ft8FieldKind.Token, "R"), new Ft8MessageField(Ft8FieldKind.Grid, "FN42")], split);
        var rr73 = Ft8Decoder.Classified(new Ft8MessageField(Ft8FieldKind.Grid, "RR73")).Single();
        Assert.Equal(new Ft8MessageField(Ft8FieldKind.Token, "RR73"), rr73);
        var call = new Ft8MessageField(Ft8FieldKind.Call, "K1ABC");
        Assert.Equal([call], Ft8Decoder.Classified(call).ToList());
    }

    [Fact]
    public void SlotTimingMatchesTheProtocols()
    {
        Assert.Equal(1920, Ft8Mode.Ft8.BlockSize(12000));
        Assert.Equal(576, Ft8Mode.Ft4.BlockSize(12000));
        Assert.Equal(15.0, Ft8Mode.Ft8.SlotSeconds());
        Assert.Equal(7.5, Ft8Mode.Ft4.SlotSeconds());
    }

    private static List<Ft8RawMessage> Decode(string name, Ft8Mode mode)
    {
        var (samples, rate) = LoadWav(Path.Combine(AppContext.BaseDirectory, "Ft8Fixtures", name + ".wav"));
        using var decoder = new Ft8Decoder(rate, mode);
        for (var offset = 0; offset + decoder.BlockSize <= samples.Length; offset += decoder.BlockSize)
        {
            decoder.Process(samples[offset..(offset + decoder.BlockSize)]);
        }
        return decoder.Decode();
    }

    /// Minimal WAV reader: 16-bit PCM or 32-bit float, first channel.
    private static (float[] Samples, int Rate) LoadWav(string path)
    {
        var data = File.ReadAllBytes(path);
        int rate = 12000, channels = 1, bits = 16, format = 1, dataStart = 0, dataLength = 0;
        var offset = 12;
        while (offset + 8 <= data.Length)
        {
            var id = System.Text.Encoding.ASCII.GetString(data, offset, 4);
            var size = BitConverter.ToInt32(data, offset + 4);
            var start = offset + 8;
            if (id == "fmt ")
            {
                format = BitConverter.ToUInt16(data, start);
                channels = BitConverter.ToUInt16(data, start + 2);
                rate = BitConverter.ToInt32(data, start + 4);
                bits = BitConverter.ToUInt16(data, start + 14);
            }
            else if (id == "data")
            {
                dataStart = start;
                dataLength = Math.Min(size, data.Length - start);
            }
            offset = start + size + (size % 2);
        }
        var frameSize = bits / 8 * channels;
        var samples = new float[dataLength / frameSize];
        for (var i = 0; i < samples.Length; i++)
        {
            var at = dataStart + i * frameSize;
            samples[i] = format == 3 && bits == 32 ? BitConverter.ToSingle(data, at) : BitConverter.ToInt16(data, at) / 32768f;
        }
        return (samples, rate);
    }
}
