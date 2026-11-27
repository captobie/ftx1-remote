using FTX1RemoteWindows.Services.Digi;

namespace FTX1RemoteWindows.Services.FreeDv;

/// What FreeDV transmit needs from the app: the transmit gate, keying, and
/// somewhere to send 8 kHz audio. MainWindow implements it (the Mac's
/// HubService+FreeDVTransmitLink.swift). All calls on the UI thread.
public interface IFreeDvTransmitLink
{
    /// Why a transmission can't start (or must stop) now, null when it may:
    /// the transmit gate, no rig, no transmit audio path, the wrong sideband
    /// for the band, the rig keyed by something else
    /// (<paramref name="keyedBySender"/> false).
    string? TransmitBlock(bool keyedBySender);
    /// What the rig reports (PTT).
    bool RigIsKeyed { get; }
    void SetKeyed(bool keyed);
    /// 16-bit little-endian mono PCM at 8 kHz.
    void SendAudio(byte[] pcm);
}

/// The microphone the sender runs while it transmits (FreeDvMicrophone).
public interface IFreeDvMicrophone
{
    /// Starts capture; throws with a message for the window if it can't.
    /// Both callbacks may come on any thread: samples are mono, ±1, at the
    /// given rate; <paramref name="onFailed"/> reports capture ending by
    /// itself.
    void Start(Action<float[], int> onSamples, Action<string> onFailed);
    void Stop();
}

/// Tools → FreeDV's transmitter — the Mac's FreeDVSender: keys the rig,
/// encodes the microphone with <see cref="RadeEncoder"/> and sends the modem
/// audio through the app's transmit audio path; RX (or releasing the space
/// bar) sends the end-of-over with the station's callsign, lets the audio play
/// out, then unkeys.
///
/// Stops on its own when the transmit gate closes, when the rig stops
/// reporting PTT (after a grace period), when the microphone fails, and at
/// <see cref="MaxTransmitSeconds"/>. Lives on the UI thread (its
/// continuations return to it); encoding runs off it, in order.
public sealed class FreeDvSender
{
    public enum SenderState
    {
        Idle,
        /// Keyed, sending the microphone.
        Transmitting,
        /// The end-of-over and tail are playing out; unkeys when done.
        Finishing,
    }

    /// How a transmission was started: the TX button latches; the space bar
    /// lasts only while held.
    public enum Trigger
    {
        Toggle,
        Momentary,
    }

    /// Anything the window shows changed (not the microphone level).
    public event Action? Changed;
    /// Called on every state change (the receiver pauses while active).
    public event Action<SenderState>? StateChanged;

    /// Safety limit for one over.
    public const double MaxTransmitSeconds = 300;
    /// PTT may read "off" for this long after keying before it counts.
    internal const double PttGraceSeconds = 2;
    /// How long PTT may read "off" mid-transmission before the sender stops.
    internal const double PttLossSeconds = 1;
    /// Kept keyed this long past the audio's estimated end (sink buffering).
    internal const double PlayoutMarginSeconds = 0.3;
    /// Silence ahead of the first modem frame. The modem audio comes in 120 ms
    /// frames at real-time pace, so without a cushion the sink (the Pi's
    /// ftx1-txaudio, or the local output) would run dry between two of them
    /// whenever one is late, leaving gaps in the signal on the air.
    internal const double LeadSilenceSeconds = 0.2;
    public const double MinLevelDb = -20;
    public const double MaxLevelDb = 0;
    public const double MicFloorDb = -60;

    private readonly IFreeDvTransmitLink _link;
    private readonly IFreeDvMicrophone _microphone;
    private readonly Func<string> _callsign;
    private readonly Action<Action> _post;
    private readonly IDigiSenderClock _clock;
    private readonly Action<string> _log;

    /// One over's encoder; touched only by the encoding chain.
    private sealed class Session(RadeEncoder encoder)
    {
        public RadeEncoder Encoder { get; } = encoder;
        public DigiResampler Resampler { get; } = new(RadeEncoder.SpeechSampleRate);
    }

    private Session? _session;
    /// The tail of the encoding chain, so chunks encode and go out in order.
    private Task _encoding = Task.CompletedTask;
    private volatile float _gain;
    private double _levelDb;

    private CancellationTokenSource? _loop;
    private double _keyedAt;
    private double? _pttOffSince;
    /// Modem audio handed to the link this over, and when the first went.
    private long _sentSamples;
    private double? _firstSentAt;
    /// Bumped per transmission so a late chunk from the last one is dropped.
    private int _generation;

    /// <param name="callsign">The station callsign for the end-of-over, read
    /// at each over's end (Settings → Station).</param>
    /// <param name="post">Runs an action on the UI thread.</param>
    public FreeDvSender(IFreeDvTransmitLink link, IFreeDvMicrophone microphone, Func<string> callsign,
        Action<Action> post, double levelDb, Action<string>? log = null, IDigiSenderClock? clock = null)
    {
        _link = link;
        _microphone = microphone;
        _callsign = callsign;
        _post = post;
        _log = log ?? (_ => { });
        _clock = clock ?? new SystemDigiSenderClock();
        _levelDb = Math.Clamp(levelDb, MinLevelDb, MaxLevelDb);
        _gain = Gain(_levelDb);
    }

    public SenderState State { get; private set; } = SenderState.Idle;
    public Trigger StartedBy { get; private set; } = Trigger.Toggle;
    public bool IsActive => State != SenderState.Idle;
    /// Seconds on the clock when the current transmission keyed.
    public double? TransmitStartedAt { get; private set; }
    public double Now => _clock.Now();
    /// Why the last start was refused or the last transmission stopped early;
    /// cleared on the next start.
    public string? Message { get; private set; }
    /// Peak of the last microphone chunk, dBFS (the window samples it).
    public double MicPeakDb { get; private set; } = MicFloorDb;

    /// Output level relative to the FreeDV app's (16383 of 32767), dB.
    public double LevelDb
    {
        get => _levelDb;
        set
        {
            _levelDb = Math.Clamp(value, MinLevelDb, MaxLevelDb);
            _gain = Gain(_levelDb);
        }
    }

    internal static float Gain(double levelDb) =>
        RadeEncoder.NominalOutputScale * (float)Math.Pow(10, levelDb / 20);

    // Control

    /// TX, or the space bar going down. Refused (with <see cref="Message"/>)
    /// when the link says no.
    public void Start(Trigger trigger)
    {
        if (State != SenderState.Idle)
        {
            return;
        }
        if (_link.TransmitBlock(false) is { } reason)
        {
            SetMessage(reason);
            return;
        }
        RadeEncoder encoder;
        try
        {
            encoder = new RadeEncoder();
        }
        catch (Exception ex)
        {
            _log($"freedv-tx: encoder: {ex.Message}");
            SetMessage(Loc.S("freeDvSender.encoderFailed"));
            return;
        }
        Message = null;
        var generation = ++_generation;
        _session = new Session(encoder);
        _sentSamples = 0;
        _firstSentAt = null;
        _pttOffSince = null;
        _keyedAt = _clock.Now();
        StartedBy = trigger;
        TransmitStartedAt = _keyedAt;
        SetState(SenderState.Transmitting);
        _link.SetKeyed(true);
        try
        {
            _microphone.Start(
                (samples, rate) => _post(() => IngestMicrophone(samples, rate, generation)),
                failure => _post(() =>
                {
                    if (generation == _generation && State == SenderState.Transmitting)
                    {
                        StopNow(failure);
                    }
                }));
        }
        catch (Exception ex)
        {
            _log($"freedv-tx: microphone: {ex.Message}");
            StopNow(ex.Message);
            return;
        }
        _log($"freedv-tx: keyed ({(trigger == Trigger.Toggle ? "TX" : "space")})");
        _loop = new CancellationTokenSource();
        _ = MonitorAsync(_loop.Token);
    }

    /// RX, or the space bar coming up after a momentary start: the
    /// end-of-over goes out, then the rig unkeys.
    public void Finish()
    {
        if (State != SenderState.Transmitting || _session is not { } session)
        {
            return;
        }
        _session = null;
        _microphone.Stop();
        MicPeakDb = MicFloorDb;
        SetState(SenderState.Finishing);
        var call = _callsign().Trim();
        var generation = _generation;
        Encode(() =>
        {
            try
            {
                var tail = new float[(int)(RadeEncoder.TailSilenceSeconds * RadeEncoder.ModemSampleRate)];
                float[] modem = [.. session.Encoder.Finish(call.Length == 0 ? null : call), .. tail];
                var pcm = FreeDvPcm.From(modem, _gain);
                _post(() =>
                {
                    Send(pcm, generation);
                    _log($"freedv-tx: end of over ({(call.Length == 0 ? "no callsign" : call)})");
                    _ = UnkeyAfterPlayoutAsync(generation);
                });
            }
            catch (Exception ex)
            {
                _log($"freedv-tx: end of over failed: {ex.Message}");
                _post(() =>
                {
                    if (generation == _generation)
                    {
                        StopNow(ex.Message);
                    }
                });
            }
            finally
            {
                session.Encoder.Dispose();
            }
        });
    }

    /// The space bar came up: ends the over only if the space bar started it.
    public void ReleaseMomentary()
    {
        if (State == SenderState.Transmitting && StartedBy == Trigger.Momentary)
        {
            Finish();
        }
    }

    /// Stop now: unkey at once, no end-of-over (the gate closed, the link
    /// dropped, the app is quitting).
    public void Stop(string? reason = null)
    {
        if (State != SenderState.Idle)
        {
            StopNow(reason);
        }
    }

    // Audio

    private void IngestMicrophone(float[] samples, int sampleRate, int generation)
    {
        if (generation != _generation || State != SenderState.Transmitting || _session is not { } session)
        {
            return;
        }
        var peak = 0f;
        foreach (var sample in samples)
        {
            peak = Math.Max(peak, Math.Abs(sample));
        }
        MicPeakDb = Math.Max(MicFloorDb, 20 * Math.Log10(Math.Max(peak, 1e-6)));
        Encode(() =>
        {
            var modem = session.Encoder.Process(session.Resampler.Convert(samples, sampleRate));
            if (modem.Length == 0)
            {
                return;
            }
            var pcm = FreeDvPcm.From(modem, _gain);
            _post(() => Send(pcm, generation));
        });
    }

    /// Runs <paramref name="work"/> off the UI thread, after everything queued
    /// before it.
    private void Encode(Action work) => _encoding = _encoding.ContinueWith(_ =>
    {
        try
        {
            work();
        }
        catch (Exception ex)
        {
            _log($"freedv-tx: encoding: {ex.Message}");
        }
    }, CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);

    private void Send(byte[] pcm, int generation)
    {
        if (generation != _generation || State == SenderState.Idle)
        {
            return;
        }
        if (_firstSentAt is null)
        {
            _firstSentAt = _clock.Now();
            var lead = new byte[(int)(LeadSilenceSeconds * RadeEncoder.ModemSampleRate) * 2];
            pcm = [.. lead, .. pcm];
        }
        _sentSamples += pcm.Length / 2;
        _link.SendAudio(pcm);
    }

    // Ending

    private async Task UnkeyAfterPlayoutAsync(int generation)
    {
        var sentSeconds = (double)_sentSamples / RadeEncoder.ModemSampleRate;
        var elapsed = _firstSentAt is { } first ? _clock.Now() - first : 0;
        var remaining = Math.Max(0, sentSeconds - elapsed) + PlayoutMarginSeconds;
        await _clock.SleepAsync(remaining, CancellationToken.None);
        if (generation != _generation || State != SenderState.Finishing)
        {
            return;
        }
        _link.SetKeyed(false);
        _log("freedv-tx: done");
        EndTransmission();
    }

    private void StopNow(string? reason)
    {
        _microphone.Stop();
        MicPeakDb = MicFloorDb;
        _generation++;
        if (_session is { } session)
        {
            _session = null;
            // After any chunk still being encoded.
            Encode(session.Encoder.Dispose);
        }
        _link.SetKeyed(false);
        Message = reason;
        _log($"freedv-tx: stopped{(reason is null ? "" : ": " + reason)}");
        EndTransmission();
    }

    private void EndTransmission()
    {
        _loop?.Cancel();
        _loop = null;
        TransmitStartedAt = null;
        SetState(SenderState.Idle);
        Changed?.Invoke();
    }

    private void SetMessage(string? message)
    {
        Message = message;
        Changed?.Invoke();
    }

    private void SetState(SenderState state)
    {
        if (State == state)
        {
            return;
        }
        State = state;
        StateChanged?.Invoke(state);
        Changed?.Invoke();
    }

    /// Every 100 ms while transmitting: the gate, PTT, the time limit.
    private async Task MonitorAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested && State == SenderState.Transmitting)
        {
            await _clock.SleepAsync(0.1, token);
            if (token.IsCancellationRequested || State != SenderState.Transmitting)
            {
                return;
            }
            var now = _clock.Now();
            if (_link.TransmitBlock(true) is { } reason)
            {
                StopNow(reason);
                return;
            }
            if (now - _keyedAt > MaxTransmitSeconds)
            {
                Message = Loc.S("freeDvSender.timeLimit");
                Finish();
                return;
            }
            if (_link.RigIsKeyed)
            {
                _pttOffSince = null;
            }
            else if (now - _keyedAt > PttGraceSeconds)
            {
                var since = _pttOffSince ?? now;
                _pttOffSince = since;
                if (now - since > PttLossSeconds)
                {
                    StopNow(Loc.S("freeDvSender.unkeyedElsewhere"));
                    return;
                }
            }
        }
    }
}
