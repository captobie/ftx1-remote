using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services.Digi;

namespace FTX1RemoteWindows.Services;

/// Why APRS can't transmit yet, worded for the user.
public enum AprsSetupProblem
{
    TransmitOff,
    NoCallsign,
    NoPosition,
    BadSymbol,
    BadPath,
    BadAddressee,
    EmptyMessage,
}

public static class AprsSetupProblems
{
    public static string Message(this AprsSetupProblem problem) => problem switch
    {
        AprsSetupProblem.TransmitOff => Loc.S("aprsMessaging.transmitOff"),
        AprsSetupProblem.NoCallsign => Loc.S("aprsTransmit.noCallsign"),
        AprsSetupProblem.NoPosition => Loc.S("aprsMessaging.noPosition"),
        AprsSetupProblem.BadSymbol => Loc.S("aprsMessaging.badSymbol"),
        AprsSetupProblem.BadPath => Loc.S("aprsTransmit.badPath"),
        AprsSetupProblem.BadAddressee => Loc.S("aprsMessaging.badAddressee"),
        AprsSetupProblem.EmptyMessage => Loc.S("aprsMessaging.emptyMessage"),
        _ => "",
    };
}

/// The APRS side of transmitting: position beacons (Beacon Now and the
/// optional interval), this station's messages with retries until acked, and
/// acks for messages addressed to this station. Everything goes out through
/// an <see cref="AprsTransmitter"/>; nothing does while Settings → APRS →
/// Transmit is off. Port of the Mac's APRSMessaging
/// (Sources/FTX1Core/APRS/APRSMessaging.swift). UI thread only; the owner
/// calls <see cref="Tick"/> once a second.
public sealed class AprsMessaging
{
    /// Seconds to wait after each transmission of a message before sending it
    /// again; one entry per transmission (so 5 tries), the last being how
    /// long to wait for the ack before giving up.
    public static readonly double[] RetryDelays = [30, 60, 120, 240, 240];
    /// A message not sent in this long (transmit blocked all along) fails.
    public const double GiveUpAfter = 15 * 60;
    /// Same message from the same station acked at most this often.
    public const double AckRepeatLimit = 20;
    /// Retry after a blocked attempt.
    internal const double BlockedRetry = 30;

    private readonly AprsStore _store;
    private readonly AprsTransmitter _transmitter;
    private readonly IDigiSenderClock _clock;
    private readonly Func<DateTimeOffset> _date;
    private readonly Action<string> _log;

    private sealed class Pending
    {
        public double Created;
        public double NextAttempt;
    }

    /// Own messages still waiting for an ack, by AprsMessage.Id.
    private readonly Dictionary<string, Pending> _pending = [];
    private readonly Dictionary<string, double> _lastAcked = [];
    private double? _nextBeacon;
    private int _scheduledMinutes;

    public AprsMessaging(AprsStore store, AprsTransmitter transmitter, Action<string>? log = null,
        IDigiSenderClock? clock = null, Func<DateTimeOffset>? date = null)
    {
        _store = store;
        _transmitter = transmitter;
        _log = log ?? (_ => { });
        _clock = clock ?? new SystemDigiSenderClock();
        _date = date ?? (() => DateTimeOffset.Now);
        // Own messages left pending by the last run aren't resumed: mark them.
        foreach (var message in store.Messages.Where(m => m.Delivery?.State == AprsDeliveryState.Pending).ToList())
        {
            store.UpdateDelivery(message.Id, d =>
            {
                d.State = AprsDeliveryState.Failed;
                d.Note = Loc.S("aprsMessaging.appQuit");
            });
        }
        transmitter.Outcome += Handle;
    }

    /// The last beacon's outcome, for the windows' status line.
    public string? BeaconStatus { get; private set; }
    public DateTimeOffset? LastBeaconAt { get; private set; }
    /// When the interval beacon fires next (null: interval off or transmit off).
    public DateTimeOffset? NextBeaconAt { get; private set; }

    /// Beacon status, schedule or an own message changed.
    public event Action? Changed;

    // Beacon

    /// The beacon's info field, or why there's none to send.
    public static (string? Info, AprsSetupProblem? Problem) BeaconInfo()
    {
        if (AprsTransmitSettings.SourceCall is null)
        {
            return (null, AprsSetupProblem.NoCallsign);
        }
        if (AprsTransmitSettings.Latitude is not { } latitude || AprsTransmitSettings.Longitude is not { } longitude
            || latitude is < -90 or > 90 || longitude is < -180 or > 180)
        {
            return (null, AprsSetupProblem.NoPosition);
        }
        var symbol = AprsTransmitSettings.Symbol;
        if (symbol.Length != 2 || symbol.Any(c => c > 0x7F))
        {
            return (null, AprsSetupProblem.BadSymbol);
        }
        if (Ax25Encoder.ParsePath(AprsTransmitSettings.Path) is null)
        {
            return (null, AprsSetupProblem.BadPath);
        }
        return (AprsOutgoing.Position(latitude, longitude, symbol[0], symbol[1], AprsTransmitSettings.Comment,
            AprsTransmitSettings.Ambiguity), null);
    }

    public void BeaconNow()
    {
        if (!AprsTransmitSettings.Enabled)
        {
            BeaconStatus = AprsSetupProblem.TransmitOff.Message();
            Changed?.Invoke();
            return;
        }
        var (info, problem) = BeaconInfo();
        if (info is null)
        {
            BeaconStatus = problem?.Message();
        }
        else if (!_transmitter.IsQueued(AprsPacketKind.Beacon))
        {
            BeaconStatus = Loc.S("aprsMessaging.beaconQueued");
            _transmitter.Enqueue(new AprsOutgoingPacket(AprsPacketKind.Beacon, info));
        }
        else
        {
            return;
        }
        ScheduleBeacon(_clock.Now());
        Changed?.Invoke();
    }

    /// Settings were saved (or the app started): re-plan the interval beacon,
    /// and drop anything queued if transmit went off.
    public void SettingsChanged()
    {
        var wanted = AprsTransmitSettings.Enabled && AprsTransmitSettings.BeaconMinutes > 0;
        if (!wanted)
        {
            _nextBeacon = null;
            NextBeaconAt = null;
        }
        else if (_nextBeacon is null || _scheduledMinutes != AprsTransmitSettings.BeaconMinutes)
        {
            ScheduleBeacon(_clock.Now());
        }
        if (!AprsTransmitSettings.Enabled && (_transmitter.QueueCount > 0 || _transmitter.IsTransmitting))
        {
            _transmitter.StopAll(AprsSetupProblem.TransmitOff.Message());
        }
        Changed?.Invoke();
    }

    private void ScheduleBeacon(double now)
    {
        var minutes = AprsTransmitSettings.BeaconMinutes;
        _scheduledMinutes = minutes;
        if (!AprsTransmitSettings.Enabled || minutes <= 0)
        {
            _nextBeacon = null;
            NextBeaconAt = null;
            return;
        }
        var seconds = minutes * 60.0;
        _nextBeacon = now + seconds;
        NextBeaconAt = _date().AddSeconds(seconds);
    }

    // Messages

    /// Queues a message to <paramref name="addressee"/>; it's listed in
    /// M.LIST at once and sent until acked. Returns why not, if it can't be.
    public AprsSetupProblem? Send(string text, string addressee)
    {
        if (!AprsTransmitSettings.Enabled)
        {
            return AprsSetupProblem.TransmitOff;
        }
        if (AprsTransmitSettings.SourceCall is not { } myCall)
        {
            return AprsSetupProblem.NoCallsign;
        }
        var to = addressee.Trim(' ', '\t').ToUpperInvariant();
        if (to.Length == 0 || to.Length > 9 || AprsOutgoing.Sanitized(to) != to || to.Contains(':'))
        {
            return AprsSetupProblem.BadAddressee;
        }
        var body = AprsOutgoing.Sanitized(text, forMessage: true);
        if (body.Length > AprsOutgoing.MaxMessageLength)
        {
            body = body[..AprsOutgoing.MaxMessageLength];
        }
        body = body.Trim(' ', '\t');
        if (body.Length == 0)
        {
            return AprsSetupProblem.EmptyMessage;
        }
        var message = new AprsMessage
        {
            From = myCall,
            To = to,
            Text = body,
            MessageId = NextMessageId(),
            ReceivedAt = _date(),
            Delivery = new AprsDelivery(),
        };
        _store.RecordOutgoing(message);
        var now = _clock.Now();
        _pending[message.Id] = new Pending { Created = now, NextAttempt = now };
        Attempt(message.Id);
        return null;
    }

    /// Sends it once more (a failed or cancelled one starts over).
    public void Resend(string id)
    {
        if (_store.Messages.FirstOrDefault(m => m.Id == id)?.Delivery is null)
        {
            return;
        }
        _store.UpdateDelivery(id, d =>
        {
            d.State = AprsDeliveryState.Pending;
            d.Attempts = 0;
            d.Note = null;
        });
        var now = _clock.Now();
        _pending[id] = new Pending { Created = now, NextAttempt = now };
        Attempt(id);
    }

    public void Cancel(string id)
    {
        _pending.Remove(id);
        _transmitter.Remove(AprsPacketKind.Message(id));
        _store.UpdateDelivery(id, d =>
        {
            if (d.State == AprsDeliveryState.Pending)
            {
                d.State = AprsDeliveryState.Cancelled;
            }
        });
    }

    /// 1…99999, persisted, so ids don't repeat soon across launches.
    private static string NextMessageId() =>
        AprsTransmitSettings.Config.NextMessageNumber().ToString(System.Globalization.CultureInfo.InvariantCulture);

    private void Attempt(string id)
    {
        var message = _store.Messages.FirstOrDefault(m => m.Id == id);
        if (message?.Delivery?.State != AprsDeliveryState.Pending || message.MessageId is not { } messageId)
        {
            _pending.Remove(id);
            return;
        }
        if (_transmitter.IsQueued(AprsPacketKind.Message(id)))
        {
            return;
        }
        // Not sent until the transmitter's outcome says so.
        if (_pending.TryGetValue(id, out var entry))
        {
            entry.NextAttempt = double.PositiveInfinity;
        }
        _transmitter.Enqueue(new AprsOutgoingPacket(AprsPacketKind.Message(id),
            AprsOutgoing.Message(message.To, message.Text, messageId)));
    }

    /// The transmitter's outcome for a packet of ours.
    private void Handle(AprsOutgoingPacket packet, AprsSendOutcome outcome)
    {
        var now = _clock.Now();
        switch (packet.Kind.Type)
        {
            case AprsPacketKindType.Beacon:
                if (outcome.SentOn is { } side)
                {
                    LastBeaconAt = _date();
                    BeaconStatus = Loc.F("aprsMessaging.beaconSent", side == AprsSource.Main ? "MAIN" : "SUB");
                }
                else
                {
                    BeaconStatus = Loc.F("aprsMessaging.beaconNotSent", outcome.BlockedReason ?? "");
                }
                break;
            case AprsPacketKindType.Ack:
                if (outcome.BlockedReason is { } why)
                {
                    _log($"aprs-tx: ack {packet.Kind.Extra} to {packet.Kind.Key} not sent: {why}");
                }
                break;
            case AprsPacketKindType.Message:
                var id = packet.Kind.Key!;
                if (!_pending.TryGetValue(id, out var entry))
                {
                    break;
                }
                if (outcome.SentOn is not null)
                {
                    var attempts = 0;
                    _store.UpdateDelivery(id, d =>
                    {
                        if (d.State != AprsDeliveryState.Pending)
                        {
                            return;
                        }
                        d.Attempts++;
                        d.Note = null;
                        attempts = d.Attempts;
                    });
                    if (attempts == 0)
                    {
                        _pending.Remove(id);
                        break;
                    }
                    entry.NextAttempt = now + RetryDelays[Math.Min(attempts, RetryDelays.Length) - 1];
                }
                else
                {
                    _store.UpdateDelivery(id, d => d.Note = outcome.BlockedReason);
                    entry.NextAttempt = now + BlockedRetry;
                }
                break;
        }
        Changed?.Invoke();
    }

    /// Once a second: due retries, give-ups, the interval beacon.
    public void Tick()
    {
        var now = _clock.Now();
        foreach (var (id, entry) in _pending.ToList())
        {
            if (entry.NextAttempt > now)
            {
                continue;
            }
            var delivery = _store.Messages.FirstOrDefault(m => m.Id == id)?.Delivery;
            if (delivery is not { State: AprsDeliveryState.Pending })
            {
                _pending.Remove(id);
            }
            else if (delivery.Attempts >= RetryDelays.Length)
            {
                _pending.Remove(id);
                _store.UpdateDelivery(id, d =>
                {
                    d.State = AprsDeliveryState.Failed;
                    d.Note = Loc.S("aprsMessaging.noAck");
                });
            }
            else if (now - entry.Created > GiveUpAfter)
            {
                _pending.Remove(id);
                _store.UpdateDelivery(id, d => d.State = AprsDeliveryState.Failed);
            }
            else
            {
                Attempt(id);
            }
        }
        if (_nextBeacon is { } next && now >= next)
        {
            // A missed beacon (setup incomplete, transmit blocked) just waits
            // for the next interval.
            BeaconNow();
        }
        foreach (var key in _lastAcked.Where(p => now - p.Value >= AckRepeatLimit).Select(p => p.Key).ToList())
        {
            _lastAcked.Remove(key);
        }
    }

    // Received

    /// Every decoded message (both receivers): acks for our messages, and an
    /// ack back for messages to us that carry an id.
    public void HandleIncoming(string from, string to, string text, string? messageId)
    {
        if (AprsTransmitSettings.SourceCall is not { } myCall || to.Trim(' ', '\t').ToUpperInvariant() != myCall)
        {
            return;
        }
        var sender = from.ToUpperInvariant();

        if (AprsOutgoing.ReplyTo(text, messageId) is { } reply)
        {
            Settle(sender, reply.Id, reply.Kind == AprsOutgoing.ReplyKind.Ack ? AprsDeliveryState.Acked : AprsDeliveryState.Rejected);
        }

        // A plain "ack"/"rej" has no id of its own; a message (incl. one with
        // a reply-ack) gets acked.
        if (AprsOutgoing.IdToAck(messageId) is not { } id || !AprsTransmitSettings.Enabled || !AprsTransmitSettings.AutoAck
            || Ax25Encoder.ParseAddress(sender) is null)
        {
            return;
        }
        var key = sender + "|" + id;
        var now = _clock.Now();
        if (_lastAcked.TryGetValue(key, out var last) && now - last < AckRepeatLimit)
        {
            return;
        }
        var kind = AprsPacketKind.Ack(sender, id);
        if (_transmitter.IsQueued(kind))
        {
            return;
        }
        _lastAcked[key] = now;
        _transmitter.Enqueue(new AprsOutgoingPacket(kind, AprsOutgoing.Ack(sender, id)));
    }

    private void Settle(string sender, string id, AprsDeliveryState state)
    {
        var message = _store.Messages.LastOrDefault(m =>
            m.Delivery is not null && m.To.ToUpperInvariant() == sender && m.MessageId == id);
        if (message is null)
        {
            return;
        }
        _pending.Remove(message.Id);
        _transmitter.Remove(AprsPacketKind.Message(message.Id));
        _store.UpdateDelivery(message.Id, d =>
        {
            d.State = state;
            d.Note = null;
        });
        _log($"aprs-tx: message {id} to {sender} {state}");
        Changed?.Invoke();
    }
}
