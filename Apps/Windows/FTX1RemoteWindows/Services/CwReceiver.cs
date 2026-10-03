using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using NAudio.Wave;

namespace FTX1RemoteWindows.Services;

/// Which audio the CW decoder listens to. MAIN/SUB are roles, not L/R
/// channels: MainWindow's audio routing already swaps the channels to
/// follow a Main/Sub swap, so Main is always the Main VFO's audio. (The
/// Mac's third source, the WebSDR window's audio, isn't ported.)
public enum CwAudioChannel
{
    Main,
    Sub,
}

/// What the receiver needs from the rig, so MainWindow only forwards
/// changes (the Mac's CWRigInfo). Modes are null while disconnected or
/// unknown (C4FM has no RigMode here).
public readonly record struct CwRigInfo(bool Transmitting, int? PitchHz, RigMode? MainMode, RigMode? SubMode);

/// The receive side of the CW window: decodes rig audio (or an audio file)
/// to text — the Mac's CWReceiver (Apps/Mac/FTX1RemoteMac/CWReceiver.swift)
/// together with CWKit's PipelineRunner, with either decoder: neural
/// (Services/CwNeuralDecoder.cs, the default, as on the Mac) or classic
/// (Services/CwClassicDecoder.cs). The neural model loads the first time the
/// window opens, on the worker; if it can't, the classic decoder is used and
/// <see cref="NeuralUnavailableReason"/> says why.
///
/// MainWindow feeds it both receivers' audio from the audio thread
/// (<see cref="Ingest"/>); it keeps only the selected channel, and drops
/// everything while the window is closed (<see cref="Start"/>/
/// <see cref="Stop"/>), the same "decode only while the window is open"
/// shape as the Mac. Decoding runs on this object's own worker thread;
/// everything else (text, settings, state) lives on the UI thread, and the
/// worker's results are marshaled there in order. Owned by MainWindow, not
/// the window, so the decoded text survives closing and reopening it.
///
/// The per-chunk readouts (key, level, SNR, WPM, tone, pending symbols)
/// aren't events: the worker leaves the latest in <see cref="Meters"/>,
/// which the open window samples on a timer, so ~21 chunks a second never
/// touch the decoded text.
public sealed class CwReceiver : IDisposable
{
    /// The decoded text, the decoding-file flag, the notes or the settings
    /// changed (UI thread).
    public event Action? Changed;
    /// A file couldn't be read (UI thread).
    public event Action<string>? Error;

    private abstract record Work;
    private sealed record SamplesWork(float[] Samples, int SampleRate) : Work;
    private sealed record SettingsWork(CwPipelineSettings Settings) : Work;
    private sealed record FlushWork : Work;
    private sealed record FileWork(string Path) : Work;
    private sealed record LoadModelWork : Work;

    private readonly DispatcherQueue _dispatcher;
    private readonly BlockingCollection<Work> _queue = new(boundedCapacity: 256);
    private readonly Thread _worker;

    // Worker thread only.
    private ICwDecoderEngine? _decoder;
    private CwPipelineSettings _workerSettings;
    private CwNetModel? _model;
    private string _workerTentative = "";

    // Read by the audio thread.
    private volatile bool _running;
    private volatile bool _decodingFile;
    private volatile bool _pausedForTransmit;
    private volatile CwAudioChannel _channel;
    private long _lastSubAudioTicks;

    // UI thread.
    private readonly StringBuilder _text = new();
    private CwRigInfo _rigInfo;
    private bool _senderActive;
    private CwAudioChannel _channelSetting;
    private double _toneFrequency;
    private bool _autoTune;
    private double _squelchDb;
    private CwDecoderKind _decoderKind;
    private string _tentative = "";
    private bool _modelLoadQueued;

    private const int MaxTextLength = 100_000;
    /// No Sub audio (or only digital silence, which is what a mono Local
    /// input device delivers for Sub) for this long means there's no Sub
    /// channel.
    private static readonly TimeSpan SubAudioTimeout = TimeSpan.FromSeconds(2);
    /// File decoding's chunk size, in frames (CWKit's AudioFileReader).
    private const int FileChunkFrames = 16_384;

    public CwReceiver(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
        _channelSetting = AppSettings.CwChannel;
        _channel = _channelSetting;
        _toneFrequency = Math.Clamp(AppSettings.CwToneFrequency, FrequencyTracker.SearchMin, FrequencyTracker.SearchMax);
        _autoTune = AppSettings.CwAutoTune;
        _squelchDb = AppSettings.CwSquelchDb;
        _decoderKind = AppSettings.CwDecoder;
        _workerSettings = CurrentSettings;
        _meters = new CwMeters(false, 0, 0, _toneFrequency, 0, "");
        _worker = new Thread(Run) { IsBackground = true, Name = "CW decoder" };
        _worker.Start();
    }

    /// The worker disposes the model once the queue is drained.
    public void Dispose() => _queue.CompleteAdding();

    // Lifecycle (the CW window's open/close)

    public bool IsRunning => _running;

    public void Start()
    {
        _running = true;
        // The model loads on first use, so a session that never opens the
        // CW window never pays for it (the Mac's makeRunnerIfNeeded).
        if (!_modelLoadQueued)
        {
            _modelLoadQueued = true;
            Enqueue(new LoadModelWork());
        }
    }

    /// Called when the CW window closes. A file decode already under way
    /// runs to the end.
    public void Stop()
    {
        if (!_running)
        {
            return;
        }
        _running = false;
        if (!_decodingFile)
        {
            Enqueue(new FlushWork());
        }
    }

    // Audio

    /// From MainWindow's audio routing (audio thread), for every chunk,
    /// whether or not the window is open — cheap when it isn't. The arrays
    /// are fresh per chunk, so they can be queued as they are.
    public void Ingest(float[] main, float[] sub, int sampleRate)
    {
        if (HasAudio(sub))
        {
            Interlocked.Exchange(ref _lastSubAudioTicks, Stopwatch.GetTimestamp());
        }
        if (!_running || _decodingFile || _pausedForTransmit || sampleRate <= 0)
        {
            return;
        }
        Enqueue(new SamplesWork(_channel == CwAudioChannel.Main ? main : sub, sampleRate));
    }

    /// Whether Sub audio has been arriving: a mono input device (Local
    /// mode) delivers exact zeros for Sub, which no real capture does.
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

    // Settings (persisted, like the Mac's cw.* defaults)

    public CwAudioChannel Channel
    {
        get => _channelSetting;
        set
        {
            if (value == _channelSetting)
            {
                return;
            }
            _channelSetting = value;
            _channel = value;
            AppSettings.CwChannel = value;
            // Flush what the old channel's decoder still holds; the next
            // audio starts a fresh one on the new channel.
            if (_running && !_decodingFile)
            {
                Enqueue(new FlushWork());
                StartNewLine();
            }
            Changed?.Invoke();
        }
    }

    public double ToneFrequency
    {
        get => _toneFrequency;
        set
        {
            value = Math.Clamp(value, FrequencyTracker.SearchMin, FrequencyTracker.SearchMax);
            if (value == _toneFrequency)
            {
                return;
            }
            _toneFrequency = value;
            SettingsChanged();
        }
    }

    public bool AutoTune
    {
        get => _autoTune;
        set
        {
            if (value == _autoTune)
            {
                return;
            }
            _autoTune = value;
            // Keep listening on the tone we found rather than jumping back
            // to the old manual setting (same as the Mac and CWDecode).
            if (!value)
            {
                _toneFrequency = Math.Clamp(Meters.ToneFrequency, FrequencyTracker.SearchMin, FrequencyTracker.SearchMax);
            }
            SettingsChanged();
        }
    }

    public double SquelchDb
    {
        get => _squelchDb;
        set
        {
            if (value == _squelchDb)
            {
                return;
            }
            _squelchDb = value;
            SettingsChanged();
        }
    }

    /// Neural or classic (the Mac's cw.decoder, Neural by default).
    public CwDecoderKind Decoder
    {
        get => _decoderKind;
        set
        {
            if (value == _decoderKind)
            {
                return;
            }
            _decoderKind = value;
            AppSettings.CwDecoder = value;
            SettingsChanged();
        }
    }

    /// Why the neural decoder can't be used, or null when it can (or hasn't
    /// been loaded yet).
    public string? NeuralUnavailableReason { get; private set; }

    /// The decoder actually running: classic when the model couldn't load.
    public CwDecoderKind EffectiveDecoder => NeuralUnavailableReason is null ? _decoderKind : CwDecoderKind.Classic;

    private CwPipelineSettings CurrentSettings => new(_toneFrequency, _autoTune, _squelchDb, Decoder: EffectiveDecoder);

    private void SettingsChanged()
    {
        AppSettings.SaveCw(_toneFrequency, _autoTune, _squelchDb);
        if (!_autoTune)
        {
            Meters = Meters with { ToneFrequency = _toneFrequency };
        }
        Enqueue(new SettingsWork(CurrentSettings));
        Changed?.Invoke();
    }

    // Rig

    public int? RigPitchHz => _rigInfo.PitchHz;

    /// The decoder skips audio while the rig transmits or the send pane is
    /// sending (the Mac's v2 decision): otherwise it decodes the operator's
    /// own sidetone, which the send pane already shows.
    public bool IsPausedForTransmit => _pausedForTransmit;

    /// The selected receiver's mode, when it's known and isn't CW.
    public RigMode? SourceModeIfNotCw
    {
        get
        {
            var mode = _channelSetting == CwAudioChannel.Main ? _rigInfo.MainMode : _rigInfo.SubMode;
            return mode is { } m && m != RigMode.Cw ? m : null;
        }
    }

    /// From MainWindow after every poll and on disconnect.
    public void RigInfoChanged(CwRigInfo info)
    {
        if (info == _rigInfo)
        {
            return;
        }
        _rigInfo = info;
        UpdateTransmitPause();
        Changed?.Invoke();
    }

    /// From the send pane's CwSender: true while a line is being sent,
    /// which covers the lag before the poll sees PTT.
    public void SetSenderActive(bool active)
    {
        if (active == _senderActive)
        {
            return;
        }
        _senderActive = active;
        UpdateTransmitPause();
        Changed?.Invoke();
    }

    private void UpdateTransmitPause()
    {
        var paused = _senderActive || _rigInfo.Transmitting;
        if (paused == _pausedForTransmit)
        {
            return;
        }
        _pausedForTransmit = paused;
        // End the character in progress cleanly rather than leave it to be
        // finished by the first audio after TX.
        if (paused && _running && !_decodingFile)
        {
            Enqueue(new FlushWork());
            StartNewLine();
        }
    }

    /// Sets the manual tone to the rig's CW pitch: a signal tuned to zero
    /// beat on the rig sounds at exactly that pitch.
    public void UseRigPitch()
    {
        if (_rigInfo.PitchHz is not { } pitch)
        {
            return;
        }
        _autoTune = false;
        _toneFrequency = Math.Clamp(pitch, FrequencyTracker.SearchMin, FrequencyTracker.SearchMax);
        SettingsChanged();
    }

    // Files

    public bool IsDecodingFile => _decodingFile;

    /// Pauses live decoding, decodes the file into the same text under a
    /// header line, then live decoding resumes (if the window is still open).
    public void DecodeFile(string path)
    {
        if (_decodingFile)
        {
            return;
        }
        // The flag drops live audio from here on; the worker flushes the
        // live decoder before the file's audio reaches it.
        _decodingFile = true;
        StartNewLine();
        Append($"— {Path.GetFileName(path)} —\n");
        Enqueue(new FileWork(path));
        Changed?.Invoke();
    }

    // Text

    public string DecodedText => _text.ToString();
    public bool HasText => _text.Length > 0;
    /// Neural decoder: the newest text, not final yet; replaced on every update.
    public string TentativeText => _tentative;

    public void ClearText()
    {
        _text.Clear();
        _tentative = "";
        Changed?.Invoke();
    }

    private void Append(string text)
    {
        if (text.Length == 0)
        {
            return;
        }
        _text.Append(text);
        if (_text.Length > MaxTextLength)
        {
            _text.Remove(0, _text.Length - MaxTextLength);
        }
    }

    private void StartNewLine()
    {
        if (_text.Length > 0 && _text[^1] != '\n')
        {
            Append("\n");
        }
    }

    // Worker

    /// The latest readouts; written by the worker, sampled by the window.
    public CwMeters Meters
    {
        get => _meters;
        private set => _meters = value;
    }
    private volatile CwMeters _meters;

    private void Enqueue(Work work)
    {
        if (_queue.IsAddingCompleted)
        {
            return;
        }
        if (work is SamplesWork)
        {
            // Live audio: drop rather than block the audio thread if the
            // worker ever falls ~12 s behind.
            _queue.TryAdd(work);
        }
        else
        {
            // Control items must not be lost; the UI thread can wait.
            _queue.Add(work);
        }
    }

    private void Run()
    {
        foreach (var work in _queue.GetConsumingEnumerable())
        {
            try
            {
                switch (work)
                {
                    case SamplesWork samples:
                        Process(samples.Samples, samples.SampleRate);
                        break;
                    case SettingsWork settings:
                        ApplySettings(settings.Settings);
                        break;
                    case LoadModelWork:
                        LoadModel();
                        break;
                    case FlushWork:
                        Flush();
                        break;
                    case FileWork file:
                        DecodeFileOnWorker(file.Path);
                        break;
                }
            }
            catch (Exception ex)
            {
                AppLog.Write($"cw-decoder: {ex.Message}");
            }
        }
        _model?.Dispose();
    }

    private void LoadModel()
    {
        if (_model is not null)
        {
            return;
        }
        try
        {
            var stopwatch = Stopwatch.StartNew();
            _model = new CwNetModel();
            AppLog.Write($"cw-decoder: neural model loaded in {stopwatch.ElapsedMilliseconds} ms ({_model.Vocabulary.Count} tokens)");
        }
        catch (Exception ex)
        {
            var reason = ex.Message;
            AppLog.Write($"cw-decoder: neural decoder unavailable: {reason}");
            _dispatcher.TryEnqueue(() =>
            {
                NeuralUnavailableReason = reason;
                // Falls back to classic from here on.
                Enqueue(new SettingsWork(CurrentSettings));
                Changed?.Invoke();
            });
        }
    }

    /// Like PipelineRunner.update: switching decoders flushes what the old
    /// one still holds; the next audio starts the new one.
    private void ApplySettings(CwPipelineSettings settings)
    {
        var switching = settings.Decoder != _workerSettings.Decoder;
        _workerSettings = settings;
        if (switching && _decoder is { } old)
        {
            Publish(old.Finish());
            PublishTentative("");
            _decoder = null;
        }
        else
        {
            _decoder?.Update(settings);
        }
    }

    private void Process(float[] samples, int sampleRate)
    {
        // A new rate (a new source, or a file) needs a new decoder, like
        // PipelineRunner's.
        if (_decoder is null || _decoder.SampleRate != sampleRate)
        {
            _decoder = _workerSettings.Decoder == CwDecoderKind.Neural && _model is { } model
                ? new CwNeuralPipeline(sampleRate, _workerSettings, model)
                : new CwClassicDecoder(sampleRate, _workerSettings);
        }
        Publish(_decoder.Process(samples));
    }

    /// Ends whatever the decoder is in the middle of; the next audio starts
    /// a fresh one.
    private void Flush()
    {
        if (_decoder is { } decoder)
        {
            Publish(decoder.Finish());
            _decoder = null;
        }
        PublishTentative("");
        Meters = Meters with { KeyDown = false, SignalLevel = 0, PendingSymbols = "" };
    }

    private void Publish(CwPipelineOutput output)
    {
        Meters = new CwMeters(output.KeyDown, output.SignalLevel, output.SnrDb, output.ToneFrequency, output.Wpm, output.PendingSymbols);
        var tentative = output.TentativeText ?? "";
        if (output.Text.Length > 0 || tentative != _workerTentative)
        {
            var text = output.Text;
            _workerTentative = tentative;
            _dispatcher.TryEnqueue(() =>
            {
                Append(text);
                _tentative = tentative;
                Changed?.Invoke();
            });
        }
    }

    private void PublishTentative(string tentative)
    {
        if (tentative == _workerTentative)
        {
            return;
        }
        _workerTentative = tentative;
        _dispatcher.TryEnqueue(() =>
        {
            _tentative = tentative;
            Changed?.Invoke();
        });
    }

    private void DecodeFileOnWorker(string path)
    {
        Flush();
        string? error = null;
        try
        {
            // Media Foundation reads WAV, MP3, M4A/AAC, WMA, … (CWKit's
            // AudioFileReader reads whatever AVFoundation does).
            using var reader = new MediaFoundationReader(path);
            var provider = reader.ToSampleProvider();
            var channels = provider.WaveFormat.Channels;
            var sampleRate = provider.WaveFormat.SampleRate;
            var buffer = new float[FileChunkFrames * channels];
            int read;
            while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
            {
                var frames = read / channels;
                var mono = new float[frames];
                for (var i = 0; i < frames; i++)
                {
                    float sum = 0;
                    for (var c = 0; c < channels; c++)
                    {
                        sum += buffer[i * channels + c];
                    }
                    mono[i] = sum / channels;
                }
                Process(mono, sampleRate);
            }
        }
        catch (Exception ex)
        {
            error = $"Couldn't read “{Path.GetFileName(path)}”: {ex.Message}";
            AppLog.Write($"cw-decoder: {error}");
        }
        Flush();
        _dispatcher.TryEnqueue(() =>
        {
            _decodingFile = false;
            StartNewLine();
            Changed?.Invoke();
            if (error is not null)
            {
                Error?.Invoke(error);
            }
        });
    }
}

/// The decoder's live readouts (the Mac's CWMeterStore).
public sealed record CwMeters(
    bool KeyDown,
    double SignalLevel,
    double SnrDb,
    double ToneFrequency,
    double Wpm,
    string PendingSymbols);
