using FTX1RemoteWindows.Controls;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;

namespace FTX1RemoteWindows.Services;

/// The MyKiwiSDR window's way back into MainWindow — the parts of the Mac's
/// HubService that LocalSDRModel uses.
public sealed class LocalSdrRigLink
{
    /// The rig as of the last poll (the Mac's hub.rigState).
    public required Func<RigSnapshot> Current { get; init; }
    /// Whether the rig link is up (the Mac's hub.connectionState).
    public required Func<bool> Connected { get; init; }
    /// Main's frequency (null = unchanged) and mode (null = unchanged) — the
    /// Mac's hub.send(.setFrequency/.setMode).
    public required Action<long?, RigMode?> Tune { get; init; }
    /// The Mac's HubService.setMainAudioOverride(.localSDR, …): mutes the
    /// rig's Main playback while the Kiwi is audible.
    public required Action<bool> SetAudioActive { get; init; }
    /// MAIN's receive filter as a Kiwi passband, null if unknown (Follow width).
    public required Func<KiwiPassband?> RigFilter { get; init; }
    /// The CW and RTTY/PSK windows' MyKiwiSDR source (the Mac's hub.localSDRSource).
    public required LocalSdrAudioSource Source { get; init; }
}

/// MyKiwiSDR: native audio and waterfall from the operator's own KiwiSDR over
/// its WebSockets (KiwiSdrClient / KiwiWaterfallClient), bypassing the Kiwi's
/// web page (which the WebSDR window embeds). A port of the Mac's
/// LocalSDRModel: decoder source, recording, Follow width and the playout
/// controller included.
///
/// Explicit connect only: the window opens disconnected, and Disconnect or
/// closing the window closes the sockets (the Kiwi frees the channel). The
/// waterfall is a second stream opened with the sound stream's timestamp once
/// that one is ready; a waterfall failure leaves the audio playing.
///
/// Rig link, the WebSDR window's rules on the open socket (KiwiRigLink holds
/// the pure part): Follow tunes the Kiwi to the rig's MAIN frequency/mode
/// (debounced 400 ms) with one "SET mod=… freq=…"; Tune rig sends the
/// window's own tunes to the rig (at most every 100 ms, the last always going
/// out). Mute on TX silences the playback while the rig transmits.
///
/// UI thread only: every await resumes on the window's dispatcher.
public sealed class LocalSdrModel
{
    public enum ConnectionState { Disconnected, Connecting, Connected, Failed }

    public enum WaterfallState { Off, Connecting, Running, Failed }

    /// The waterfall position asked for (start in x_bin units, zoom).
    public readonly record struct WaterfallView(int Start, int Zoom);

    /// The rig as the link sees it: MAIN's frequency and mode, and its filter
    /// as a Kiwi passband (null if unknown).
    private readonly record struct RigTarget(int Frequency, RigMode? Mode, KiwiPassband? Filter);

    public static readonly (int Min, int Max) FrequencyRange = (10_000, 30_000_000);
    private static readonly TimeSpan RigSendInterval = TimeSpan.FromMilliseconds(100);
    private static readonly TimeSpan RetuneInterval = TimeSpan.FromMilliseconds(50);
    private static readonly TimeSpan ViewInterval = TimeSpan.FromMilliseconds(60);
    private static readonly TimeSpan FollowDebounce = TimeSpan.FromMilliseconds(400);

    private readonly LocalSdrRigLink _rig;
    private readonly DispatcherQueue _dispatcher = DispatcherQueue.GetForCurrentThread();
    private readonly KiwiRigLink _link = new();

    private KiwiSdrClient? _client;
    private KiwiWaterfallClient? _waterfallClient;
    private KiwiAudioPlayer? _player;
    private long _timestamp;
    private string _connectedHost = "";
    private string _passwordInUse = "";
    private int _preferredZoom;
    private DateTime _lastRetune = DateTime.MinValue;
    private DispatcherQueueTimer? _retuneTimer;
    private DateTime _lastViewSend = DateTime.MinValue;
    private DispatcherQueueTimer? _viewTimer;
    private DateTime _lastRigSend = DateTime.MinValue;
    private DispatcherQueueTimer? _rigSendTimer;
    private DispatcherQueueTimer? _receiverTimer;
    private DispatcherQueueTimer? _followTimer;
    private DispatcherQueueTimer? _pendingExpiry;
    private int? _queuedRigFrequency;
    private RigMode? _queuedRigMode;
    private RigTarget? _lastPushed;
    private RigTarget? _rigTarget;
    private KiwiPlayoutAdjuster? _adjuster;
    private SdrAudioFileWriter? _recorder;
    private KiwiRecordingSplit? _recordingSplit;
    private DispatcherQueueTimer? _splitCheck;
    private double? _audioSampleRate;
    private bool _isTransmitting;
    private DateTime _lastMeterPublish = DateTime.MinValue;
    private int _session;

    public LocalSdrModel(LocalSdrRigLink rig)
    {
        _rig = rig;
        var saved = AppSettings.LocalSdr;
        FrequencyHz = saved.FrequencyHz is var f && f >= FrequencyRange.Min && f <= FrequencyRange.Max ? f : 14_074_000;
        Mode = KiwiSdrModeExtensions.FromRawValue(saved.Mode) ?? KiwiSdrMode.Usb;
        Passband = SavedPassband(Mode);
        _volume = Math.Clamp(saved.Volume, 0, 1);
        IsMuted = saved.Muted;
        Receiver = saved.Receiver.Clamped();
        _preferredZoom = saved.WaterfallZoom;
        _followRigWidth = saved.FollowRigWidth;
        FollowRig = saved.FollowRig;
        TuneRig = saved.TuneRig;
        MuteOnTransmit = saved.MuteOnTransmit;
    }

    // MARK: State

    /// Raised on any change the window should redraw its controls for.
    public event Action? Changed;
    /// ~10 a second while connected (dBm, overload).
    public event Action? MeterChanged;
    /// A new waterfall row is in <see cref="Bitmap"/> (~19 a second).
    public event Action? PictureChanged;

    public ConnectionState State { get; private set; } = ConnectionState.Disconnected;
    public KiwiSdrError? Error { get; private set; }
    public double SampleRate { get; private set; }
    public string ConnectedHostPort => _connectedHost;
    public int FrequencyHz { get; private set; }
    public KiwiSdrMode Mode { get; private set; }
    public KiwiPassband Passband { get; private set; }
    public bool IsMuted { get; private set; }
    public KiwiReceiverSettings Receiver { get; private set; }
    public string? RigLinkNote { get; private set; }

    public bool IsRecording { get; private set; }
    /// When the current file started (the Stop button's timer).
    public DateTime? SegmentStartedAt { get; private set; }
    /// "Saved ..." after a file is finished, for the status line.
    public string? RecordingNote { get; private set; }
    public double? MeterDbm { get; private set; }
    public bool MeterOverload { get; private set; }

    public WaterfallState Waterfall { get; private set; } = WaterfallState.Off;
    public KiwiSdrError? WaterfallError { get; private set; }
    public KiwiWaterfallGeometry Geometry { get; private set; } = new();
    /// The view asked for; null until the waterfall stream is set up.
    public WaterfallView? View { get; private set; }
    /// The picture and the position of its newest row (null without one).
    public KiwiWaterfallBitmap? Bitmap { get; private set; }
    public WaterfallView? PicturePosition { get; private set; }
    public (double Floor, double Ceiling)? RangeDbm =>
        _autoRange.IsSettled ? (_autoRange.FloorDbm, _autoRange.CeilingDbm) : null;

    private readonly KiwiWaterfallAutoRange _autoRange = new();
    private (int XBin, int Zoom)? _anchor;
    private int _cal = -13;
    private uint[] _colors = BuildColors(null, 0);

    public bool IsConnected => State is ConnectionState.Connecting or ConnectionState.Connected;

    public static string SavedHostPort => AppSettings.LocalSdr.Host.Trim();

    public static bool IsValidHost(string hostPort) => KiwiProtocol.SoundUrl(hostPort.Trim(), 0) is not null;

    private double _volume;
    public double Volume
    {
        get => _volume;
        set
        {
            _volume = Math.Clamp(value, 0, 1);
            AppSettings.LocalSdr.Volume = _volume;
            AppSettings.SaveLocalSdr();
            ApplyVolume();
        }
    }

    private bool _followRig;
    /// Rig → Kiwi.
    public bool FollowRig
    {
        get => _followRig;
        set
        {
            if (_followRig == value)
            {
                return;
            }
            _followRig = value;
            AppSettings.LocalSdr.FollowRig = value;
            AppSettings.SaveLocalSdr();
            if (value && _rigTarget is { } target)
            {
                Follow(target);
            }
            else
            {
                RigLinkNote = null;
                if (!value && FollowRigWidth)
                {
                    RestoreSavedPassband();
                }
            }
            Changed?.Invoke();
        }
    }

    private bool _followRigWidth;
    /// With Follow on, the passband follows MAIN's filter. Changed through
    /// <see cref="SetFollowRigWidth"/> (the toggle) or by a manual drag.
    public bool FollowRigWidth => _followRigWidth;

    private bool IsFollowingRigWidth => FollowRig && FollowRigWidth;

    private bool _tuneRig;
    /// Kiwi → rig.
    public bool TuneRig
    {
        get => _tuneRig;
        set
        {
            if (_tuneRig == value)
            {
                return;
            }
            _tuneRig = value;
            AppSettings.LocalSdr.TuneRig = value;
            AppSettings.SaveLocalSdr();
            if (!value)
            {
                CancelRigSend();
                _link.Reset();
                RigLinkNote = null;
            }
            Changed?.Invoke();
        }
    }

    private bool _muteOnTransmit;
    /// Silences the playback while the rig transmits; the Mute button and the
    /// rig's own audio are left alone.
    public bool MuteOnTransmit
    {
        get => _muteOnTransmit;
        set
        {
            _muteOnTransmit = value;
            AppSettings.LocalSdr.MuteOnTransmit = value;
            AppSettings.SaveLocalSdr();
            ApplyVolume();
            Changed?.Invoke();
        }
    }

    // MARK: Connection

    private static double Now => Environment.TickCount64 / 1000.0;

    /// Reads the password (Credential Manager) off the UI thread, then
    /// connects to the saved address.
    public async void Connect()
    {
        if (IsLoadingPassword)
        {
            return;
        }
        CloseSession();
        var hostPort = SavedHostPort;
        if (!IsValidHost(hostPort))
        {
            Fail(new KiwiSdrError(KiwiErrorKind.InvalidHost));
            return;
        }
        State = ConnectionState.Disconnected;
        Error = null;
        IsLoadingPassword = true;
        Changed?.Invoke();
        var session = ++_session;
        var password = await Task.Run(LocalSdrPassword.Read);
        IsLoadingPassword = false;
        if (session != _session)
        {
            return;
        }
        StartSession(hostPort, password);
    }

    public bool IsLoadingPassword { get; private set; }

    private void StartSession(string hostPort, string password)
    {
        // Start where the rig is, so the first tune is already right.
        if (FollowRig && _rig.Connected())
        {
            var target = ReadRigTarget();
            _rigTarget = target;
            if (_link.Follow(target.Frequency, target.Mode, FrequencyHz, Mode, MaxFrequencyHz, Now)
                is KiwiRigLink.FollowDecision.Tune tune)
            {
                ApplyTuning(tune.FrequencyHz, tune.Mode);
            }
            ApplyRigWidth(target);
        }
        _isTransmitting = _rig.Current().Ptt;
        _timestamp = KiwiProtocol.TimestampNow();
        _connectedHost = hostPort;
        _passwordInUse = password;
        var client = new KiwiSdrClient(hostPort, password, CurrentTuning, Receiver, _timestamp);
        _client = client;
        State = ConnectionState.Connecting;
        Changed?.Invoke();
        _ = PumpAsync(client, _session);
        client.Start();
    }

    public void Disconnect()
    {
        CloseSession();
        State = ConnectionState.Disconnected;
        Error = null;
        Changed?.Invoke();
    }

    private void Fail(KiwiSdrError error)
    {
        State = ConnectionState.Failed;
        Error = error;
        Changed?.Invoke();
    }

    private void CloseSession()
    {
        _session++;
        IsLoadingPassword = false;
        EndAudioSession();
        StopRigLink();
        _client?.Stop();
        _client = null;
        CancelTimer(ref _retuneTimer);
        CancelTimer(ref _receiverTimer);
        StopWaterfall();
        StopPlayback();
        MeterDbm = null;
        MeterOverload = false;
        UpdateMainAudio();
    }

    private async Task PumpAsync(KiwiSdrClient client, int session)
    {
        try
        {
            await foreach (var kiwiEvent in client.Events.ReadAllAsync())
            {
                if (_client != client || session != _session)
                {
                    return;
                }
                Handle(kiwiEvent);
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"kiwisdr: event loop failed: {ex.Message}");
        }
    }

    private void Handle(KiwiSdrEvent kiwiEvent)
    {
        switch (kiwiEvent)
        {
            case KiwiSdrEvent.Ready ready:
                AppLog.Write($"kiwisdr: connected, audio at {ready.SampleRate} Hz");
                SampleRate = ready.SampleRate;
                _audioSampleRate = ready.SampleRate;
                State = ConnectionState.Connected;
                _rig.Source.SessionStarted(ready.SampleRate, Mode);
                StartPlayback(ready.SampleRate);
                StartWaterfall();
                SubscribeToRig();
                UpdateMainAudio();
                Changed?.Invoke();
                break;
            case KiwiSdrEvent.Audio audio:
                // Only the player's copy is adjusted: the recording and the
                // decoders get every sample as it came.
                var played = _adjuster is { } adjuster
                    ? adjuster.Process(audio.Chunk.Samples, _player?.BufferedSeconds, Now)
                    : audio.Chunk.Samples;
                if (played.Length > 0)
                {
                    _player?.Push(played);
                }
                // Both before the volume/mute: a muted Kiwi still decodes and records.
                if (_recorder is { } recorder && _audioSampleRate is { } rate)
                {
                    recorder.Append(LittleEndianPcm(audio.Chunk.Samples), (int)rate);
                }
                if (_rig.Source.IsWanted)
                {
                    _rig.Source.Deliver(audio.Chunk.Samples);
                }
                if (DateTime.UtcNow - _lastMeterPublish >= TimeSpan.FromMilliseconds(100))
                {
                    _lastMeterPublish = DateTime.UtcNow;
                    MeterDbm = audio.Chunk.SmeterDbm;
                    MeterOverload = audio.Chunk.Flags.HasFlag(KiwiSoundFlags.AdcOverflow);
                    MeterChanged?.Invoke();
                }
                break;
            case KiwiSdrEvent.Closed closed:
                _client = null;
                CancelTimer(ref _retuneTimer);
                CancelTimer(ref _receiverTimer);
                EndAudioSession();
                StopRigLink();
                StopWaterfall();
                StopPlayback();
                MeterDbm = null;
                State = closed.Error is null ? ConnectionState.Disconnected : ConnectionState.Failed;
                Error = closed.Error;
                UpdateMainAudio();
                Changed?.Invoke();
                MeterChanged?.Invoke();
                break;
        }
    }

    private void StartPlayback(double sampleRate)
    {
        StopPlayback();
        var player = new KiwiAudioPlayer(sampleRate, 0);
        var error = player.Start(AudioPlayback.ResolveOutputId(AppSettings.AudioOutputDeviceId));
        if (error is not null)
        {
            AppLog.Write($"kiwisdr: no audio output: {error}");
        }
        _player = player;
        _adjuster = new KiwiPlayoutAdjuster(sampleRate, KiwiAudioPlayer.TargetSeconds);
        ApplyVolume();
    }

    private void StopPlayback()
    {
        _adjuster = null;
        _player?.Dispose();
        _player = null;
    }

    // MARK: Tuning and audio

    private KiwiTuning CurrentTuning =>
        new(FrequencyHz, Mode, Passband.Low, Passband.High, Passband.CwShiftHz);

    /// The Kiwi's reported bandwidth (30 MHz until the waterfall says).
    public int MaxFrequencyHz => (int)Geometry.BandwidthHz;

    /// A frequency the window tuned to (entry, steppers). Clamped to the
    /// Kiwi's range (from 10 kHz).
    public void SetFrequency(int hz)
    {
        var clamped = Math.Min(Math.Max(hz, FrequencyRange.Min), MaxFrequencyHz);
        if (clamped == FrequencyHz)
        {
            return;
        }
        ApplyTuning(clamped, null);
        WindowTuned();
    }

    /// The window's mode picker.
    public void SelectMode(KiwiSdrMode mode)
    {
        if (mode == Mode)
        {
            return;
        }
        ApplyTuning(null, mode);
        WindowTuned();
    }

    public void Step(int deltaHz) => SetFrequency(FrequencyHz + deltaHz);

    /// A click on the waterfall: the dial goes there, snapped to the mode's
    /// step (the dial is the carrier, or the signal in CW).
    public void TuneToWaterfallHz(double hz)
    {
        double step = Mode.WaterfallStepHz();
        SetFrequency((int)(Math.Round(hz / step, MidpointRounding.AwayFromZero) * step));
    }

    /// One scroll-wheel step up (+1) or down (−1), landing on the step grid:
    /// from an off-grid frequency the first step snaps to it.
    public void ScrollStep(int direction)
    {
        if (direction == 0)
        {
            return;
        }
        var step = Mode.WaterfallStepHz();
        var ratio = (double)FrequencyHz / step;
        var baseHz = (int)(direction > 0 ? Math.Floor(ratio) : Math.Ceiling(ratio)) * step;
        SetFrequency(baseHz + direction * step);
    }

    /// Changes the Kiwi's tuning (null = keep) and sends it on the open
    /// socket, panning the waterfall only if the passband nears an edge.
    /// Doesn't touch the rig: WindowTuned does that for the window's own
    /// tunes, and Follow's must not echo back.
    private void ApplyTuning(int? frequencyHz, KiwiSdrMode? mode)
    {
        var changed = false;
        if (frequencyHz is { } hz && hz != FrequencyHz)
        {
            FrequencyHz = hz;
            AppSettings.LocalSdr.FrequencyHz = hz;
            changed = true;
        }
        if (mode is { } newMode && newMode != Mode)
        {
            Mode = newMode;
            Passband = RigBand(_rigTarget, newMode) ?? SavedPassband(newMode);
            AppSettings.LocalSdr.Mode = newMode.RawValue();
            changed = true;
        }
        if (!changed)
        {
            return;
        }
        AppSettings.SaveLocalSdr();
        Retune();
        KeepPassbandVisible();
        _rig.Source.ModeChanged(Mode);
        CheckRecordingSplit();
        Changed?.Invoke();
    }

    /// Retunes the open socket ("SET mod=… freq=…"), no reconnect. At most
    /// every 50 ms (a drag asks for one per mouse event), the last one always
    /// going out.
    private void Retune()
    {
        if (_client is null)
        {
            return;
        }
        var elapsed = DateTime.UtcNow - _lastRetune;
        if (elapsed >= RetuneInterval)
        {
            CancelTimer(ref _retuneTimer);
            SendRetune();
        }
        else if (_retuneTimer is null)
        {
            _retuneTimer = OneShot(RetuneInterval - elapsed, () =>
            {
                _retuneTimer = null;
                SendRetune();
            });
        }
    }

    private void SendRetune()
    {
        if (_client is null)
        {
            return;
        }
        _lastRetune = DateTime.UtcNow;
        _client.Tune(CurrentTuning);
    }

    // MARK: Receiver controls

    /// A change from the Receiver section: saved at once, and sent at most
    /// every 100 ms so a dragged slider doesn't flood the socket.
    public void UpdateReceiver(Func<KiwiReceiverSettings, KiwiReceiverSettings> change)
    {
        var updated = change(Receiver).Clamped();
        if (updated == Receiver)
        {
            return;
        }
        Receiver = updated;
        AppSettings.LocalSdr.Receiver = updated;
        AppSettings.SaveLocalSdr();
        Changed?.Invoke();
        if (_client is null || _receiverTimer is not null)
        {
            return;
        }
        _receiverTimer = OneShot(TimeSpan.FromMilliseconds(100), () =>
        {
            _receiverTimer = null;
            _client?.SetReceiver(Receiver);
        });
    }

    // MARK: Passband

    public bool IsPassbandDefault => Passband == KiwiPassband.DefaultFor(Mode);

    /// A drag of one edge on the waterfall; hz is where the mouse is.
    public void DragPassbandEdge(KiwiPassband.Edge edge, double waterfallHz)
    {
        StopFollowingWidth();
        SetPassband(Passband.Dragging(edge, waterfallHz - FrequencyHz, Mode));
    }

    public void ResetPassband()
    {
        StopFollowingWidth();
        SetPassband(KiwiPassband.DefaultFor(Mode));
        KeepPassbandVisible();
    }

    private void SetPassband(KiwiPassband passband)
    {
        if (passband == Passband)
        {
            return;
        }
        Passband = passband;
        AppSettings.LocalSdr.Passbands[Mode.RawValue()] = [passband.Low, passband.High];
        AppSettings.SaveLocalSdr();
        Retune();
        Changed?.Invoke();
    }

    private static KiwiPassband SavedPassband(KiwiSdrMode mode)
    {
        if (AppSettings.LocalSdr.Passbands.TryGetValue(mode.RawValue(), out var saved) && saved.Length == 2)
        {
            var band = new KiwiPassband(saved[0], saved[1]);
            if (band.IsValid(mode))
            {
                return band;
            }
        }
        return KiwiPassband.DefaultFor(mode);
    }

    public void ToggleMuted()
    {
        IsMuted = !IsMuted;
        AppSettings.LocalSdr.Muted = IsMuted;
        AppSettings.SaveLocalSdr();
        ApplyVolume();
        Changed?.Invoke();
    }

    /// Mute is volume 0, so the player keeps its buffer and unmuting is
    /// immediate. Mute on TX the same way, without touching IsMuted.
    private void ApplyVolume()
    {
        var silent = IsMuted || (MuteOnTransmit && _isTransmitting);
        if (_player is not null)
        {
            _player.Volume = silent ? 0 : (float)_volume;
        }
        UpdateMainAudio();
    }

    private bool _mainOverrideActive;

    /// While the Kiwi is audible (connected, not muted here), the rig's Main
    /// playback is muted, and given back once it isn't.
    private void UpdateMainAudio()
    {
        var audible = State == ConnectionState.Connected && !IsMuted;
        if (audible == _mainOverrideActive)
        {
            return;
        }
        _mainOverrideActive = audible;
        _rig.SetAudioActive(audible);
    }

    // MARK: Follow width

    /// The Follow width toggle.
    public void SetFollowRigWidth(bool on)
    {
        if (on == _followRigWidth)
        {
            return;
        }
        _followRigWidth = on;
        AppSettings.LocalSdr.FollowRigWidth = on;
        AppSettings.SaveLocalSdr();
        if (on && _rigTarget is { } target)
        {
            ApplyRigWidth(target);
        }
        else if (!on)
        {
            RestoreSavedPassband();
        }
        Changed?.Invoke();
    }

    /// A manual drag or Reset takes the passband back from the rig.
    private void StopFollowingWidth()
    {
        if (_followRigWidth)
        {
            _followRigWidth = false;
            AppSettings.LocalSdr.FollowRigWidth = false;
            AppSettings.SaveLocalSdr();
        }
    }

    /// MAIN's filter as a passband, if it's being followed and applies to "mode".
    private KiwiPassband? RigBand(RigTarget? target, KiwiSdrMode mode) =>
        IsFollowingRigWidth && target is { } t && KiwiSdrModeExtensions.FromRigMode(t.Mode) == mode ? t.Filter : null;

    private void ApplyRigWidth(RigTarget target)
    {
        if (RigBand(target, Mode) is not { } band || band == Passband)
        {
            return;
        }
        AppLog.Write($"kiwisdr: rig link: passband {band.Low}…{band.High} from the rig");
        Passband = band;
        Retune();
        KeepPassbandVisible();
        Changed?.Invoke();
    }

    /// Following stopped: the mode's own passband again.
    private void RestoreSavedPassband()
    {
        var saved = SavedPassband(Mode);
        if (saved == Passband)
        {
            return;
        }
        Passband = saved;
        Retune();
        KeepPassbandVisible();
    }

    // MARK: Recording

    /// Record while connected; Stop saves the file.
    public void ToggleRecording()
    {
        if (IsRecording)
        {
            StopRecording();
        }
        else if (State == ConnectionState.Connected)
        {
            IsRecording = true;
            RecordingNote = null;
            BeginFile();
        }
        Changed?.Invoke();
    }

    private KiwiRecordingSplit.Tuning SplitTuning => new(FrequencyHz, Mode);

    private void BeginFile()
    {
        _recordingSplit = new KiwiRecordingSplit(SplitTuning);
        var label = $"{Recordings.Label(FrequencyHz, Mode.Label())} MyKiwiSDR";
        var date = DateTime.Now;
        var path = Recordings.NewRecordingPath(label, date);
        for (var n = 2; File.Exists(path); n++)
        {
            path = Recordings.NewRecordingPath($"{label} {n}", date);
        }
        _recorder = new SdrAudioFileWriter(path, "kiwisdr-recording");
        SegmentStartedAt = date;
        AppLog.Write($"kiwisdr: recording to {Path.GetFileName(path)}");
    }

    /// Closes the current file (everything handed over is already written).
    private void FinishFile()
    {
        if (_recorder is not { } recorder)
        {
            return;
        }
        _recorder = null;
        if (recorder.Finish() is { } path)
        {
            AppLog.Write($"kiwisdr: saved {Path.GetFileName(path)}");
            RecordingNote = Loc.F("localSdr.recording.saved", Path.GetFileNameWithoutExtension(path));
        }
    }

    private void StopRecording()
    {
        if (!IsRecording)
        {
            return;
        }
        FinishFile();
        IsRecording = false;
        SegmentStartedAt = null;
        _recordingSplit = null;
        CancelTimer(ref _splitCheck);
    }

    /// After every tune, and again when a pending split has had time to
    /// settle: starts a new file once a retune has held.
    private void CheckRecordingSplit()
    {
        if (!IsRecording || _recordingSplit is not { } split)
        {
            return;
        }
        CancelTimer(ref _splitCheck);
        if (split.Update(SplitTuning, Now) is { } tuning)
        {
            AppLog.Write($"kiwisdr: recording: retuned to {tuning.FrequencyHz} Hz {tuning.Mode.Label()}, new file");
            FinishFile();
            BeginFile();
            return;
        }
        if (split.NextCheck is { } next)
        {
            _splitCheck = OneShot(TimeSpan.FromSeconds(Math.Max(0, next - Now) + 0.02), () =>
            {
                _splitCheck = null;
                CheckRecordingSplit();
                Changed?.Invoke();
            });
        }
    }

    /// The Kiwi's audio stopped (Disconnect, a dropped connection, the window
    /// closing): the recording is saved and the decoders told.
    private void EndAudioSession()
    {
        StopRecording();
        _audioSampleRate = null;
        _rig.Source.SessionEnded();
    }

    private static byte[] LittleEndianPcm(short[] samples)
    {
        var bytes = new byte[samples.Length * 2];
        Buffer.BlockCopy(samples, 0, bytes, 0, bytes.Length);
        return BitConverter.IsLittleEndian ? bytes : bytes.Chunk(2).SelectMany(p => p.Reverse()).ToArray();
    }

    // MARK: Rig link

    /// MainWindow pushes the rig state after every poll (the Mac subscribes to
    /// hub.$rigState): the PTT at once, the frequency/mode debounced 400 ms.
    public void OnRigState()
    {
        if (!IsConnected)
        {
            return;
        }
        var snapshot = _rig.Current();
        if (_isTransmitting != snapshot.Ptt)
        {
            _isTransmitting = snapshot.Ptt;
            ApplyVolume();
        }
        var pushed = ReadRigTarget();
        if (_lastPushed == pushed)
        {
            return;
        }
        _lastPushed = pushed;
        _followTimer?.Stop();
        _followTimer = OneShot(FollowDebounce, () =>
        {
            _followTimer = null;
            _rigTarget = pushed;
            Follow(pushed);
        });
    }

    private void SubscribeToRig()
    {
        var snapshot = _rig.Current();
        _isTransmitting = snapshot.Ptt;
        _lastPushed = ReadRigTarget();
        _rigTarget = _lastPushed;
        ApplyVolume();
    }

    private void StopRigLink()
    {
        if (IsFollowingRigWidth)
        {
            RestoreSavedPassband();
        }
        _followTimer?.Stop();
        _followTimer = null;
        _lastPushed = null;
        _rigTarget = null;
        _isTransmitting = false;
        CancelRigSend();
        CancelTimer(ref _pendingExpiry);
        _link.Reset();
        RigLinkNote = null;
        ApplyVolume();
    }

    private RigTarget ReadRigTarget()
    {
        var snapshot = _rig.Current();
        return new RigTarget((int)snapshot.FrequencyHz, snapshot.Mode, _rig.RigFilter());
    }

    private void Follow(RigTarget target)
    {
        if (!FollowRig || !IsConnected)
        {
            return;
        }
        switch (_link.Follow(target.Frequency, target.Mode, FrequencyHz, Mode, MaxFrequencyHz, Now))
        {
            case KiwiRigLink.FollowDecision.Tune tune:
                AppLog.Write($"kiwisdr: rig link: follow → Kiwi {tune.FrequencyHz} Hz {tune.Mode?.Label() ?? "-"}");
                RigLinkNote = null;
                ApplyTuning(tune.FrequencyHz, tune.Mode);
                ApplyRigWidth(target);
                break;
            case KiwiRigLink.FollowDecision.AlreadyThere:
                if (RigLinkNote is not null)
                {
                    RigLinkNote = null;
                    Changed?.Invoke();
                }
                ApplyRigWidth(target);
                break;
            case KiwiRigLink.FollowDecision.OutOfRange range:
                RigLinkNote = Loc.F("localSdr.rigLink.outOfRange",
                                    (range.FrequencyHz / 1e6).ToString("F3", System.Globalization.CultureInfo.InvariantCulture),
                                    (MaxFrequencyHz / 1e6).ToString("F0", System.Globalization.CultureInfo.InvariantCulture));
                Changed?.Invoke();
                break;
        }
    }

    private KiwiRigSnapshot RigSnapshotNow()
    {
        var rig = _rig.Current();
        return new KiwiRigSnapshot(_rig.Connected(), rig.Ptt, rig.InMemoryMode, (int)rig.FrequencyHz, rig.Mode);
    }

    /// A tune made in the window: to the rig too, if Tune rig is on.
    private void WindowTuned()
    {
        if (!TuneRig || !IsConnected)
        {
            return;
        }
        switch (_link.WindowTuned(FrequencyHz, Mode, RigSnapshotNow(), Now))
        {
            case KiwiRigLink.TuneRigDecision.Send send:
                if (send.FrequencyHz is { } hz) { _queuedRigFrequency = hz; }
                if (send.Mode is { } mode) { _queuedRigMode = mode; }
                ScheduleRigSend();
                SchedulePendingExpiry();
                break;
            case KiwiRigLink.TuneRigDecision.Refused refused:
                NoteRefusal(refused.Reason);
                break;
        }
    }

    private void NoteRefusal(KiwiRigLink.Refusal refusal)
    {
        var reason = Loc.S(refusal switch
        {
            KiwiRigLink.Refusal.RigDisconnected => "localSdr.rigLink.refused.disconnected",
            KiwiRigLink.Refusal.NoRigFrequency => "localSdr.rigLink.refused.noFrequency",
            KiwiRigLink.Refusal.Transmitting => "localSdr.rigLink.refused.transmitting",
            _ => "localSdr.rigLink.refused.memory",
        });
        RigLinkNote = Loc.F("localSdr.rigLink.refused", reason, DateTime.Now.ToLongTimeString());
        Changed?.Invoke();
    }

    /// At most one rig tune every 100 ms, the last always going out.
    private void ScheduleRigSend()
    {
        var elapsed = DateTime.UtcNow - _lastRigSend;
        if (elapsed >= RigSendInterval)
        {
            CancelTimer(ref _rigSendTimer);
            SendQueuedRigTune();
        }
        else if (_rigSendTimer is null)
        {
            _rigSendTimer = OneShot(RigSendInterval - elapsed, () =>
            {
                _rigSendTimer = null;
                SendQueuedRigTune();
            });
        }
    }

    private void SendQueuedRigTune()
    {
        var hz = _queuedRigFrequency;
        var mode = _queuedRigMode;
        _queuedRigFrequency = null;
        _queuedRigMode = null;
        if (hz is null && mode is null)
        {
            return;
        }
        // The rig may have started transmitting (etc.) since the tune.
        if (KiwiRigLink.RefusalFor(RigSnapshotNow()) is { } refusal)
        {
            _link.Reset();
            NoteRefusal(refusal);
            return;
        }
        _lastRigSend = DateTime.UtcNow;
        AppLog.Write($"kiwisdr: rig link: Kiwi → rig {hz ?? 0} Hz {mode?.DisplayName() ?? "-"}");
        if (RigLinkNote is not null)
        {
            RigLinkNote = null;
            Changed?.Invoke();
        }
        _rig.Tune(hz, mode);
    }

    private void CancelRigSend()
    {
        CancelTimer(ref _rigSendTimer);
        _queuedRigFrequency = null;
        _queuedRigMode = null;
    }

    /// If the rig never shows the window's tune (rejected, link lost), follow
    /// its actual state again once the grace period is over.
    private void SchedulePendingExpiry()
    {
        CancelTimer(ref _pendingExpiry);
        _pendingExpiry = OneShot(TimeSpan.FromSeconds(KiwiRigLink.RigTuneGrace + 0.1), () =>
        {
            _pendingExpiry = null;
            if (_link.ExpirePending(Now) && _rigTarget is { } target)
            {
                Follow(target);
            }
        });
    }

    // MARK: Waterfall

    /// The demodulated passband in absolute Hz.
    public (double Low, double High) PassbandHz
    {
        get
        {
            var tuning = CurrentTuning;
            double carrier = tuning.CarrierHz;
            return (carrier + tuning.LowCut, carrier + tuning.HighCut);
        }
    }

    private double PassbandCentreHz => (PassbandHz.Low + PassbandHz.High) / 2;

    public bool CanZoomIn => (View?.Zoom ?? int.MaxValue) < Geometry.ZoomMax;
    public bool CanZoomOut => (View?.Zoom ?? 0) > 0;

    private void StartWaterfall()
    {
        StopWaterfall();
        var client = new KiwiWaterfallClient(_connectedHost, _passwordInUse, _timestamp);
        _waterfallClient = client;
        Waterfall = WaterfallState.Connecting;
        ResetPicture();
        _ = PumpWaterfallAsync(client, _session);
        client.Start();
    }

    private void StopWaterfall()
    {
        _waterfallClient?.Stop();
        _waterfallClient = null;
        CancelTimer(ref _viewTimer);
        View = null;
        Waterfall = WaterfallState.Off;
        ResetPicture();
    }

    private async Task PumpWaterfallAsync(KiwiWaterfallClient client, int session)
    {
        try
        {
            await foreach (var kiwiEvent in client.Events.ReadAllAsync())
            {
                if (_waterfallClient != client || session != _session)
                {
                    return;
                }
                switch (kiwiEvent)
                {
                    case KiwiWaterfallEvent.Ready ready:
                        AppLog.Write("kiwisdr: waterfall running");
                        ConfigurePicture(ready.Geometry, ready.Cal);
                        Waterfall = WaterfallState.Running;
                        var zoom = ready.Geometry.ClampZoom(_preferredZoom);
                        RequestView(new WaterfallView(ready.Geometry.Start(PassbandCentreHz, zoom), zoom));
                        Changed?.Invoke();
                        break;
                    case KiwiWaterfallEvent.Row row:
                        AddRow(row.Frame);
                        break;
                    case KiwiWaterfallEvent.Closed closed:
                        // The audio carries on: only the waterfall stopped.
                        _waterfallClient = null;
                        View = null;
                        CancelTimer(ref _viewTimer);
                        Waterfall = closed.Error is null ? WaterfallState.Off : WaterfallState.Failed;
                        WaterfallError = closed.Error;
                        Changed?.Invoke();
                        break;
                }
            }
        }
        catch (Exception ex)
        {
            AppLog.Write($"kiwisdr: waterfall loop failed: {ex.Message}");
        }
    }

    public const int HistoryRows = 300;

    private void ConfigurePicture(KiwiWaterfallGeometry geometry, int cal)
    {
        Geometry = geometry;
        _cal = cal;
        Bitmap = new KiwiWaterfallBitmap(geometry.FftSize, HistoryRows, BlankColor);
        _anchor = null;
        _autoRange.Reset();
        PicturePosition = null;
    }

    private void ResetPicture()
    {
        Bitmap = null;
        _anchor = null;
        _autoRange.Reset();
        PicturePosition = null;
        PictureChanged?.Invoke();
    }

    private static uint BlankColor => WaterfallPalette.Packed(0);

    private void AddRow(KiwiWaterfallFrame row)
    {
        if (Bitmap is not { } bitmap || row.Bins.Length != Geometry.FftSize || row.Zoom > Geometry.ZoomMax)
        {
            return;
        }
        var position = (row.XBin, row.Zoom);
        switch (KiwiWaterfallPlacement.Place(position, _anchor, Geometry))
        {
            case KiwiWaterfallPlacement.Shift shift:
                bitmap.Shift(shift.Bins);
                break;
            case KiwiWaterfallPlacement.Rezoom:
                if (_anchor is { } anchor)
                {
                    bitmap.Remap(KiwiWaterfallPlacement.ColumnMap(anchor, position, Geometry));
                }
                break;
        }
        _anchor = position;
        if (_autoRange.Add(row.Bins, _cal))
        {
            _colors = BuildColors(_autoRange, _cal);
        }
        bitmap.Append(row.Bins, _colors);
        PicturePosition = new WaterfallView(row.XBin, row.Zoom);
        PictureChanged?.Invoke();
    }

    private static uint[] BuildColors(KiwiWaterfallAutoRange? range, int cal)
    {
        var colors = new uint[256];
        var steps = range?.PaletteSteps(cal);
        for (var value = 0; value < 256; value++)
        {
            colors[value] = WaterfallPalette.Packed(steps?[value] ?? 0);
        }
        return colors;
    }

    /// Pans only when the passband is near or past an edge of the span.
    private void KeepPassbandVisible()
    {
        if (View is not { } view)
        {
            return;
        }
        var band = PassbandHz;
        if (Geometry.StartKeeping(band.Low, band.High, view.Start, view.Zoom) is { } start)
        {
            RequestView(new WaterfallView(start, view.Zoom));
        }
    }

    /// Zooms one step, centred on the passband (the Kiwi page's rule), or on
    /// the middle of the span when the passband is out of view.
    public void Zoom(int delta)
    {
        if (View is not { } view)
        {
            return;
        }
        var zoom = Geometry.ClampZoom(view.Zoom + delta);
        if (zoom == view.Zoom)
        {
            return;
        }
        var band = PassbandHz;
        var visible = Geometry.StartKeeping(band.Low, band.High, view.Start, view.Zoom, 0) is null;
        var centre = visible
            ? PassbandCentreHz
            : Geometry.HzAtColumn(Geometry.FftSize / 2.0, view.Start, view.Zoom);
        _preferredZoom = zoom;
        AppSettings.LocalSdr.WaterfallZoom = zoom;
        AppSettings.SaveLocalSdr();
        RequestView(new WaterfallView(Geometry.Start(centre, zoom), zoom));
    }

    /// A drag: the new left edge (clamped to the band and a whole bin).
    public void Pan(int start)
    {
        if (View is not { } view)
        {
            return;
        }
        var clamped = Geometry.ClampStart(start, view.Zoom);
        if (clamped != view.Start)
        {
            RequestView(new WaterfallView(clamped, view.Zoom));
        }
    }

    /// Publishes the view at once and sends it at most every 60 ms (a drag
    /// asks for one per mouse event), the last one always going out.
    private void RequestView(WaterfallView view)
    {
        View = view;
        Changed?.Invoke();
        if (_waterfallClient is null)
        {
            return;
        }
        var elapsed = DateTime.UtcNow - _lastViewSend;
        if (elapsed >= ViewInterval)
        {
            CancelTimer(ref _viewTimer);
            SendView();
        }
        else if (_viewTimer is null)
        {
            _viewTimer = OneShot(ViewInterval - elapsed, () =>
            {
                _viewTimer = null;
                SendView();
            });
        }
    }

    private void SendView()
    {
        if (_waterfallClient is { } client && View is { } view)
        {
            _lastViewSend = DateTime.UtcNow;
            client.SetView(view.Zoom, view.Start);
        }
    }

    // MARK: Timers

    private DispatcherQueueTimer OneShot(TimeSpan delay, Action action)
    {
        var timer = _dispatcher.CreateTimer();
        timer.Interval = delay < TimeSpan.FromMilliseconds(1) ? TimeSpan.FromMilliseconds(1) : delay;
        timer.IsRepeating = false;
        timer.Tick += (t, _) =>
        {
            t.Stop();
            action();
        };
        timer.Start();
        return timer;
    }

    private static void CancelTimer(ref DispatcherQueueTimer? timer)
    {
        timer?.Stop();
        timer = null;
    }
}
