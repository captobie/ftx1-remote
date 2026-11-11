using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// The MyKiwiSDR port's decoder source, recording split, Follow width and
/// playout controller — the Swift tests' cases (ReceiveAudioChannelTests'
/// KiwiRecordingSplitTests, KiwiPlayoutTests) on the C# ports.
public class KiwiRecordingSplitTests
{
    private static KiwiRecordingSplit.Tuning T(int hz, KiwiSdrMode mode = KiwiSdrMode.Cw) => new(hz, mode);

    [Fact]
    public void SmallTunesNeverSplit()
    {
        var split = new KiwiRecordingSplit(T(7_030_000));
        double now = 0;
        for (var step = 1; step <= 49; step++)
        {
            now += 0.05;
            Assert.Null(split.Update(T(7_030_000 + step * 10), now));
        }
        Assert.Null(split.NextCheck);
        Assert.Null(split.Update(T(7_030_490), now + 60));
        Assert.Equal(T(7_030_000), split.FileTuning);
    }

    [Fact]
    public void RetuneSplitsOnceItHolds()
    {
        var split = new KiwiRecordingSplit(T(7_030_000));
        Assert.Null(split.Update(T(14_050_000), 10));
        Assert.Equal(11, split.NextCheck);
        Assert.Null(split.Update(T(14_050_000), 10.9));
        Assert.Equal(T(14_050_000), split.Update(T(14_050_000), 11));
        Assert.Null(split.NextCheck);
        Assert.Null(split.Update(T(14_050_000), 20));
    }

    [Fact]
    public void FastScrollRestartsTheSettleTime()
    {
        var split = new KiwiRecordingSplit(T(7_030_000, KiwiSdrMode.Usb));
        double now = 0;
        for (var step = 1; step <= 20; step++)
        {
            now += 0.2;
            Assert.Null(split.Update(T(7_030_000 + step * 100, KiwiSdrMode.Usb), now));
        }
        Assert.Equal(now + 1, split.NextCheck!.Value, 9);
        Assert.Equal(T(7_032_000, KiwiSdrMode.Usb), split.Update(T(7_032_000, KiwiSdrMode.Usb), now + 1));
    }

    [Fact]
    public void ModeChangeSplitsAndGoingBackCancels()
    {
        var split = new KiwiRecordingSplit(T(7_074_000, KiwiSdrMode.Usb));
        Assert.Null(split.Update(T(7_074_000, KiwiSdrMode.Lsb), 0));
        Assert.NotNull(split.NextCheck);
        Assert.Null(split.Update(T(7_074_000, KiwiSdrMode.Usb), 0.5));
        Assert.Null(split.NextCheck);
        Assert.Null(split.Update(T(7_074_000, KiwiSdrMode.Lsb), 3));
        Assert.Equal(T(7_074_000, KiwiSdrMode.Lsb), split.Update(T(7_074_000, KiwiSdrMode.Lsb), 4));
    }
}

public class KiwiFollowWidthTests
{
    private static RigState State(RigMode mode, int widthHz, int shift = 0, FilterSide side = FilterSide.Main)
    {
        var index = FilterWidthTable.Entries(mode).First(e => e.Hz == widthHz).Index;
        return new RigState { Mode = mode, FilterSide = side, FilterWidthIndex = index, IfShiftHz = shift };
    }

    [Fact]
    public void UsbFilterIsTheAudioPassbandOnItsSideband()
    {
        // USB 2400 Hz centred on 1650: 450–2850.
        Assert.Equal(new KiwiPassband(450, 2850), KiwiPassband.FromRigFilter(State(RigMode.Usb, 2400)));
        // LSB mirrors below the carrier.
        Assert.Equal(new KiwiPassband(-2850, -450), KiwiPassband.FromRigFilter(State(RigMode.Lsb, 2400)));
        // SHIFT moves it.
        Assert.Equal(new KiwiPassband(650, 3050), KiwiPassband.FromRigFilter(State(RigMode.Usb, 2400, 200)));
    }

    [Fact]
    public void CwUsesTheKiwisPitchAndCarriesShift()
    {
        var band = KiwiPassband.FromRigFilter(State(RigMode.Cw, 500, 100))!.Value;
        // Half-width 250 around 500 Hz, moved up by the SHIFT.
        Assert.Equal(new KiwiPassband(350, 850, 100), band);
    }

    [Fact]
    public void AmIsSymmetricAndClamped()
    {
        Assert.Equal(new KiwiPassband(-3000, 3000), KiwiPassband.FromRigFilter(State(RigMode.Am, 6000)));
        Assert.Equal(new KiwiPassband(-4500, 4500), KiwiPassband.FromRigFilter(State(RigMode.Am, 9000)));
    }

    [Fact]
    public void NoPassbandForSubUnknownWidthOrUnmappedModes()
    {
        Assert.Null(KiwiPassband.FromRigFilter(State(RigMode.Usb, 2400, 0, FilterSide.Sub)));
        Assert.Null(KiwiPassband.FromRigFilter(new RigState { Mode = RigMode.Usb }));
        Assert.Null(KiwiPassband.FromRigFilter(State(RigMode.Rtty, 500)));
    }
}

public class LocalSdrAudioSourceTests
{
    [Fact]
    public void DeliversOnlyToWantedConsumersAndTracksStatusAndMode()
    {
        var source = new LocalSdrAudioSource();
        var wanted = true;
        var received = new List<(int Count, int Rate)>();
        source.AddConsumer("cw", () => wanted, (samples, rate) => received.Add((samples.Length, rate)));
        var changes = 0;
        source.Changed += () => changes++;
        Assert.True(source.IsWanted);
        Assert.Equal(LocalSdrAudioSource.SourceStatus.NotConnected, source.Status);

        source.Deliver(new short[10]); // no session yet
        Assert.Empty(received);

        source.SessionStarted(11998.9, KiwiSdrMode.Cw);
        Assert.Equal(RigMode.Cw, source.Mode);
        source.Deliver(new short[] { 1000, -1000, 2000 });
        Assert.Equal((3, 11999), received.Single());
        Assert.Equal(LocalSdrAudioSource.SourceStatus.Receiving, source.Status);

        source.ModeChanged(KiwiSdrMode.Lsb);
        Assert.Equal(RigMode.Lsb, source.Mode);

        wanted = false;
        source.Update();
        Assert.False(source.IsWanted);
        source.Deliver(new short[] { 1, 2, 3 });
        Assert.Single(received);

        source.SessionEnded();
        Assert.Equal(LocalSdrAudioSource.SourceStatus.NotConnected, source.Status);
        Assert.Null(source.Mode);
        Assert.True(changes >= 3);
    }
}

public class KiwiPlayoutTests
{
    private const double Chunk = 0.043;
    private const double Rate = 11_998.902;

    private static (List<KiwiPlayoutController.PlayoutAction> Actions, double End) Run(
        KiwiPlayoutController controller, double start, double seconds, Func<double, double> buffered)
    {
        var now = start;
        var actions = new List<KiwiPlayoutController.PlayoutAction>();
        while (now < start + seconds)
        {
            var action = controller.Observe(buffered(now), 0, now);
            if (action is not KiwiPlayoutController.PlayoutAction.None)
            {
                actions.Add(action);
            }
            now += Chunk;
        }
        return (actions, now);
    }

    [Fact]
    public void NothingHappensOnTargetOrInsideTheDeadband()
    {
        Assert.Empty(Run(new KiwiPlayoutController(0.25), 0, 60, _ => 0.25).Actions);
        Assert.Empty(Run(new KiwiPlayoutController(0.25), 0, 120, now => 0.25 + 0.04 * Math.Sin(now * 7)).Actions);
        Assert.Empty(Run(new KiwiPlayoutController(0.25), 0, 9, _ => 0.29).Actions);
    }

    [Fact]
    public void SustainedHighQueueSplicesOutAtMostTwiceASecondUntilSettled()
    {
        var controller = new KiwiPlayoutController(0.25);
        var offset = 0.0;
        var times = new List<double>();
        for (var now = 0.0; now < 60; now += Chunk)
        {
            if (controller.Observe(0.29 + offset, 0, now) is KiwiPlayoutController.PlayoutAction.Splice splice)
            {
                Assert.Equal(1, splice.Direction);
                times.Add(now);
                offset -= 0.001;
                controller.Applied(0.001);
            }
        }
        Assert.Equal(10, times[0], 0.1);
        Assert.Equal(30, times.Count);
        for (var i = 1; i < times.Count; i++)
        {
            Assert.True(times[i] - times[i - 1] >= KiwiPlayoutController.CorrectionInterval);
        }
    }

    [Fact]
    public void SustainedLowQueueAddsAudio()
    {
        var actions = Run(new KiwiPlayoutController(0.25), 0, 11, _ => 0.21).Actions;
        Assert.Equal(new KiwiPlayoutController.PlayoutAction.Splice(-1), actions.First());
    }

    [Fact]
    public void BacklogIsDiscardedOnceAndAShortBurstIsNotABacklog()
    {
        var controller = new KiwiPlayoutController(0.25);
        var level = 0.25;
        var discards = new List<double>();
        for (var now = 0.0; now < 20; now += Chunk)
        {
            if (now >= 5 && now < 5 + Chunk) { level = 2.25; }
            if (controller.Observe(level, 0, now) is KiwiPlayoutController.PlayoutAction.Discard d)
            {
                discards.Add(d.Seconds);
                level = 0.25;
            }
        }
        Assert.Single(discards);
        Assert.Equal(2, discards[0], 6);

        Assert.Empty(Run(new KiwiPlayoutController(0.25), 0, 20, now => now is >= 12 and < 12.2 ? 0.8 : 0.25).Actions);
    }

    [Fact]
    public void ADryQueueIsPaddedAndTheChunkCountsInTheLevel()
    {
        var controller = new KiwiPlayoutController(0.25);
        Run(controller, 0, 2, _ => 0.25);
        Assert.Equal(new KiwiPlayoutController.PlayoutAction.Pad(0.25 - Chunk), controller.Observe(0, Chunk, 2.5));

        var steady = new KiwiPlayoutController(0.25);
        for (var now = 0.0; now < 60; now += Chunk)
        {
            Assert.IsType<KiwiPlayoutController.PlayoutAction.None>(steady.Observe(0.25 - Chunk, Chunk, now));
        }
        Assert.IsType<KiwiPlayoutController.PlayoutAction.None>(new KiwiPlayoutController(0.25).Observe(0, Chunk, 0));
    }

    private static short[] Sine(double hz, int count, int start = 0) =>
        Enumerable.Range(0, count).Select(i => (short)(10_000 * Math.Sin(2 * Math.PI * hz * (start + i) / Rate))).ToArray();

    [Fact]
    public void SpliceShortensOrLengthensAndKeepsATonesPhase()
    {
        var x = Sine(700, 512);
        var shorter = KiwiPlayoutAdjuster.Spliced(x, 1)!;
        var longer = KiwiPlayoutAdjuster.Spliced(x, -1)!;
        Assert.InRange(x.Length - shorter.Length, KiwiPlayoutAdjuster.MinOffset, KiwiPlayoutAdjuster.MaxOffset);
        Assert.InRange(longer.Length - x.Length, KiwiPlayoutAdjuster.MinOffset, KiwiPlayoutAdjuster.MaxOffset);
        var maxStep = 10_000 * 2 * Math.PI * 700 / Rate;
        foreach (var y in new[] { shorter, longer })
        {
            for (var i = 1; i < y.Length; i++)
            {
                Assert.True(Math.Abs(y[i] - y[i - 1]) <= maxStep * 1.05);
            }
            Assert.True(y.Skip(30).Take(96).Max(v => Math.Abs((int)v)) > 9_000);
        }
        Assert.Null(KiwiPlayoutAdjuster.Spliced(new short[100], 1));
    }

    /// Chunks arrive every 512 samples; the queue drains at clockRatio of the input's rate.
    private static (double PeakError, KiwiPlayoutAdjuster Adjuster, int Gaps) Simulate(
        double minutes, double clockRatio, double? stallAt = null, double stallSeconds = 0)
    {
        var adjuster = new KiwiPlayoutAdjuster(Rate, 0.25);
        const int chunk = 512;
        var chunkSeconds = chunk / Rate;
        var queue = 0.25;
        double now = 0, peakError = 0;
        var gaps = 0;
        var stalled = false;
        var index = 0;
        var backlog = 0;
        while (now < minutes * 60)
        {
            now += chunkSeconds;
            queue -= chunkSeconds * clockRatio;
            if (queue < 0) { queue = 0; gaps++; }
            if (stallAt is { } at && !stalled && now >= at)
            {
                stalled = true;
                backlog = (int)(stallSeconds / chunkSeconds);
                queue = Math.Max(queue - stallSeconds, 0);
                now += stallSeconds;
            }
            var arrivals = 1 + backlog;
            backlog = 0;
            for (var n = 0; n < arrivals; n++)
            {
                var output = adjuster.Process(Sine(700, chunk, index * chunk), queue, now);
                index++;
                queue += output.Length / Rate;
            }
            if (now > 15 && (stallAt is null || now > stallAt + 15))
            {
                peakError = Math.Max(peakError, Math.Abs(queue - 0.25));
            }
        }
        return (peakError, adjuster, gaps);
    }

    [Theory]
    [InlineData(1.0002)]
    [InlineData(0.9998)]
    public void DriftIsHeldInsideTheDeadbandEitherWay(double ratio)
    {
        var result = Simulate(10, ratio);
        Assert.True(result.PeakError < KiwiPlayoutController.Deadband + 0.01);
        Assert.True(result.Adjuster.Splices > 0);
        Assert.Equal(0, result.Gaps);
    }

    [Fact]
    public void AStallsBacklogDoesNotStay()
    {
        var result = Simulate(3, 1, stallAt: 30, stallSeconds: 2);
        Assert.True(result.PeakError < 0.1);
        Assert.Equal(2, result.Adjuster.DiscardedSeconds, 0.4);
    }

    [Fact]
    public void AStallWithNoBacklogRefillsTheQueueAndEarlySamplesPassThrough()
    {
        var adjuster = new KiwiPlayoutAdjuster(Rate, 0.25);
        var chunk = Enumerable.Repeat((short)1000, 512).ToArray();
        adjuster.Process(chunk, 0.25, 0);
        var output = adjuster.Process(chunk, 0, 3);
        Assert.Equal(0.25 - 512 / Rate, adjuster.PaddedSeconds, 9);
        Assert.Equal((int)((0.25 - 512 / Rate) * Rate) + 512, output.Length);

        var fresh = new KiwiPlayoutAdjuster(Rate, 0.25);
        var tone = Sine(700, 512);
        Assert.Equal(tone, fresh.Process(tone, null, 0));
    }
}
