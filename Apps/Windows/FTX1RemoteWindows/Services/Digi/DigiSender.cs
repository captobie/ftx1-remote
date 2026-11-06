using System.Diagnostics;
using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services.Digi;

/// What the RTTY/PSK sender needs from the app: the transmit gate, keying,
/// and somewhere to send 8 kHz audio. MainWindow implements it (the Mac's
/// HubService+DigiTransmitLink.swift). All calls on the UI thread.
public interface IDigiTransmitLink
{
    /// Why a transmission can't start (or must stop) now, null when it may:
    /// the transmit gate, no rig, no transmit audio path, the rig keyed by
    /// something else (<paramref name="keyedBySender"/> false).
    string? TransmitBlock(bool keyedBySender);
    /// The transmitting side's mode, null before it's known (or in C4FM).
    RigMode? TransmitMode { get; }
    /// What the rig reports (PTT).
    bool RigIsKeyed { get; }
    void SetKeyed(bool keyed);
    /// 16-bit little-endian mono PCM at 8 kHz.
    void SendAudio(byte[] pcm);
}

/// What the sender needs to know about the receiver at TX: the signal goes
/// out where the decoder is listening (after AFC), so an answer lands on the
/// station being decoded.
public interface IDigiTxSource
{
    DigiMode Mode { get; }
    /// Where the decoder is listening now (after AFC); 0 if unknown.
    double TrackedHz { get; }
    /// Where the operator put it.
    double CenterHz { get; }
    /// The operator's settings (Reverse = "this station sends upside down").
    RttySettings Rtty { get; }
}

/// Time for <see cref="DigiSender"/>'s pacing loop; replaced in tests.
public interface IDigiSenderClock
{
    /// Seconds on a monotonic clock.
    double Now();
    Task SleepAsync(double seconds, CancellationToken cancellationToken);
}

public sealed class SystemDigiSenderClock : IDigiSenderClock
{
    public double Now() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    public async Task SleepAsync(double seconds, CancellationToken cancellationToken)
    {
        if (seconds <= 0)
        {
            return;
        }
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(seconds), cancellationToken);
        }
        catch (OperationCanceledException)
        {
        }
    }
}

/// Live-typeahead RTTY/PSK sending, as in fldigi — the Mac's DigiSender: TX
/// keys the rig and sends what's in the box as it's typed (idling when the
/// box is empty), RX sends what's left plus the closing tail and unkeys,
/// Stop unkeys at once. Audio is generated just ahead of real time
/// (<see cref="Lead"/>), so typing reaches the air quickly and Stop is
/// near-instant.
///
/// Mode, centre frequency and RTTY settings come from the receiver at TX.
/// Lives on the UI thread (its continuations return to it).
public sealed class DigiSender
{
    public enum SenderState
    {
        Idle,
        Transmitting,
        /// RX pressed: sending the rest, then the tail.
        Finishing,
    }

    /// Anything the pane shows changed.
    public event Action? Changed;
    /// Each character as it starts going out, for the transmit echo.
    public event Action<string>? Echo;
    /// Called on every state change (the receiver pauses while sending).
    public event Action<SenderState>? StateChanged;

    public const double TransmitLimit = 180;
    internal const double Lead = 0.25;
    internal const double Tick = 0.02;
    internal const int Chunk = 160;
    /// After the last sample: the lead still to play plus the output's own buffer.
    internal const double UnkeyDelay = Lead + 0.3;
    /// How long the rig may read "not keyed" before the sender gives up.
    internal const double KeyLossLimit = 1.0;
    /// No key-loss check this soon after keying (the first PTT read lags).
    internal const double KeyLossGrace = 2.0;
    public const double MinLevelDb = -30;
    public const double MaxLevelDb = 0;

    /// AFSK and PSK are audio: the rig must pass audio through on SSB.
    internal static readonly RigMode[] TransmitModes = [RigMode.DataUsb, RigMode.Usb, RigMode.Lsb];

    private readonly IDigiTransmitLink _link;
    private readonly IDigiTxSource _source;
    private readonly IDigiSenderClock _clock;
    private readonly Func<string> _myCall;
    private readonly Func<string> _myGrid;
    private readonly Action<string> _log;
    private List<char> _characters = [];
    private IDigiModulator? _modulator;
    private CancellationTokenSource? _loop;
    private double? _keyLostAt;
    private string _text = "";
    private int _sentCount;
    private double _levelDb;

    public DigiSender(IDigiTransmitLink link, IDigiTxSource source, Func<string> myCall, Func<string> myGrid,
        double levelDb, Action<string>? log = null, IDigiSenderClock? clock = null)
    {
        _link = link;
        _source = source;
        _myCall = myCall;
        _myGrid = myGrid;
        _levelDb = Math.Clamp(levelDb, MinLevelDb, MaxLevelDb);
        _log = log ?? (_ => { });
        _clock = clock ?? new SystemDigiSenderClock();
    }

    public SenderState State { get; private set; } = SenderState.Idle;

    /// The typeahead box. The first <see cref="SentCount"/> characters have gone out.
    public string Text => _text;
    public int SentCount => _sentCount;
    /// Why the last transmission ended early, or why one couldn't start.
    public string? Message { get; private set; }
    /// Seconds on the clock when TX started, null when not transmitting.
    public double? TransmitStartedAt { get; private set; }
    public string TheirCall { get; set; } = "";

    /// dBFS peak of the generated audio.
    public double LevelDb
    {
        get => _levelDb;
        set
        {
            _levelDb = Math.Clamp(value, MinLevelDb, MaxLevelDb);
            Changed?.Invoke();
        }
    }

    public double Now => _clock.Now();
    public bool IsTransmitting => State != SenderState.Idle;
    public int UnsentCount => _characters.Count - _sentCount;

    /// Why TX would be refused right now, null when it would start.
    public string? BlockReason
    {
        get
        {
            if (_link.TransmitBlock(IsTransmitting) is { } reason)
            {
                return reason;
            }
            if (_link.TransmitMode is { } mode && !TransmitModes.Contains(mode))
            {
                return Loc.F("digiSender.wrongMode", mode.DisplayName());
            }
            return null;
        }
    }

    // The box

    /// The box after an edit. Edits that would change text already sent are
    /// refused (the box keeps its old text); returns the box's text.
    public string Edit(string newText)
    {
        var chars = newText.ToList();
        if (chars.Count < _sentCount || !chars.Take(_sentCount).SequenceEqual(_characters.Take(_sentCount)))
        {
            return _text;
        }
        _characters = chars;
        _text = newText;
        Changed?.Invoke();
        return _text;
    }

    public void Append(string addition) => Edit(_text + addition);

    /// Empties the unsent part (the sent part goes when the transmission ends).
    public void ClearUnsent() => Edit(new string(_characters.Take(_sentCount).ToArray()));

    // TX / RX / Stop

    public void Transmit()
    {
        if (State != SenderState.Idle)
        {
            // RX pressed, then TX again before the tail: keep going.
            if (State == SenderState.Finishing && !(_modulator?.IsFinished ?? true))
            {
                SetState(SenderState.Transmitting);
            }
            return;
        }
        if (BlockReason is { } reason)
        {
            Message = reason;
            Changed?.Invoke();
            return;
        }
        var modulator = MakeModulator();
        Message = null;
        _modulator = modulator;
        modulator.OnCharacterStarted = character => Echo?.Invoke(character.ToString());
        _keyLostAt = null;
        _link.SetKeyed(true);
        SetState(SenderState.Transmitting);
        _log($"digi: TX {_source.Mode.Title()} at {(int)_source.TrackedHz} Hz");
        _loop?.Cancel();
        _loop = new CancellationTokenSource();
        _ = RunAsync(_loop.Token);
    }

    /// Send what's left, the tail, then unkey.
    public void Finish()
    {
        if (State == SenderState.Transmitting)
        {
            SetState(SenderState.Finishing);
        }
    }

    /// Unkey now; unsent text is dropped.
    public void Stop(string? reason = null)
    {
        _loop?.Cancel();
        _loop = null;
        var wasTransmitting = State != SenderState.Idle;
        _modulator = null;
        if (wasTransmitting)
        {
            _link.SetKeyed(false);
            _log($"digi: TX stopped{(reason is null ? "" : ": " + reason)}");
        }
        Message = reason;
        EndTransmission(keepUnsent: false);
    }

    private void EndTransmission(bool keepUnsent)
    {
        var unsent = keepUnsent ? new string(_characters.Skip(_sentCount).ToArray()) : "";
        _characters = unsent.ToList();
        _text = unsent;
        _sentCount = 0;
        TransmitStartedAt = null;
        if (State != SenderState.Idle)
        {
            Echo?.Invoke("\n");
        }
        SetState(SenderState.Idle);
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

    private IDigiModulator MakeModulator()
    {
        var level = (float)Math.Pow(10, _levelDb / 20);
        var center = Math.Round(_source.TrackedHz > 0 ? _source.TrackedHz : _source.CenterHz);
        if (_source.Mode == DigiMode.Rtty)
        {
            var upper = _link.TransmitMode is RigMode.Usb or RigMode.DataUsb;
            var tones = _source.Rtty.Tones(center, upper);
            return new RttyModulator(tones.MarkHz, tones.SpaceHz, _source.Rtty.Baud, level);
        }
        return new PskModulator(center, _source.Mode.PskBaud(), level);
    }

    // Pacing

    private async Task RunAsync(CancellationToken token)
    {
        var start = _clock.Now();
        TransmitStartedAt = start;
        var samplesSent = 0;
        while (!token.IsCancellationRequested && _modulator is { } modulator)
        {
            var now = _clock.Now();
            var elapsed = now - start;

            if (elapsed >= TransmitLimit)
            {
                Stop(Loc.S("digiSender.limitReached"));
                return;
            }
            if (_link.TransmitBlock(true) is { } blocked)
            {
                Stop(blocked);
                return;
            }
            if (elapsed > KeyLossGrace && !_link.RigIsKeyed)
            {
                if (_keyLostAt is { } lostAt)
                {
                    if (now - lostAt > KeyLossLimit)
                    {
                        Stop(Loc.S("digiSender.keyingEnded"));
                        return;
                    }
                }
                else
                {
                    _keyLostAt = now;
                }
            }
            else
            {
                _keyLostAt = null;
            }

            var target = (int)Math.Round((elapsed + Lead) * DigiDecoder.SampleRate);
            while (samplesSent < target && !modulator.IsFinished)
            {
                if (State == SenderState.Finishing && _sentCount >= _characters.Count)
                {
                    modulator.BeginTail();
                }
                var samples = modulator.Render(Chunk, NextCharacter);
                _link.SendAudio(Pcm(samples));
                samplesSent += samples.Length;
            }

            if (modulator.IsFinished)
            {
                // Let the audio already sent play out, then unkey.
                var playedOut = start + samplesSent / DigiDecoder.SampleRate + UnkeyDelay - Lead;
                var wait = Math.Max(0, playedOut - _clock.Now());
                await _clock.SleepAsync(wait, token);
                if (token.IsCancellationRequested)
                {
                    return;
                }
                _link.SetKeyed(false);
                _loop = null;
                _modulator = null;
                _log("digi: TX done");
                EndTransmission(keepUnsent: true);
                return;
            }
            await _clock.SleepAsync(Tick, token);
        }
    }

    /// The next unsent character, or '\0' to idle. Once RX is pressed,
    /// nothing typed after the tail has started goes out.
    private char NextCharacter()
    {
        if (_sentCount >= _characters.Count)
        {
            return '\0';
        }
        var character = _characters[_sentCount];
        _sentCount++;
        Changed?.Invoke();
        return character;
    }

    internal static byte[] Pcm(float[] samples)
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

    // Macros

    /// Appends the macro's text; {TX} at the start also keys, {RX} at the end
    /// returns to receive once the box has gone out.
    public void Run(DigiMacro macro)
    {
        var result = macro.Expand(_myCall(), _myGrid(), TheirCall);
        if (result.Problem is { } problem)
        {
            Message = problem;
            Changed?.Invoke();
            return;
        }
        Message = null;
        Append(result.Text);
        if (result.StartsTransmit && State == SenderState.Idle)
        {
            Transmit();
        }
        if (result.EndsTransmit)
        {
            Finish();
        }
    }
}

/// A send-pane macro: text with {MYCALL}, {MYGRID}, {CALL}, and optional
/// {TX} at the start / {RX} at the end — the Mac's DigiMacro.
public sealed class DigiMacro
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Label { get; set; } = "";
    public string Text { get; set; } = "";

    public DigiMacro()
    {
    }

    public DigiMacro(string label, string text)
    {
        Label = label;
        Text = text;
    }

    public sealed record Expansion(string Text, bool StartsTransmit, bool EndsTransmit, string? Problem);

    public Expansion Expand(string myCall, string myGrid, string theirCall)
    {
        var body = Text.Trim(' ', '\t');
        var startsTransmit = false;
        var endsTransmit = false;
        if (body.StartsWith("{TX}", StringComparison.OrdinalIgnoreCase))
        {
            startsTransmit = true;
            body = body[4..];
        }
        if (body.EndsWith("{RX}", StringComparison.OrdinalIgnoreCase))
        {
            endsTransmit = true;
            body = body[..^4];
        }
        var stationSettings = Loc.S("digiSender.settingsStation");
        var values = new (string Placeholder, string Value, string Name)[]
        {
            ("{MYCALL}", myCall, Loc.F("digiSender.yourCallsign", stationSettings)),
            ("{MYGRID}", myGrid, Loc.F("digiSender.yourGridSquare", stationSettings)),
            ("{CALL}", theirCall, Loc.S("digiSender.theirCall")),
        };
        foreach (var (placeholder, value, name) in values)
        {
            if (!body.Contains(placeholder, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            var trimmed = value.Trim(' ', '\t');
            if (trimmed.Length == 0)
            {
                return new Expansion("", false, false, Loc.F("digiSender.isEmpty", name));
            }
            body = body.Replace(placeholder, trimmed, StringComparison.OrdinalIgnoreCase);
        }
        return new Expansion(body, startsTransmit, endsTransmit, null);
    }

    /// Each sent as its own transmission: a line break after keeps it apart
    /// from the other station's text.
    public static List<DigiMacro> Defaults() =>
    [
        new("CQ", "{TX}\nCQ CQ CQ de {MYCALL} {MYCALL} {MYCALL}\nCQ CQ CQ de {MYCALL} {MYCALL} {MYCALL} pse k\n{RX}"),
        new("Answer", "{TX}\n{CALL} {CALL} de {MYCALL} {MYCALL} {MYCALL} k\n{RX}"),
        new("Report", "{TX}\n{CALL} de {MYCALL} - tnx for the call, ur rst 599 599 - grid {MYGRID} - btu {CALL} de {MYCALL} k\n{RX}"),
        new("73", "{TX}\n{CALL} de {MYCALL} - tnx for the qso, 73 - {CALL} de {MYCALL} sk\n{RX}"),
        new("QRZ?", "{TX}\nQRZ? de {MYCALL} k\n{RX}"),
    ];
}
