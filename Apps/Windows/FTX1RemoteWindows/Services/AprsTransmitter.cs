using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services.Digi;

namespace FTX1RemoteWindows.Services;

/// What the planner needs to know about the rig.
public readonly record struct AprsRigView(
    bool MemoryScanActive,
    bool? SplitOn,
    bool? SingleReceive,
    bool? TxSideSub,
    TransmitSignal Main,
    TransmitSignal Sub);

/// Which receiver an APRS packet goes out on, and the TX side to put back
/// afterwards.
public readonly record struct AprsTransmitPlan(AprsSource Side, AprsSource? RestoreSide);

/// Either a plan or the reason there isn't one.
public readonly record struct AprsTransmitDecision(AprsTransmitPlan? Plan, string? BlockedReason)
{
    public static AprsTransmitDecision Send(AprsTransmitPlan plan) => new(plan, null);
    public static AprsTransmitDecision Blocked(string reason) => new(null, reason);
}

/// Picks the receiver for an APRS packet: MAIN or SUB, whichever is on the
/// APRS frequency in FM or DATA-FM (the current TX side first), then the
/// transmit gate judged as if that side transmitted. Port of the Mac's
/// APRSTransmitPlanner (Sources/FTX1Core/APRS/APRSTransmitter.swift).
public static class AprsTransmitPlanner
{
    public static AprsTransmitDecision Plan(AprsRigView rig, bool transmitEnabled, PrivilegeProfile? privileges,
        long aprsHz, long toleranceHz)
    {
        if (rig.MemoryScanActive)
        {
            return AprsTransmitDecision.Blocked(Loc.S("aprsTransmit.memoryScan"));
        }
        if (rig.SplitOn == true)
        {
            return AprsTransmitDecision.Blocked(Loc.S("aprsTransmit.split"));
        }

        bool OnFrequency(long hz) => hz > 0 && Math.Abs(hz - aprsHz) <= toleranceHz;
        bool FmMode(TransmitSignal s) => !s.IsC4fm && s.Mode is RigMode.Fm or RigMode.DataFm;

        var mainOn = OnFrequency(rig.Main.FrequencyHz);
        var subOn = rig.SingleReceive != true && OnFrequency(rig.Sub.FrequencyHz);
        var mainOk = mainOn && FmMode(rig.Main);
        var subOk = subOn && FmMode(rig.Sub);

        var current = rig.TxSideSub == true ? AprsSource.Sub : AprsSource.Main;
        AprsSource side;
        if (current == AprsSource.Sub && subOk)
        {
            side = AprsSource.Sub;
        }
        else if (mainOk)
        {
            side = AprsSource.Main;
        }
        else if (subOk)
        {
            side = AprsSource.Sub;
        }
        else
        {
            var frequency = (aprsHz / 1_000_000.0).ToString("0.000", System.Globalization.CultureInfo.InvariantCulture);
            return AprsTransmitDecision.Blocked(mainOn || subOn
                ? Loc.F("aprsTransmit.wrongMode", frequency)
                : Loc.F("aprsTransmit.notOnFrequency", frequency));
        }

        var signal = side == AprsSource.Main ? rig.Main : rig.Sub;
        if (TransmitGate.BlockReason(TransmitAction.PttOn, transmitEnabled, signal, privileges) is { } reason)
        {
            return AprsTransmitDecision.Blocked(reason);
        }
        return AprsTransmitDecision.Send(new AprsTransmitPlan(side, side == current ? null : current));
    }
}

/// What the APRS transmitter needs from the app; MainWindow implements it
/// (the Mac's HubService+APRSTransmitLink). All calls on the UI thread.
public interface IAprsTransmitLink
{
    /// Before keying: the receiver to use, or why not now (incl. no rig, no
    /// transmit audio path, the rig keyed by something else).
    AprsTransmitDecision PlanTransmit();
    /// While keyed: why it must stop now, null when it may go on — judged for
    /// <paramref name="side"/>, the receiver the packet is going out on, not
    /// the TX side the rig reports (it may not have caught up with the switch).
    string? TransmitBlock(AprsSource side);
    /// Keys the rig, first moving the TX side to <paramref name="switchTo"/>
    /// when given — in that order.
    void Key(AprsSource? switchTo);
    /// Unkeys, then puts the TX side back to <paramref name="restoreSide"/>
    /// when given.
    void Unkey(AprsSource? restoreSide);
    /// 16-bit little-endian mono PCM at 8 kHz.
    void SendAudio(byte[] pcm);
    /// Packet audio heard on that receiver within <paramref name="seconds"/>.
    bool ChannelBusy(AprsSource side, double seconds);
}

/// One packet waiting to go out.
public sealed record AprsOutgoingPacket(AprsPacketKind Kind, string Info);

public readonly record struct AprsPacketKind(AprsPacketKindType Type, string? Key = null, string? Extra = null)
{
    public static AprsPacketKind Beacon => new(AprsPacketKindType.Beacon);
    /// <paramref name="id"/>: the AprsMessage.Id of an own message.
    public static AprsPacketKind Message(string id) => new(AprsPacketKindType.Message, id);
    /// To this call, for this id.
    public static AprsPacketKind Ack(string to, string id) => new(AprsPacketKindType.Ack, to, id);
}

public enum AprsPacketKindType
{
    Beacon,
    Message,
    Ack,
}

/// A packet's outcome: sent on a receiver, or why not.
public readonly record struct AprsSendOutcome(AprsSource? SentOn, string? BlockedReason)
{
    public static AprsSendOutcome Sent(AprsSource side) => new(side, null);
    public static AprsSendOutcome Blocked(string reason) => new(null, reason);
}

/// Sends APRS packets one at a time: waits for a clear channel, switches the
/// TX side to the receiver on the APRS frequency if needed, keys, plays
/// TXDELAY flags + the frame as 8 kHz Bell 202 audio paced just ahead of real
/// time, unkeys once it has played out, and puts the TX side back. Port of
/// the Mac's APRSTransmitter. Lives on the UI thread (its continuations
/// return to it).
public sealed class AprsTransmitter
{
    public const double SampleRate = 8000;
    internal const double Lead = 0.25;
    internal const double Tick = 0.02;
    internal const int Chunk = 160;
    /// After the last sample: the lead still to play plus the output's own buffer.
    internal const double UnkeyDelay = Lead + 0.3;
    internal const int TailFlags = 3;
    /// The channel must have been quiet this long.
    internal const double ClearFor = 1.5;
    /// Longest wait for a clear channel before sending anyway.
    internal const double MaxChannelWait = 10;
    /// Between two packets of ours.
    internal const double PacketGap = 1.0;

    private readonly IAprsTransmitLink _link;
    private readonly IDigiSenderClock _clock;
    private readonly Func<double> _random;
    private readonly Action<string> _log;
    private readonly List<AprsOutgoingPacket> _queue = [];
    private AprsOutgoingPacket? _current;
    private CancellationTokenSource? _loop;
    /// The TX side to put back after the packet being sent.
    private AprsSource? _activeRestore;

    public AprsTransmitter(IAprsTransmitLink link, Action<string>? log = null, IDigiSenderClock? clock = null,
        Func<double>? random = null)
    {
        _link = link;
        _log = log ?? (_ => { });
        _clock = clock ?? new SystemDigiSenderClock();
        _random = random ?? (() => Random.Shared.NextDouble());
    }

    /// Anything the windows show changed (sending, queue length).
    public event Action? Changed;

    /// Each packet's outcome, in order.
    public event Action<AprsOutgoingPacket, AprsSendOutcome>? Outcome;

    public bool IsTransmitting { get; private set; }
    public int QueueCount => _queue.Count;

    /// Acks go ahead of everything else; the rest in order.
    public void Enqueue(AprsOutgoingPacket packet)
    {
        if (packet.Kind.Type == AprsPacketKindType.Ack)
        {
            var firstNonAck = _queue.FindIndex(p => p.Kind.Type != AprsPacketKindType.Ack);
            _queue.Insert(firstNonAck < 0 ? _queue.Count : firstNonAck, packet);
        }
        else
        {
            _queue.Add(packet);
        }
        Changed?.Invoke();
        if (_loop is null)
        {
            _loop = new CancellationTokenSource();
            _ = RunAsync(_loop);
        }
    }

    /// Waiting or being sent.
    public bool IsQueued(AprsPacketKind kind) =>
        (_current?.Kind == kind) || _queue.Any(p => p.Kind == kind);

    /// Drops a waiting packet (not the one being sent).
    public void Remove(AprsPacketKind kind)
    {
        _queue.RemoveAll(p => p.Kind == kind);
        Changed?.Invoke();
    }

    /// Unkeys now and drops the queue (Enable Transmit off, link lost).
    public void StopAll(string reason)
    {
        // Read before cancelling: the send loop's own cleanup clears these.
        var wasTransmitting = IsTransmitting;
        var restore = _activeRestore;
        var current = _current;
        _loop?.Cancel();
        _loop = null;
        var dropped = new List<AprsOutgoingPacket>();
        if (current is not null)
        {
            dropped.Add(current);
        }
        dropped.AddRange(_queue);
        _current = null;
        _queue.Clear();
        if (wasTransmitting)
        {
            _link.Unkey(restore);
            _activeRestore = null;
            IsTransmitting = false;
            _log($"aprs-tx: stopped: {reason}");
        }
        Changed?.Invoke();
        foreach (var packet in dropped)
        {
            Outcome?.Invoke(packet, AprsSendOutcome.Blocked(reason));
        }
    }

    private async Task RunAsync(CancellationTokenSource source)
    {
        var token = source.Token;
        while (!token.IsCancellationRequested && _queue.Count > 0)
        {
            var packet = _queue[0];
            _queue.RemoveAt(0);
            _current = packet;
            Changed?.Invoke();
            var outcome = await SendAsync(packet, token);
            if (token.IsCancellationRequested)
            {
                return;
            }
            _current = null;
            Outcome?.Invoke(packet, outcome);
            if (outcome.SentOn is not null && _queue.Count > 0)
            {
                await _clock.SleepAsync(PacketGap, token);
            }
        }
        if (ReferenceEquals(_loop, source))
        {
            _loop = null;
        }
        Changed?.Invoke();
    }

    private async Task<AprsSendOutcome> SendAsync(AprsOutgoingPacket packet, CancellationToken token)
    {
        if (AprsTransmitSettings.SourceCall is not { } call || Ax25Encoder.ParseAddress(call) is not { } source)
        {
            return AprsSendOutcome.Blocked(Loc.S("aprsTransmit.noCallsign"));
        }
        if (Ax25Encoder.ParsePath(AprsTransmitSettings.Path) is not { } path)
        {
            return AprsSendOutcome.Blocked(Loc.S("aprsTransmit.badPath"));
        }

        // Wait for a clear channel (bounded), then a short random delay so
        // two stations waiting for the same gap don't both go.
        var waitStart = _clock.Now();
        AprsTransmitPlan plan;
        while (true)
        {
            var decision = _link.PlanTransmit();
            if (decision.Plan is not { } chosen)
            {
                return AprsSendOutcome.Blocked(decision.BlockedReason ?? "");
            }
            plan = chosen;
            if (_clock.Now() - waitStart < MaxChannelWait && _link.ChannelBusy(plan.Side, ClearFor))
            {
                await _clock.SleepAsync(0.25, token);
                if (token.IsCancellationRequested)
                {
                    return AprsSendOutcome.Blocked("cancelled");
                }
                continue;
            }
            await _clock.SleepAsync(0.1 + 0.4 * _random(), token);
            if (token.IsCancellationRequested)
            {
                return AprsSendOutcome.Blocked("cancelled");
            }
            decision = _link.PlanTransmit();
            if (decision.Plan is not { } again)
            {
                return AprsSendOutcome.Blocked(decision.BlockedReason ?? "");
            }
            plan = again;
            break;
        }

        var frame = Ax25Encoder.Frame(AprsTransmitSettings.Destination, source, path, System.Text.Encoding.UTF8.GetBytes(packet.Info));
        var bits = Ax25Encoder.LineBits(frame, Ax25Encoder.Flags(AprsTransmitSettings.TxDelayMs / 1000.0), TailFlags);
        var level = (float)Math.Pow(10, AprsTransmitSettings.LevelDb / 20);
        var samples = Ax25Encoder.Afsk(bits, SampleRate, level);

        _link.Key(plan.RestoreSide is not null ? plan.Side : null);
        IsTransmitting = true;
        _activeRestore = plan.RestoreSide;
        Changed?.Invoke();
        _log($"aprs-tx: TX on {plan.Side}: {call}>{packet.Info}");
        try
        {
            var start = _clock.Now();
            var sent = 0;
            while (sent < samples.Length)
            {
                if (token.IsCancellationRequested)
                {
                    return AprsSendOutcome.Blocked("cancelled");
                }
                if (_link.TransmitBlock(plan.Side) is { } reason)
                {
                    _link.Unkey(plan.RestoreSide);
                    _log($"aprs-tx: stopped: {reason}");
                    return AprsSendOutcome.Blocked(reason);
                }
                var target = Math.Min(samples.Length, (int)Math.Round((_clock.Now() - start + Lead) * SampleRate));
                while (sent < target)
                {
                    var end = Math.Min(target, sent + Chunk);
                    _link.SendAudio(Pcm(samples.AsSpan(sent, end - sent)));
                    sent = end;
                }
                if (sent < samples.Length)
                {
                    await _clock.SleepAsync(Tick, token);
                }
            }
            var playedOut = start + samples.Length / SampleRate + UnkeyDelay - Lead;
            await _clock.SleepAsync(Math.Max(0, playedOut - _clock.Now()), token);
            if (token.IsCancellationRequested)
            {
                return AprsSendOutcome.Blocked("cancelled");
            }
            _link.Unkey(plan.RestoreSide);
            return AprsSendOutcome.Sent(plan.Side);
        }
        finally
        {
            IsTransmitting = false;
            _activeRestore = null;
            Changed?.Invoke();
        }
    }

    internal static byte[] Pcm(ReadOnlySpan<float> samples)
    {
        var data = new byte[samples.Length * 2];
        for (var i = 0; i < samples.Length; i++)
        {
            var value = (short)(Math.Clamp(samples[i], -1f, 1f) * 32767);
            data[i * 2] = (byte)value;
            data[i * 2 + 1] = (byte)(value >> 8);
        }
        return data;
    }
}
