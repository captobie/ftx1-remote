using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using FTX1RemoteWindows.Services.Digi;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// APRS transmit (Services/Ax25Encoder.cs, AprsOutgoing.cs, AprsTransmitter.cs,
/// AprsMessaging.cs): the Windows port of the Mac's APRSTransmitTests — the
/// encoder against the app's own decoder, the info fields, the receiver choice,
/// the transmitter's keying and messaging's retries and acks.
public sealed class AprsTransmitTests : IDisposable
{
    private readonly AprsTransmitConfigData _config = new()
    {
        Enabled = true,
        Ssid = 7,
        StationCallsign = "N0CALL",
        Latitude = 41.708333,
        Longitude = -72.72,
        Comment = "Test station",
    };
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "AprsTransmitTests-" + Guid.NewGuid());

    public AprsTransmitTests()
    {
        AprsTransmitSettings.Config = _config;
    }

    public void Dispose()
    {
        AprsTransmitSettings.Config = new AprsTransmitConfigData();
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch
        {
        }
    }

    private AprsStore NewStore() =>
        new(Path.Combine(_directory, "aprs-history.json"), () => 1000, () => 1000);

    // Encoder

    /// 8 kHz (the transmit path's rate) up to 44.1 kHz, as the rig's audio comes
    /// back (linear interpolation: the tones are far below 4 kHz), then the
    /// app's demodulator and frame decoder.
    private static List<Ax25Frame> DecodeAt8k(float[] samples)
    {
        var padded = new float[400].Concat(samples).Concat(new float[2000]).ToArray();
        var up = new float[(int)(padded.Length * 44100.0 / 8000)];
        for (var i = 0; i < up.Length; i++)
        {
            var position = i * 8000.0 / 44100;
            var index = (int)position;
            var fraction = (float)(position - index);
            var next = Math.Min(index + 1, padded.Length - 1);
            up[i] = padded[index] * (1 - fraction) + padded[next] * fraction;
        }
        var demodulator = new AfskDemodulator(44100);
        var decoder = new Ax25FrameDecoder();
        var frames = new List<Ax25Frame>();
        for (var start = 0; start < up.Length; start += 2048)
        {
            var bits = new List<bool>();
            demodulator.Process(up.AsSpan(start, Math.Min(2048, up.Length - start)), bits);
            frames.AddRange(decoder.Process(bits));
        }
        return frames;
    }

    [Fact]
    public void PacketAt8kHzRoundTrips()
    {
        var info = AprsOutgoing.Message("W1AW-9", "Hello from the test, 73!", "42");
        var frame = Ax25Encoder.Frame(AprsTransmitSettings.Destination, new("N0CALL", 7),
            [new("WIDE1", 1), new("WIDE2", 1)], System.Text.Encoding.UTF8.GetBytes(info));
        var bits = Ax25Encoder.LineBits(frame, Ax25Encoder.Flags(0.3), 3);
        var frames = DecodeAt8k(Ax25Encoder.Afsk(bits, 8000, 0.5f));
        var decoded = Assert.Single(frames);
        Assert.Equal("N0CALL-7", decoded.Source.DisplayString);
        Assert.Equal("APZFTX", decoded.Destination.Callsign);
        Assert.Equal(["WIDE1-1", "WIDE2-1"], decoded.Digipeaters.Select(d => d.DisplayString));
        Assert.Equal(new AprsPacket.Message("W1AW-9", "Hello from the test, 73!", "42"), AprsPacket.Parse(decoded.Info));
    }

    [Fact]
    public void BeaconAt8kHzParsesBackToThePosition()
    {
        var (info, problem) = AprsMessaging.BeaconInfo();
        Assert.Null(problem);
        var frame = Ax25Encoder.Frame(AprsTransmitSettings.Destination, new("N0CALL", 7), [],
            System.Text.Encoding.UTF8.GetBytes(info!));
        var audio = Ax25Encoder.Afsk(Ax25Encoder.LineBits(frame, 30, 3), 8000, 0.5f);
        var decoded = Assert.Single(DecodeAt8k(audio));
        Assert.Empty(decoded.Digipeaters);
        var position = Assert.IsType<AprsPacket.Position>(AprsPacket.Parse(decoded.Info));
        Assert.Equal(41.708333, position.Latitude, 4);
        Assert.Equal(-72.72, position.Longitude, 4);
        Assert.Equal("/-", position.SymbolTable + position.SymbolCode);
        Assert.Equal("Test station", position.Comment);
    }

    [Fact]
    public void AddressesAndPaths()
    {
        Assert.Equal(new Ax25Encoder.Address("N0CALL", 9), Ax25Encoder.ParseAddress("n0call-9"));
        Assert.Null(Ax25Encoder.ParseAddress("TOOLONGX"));
        Assert.Null(Ax25Encoder.ParseAddress("N0CALL-16"));
        Assert.Null(Ax25Encoder.ParseAddress("VP2E/K6NA"));
        Assert.Equal(2, Ax25Encoder.ParsePath("WIDE1-1, WIDE2-1")!.Count);
        Assert.Empty(Ax25Encoder.ParsePath("")!);
        Assert.Null(Ax25Encoder.ParsePath("WIDE1-1,BAD CALL"));
    }

    // Info fields

    [Fact]
    public void PositionFormat()
    {
        Assert.Equal("=4142.50N/07243.20W-Home", AprsOutgoing.Position(41.708333, -72.72, '/', '-', "Home"));
        Assert.Equal("=3352.13S/15112.56E-", AprsOutgoing.Position(-33.8688, 151.2093, '/', '-', ""));
        // 59.999' rounds up into the next degree.
        Assert.Equal("4200.00N", AprsOutgoing.Coordinate(41.99999, 2, 'N', 0));
        Assert.Equal("4142.  N", AprsOutgoing.Coordinate(41.708333, 2, 'N', 2));
        Assert.Equal("072  .  W", AprsOutgoing.Coordinate(72.72, 3, 'W', 4));
    }

    [Fact]
    public void MessageAndAckFormat()
    {
        Assert.Equal(":W1AW     :hi there}  {7", AprsOutgoing.Message("w1aw", "hi {there} | ~", "7"));
        Assert.Equal(":W1AW-9   :ack12", AprsOutgoing.Ack("W1AW-9", "12"));
        Assert.Equal(11 + 67, AprsOutgoing.Message("W1AW", new string('x', 80), null).Length);
    }

    [Fact]
    public void RepliesParse()
    {
        Assert.Equal(new AprsOutgoing.Reply(AprsOutgoing.ReplyKind.Ack, "12"), AprsOutgoing.ReplyTo("ack12", null));
        Assert.Equal(new AprsOutgoing.Reply(AprsOutgoing.ReplyKind.Reject, "3"), AprsOutgoing.ReplyTo("rej3", null));
        Assert.Equal(new AprsOutgoing.Reply(AprsOutgoing.ReplyKind.Ack, "3"), AprsOutgoing.ReplyTo("ack3}", null));
        Assert.Equal(new AprsOutgoing.Reply(AprsOutgoing.ReplyKind.Ack, "12"), AprsOutgoing.ReplyTo("Sure", "AB}12"));
        Assert.Null(AprsOutgoing.ReplyTo("acknowledged, thanks", null));
        Assert.Null(AprsOutgoing.ReplyTo("hello", "5"));
        Assert.Equal("AB", AprsOutgoing.IdToAck("AB}12"));
        Assert.Equal("5", AprsOutgoing.IdToAck("5"));
        Assert.Null(AprsOutgoing.IdToAck(null));
    }

    // Planner

    private static AprsRigView Rig(long main, RigMode mainMode = RigMode.Fm, long sub = 0, RigMode? subMode = RigMode.Fm,
        bool txSub = false, bool scanning = false, bool? split = null, bool? single = null) =>
        new(scanning, split, single, txSub, new TransmitSignal(main, mainMode), new TransmitSignal(sub, subMode));

    private static AprsTransmitDecision Plan(AprsRigView rig, bool transmitEnabled = true) =>
        AprsTransmitPlanner.Plan(rig, transmitEnabled, null, 144_390_000, 5_000);

    [Fact]
    public void PlannerPicksTheReceiverOnFrequency()
    {
        Assert.Equal(new AprsTransmitPlan(AprsSource.Main, null), Plan(Rig(144_390_000)).Plan);
        Assert.Equal(new AprsTransmitPlan(AprsSource.Sub, AprsSource.Main),
            Plan(Rig(14_074_000, RigMode.DataUsb, 144_390_000)).Plan);
        Assert.Equal(new AprsTransmitPlan(AprsSource.Sub, null),
            Plan(Rig(14_074_000, RigMode.DataUsb, 144_390_000, txSub: true)).Plan);
        Assert.Equal(new AprsTransmitPlan(AprsSource.Sub, null),
            Plan(Rig(144_390_000, RigMode.DataFm, 144_390_000, txSub: true)).Plan);
        // DATA-FM counts; MAIN's out-of-band frequency doesn't matter when SUB sends.
        Assert.Equal(new AprsTransmitPlan(AprsSource.Sub, AprsSource.Main),
            Plan(Rig(5_000_000, RigMode.Am, 144_391_000, RigMode.DataFm)).Plan);
    }

    [Fact]
    public void PlannerRefuses()
    {
        Assert.NotNull(Plan(Rig(146_520_000, sub: 446_000_000)).BlockedReason);
        Assert.NotNull(Plan(Rig(144_390_000, RigMode.Usb)).BlockedReason);
        Assert.NotNull(Plan(Rig(144_390_000), transmitEnabled: false).BlockedReason);
        Assert.NotNull(Plan(Rig(144_390_000, split: true)).BlockedReason);
        Assert.NotNull(Plan(Rig(14_074_000, RigMode.Usb, 144_390_000, single: true)).BlockedReason);
        Assert.NotNull(Plan(Rig(144_390_000, scanning: true)).BlockedReason);
        // C4FM isn't FM for this.
        var c4fm = new AprsRigView(false, null, null, false, new TransmitSignal(144_390_000, RigMode.Fm, IsC4fm: true), default);
        Assert.NotNull(Plan(c4fm).BlockedReason);
    }

    // Transmitter

    /// Virtual time: sleeping advances it, then yields so the test can interleave.
    private sealed class FakeClock : IDigiSenderClock
    {
        public double Time;
        public double Now() => Time;

        public async Task SleepAsync(double seconds, CancellationToken cancellationToken)
        {
            Time += seconds;
            await Task.Yield();
        }
    }

    /// Virtual time that also waits a little for real, so a test can catch a
    /// transmission part-way.
    private sealed class SlowClock : IDigiSenderClock
    {
        public double Time;
        public double Now() => Time;

        public async Task SleepAsync(double seconds, CancellationToken cancellationToken)
        {
            Time += seconds;
            try
            {
                await Task.Delay(10, cancellationToken);
            }
            catch (OperationCanceledException)
            {
            }
        }
    }

    private sealed class FakeLink : IAprsTransmitLink
    {
        public AprsTransmitDecision Decision = AprsTransmitDecision.Send(new AprsTransmitPlan(AprsSource.Main, null));
        public readonly List<string> Events = [];
        public readonly List<AprsSource> CheckedSides = [];
        public HashSet<AprsSource> BlockedSides = [];
        public FakeClock? Clock;
        public double BusyUntil;
        public double? BlockAfter;
        public double? KeyedAt;
        public int AudioBytes;
        public int KeyCount;

        public AprsTransmitDecision PlanTransmit() => Decision;

        public string? TransmitBlock(AprsSource side)
        {
            CheckedSides.Add(side);
            if (BlockedSides.Contains(side))
            {
                return "blocked";
            }
            return BlockAfter is { } after && Clock is { } clock && KeyedAt is { } keyed && clock.Time - keyed > after ? "blocked" : null;
        }

        public void Key(AprsSource? switchTo)
        {
            KeyCount++;
            KeyedAt = Clock?.Time ?? 0;
            Events.Add("key " + (switchTo?.ToString().ToLowerInvariant() ?? "-"));
        }

        public void Unkey(AprsSource? restoreSide) =>
            Events.Add("unkey " + (restoreSide?.ToString().ToLowerInvariant() ?? "-"));

        public void SendAudio(byte[] pcm) => AudioBytes += pcm.Length;

        public bool ChannelBusy(AprsSource side, double seconds) => Clock is { } clock && clock.Time < BusyUntil;
    }

    private static async Task WaitUntil(Func<bool> condition)
    {
        for (var i = 0; i < 5000 && !condition(); i++)
        {
            await Task.Delay(1);
        }
        Assert.True(condition(), "timed out");
    }

    private static AprsTransmitter MakeTransmitter(FakeLink link, IDigiSenderClock clock) =>
        new(link, clock: clock, random: () => 0);

    [Fact]
    public async Task TransmitterKeysSendsAudioAndRestoresTheSide()
    {
        var link = new FakeLink { Decision = AprsTransmitDecision.Send(new AprsTransmitPlan(AprsSource.Sub, AprsSource.Main)) };
        var transmitter = MakeTransmitter(link, new FakeClock());
        var outcomes = new List<AprsSendOutcome>();
        transmitter.Outcome += (_, outcome) => outcomes.Add(outcome);
        transmitter.Enqueue(new AprsOutgoingPacket(AprsPacketKind.Beacon, "=4142.50N/07243.20W-"));
        await WaitUntil(() => outcomes.Count > 0);
        Assert.Equal([AprsSendOutcome.Sent(AprsSource.Sub)], outcomes);
        Assert.Equal(["key sub", "unkey main"], link.Events);
        // TXDELAY 400 ms + frame + tail, all of it.
        var seconds = link.AudioBytes / 2 / 8000.0;
        Assert.InRange(seconds, 0.5, 1.5);
        Assert.False(transmitter.IsTransmitting);
    }

    /// The in-transmission check judges the receiver the packet goes out on,
    /// not the old TX side (MAIN on an HF frequency the License blocks).
    [Fact]
    public async Task MidPacketCheckJudgesThePlannedSide()
    {
        var link = new FakeLink
        {
            Decision = AprsTransmitDecision.Send(new AprsTransmitPlan(AprsSource.Sub, AprsSource.Main)),
            BlockedSides = [AprsSource.Main],
        };
        var transmitter = MakeTransmitter(link, new FakeClock());
        var outcomes = new List<AprsSendOutcome>();
        transmitter.Outcome += (_, outcome) => outcomes.Add(outcome);
        transmitter.Enqueue(new AprsOutgoingPacket(AprsPacketKind.Beacon, "=x"));
        await WaitUntil(() => outcomes.Count > 0);
        Assert.Equal([AprsSendOutcome.Sent(AprsSource.Sub)], outcomes);
        Assert.NotEmpty(link.CheckedSides);
        Assert.All(link.CheckedSides, side => Assert.Equal(AprsSource.Sub, side));
    }

    [Fact]
    public async Task TransmitterWaitsForAClearChannel()
    {
        var clock = new FakeClock();
        var link = new FakeLink { Clock = clock, BusyUntil = 3 };
        var transmitter = MakeTransmitter(link, clock);
        var done = false;
        transmitter.Outcome += (_, _) => done = true;
        transmitter.Enqueue(new AprsOutgoingPacket(AprsPacketKind.Beacon, "=x"));
        await WaitUntil(() => done);
        Assert.True(link.KeyedAt >= 3);
    }

    [Fact]
    public async Task TransmitterStopsWhenBlockedMidPacket()
    {
        var clock = new FakeClock();
        var link = new FakeLink { Clock = clock, BlockAfter = 0.2 };
        var transmitter = MakeTransmitter(link, clock);
        var outcomes = new List<AprsSendOutcome>();
        transmitter.Outcome += (_, outcome) => outcomes.Add(outcome);
        transmitter.Enqueue(new AprsOutgoingPacket(AprsPacketKind.Beacon, "=x"));
        await WaitUntil(() => outcomes.Count > 0);
        Assert.Equal([AprsSendOutcome.Blocked("blocked")], outcomes);
        Assert.Equal(["key -", "unkey -"], link.Events);
    }

    [Fact]
    public async Task StopAllUnkeysAndDropsTheQueue()
    {
        var link = new FakeLink();
        var transmitter = MakeTransmitter(link, new SlowClock());
        var outcomes = new List<AprsSendOutcome>();
        transmitter.Outcome += (_, outcome) => outcomes.Add(outcome);
        transmitter.Enqueue(new AprsOutgoingPacket(AprsPacketKind.Beacon, "=a"));
        transmitter.Enqueue(new AprsOutgoingPacket(AprsPacketKind.Message("m"), ":X        :b{1"));
        await WaitUntil(() => transmitter.IsTransmitting);
        transmitter.StopAll("transmit off");
        Assert.Equal(["key -", "unkey -"], link.Events);
        Assert.Equal(2, outcomes.Count);
        Assert.All(outcomes, o => Assert.Equal("transmit off", o.BlockedReason));
        Assert.False(transmitter.IsTransmitting);
        Assert.Equal(0, transmitter.QueueCount);
    }

    [Fact]
    public async Task AcksJumpTheQueue()
    {
        var link = new FakeLink();
        var transmitter = MakeTransmitter(link, new FakeClock());
        var order = new List<AprsPacketKind>();
        transmitter.Outcome += (packet, _) => order.Add(packet.Kind);
        transmitter.Enqueue(new AprsOutgoingPacket(AprsPacketKind.Beacon, "=a"));
        await WaitUntil(() => transmitter.QueueCount == 0);
        transmitter.Enqueue(new AprsOutgoingPacket(AprsPacketKind.Message("m"), ":X        :b{1"));
        transmitter.Enqueue(new AprsOutgoingPacket(AprsPacketKind.Ack("X", "9"), ":X        :ack9"));
        await WaitUntil(() => order.Count == 3);
        // The beacon was already on its way when the others came in.
        Assert.Equal([AprsPacketKind.Beacon, AprsPacketKind.Ack("X", "9"), AprsPacketKind.Message("m")], order);
    }

    // Messaging

    /// Raised by AprsMessaging after it has handled a packet's outcome (the
    /// transmitter's continuations run on the thread pool here, not one UI thread).
    private int _handledOutcomes;

    private (AprsMessaging Messaging, AprsStore Store, FakeLink Link, FakeClock Clock) NewMessaging()
    {
        var link = new FakeLink();
        var clock = new FakeClock();
        var store = NewStore();
        var transmitter = MakeTransmitter(link, clock);
        var messaging = new AprsMessaging(store, transmitter, clock: clock);
        messaging.Changed += () => Interlocked.Increment(ref _handledOutcomes);
        return (messaging, store, link, clock);
    }

    private Task WaitForOutcomes(int count) => WaitUntil(() => Volatile.Read(ref _handledOutcomes) >= count);

    [Fact]
    public async Task MessageRetriesUntilAcked()
    {
        var (messaging, store, link, clock) = NewMessaging();
        Assert.Null(messaging.Send("Hello", "w1aw-9"));
        var id = store.Messages[^1].Id;
        await WaitForOutcomes(1);
        Assert.Equal(1, store.Messages[^1].Delivery!.Attempts);
        Assert.Equal("N0CALL-7", store.Messages[^1].From);
        Assert.Equal("1", store.Messages[^1].MessageId);

        clock.Time += 29;
        messaging.Tick();
        Assert.Equal(1, link.KeyCount);
        clock.Time += 2;
        messaging.Tick();
        await WaitForOutcomes(2);
        Assert.Equal(2, store.Messages[^1].Delivery!.Attempts);

        // Their ack, which also isn't acked back.
        messaging.HandleIncoming("W1AW-9", "N0CALL-7", "ack1", null);
        Assert.Equal(AprsDeliveryState.Acked, store.Messages.First(m => m.Id == id).Delivery!.State);
        clock.Time += 120;
        messaging.Tick();
        Assert.Equal(2, link.KeyCount);
    }

    [Fact]
    public async Task MessageFailsAfterTheLastTry()
    {
        var (messaging, store, link, clock) = NewMessaging();
        messaging.Send("Anyone?", "W1AW");
        for (var attempt = 1; attempt <= AprsMessaging.RetryDelays.Length; attempt++)
        {
            await WaitForOutcomes(attempt);
            clock.Time += AprsMessaging.RetryDelays[attempt - 1] + 1;
            messaging.Tick();
        }
        Assert.Equal(AprsDeliveryState.Failed, store.Messages[^1].Delivery!.State);
        Assert.Equal(AprsMessaging.RetryDelays.Length, link.KeyCount);
    }

    [Fact]
    public async Task BlockedAttemptsDontCount()
    {
        var (messaging, store, link, clock) = NewMessaging();
        link.Decision = AprsTransmitDecision.Blocked("not on 144.390");
        messaging.Send("Hi", "W1AW");
        await WaitForOutcomes(1);
        Assert.Equal("not on 144.390", store.Messages[^1].Delivery!.Note);
        Assert.Equal(0, store.Messages[^1].Delivery!.Attempts);
        Assert.Equal(AprsDeliveryState.Pending, store.Messages[^1].Delivery!.State);
        link.Decision = AprsTransmitDecision.Send(new AprsTransmitPlan(AprsSource.Main, null));
        clock.Time += 31;
        messaging.Tick();
        await WaitForOutcomes(2);
        Assert.Equal(1, store.Messages[^1].Delivery!.Attempts);
    }

    [Fact]
    public async Task CancelStopsASendingMessage()
    {
        var (messaging, store, link, clock) = NewMessaging();
        messaging.Send("Hi", "W1AW");
        await WaitForOutcomes(1);
        messaging.Cancel(store.Messages[^1].Id);
        Assert.Equal(AprsDeliveryState.Cancelled, store.Messages[^1].Delivery!.State);
        clock.Time += 100;
        messaging.Tick();
        Assert.Equal(1, link.KeyCount);
        messaging.Resend(store.Messages[^1].Id);
        await WaitUntil(() => link.KeyCount == 2);
    }

    [Fact]
    public async Task IncomingMessagesToUsAreAckedOnce()
    {
        var link = new FakeLink();
        var clock = new FakeClock();
        var transmitter = MakeTransmitter(link, clock);
        var messaging = new AprsMessaging(NewStore(), transmitter, clock: clock);
        var sent = new List<string>();
        transmitter.Outcome += (packet, _) => sent.Add(packet.Info);

        messaging.HandleIncoming("W1AW-9", "N0CALL-7", "Hi there", "AB}");
        messaging.HandleIncoming("W1AW-9", "N0CALL-7", "Hi there", "AB}");
        messaging.HandleIncoming("W1AW-9", "N0CALL", "Other SSID", "5");
        messaging.HandleIncoming("W1AW-9", "N0CALL-7", "No id", null);
        await WaitUntil(() => sent.Count > 0);
        Assert.Equal([":W1AW-9   :ackAB"], sent);

        // A retry after the repeat limit gets acked again.
        clock.Time += AprsMessaging.AckRepeatLimit + 1;
        messaging.HandleIncoming("W1AW-9", "N0CALL-7", "Hi there", "AB}");
        await WaitUntil(() => sent.Count == 2);

        // Not with auto-ack off.
        _config.AutoAck = false;
        clock.Time += AprsMessaging.AckRepeatLimit + 1;
        messaging.HandleIncoming("W1AW-9", "N0CALL-7", "Again", "AC");
        await Task.Delay(50);
        Assert.Equal(2, sent.Count);
    }

    [Fact]
    public void StoreSkipsRepeatedMessages()
    {
        var store = NewStore();
        var now = DateTimeOffset.Now;
        Assert.True(store.RecordMessage("W1AW", "N0CALL", "Hi", "1", now, AprsSource.Main));
        Assert.False(store.RecordMessage("W1AW", "N0CALL", "Hi", "1", now.AddSeconds(30), AprsSource.Main));
        Assert.True(store.RecordMessage("W1AW", "N0CALL", "Hi", null, now.AddSeconds(31), AprsSource.Main));
        Assert.True(store.RecordMessage("W1AW", "N0CALL", "Hi", "1", now.AddSeconds(3600), AprsSource.Main));
    }

    [Fact]
    public void PendingMessagesFromALastRunAreMarkedFailed()
    {
        var store = NewStore();
        store.RecordOutgoing(new AprsMessage { From = "N0CALL", To = "W1AW", Text = "x", MessageId = "1", ReceivedAt = DateTimeOffset.Now, Delivery = new AprsDelivery() });
        _ = new AprsMessaging(store, MakeTransmitter(new FakeLink(), new FakeClock()));
        Assert.Equal(AprsDeliveryState.Failed, store.Messages[^1].Delivery!.State);
        // And an older history file without the Delivery field still loads.
        var reloaded = NewStore();
        Assert.Equal(AprsDeliveryState.Failed, reloaded.Messages[^1].Delivery!.State);
    }

    [Fact]
    public void BeaconNeedsAPosition()
    {
        _config.Latitude = null;
        Assert.Equal(AprsSetupProblem.NoPosition, AprsMessaging.BeaconInfo().Problem);
        _config.Latitude = 41.7;
        _config.StationCallsign = "";
        Assert.Equal(AprsSetupProblem.NoCallsign, AprsMessaging.BeaconInfo().Problem);
    }

    [Fact]
    public void SourceCallNeedsABareCallsign()
    {
        Assert.Equal("N0CALL-7", AprsTransmitSettings.SourceCall);
        _config.Ssid = 0;
        Assert.Equal("N0CALL", AprsTransmitSettings.SourceCall);
        _config.StationCallsign = "N0CALL-3";
        Assert.Null(AprsTransmitSettings.SourceCall);
        _config.StationCallsign = "W1AW/4";
        Assert.Null(AprsTransmitSettings.SourceCall);
    }
}
