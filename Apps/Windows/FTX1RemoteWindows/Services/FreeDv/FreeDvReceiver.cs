using System.Collections.Concurrent;
using System.Diagnostics;
using FTX1RemoteWindows.Services.Digi;
using FTX1RemoteWindows.Models;
using NAudio.Wave;

namespace FTX1RemoteWindows.Services.FreeDv;

/// Where the decoded speech plays (FreeDvSpeechPlayer). UI thread only.
public interface IFreeDvSpeechOutput : IDisposable
{
    /// 0…1.
    float Volume { set; }
    /// Why nothing is playing, null when fine.
    string? Problem { get; }
    /// Mono speech at 16 kHz, ±1.
    void Push(float[] speech);
}

/// Sync, SNR and tuning offset: the window's status line samples these on its
/// own timer, so ~20 updates a second don't rebuild anything else.
public readonly record struct FreeDvStatus(bool Sync, float SnrDb, float FrequencyOffsetHz);

/// Tools → FreeDV's receiver — the Mac's FreeDVReceiver: FreeDV RADE V1 from
/// the rig's MAIN or SUB audio, the WebSDR window's or the MyKiwiSDR window's,
/// decoded to speech and played on this PC; callsigns from each end-of-over
/// go to <see cref="Heard"/>.
///
/// Fed like DigiReceiver: MainWindow hands it every receive chunk; it keeps
/// only the selected channel, and only between <see cref="Start"/> and
/// <see cref="Stop"/> (the window's open/close). Decoding runs on this
/// object's own worker thread; everything else is on the UI thread, where the
/// worker's results are posted in order. Owned by MainWindow, so the heard
/// list survives closing and reopening the window.
public sealed class FreeDvReceiver : IDisposable
{
    /// The heard list, status notes, settings or file state changed.
    public event Action? Changed;
    /// <see cref="IsReceivingVoice"/> changed (MainWindow mutes that
    /// receiver's own playback).
    public event Action? VoiceChanged;
    /// <see cref="Channel"/> changed (the SDR sources follow it).
    public event Action? ChannelChanged;
    /// A file couldn't be decoded.
    public event Action<string>? Error;
    /// Each callsign heard live (not from a file): FreeDV Reporter's spots.
    public event Action<FreeDvHeardStation>? HeardLive;

    /// How long <see cref="IsReceivingVoice"/> stays on after sync drops, so
    /// a brief fade doesn't flip the rig's audio back on between words.
    public const double VoiceHoldSeconds = 1.5;
    private const int MaxHeard = 200;
    private static readonly TimeSpan SubAudioTimeout = TimeSpan.FromSeconds(2);
    private const int FileChunkFrames = 8192;

    private readonly Action<Action> _post;
    private readonly FreeDvData _settings;
    private readonly Action _save;
    private readonly Func<IFreeDvSpeechOutput?> _openOutput;
    private readonly Func<CwAudioChannel, long?> _frequencyOfSource;
    private readonly Func<string, string> _recordingPath;
    private readonly Func<string, WaveStream> _openFile;
    private readonly Action<string> _log;

    private readonly BlockingCollection<Action> _queue = new(boundedCapacity: 256);
    private readonly Thread _worker;
    // Worker thread only.
    private RadeDecoder? _decoder;
    private readonly DigiResampler _resampler = new(RadeDecoder.ModemSampleRate);
    private float? _lastSyncSnr;

    // Read by the audio thread and the worker.
    private volatile bool _running;
    private volatile bool _pausedForTransmit;
    private volatile CwAudioChannel _channel;
    /// Bumped on every reset, so output already on its way from before it is
    /// dropped.
    private volatile int _generation;
    private long _lastSubAudioTicks;

    // UI thread.
    private readonly List<FreeDvHeardStation> _heard = [];
    private IFreeDvSpeechOutput? _output;
    private FreeDvRigInfo _rigInfo;
    private RigMode? _kiwiMode;
    private bool _senderActive;
    private CancellationTokenSource? _voiceHold;

    /// <param name="post">Runs an action on the UI thread.</param>
    /// <param name="openOutput">The speech player, opened at each start.</param>
    /// <param name="frequencyOfSource">The dial of a source the rig doesn't
    /// report (MyKiwiSDR).</param>
    /// <param name="recordingPath">Where a decoded file's speech is saved,
    /// given a label for its name.</param>
    public FreeDvReceiver(Action<Action> post, FreeDvData settings, Action save,
        Func<IFreeDvSpeechOutput?> openOutput, Func<CwAudioChannel, long?> frequencyOfSource,
        Func<string, string> recordingPath, Func<string, WaveStream> openFile, Action<string>? log = null)
    {
        _post = post;
        _settings = settings;
        _save = save;
        _openOutput = openOutput;
        _frequencyOfSource = frequencyOfSource;
        _recordingPath = recordingPath;
        _openFile = openFile;
        _log = log ?? (_ => { });
        _channel = settings.Channel;
        _worker = new Thread(Run) { IsBackground = true, Name = "FreeDV decoder" };
        _worker.Start();
    }

    public void Dispose()
    {
        _running = false;
        _voiceHold?.Cancel();
        _output?.Dispose();
        _output = null;
        Enqueue(() =>
        {
            _decoder?.Dispose();
            _decoder = null;
        });
        _queue.CompleteAdding();
    }

    // Settings

    public CwAudioChannel Channel
    {
        get => _channel;
        set
        {
            if (value == _channel)
            {
                return;
            }
            _channel = value;
            _settings.Channel = value;
            _save();
            ResetDecoder();
            UpdateModeHint();
            ChannelChanged?.Invoke();
            Changed?.Invoke();
        }
    }

    public double Volume
    {
        get => _settings.Volume;
        set
        {
            value = Math.Clamp(value, 0, 1);
            if (value == _settings.Volume)
            {
                return;
            }
            _settings.Volume = value;
            _save();
            if (_output is { } output)
            {
                output.Volume = (float)value;
            }
        }
    }

    /// Decoded speech not played; decoding, the heard list and the rig audio
    /// mute carry on regardless.
    public bool IsMuted
    {
        get => _settings.Muted;
        set
        {
            if (value == _settings.Muted)
            {
                return;
            }
            _settings.Muted = value;
            _save();
            Changed?.Invoke();
        }
    }

    // State

    public bool IsRunning => _running;
    public bool IsPausedForTransmit => _pausedForTransmit;
    /// In sync, held a moment after sync drops.
    public bool IsReceivingVoice { get; private set; }
    public FreeDvStatus Status { get; private set; }
    /// Newest first.
    public IReadOnlyList<FreeDvHeardStation> Heard => _heard;
    /// Set when the selected source's mode won't receive FreeDV where it's
    /// tuned (wrong sideband for the band, or not SSB at all).
    public FreeDvModeHint? ModeHint { get; private set; }
    public bool IsDecodingFile { get; private set; }
    /// The speech decoded from the last file.
    public string? LastDecodedFile { get; private set; }
    /// The decoder couldn't be started.
    public string? DecoderProblem { get; private set; }
    /// Why the decoded speech isn't playing.
    public string? OutputProblem => _output?.Problem;

    // Lifecycle (the window's open/close)

    public void Start()
    {
        if (_running)
        {
            return;
        }
        _running = true;
        OpenOutput();
        ResetDecoder();
        _log($"freedv: started, source {_channel}");
        UpdateModeHint();
        Changed?.Invoke();
    }

    public void Stop()
    {
        if (!_running)
        {
            return;
        }
        _running = false;
        _output?.Dispose();
        _output = null;
        ResetDecoder();
        Changed?.Invoke();
    }

    /// Settings → Audio saved: the output device may have changed.
    public void RestartOutput()
    {
        if (!_running)
        {
            return;
        }
        _output?.Dispose();
        _output = null;
        OpenOutput();
        Changed?.Invoke();
    }

    private void OpenOutput()
    {
        _output = _openOutput();
        if (_output is { } output)
        {
            output.Volume = (float)_settings.Volume;
        }
    }

    /// The rig's audio stopped: nothing more will arrive to end a sync.
    public void AudioStopped() => ResetDecoder();

    private void ResetDecoder()
    {
        var generation = ++_generation;
        Status = default;
        SetReceivingVoice(false, immediately: true);
        var running = _running;
        Enqueue(() =>
        {
            _decoder?.Dispose();
            _decoder = null;
            _resampler.Reset();
            _lastSyncSnr = null;
            if (!running || generation != _generation)
            {
                return;
            }
            try
            {
                _decoder = new RadeDecoder();
                _post(() => SetDecoderProblem(null));
            }
            catch (Exception ex)
            {
                _log($"freedv: decoder failed to start: {ex.Message}");
                _post(() => SetDecoderProblem(Loc.F("freeDvReceiver.decoderFailed", ex.Message)));
            }
        });
    }

    private void SetDecoderProblem(string? problem)
    {
        if (problem == DecoderProblem)
        {
            return;
        }
        DecoderProblem = problem;
        Changed?.Invoke();
    }

    // Audio

    /// From MainWindow's audio routing (audio thread), for every chunk,
    /// whether or not the window is open — cheap when it isn't. The arrays are
    /// fresh per chunk, so they can be queued as they are.
    public void Ingest(float[] main, float[] sub, int sampleRate)
    {
        if (HasAudio(sub))
        {
            Interlocked.Exchange(ref _lastSubAudioTicks, Stopwatch.GetTimestamp());
        }
        var channel = _channel;
        if (channel is CwAudioChannel.Main or CwAudioChannel.Sub)
        {
            Ingest(channel == CwAudioChannel.Main ? main : sub, sampleRate, channel);
        }
    }

    /// One source's chunk (the SDR sources call this one; any thread).
    public void Ingest(float[] samples, int sampleRate, CwAudioChannel source)
    {
        if (!_running || _pausedForTransmit || sampleRate <= 0 || source != _channel)
        {
            return;
        }
        var generation = _generation;
        Action work = () => Decode(samples, sampleRate, generation);
        if (!_queue.IsAddingCompleted)
        {
            // Live audio: drop rather than block the audio thread if the
            // worker ever falls far behind.
            _queue.TryAdd(work);
        }
    }

    /// Worker thread.
    private void Decode(float[] samples, int sampleRate, int generation)
    {
        if (_decoder is not { } decoder || generation != _generation)
        {
            return;
        }
        var output = decoder.Process(_resampler.Convert(samples, sampleRate));
        var calls = output.EndsOfOver.Where(e => e.Callsign is not null)
            .Select(e => (e.Callsign!, _lastSyncSnr)).ToList();
        if (output.Status.Sync)
        {
            _lastSyncSnr = output.Status.SnrDb;
        }
        _post(() => Handle(output, calls, generation));
    }

    private void Handle(RadeOutput output, List<(string Callsign, float? Snr)> calls, int generation)
    {
        if (generation != _generation)
        {
            return;
        }
        var status = output.Status;
        Status = status.Sync
            ? new FreeDvStatus(true, status.SnrDb, status.FrequencyOffsetHz)
            : Status with { Sync = false };
        SetReceivingVoice(status.Sync, immediately: false);
        if (output.Speech.Length > 0 && !_settings.Muted)
        {
            _output?.Push(output.Speech);
        }
        foreach (var (callsign, snr) in calls)
        {
            AddHeard(callsign, snr, fromFile: false);
        }
    }

    private void SetReceivingVoice(bool sync, bool immediately)
    {
        if (sync)
        {
            CancelVoiceHold();
            SetVoice(true);
        }
        else if (immediately)
        {
            CancelVoiceHold();
            SetVoice(false);
        }
        else if (IsReceivingVoice && _voiceHold is null)
        {
            _voiceHold = new CancellationTokenSource();
            _ = HoldVoiceAsync(_voiceHold.Token);
        }
    }

    private async Task HoldVoiceAsync(CancellationToken token)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(VoiceHoldSeconds), token);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (token.IsCancellationRequested)
        {
            return;
        }
        _voiceHold = null;
        if (!Status.Sync)
        {
            SetVoice(false);
        }
    }

    private void CancelVoiceHold()
    {
        _voiceHold?.Cancel();
        _voiceHold = null;
    }

    private void SetVoice(bool on)
    {
        if (on == IsReceivingVoice)
        {
            return;
        }
        IsReceivingVoice = on;
        VoiceChanged?.Invoke();
        Changed?.Invoke();
    }

    private void AddHeard(string callsign, float? snr, bool fromFile)
    {
        long? frequency = fromFile ? null : _channel switch
        {
            CwAudioChannel.Main => _rigInfo.MainHz,
            CwAudioChannel.Sub => _rigInfo.SubHz,
            var other => _frequencyOfSource(other),
        };
        var station = new FreeDvHeardStation(callsign, DateTime.UtcNow, snr, _channel, frequency, fromFile);
        _heard.Insert(0, station);
        if (_heard.Count > MaxHeard)
        {
            _heard.RemoveRange(MaxHeard, _heard.Count - MaxHeard);
        }
        _log($"freedv: heard {callsign}{(fromFile ? " (file)" : "")}");
        if (!fromFile)
        {
            HeardLive?.Invoke(station);
        }
        Changed?.Invoke();
    }

    public void ClearHeard()
    {
        _heard.Clear();
        Changed?.Invoke();
    }

    /// Whether Sub audio has been arriving: a mono input device (Local mode)
    /// delivers exact zeros for Sub, which no real capture does.
    public bool IsSubAudioAvailable
    {
        get
        {
            var last = Interlocked.Read(ref _lastSubAudioTicks);
            return last != 0 && Stopwatch.GetElapsedTime(last) < SubAudioTimeout;
        }
    }

    private static bool HasAudio(float[] samples)
    {
        foreach (var sample in samples)
        {
            if (sample != 0)
            {
                return true;
            }
        }
        return false;
    }

    // Rig

    /// From MainWindow after every poll and on disconnect.
    public void RigInfoChanged(FreeDvRigInfo info)
    {
        var changed = info != _rigInfo;
        _rigInfo = info;
        if (changed)
        {
            UpdateTransmitPause();
        }
        // Also when nothing changed: the Kiwi's dial may have.
        UpdateModeHint();
    }

    /// The FreeDV sender is transmitting (covers the lag before the poll sees
    /// PTT, as with the CW and RTTY/PSK senders).
    public void SetSenderActive(bool active)
    {
        _senderActive = active;
        UpdateTransmitPause();
    }

    private void UpdateTransmitPause()
    {
        var paused = _senderActive || _rigInfo.Transmitting;
        if (paused == _pausedForTransmit)
        {
            return;
        }
        _pausedForTransmit = paused;
        if (paused)
        {
            ResetDecoder();
        }
        Changed?.Invoke();
    }

    /// The MyKiwiSDR window's demodulation while it's connected (null
    /// otherwise).
    public void SetKiwiMode(RigMode? mode)
    {
        if (mode == _kiwiMode)
        {
            return;
        }
        _kiwiMode = mode;
        UpdateModeHint();
    }

    private void UpdateModeHint()
    {
        var hint = _channel switch
        {
            CwAudioChannel.Main => FreeDvModeHint.For(_rigInfo.MainMode, _rigInfo.MainIsC4fm, _rigInfo.MainHz),
            CwAudioChannel.Sub => FreeDvModeHint.For(_rigInfo.SubMode, _rigInfo.SubIsC4fm, _rigInfo.SubHz),
            CwAudioChannel.MyKiwiSdr => FreeDvModeHint.For(_kiwiMode, false, _frequencyOfSource(CwAudioChannel.MyKiwiSdr)),
            _ => null,
        };
        if (hint == ModeHint)
        {
            return;
        }
        ModeHint = hint;
        Changed?.Invoke();
    }

    // Files

    /// Decodes a recording (any rate, first channel) as fast as it goes:
    /// callsigns into <see cref="Heard"/>, the speech into a WAV
    /// (<see cref="LastDecodedFile"/>). Live decoding carries on meanwhile.
    public void DecodeFile(string path)
    {
        if (IsDecodingFile)
        {
            return;
        }
        IsDecodingFile = true;
        LastDecodedFile = null;
        var destination = _recordingPath($"FreeDV {Path.GetFileNameWithoutExtension(path)}");
        Changed?.Invoke();
        Task.Run(() =>
        {
            var result = DecodeFileContents(path, destination);
            _post(() => FinishFile(result, destination, path));
        });
    }

    private sealed class FileResult
    {
        public List<(string Callsign, float? Snr)> Callsigns { get; } = [];
        public long SpeechSamples { get; set; }
        public string? Error { get; set; }
    }

    private FileResult DecodeFileContents(string path, string destination)
    {
        var result = new FileResult();
        try
        {
            using var reader = _openFile(path);
            var provider = reader.ToSampleProvider();
            var channels = provider.WaveFormat.Channels;
            var sampleRate = provider.WaveFormat.SampleRate;
            using var decoder = new RadeDecoder();
            var resampler = new DigiResampler(RadeDecoder.ModemSampleRate);
            using var writer = new WaveFileWriter(destination, new WaveFormat(RadeDecoder.SpeechSampleRate, 16, 1));
            var buffer = new float[FileChunkFrames * channels];
            float? lastSyncSnr = null;
            int read;
            while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
            {
                var frames = read / channels;
                var mono = new float[frames];
                for (var i = 0; i < frames; i++)
                {
                    mono[i] = buffer[i * channels];
                }
                var output = decoder.Process(resampler.Convert(mono, sampleRate));
                foreach (var end in output.EndsOfOver)
                {
                    if (end.Callsign is { } callsign)
                    {
                        result.Callsigns.Add((callsign, lastSyncSnr));
                    }
                }
                if (output.Status.Sync)
                {
                    lastSyncSnr = output.Status.SnrDb;
                }
                if (output.Speech.Length > 0)
                {
                    var pcm = FreeDvPcm.From(output.Speech);
                    writer.Write(pcm, 0, pcm.Length);
                    result.SpeechSamples += output.Speech.Length;
                }
            }
        }
        catch (Exception ex)
        {
            result.Error = ex.Message;
        }
        return result;
    }

    private void FinishFile(FileResult result, string destination, string source)
    {
        IsDecodingFile = false;
        foreach (var (callsign, snr) in result.Callsigns)
        {
            AddHeard(callsign, snr, fromFile: true);
        }
        string? error = null;
        if (result.Error is { } message)
        {
            error = Loc.F("freeDvReceiver.couldntRead", Path.GetFileName(source), message);
        }
        else if (result.SpeechSamples == 0)
        {
            error = Loc.F("freeDvReceiver.noFreeDVIn", Path.GetFileName(source));
        }
        if (error is null)
        {
            LastDecodedFile = destination;
        }
        else
        {
            try
            {
                File.Delete(destination);
            }
            catch (Exception ex)
            {
                _log($"freedv: couldn't delete {destination}: {ex.Message}");
            }
            _log($"freedv: {error}");
        }
        Changed?.Invoke();
        if (error is not null)
        {
            Error?.Invoke(error);
        }
    }

    // Worker

    private void Enqueue(Action work)
    {
        if (!_queue.IsAddingCompleted)
        {
            _queue.Add(work);
        }
    }

    private void Run()
    {
        foreach (var work in _queue.GetConsumingEnumerable())
        {
            try
            {
                work();
            }
            catch (Exception ex)
            {
                _log($"freedv: decoder: {ex.Message}");
            }
        }
    }
}
