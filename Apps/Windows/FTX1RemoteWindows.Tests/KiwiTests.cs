using System.Net;
using System.Net.WebSockets;
using System.Text;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// The MyKiwiSDR port against the Mac's own recorded frames
/// (Tests/KiwiSDRFixtures) and the Swift tests' expectations.
public class KiwiTests
{
    private static string Fixture(string name)
    {
        var dir = AppContext.BaseDirectory;
        while (dir is not null && !Directory.Exists(Path.Combine(dir, "Tests", "KiwiSDRFixtures")))
        {
            dir = Path.GetDirectoryName(dir);
        }
        return Path.Combine(dir ?? throw new DirectoryNotFoundException("repo root"), "Tests", "KiwiSDRFixtures", name);
    }

    private static KiwiSoundFrame Sound(string name) =>
        Assert.IsType<KiwiFrame.Sound>(KiwiProtocol.ParseFrame(File.ReadAllBytes(Fixture(name)))).Frame;

    [Fact]
    public void UncompressedFramesParse()
    {
        var first = Sound("snd-pcm-1-newfreq.bin");
        Assert.Equal(KiwiSoundFlags.LowPassFilter | KiwiSoundFlags.NewFrequency, first.Flags);
        Assert.Equal(1u, first.Sequence);
        Assert.Equal(0x0123, first.SmeterRaw);
        Assert.Equal(0.1 * 291 - 127, first.SmeterDbm, 9);
        Assert.Equal(512, first.PcmSamples().Length);

        var second = Sound("snd-pcm-2.bin");
        Assert.Equal(KiwiSoundFlags.None, second.Flags);
        var samples = second.PcmSamples();
        Assert.Equal(512, samples.Length);
        Assert.Equal(unchecked((short)0x10CE), samples[0]);
        Assert.Equal(unchecked((short)0x17DB), samples[1]);
    }

    [Fact]
    public void CompressedFramesDecodeWithCarriedState()
    {
        var frames = Enumerable.Range(1, 3).Select(i => Sound($"snd-adpcm-{i}.bin")).ToArray();
        Assert.Equal(new byte[] { 0x15, 0x10, 0x10 }, frames.Select(f => (byte)f.Flags).ToArray());
        Assert.Empty(frames[0].PcmSamples());
        var decoder = new KiwiSoundDecoder();
        var decoded = frames.Select(decoder.Samples).ToArray();
        Assert.All(decoded, d => Assert.Equal(2048, d.Length));
    }

    [Fact]
    public void WaterfallFramesParse()
    {
        var frame = Assert.IsType<KiwiFrame.Waterfall>(KiwiProtocol.ParseFrame(File.ReadAllBytes(Fixture("wf-zoom8.bin")))).Frame;
        Assert.Equal(8, frame.Zoom);
        Assert.Equal(1024, frame.Bins.Length);
        Assert.False(frame.IsCompressed);
    }

    [Fact]
    public void MessagesDecodePercentEscapes()
    {
        var items = KiwiProtocol.ParseMessage("badp=0 sample_rate=11998.9 name=a%20b flag");
        Assert.Equal(new KiwiMessageItem("name", "a b"), items[2]);
        Assert.Equal(new KiwiMessageItem("flag", null), items[3]);
        var frame = Assert.IsType<KiwiFrame.Message>(KiwiProtocol.ParseFrame(Encoding.UTF8.GetBytes("MSG badp=0")));
        Assert.Equal("badp", frame.Items[0].Name);
    }

    [Fact]
    public void CommandsMatchTheMac()
    {
        Assert.Equal("SET auth t=kiwi p=a%20b%26c", KiwiProtocol.Auth("a b&c"));
        Assert.Equal("SET mod=usb low_cut=300 high_cut=2700 freq=14074.000",
                     KiwiProtocol.Tune(14_074_000, KiwiSdrMode.Usb, 300, 2700));
        Assert.Equal("SET mod=nbfm low_cut=-6000 high_cut=6000 freq=146520.000",
                     KiwiTuning.Of(146_520_000, KiwiSdrMode.Fm).Command);
        // CW: the dial is the signal, the carrier sits below it by the passband's centre.
        Assert.Equal(14_047_500 - 500, KiwiTuning.Of(14_047_500, KiwiSdrMode.Cw).CarrierHz);
        var setup = KiwiProtocol.SetupCommands("FTX1Remote", false, new KiwiReceiverSettings());
        Assert.Equal("SET agc=1 hang=0 thresh=-100 slope=6 decay=1000 manGain=50", setup[3]);
        Assert.Equal(6, setup.Count);
    }

    [Fact]
    public void ReceiverCommandsFollowTheSettings()
    {
        var wild = new KiwiReceiverSettings { NoiseBlanker = KiwiNoiseBlanker.Wild };
        Assert.Contains("SET nb type=0 param=0 pval=0.95", wild.NoiseBlankerCommands);
        Assert.Equal("SET nb type=1 en=1", wild.NoiseBlankerCommands[^1]);
        var wdsp = new KiwiReceiverSettings().WithNoiseFilter(KiwiNoiseFilter.Wdsp);
        Assert.True(wdsp.Denoise);
        Assert.Contains("SET nr type=0 param=2 pval=8e-05", wdsp.NoiseFilterCommands);
        Assert.Contains("SET nr type=0 param=3 pval=0.125", wdsp.NoiseFilterCommands);
        // Only the group that changed is sent.
        var changed = (new KiwiReceiverSettings() with { Agc = false }).Commands(new KiwiReceiverSettings());
        Assert.Single(changed);
        Assert.StartsWith("SET agc=0", changed[0]);
    }

    [Theory]
    [InlineData("kiwi.local", "ws://kiwi.local:8073/1700000000/SND")]
    [InlineData("http://192.168.1.5:8074/", "ws://192.168.1.5:8074/1700000000/SND")]
    [InlineData("kiwi:99999", null)]
    [InlineData("a/b", null)]
    [InlineData("", null)]
    public void SoundUrlFromHostText(string text, string? expected) =>
        Assert.Equal(expected, KiwiProtocol.SoundUrl(text, 1_700_000_000)?.ToString());

    [Fact]
    public void WaterfallUrlSharesTheTimestamp() =>
        Assert.Equal("ws://k:8073/5/W/F", KiwiProtocol.WaterfallUrl("k", 5)?.ToString());

    [Fact]
    public void GeometryRoundTrips()
    {
        var g = new KiwiWaterfallGeometry();
        Assert.Equal(1024 << 14, g.MaxBins);
        Assert.Equal(30_000_000.0 / 256, g.SpanHz(8), 6);
        var start = g.Start(7_100_000, 8);
        Assert.InRange(g.HzAtColumn(512, start, 8), 7_100_000 - g.BinHz(8), 7_100_000 + g.BinHz(8));
        Assert.Equal(0, g.ClampStart(-5, 8));
        Assert.Equal(g.MaxBins - g.SpanUnits(8), g.ClampStart(int.MaxValue / 2, 8));
        Assert.Null(g.BinsToShift((0, 8), (0, 9)));
        Assert.Equal(3, g.BinsToShift((0, 8), (3 * g.UnitsPerBin(8), 8)));
    }

    [Fact]
    public void StartKeepingPansOnlyNearAnEdge()
    {
        var g = new KiwiWaterfallGeometry();
        var start = g.Start(7_100_000, 8);
        Assert.Null(g.StartKeeping(7_099_000, 7_101_500, start, 8));
        var panned = g.StartKeeping(7_150_000, 7_152_700, start, 8);
        Assert.NotNull(panned);
        Assert.True(panned > start);
    }

    [Fact]
    public void PlacementAndColumnMap()
    {
        var g = new KiwiWaterfallGeometry();
        Assert.IsType<KiwiWaterfallPlacement.Append>(KiwiWaterfallPlacement.Place((0, 8), null, g));
        Assert.IsType<KiwiWaterfallPlacement.Append>(KiwiWaterfallPlacement.Place((0, 8), (0, 8), g));
        var shift = Assert.IsType<KiwiWaterfallPlacement.Shift>(KiwiWaterfallPlacement.Place((2 * g.UnitsPerBin(8), 8), (0, 8), g));
        Assert.Equal(2, shift.Bins);
        Assert.IsType<KiwiWaterfallPlacement.Rezoom>(KiwiWaterfallPlacement.Place((0, 9), (0, 8), g));
        var map = KiwiWaterfallPlacement.ColumnMap((0, 8), (0, 9), g);
        Assert.Equal(0, map[0]);
        Assert.Equal(0, map[1]);
        Assert.Equal(1, map[2]);
        Assert.Equal(511, map[1023]);
    }

    [Fact]
    public void BitmapShiftsAndBlanks()
    {
        var bitmap = new KiwiWaterfallBitmap(4, 2, 0xFF000000);
        var colors = Enumerable.Range(0, 256).Select(i => 0xFF000000u | (uint)i).ToArray();
        bitmap.Append([10, 20, 30, 40], colors);
        bitmap.Shift(1);
        Assert.Equal(20, bitmap.Pixels[0]);
        Assert.Equal(40, bitmap.Pixels[8]);
        Assert.Equal(0, bitmap.Pixels[12]);
    }

    [Fact]
    public void AutoRangeUsesMedianAndPercentile()
    {
        var bins = Enumerable.Repeat((byte)120, 1000).Concat(Enumerable.Repeat((byte)200, 100)).ToArray();
        var (floor, ceiling) = KiwiWaterfallAutoRange.Measure(bins, -13)!.Value;
        Assert.Equal(KiwiWaterfallFrame.Dbm(120, -13) - 5, floor);
        Assert.Equal(KiwiWaterfallFrame.Dbm(200, -13) + 25, ceiling, 6);
        Assert.Null(KiwiWaterfallAutoRange.Measure(new byte[] { 1, 2, 3 }, -13));
        var steps = new KiwiWaterfallAutoRange();
        Assert.True(steps.Add(bins, -13));
        var table = steps.PaletteSteps(-13);
        Assert.Equal(0, table[0]);
        Assert.Equal(255, table[255]);
    }

    [Fact]
    public void PassbandDragRules()
    {
        var usb = KiwiPassband.DefaultFor(KiwiSdrMode.Usb);
        Assert.Equal(new KiwiPassband(300, 2700), usb);
        Assert.Equal(2200, usb.Dragging(KiwiPassband.Edge.High, 2204, KiwiSdrMode.Usb).High);
        // The low edge can't pass the high one or cross the carrier.
        Assert.Equal(0, usb.Dragging(KiwiPassband.Edge.Low, -400, KiwiSdrMode.Usb).Low);
        Assert.Equal(2640, usb.Dragging(KiwiPassband.Edge.Low, 5000, KiwiSdrMode.Usb).Low);
        var cw = KiwiPassband.DefaultFor(KiwiSdrMode.Cw).Dragging(KiwiPassband.Edge.High, 100, KiwiSdrMode.Cw);
        Assert.Equal(new KiwiPassband(400, 600), cw);
        Assert.True(new KiwiPassband(-2700, -300).IsValid(KiwiSdrMode.Lsb));
        Assert.False(new KiwiPassband(300, 2700).IsValid(KiwiSdrMode.Lsb));
        Assert.Equal("300–2700 Hz", usb.RangeText(KiwiSdrMode.Usb));
        Assert.Equal("300–2700 Hz", new KiwiPassband(-2700, -300).RangeText(KiwiSdrMode.Lsb));
    }

    // MARK: Rig link

    [Fact]
    public void FollowTunesTheKiwiOnceAndRespectsPending()
    {
        var link = new KiwiRigLink();
        var tune = Assert.IsType<KiwiRigLink.FollowDecision.Tune>(
            link.Follow(7_074_000, RigMode.DataUsb, 14_000_000, KiwiSdrMode.Lsb, 30_000_000, 0));
        Assert.Equal(7_074_000, tune.FrequencyHz);
        Assert.Equal(KiwiSdrMode.Usb, tune.Mode);
        Assert.IsType<KiwiRigLink.FollowDecision.AlreadyThere>(
            link.Follow(7_074_005, RigMode.Usb, 7_074_000, KiwiSdrMode.Usb, 30_000_000, 1));
        Assert.IsType<KiwiRigLink.FollowDecision.OutOfRange>(
            link.Follow(145_000_000, RigMode.Fm, 7_074_000, KiwiSdrMode.Usb, 30_000_000, 1));
        // A rig mode with no Kiwi equivalent leaves the Kiwi's mode alone.
        var keep = Assert.IsType<KiwiRigLink.FollowDecision.Tune>(
            link.Follow(7_040_000, RigMode.Rtty, 7_074_000, KiwiSdrMode.Usb, 30_000_000, 1));
        Assert.Null(keep.Mode);
    }

    [Fact]
    public void WindowTuneSendsToTheRigAndIgnoresItsEchoUntilItCatchesUp()
    {
        var link = new KiwiRigLink();
        var rig = new KiwiRigSnapshot(true, false, false, 7_074_000, RigMode.DataUsb);
        var send = Assert.IsType<KiwiRigLink.TuneRigDecision.Send>(link.WindowTuned(7_100_000, KiwiSdrMode.Usb, rig, 10));
        Assert.Equal(7_100_000, send.FrequencyHz);
        Assert.Null(send.Mode); // DATA-U already follows USB
        // The rig still reports the old frequency: wait.
        Assert.IsType<KiwiRigLink.FollowDecision.WaitingForRig>(
            link.Follow(7_074_000, RigMode.DataUsb, 7_100_000, KiwiSdrMode.Usb, 30_000_000, 11));
        // After the grace period it follows the rig again.
        Assert.True(link.ExpirePending(14));
        Assert.IsType<KiwiRigLink.TuneRigDecision.Nothing>(
            link.WindowTuned(7_100_000, KiwiSdrMode.Usb, rig with { FrequencyHz = 7_100_000 }, 20));
    }

    [Theory]
    [InlineData(false, false, false, 7_000_000, KiwiRigLink.Refusal.RigDisconnected)]
    [InlineData(true, false, false, 0, KiwiRigLink.Refusal.NoRigFrequency)]
    [InlineData(true, true, false, 7_000_000, KiwiRigLink.Refusal.Transmitting)]
    [InlineData(true, false, true, 7_000_000, KiwiRigLink.Refusal.MemoryMode)]
    public void WindowTuneIsRefused(bool connected, bool tx, bool memory, int hz, KiwiRigLink.Refusal expected)
    {
        var link = new KiwiRigLink();
        var decision = link.WindowTuned(14_000_000, KiwiSdrMode.Usb, new KiwiRigSnapshot(connected, tx, memory, hz, RigMode.Usb), 0);
        Assert.Equal(expected, Assert.IsType<KiwiRigLink.TuneRigDecision.Refused>(decision).Reason);
        Assert.Null(link.Pending);
    }

    // MARK: Client against a fake Kiwi

    [Fact]
    public async Task ClientCompletesTheHandshakeAndReceivesAudio()
    {
        var port = FreePort();
        var listener = new HttpListener();
        listener.Prefixes.Add($"http://localhost:{port}/");
        listener.Start();
        var received = new List<string>();
        var server = Task.Run(async () =>
        {
            var context = await listener.GetContextAsync();
            var ws = (await context.AcceptWebSocketAsync(null)).WebSocket;
            async Task SendMsg(string text)
            {
                var bytes = Encoding.UTF8.GetBytes("MSG " + text);
                await ws.SendAsync(bytes, WebSocketMessageType.Binary, true, CancellationToken.None);
            }
            var buffer = new byte[4096];
            var auth = await ws.ReceiveAsync(buffer, CancellationToken.None);
            received.Add(Encoding.UTF8.GetString(buffer, 0, auth.Count));
            await SendMsg("badp=0");
            await SendMsg("sample_rate=11998.9");
            // Read the setup burst, then send one PCM frame.
            while (received.All(r => !r.StartsWith("SET mod=")))
            {
                var r = await ws.ReceiveAsync(buffer, CancellationToken.None);
                received.Add(Encoding.UTF8.GetString(buffer, 0, r.Count));
            }
            await ws.SendAsync(File.ReadAllBytes(Fixture("snd-pcm-2.bin")), WebSocketMessageType.Binary, true, CancellationToken.None);
            // Drain until the client closes.
            try
            {
                while (ws.State == WebSocketState.Open)
                {
                    var r = await ws.ReceiveAsync(buffer, CancellationToken.None);
                    if (r.MessageType == WebSocketMessageType.Close) { break; }
                }
            }
            catch (WebSocketException)
            {
            }
        });

        var client = new KiwiSdrClient($"localhost:{port}", "pw", KiwiTuning.Of(14_074_000, KiwiSdrMode.Usb),
                                       new KiwiReceiverSettings(), KiwiProtocol.TimestampNow());
        client.Start();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var reader = client.Events;
        var ready = Assert.IsType<KiwiSdrEvent.Ready>(await reader.ReadAsync(timeout.Token));
        Assert.Equal(11998.9, ready.SampleRate, 6);
        var audio = Assert.IsType<KiwiSdrEvent.Audio>(await reader.ReadAsync(timeout.Token));
        Assert.Equal(512, audio.Chunk.Samples.Length);
        client.Stop();
        var closed = Assert.IsType<KiwiSdrEvent.Closed>(await reader.ReadAsync(timeout.Token));
        Assert.Null(closed.Error);
        listener.Close();
        await Task.WhenAny(server, Task.Delay(2000));

        Assert.Equal("SET auth t=kiwi p=pw", received[0]);
        Assert.Contains(received, r => r == "SET mod=usb low_cut=300 high_cut=2700 freq=14074.000");
        Assert.Contains(received, r => r.StartsWith("SET agc=1"));
    }

    [Fact]
    public async Task ClientReportsABadPassword()
    {
        var port = FreePort();
        var listener = new HttpListener();
        listener.Prefixes.Add($"http://localhost:{port}/");
        listener.Start();
        var server = Task.Run(async () =>
        {
            var context = await listener.GetContextAsync();
            var ws = (await context.AcceptWebSocketAsync(null)).WebSocket;
            var buffer = new byte[1024];
            await ws.ReceiveAsync(buffer, CancellationToken.None);
            await ws.SendAsync(Encoding.UTF8.GetBytes("MSG badp=1"), WebSocketMessageType.Binary, true, CancellationToken.None);
            await Task.Delay(1000);
        });
        var client = new KiwiSdrClient($"localhost:{port}", "wrong", KiwiTuning.Of(14_074_000, KiwiSdrMode.Usb),
                                       new KiwiReceiverSettings(), KiwiProtocol.TimestampNow());
        client.Start();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var closed = Assert.IsType<KiwiSdrEvent.Closed>(await client.Events.ReadAsync(timeout.Token));
        // /status isn't served by this fake, so it can't say the channels are full.
        Assert.Equal(KiwiErrorKind.BadPassword, closed.Error?.Kind);
        listener.Close();
        await Task.WhenAny(server, Task.Delay(2000));
    }

    private static int FreePort()
    {
        var probe = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        return port;
    }
}
