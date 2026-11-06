using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using NAudio.Wave;

namespace FTX1RemoteWindows.Services.Digi;

/// What the decoder needs to know about the rig. Modes are null while
/// disconnected or unknown (C4FM has no RigMode here).
public readonly record struct DigiRigInfo(bool Transmitting, RigMode? MainMode, RigMode? SubMode);

/// A stretch of the window's text: received, or sent by this station.
public sealed record DigiTextRun(string Text, bool IsTransmit);

/// The tuning strip's newest row and the live readings, sampled by the open
/// window on a timer so ~10 rows a second never touch the decoded text.
public sealed record DigiMeters(float[] Row, int RowSerial, double TrackedHz, float Quality);

/// Tools → RTTY/PSK's receiver — the Mac's DigiReceiver: RTTY, BPSK31 or
/// BPSK63 from the rig's MAIN or SUB audio, the WebSDR window's audio, or an
/// audio file.
///
/// MainWindow feeds it both receivers' audio from the audio thread
/// (<see cref="Ingest"/>); it keeps only the selected channel, and only
/// between <see cref="Start"/> and <see cref="Stop"/> (the window's
/// open/close). Demodulation runs on this object's own worker thread;
/// everything else lives on the UI thread and the worker's results are
/// marshaled there in order. Owned by MainWindow, so the decoded text
/// survives closing and reopening the window.
public sealed class DigiReceiver : IDigiTxSource, IDisposable
{
    /// The decoded text, the file flag, notes or settings changed (UI thread).
    public event Action? Changed;
    /// A file couldn't be read (UI thread).
    public event Action<string>? Error;

    private abstract record Work;
    private sealed record SamplesWork(float[] Samples, int SampleRate, int Generation) : Work;
    private sealed record RebuildWork(DigiMode Mode, RttySettings Rtty, double CenterHz, bool Afc, float Squelch) : Work;
    private sealed record ResetWork : Work;
    private sealed record CenterWork(double Hz) : Work;
    private sealed record AfcWork(bool On) : Work;
    private sealed record SquelchWork(float Value) : Work;
    private sealed record FileWork(string Path, DigiMode Mode, RttySettings Rtty, double CenterHz, bool Afc, float Squelch) : Work;

    private readonly DispatcherQueue _dispatcher;
    private readonly BlockingCollection<Work> _queue = new(boundedCapacity: 256);
    private readonly Thread _worker;

    // Worker thread only.
    private DigiDecoder? _decoder;

    // Read by the audio thread and the worker.
    private volatile bool _running;
    private volatile bool _decodingFile;
    private volatile bool _pausedForTransmit;
    private volatile CwAudioChannel _channel;
    private volatile int _generation;
    private long _lastSubAudioTicks;

    // UI thread.
    private readonly AppSettings.DigiData _settings = AppSettings.Digi;
    private readonly List<DigiTextRun> _runs = [];
    private DigiMode _mode;
    private CwAudioChannel _channelSetting;
    private double _centerHz;
    private DigiRigInfo _rigInfo;
    private bool _senderActive;
    private readonly Func<WebSdrState?> _webSdrState;
    private WebSdrAudioTap? _webSdrTap;
    private readonly DispatcherQueueTimer _webSdrTimer;
    private WebSdrState? _lastWebSdrState;

    private readonly object _meterLock = new();
    private DigiMeters _meters = new([], 0, 0, 0);

    private const int MaxTextLength = 100_000;
    private static readonly TimeSpan SubAudioTimeout = TimeSpan.FromSeconds(2);
    private const int FileChunkFrames = 16_384;

    public DigiReceiver(DispatcherQueue dispatcher, Func<WebSdrState?> webSdrState)
    {
        _dispatcher = dispatcher;
        _webSdrState = webSdrState;
        _webSdrTimer = dispatcher.CreateTimer();
        _webSdrTimer.Interval = TimeSpan.FromSeconds(2);
        _webSdrTimer.Tick += (_, _) => RefreshWebSdrState();
        _mode = _settings.Mode;
        _channelSetting = _settings.Channel;
        _channel = _channelSetting;
        _centerHz = SavedCenter(_mode);
        _meters = new DigiMeters([], 0, _centerHz, 0);
        _worker = new Thread(Run) { IsBackground = true, Name = "RTTY/PSK decoder" };
        _worker.Start();
    }

    public void Dispose()
    {
        _webSdrTimer.Stop();
        _webSdrTap?.Dispose();
        _queue.CompleteAdding();
    }

    // Settings

    public DigiMode Mode
    {
        get => _mode;
        set
        {
            if (value == _mode)
            {
                return;
            }
            _mode = value;
            _settings.Mode = value;
            AppSettings.SaveDigi();
            _centerHz = SavedCenter(value);
            RebuildDecoder();
            Changed?.Invoke();
        }
    }

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
            _settings.Channel = value;
            AppSettings.SaveDigi();
            ResetDecoder();
            UpdateWebSdrTap();
            Changed?.Invoke();
        }
    }

    /// Where the operator put the decoder (a click on the strip); AFC works
    /// around it. Saved per mode.
    public double CenterHz => _centerHz;

    public double RttyShiftHz
    {
        get => _settings.RttyShiftHz;
        set => ChangeRtty(() => _settings.RttyShiftHz = value, _settings.RttyShiftHz != value);
    }

    public double RttyBaud
    {
        get => _settings.RttyBaud;
        set => ChangeRtty(() => _settings.RttyBaud = value, _settings.RttyBaud != value);
    }

    public bool RttyReverse
    {
        get => _settings.RttyReverse;
        set => ChangeRtty(() => _settings.RttyReverse = value, _settings.RttyReverse != value);
    }

    public bool RttyUnshiftOnSpace
    {
        get => _settings.RttyUnshiftOnSpace;
        set => ChangeRtty(() => _settings.RttyUnshiftOnSpace = value, _settings.RttyUnshiftOnSpace != value);
    }

    public bool AfcEnabled
    {
        get => _settings.Afc;
        set
        {
            if (value == _settings.Afc)
            {
                return;
            }
            _settings.Afc = value;
            AppSettings.SaveDigi();
            Enqueue(new AfcWork(value));
            Changed?.Invoke();
        }
    }

    /// 0…1; characters print only while the signal quality is above it.
    public double Squelch
    {
        get => _settings.Squelch;
        set
        {
            value = Math.Clamp(value, 0, 0.9);
            if (value == _settings.Squelch)
            {
                return;
            }
            _settings.Squelch = value;
            AppSettings.SaveDigi();
            Enqueue(new SquelchWork((float)value));
        }
    }

    /// The settings as the operator set them: Reverse means "this station
    /// sends upside down", whatever the sideband.
    public RttySettings Rtty => new(_settings.RttyShiftHz, _settings.RttyBaud, _settings.RttyReverse, _settings.RttyUnshiftOnSpace);

    /// What the decoder gets: Reverse flipped when the selected receiver is
    /// on an upper sideband, where a normal RTTY signal's mark (the higher
    /// RF tone) comes out as the higher audio tone.
    private RttySettings DecoderRtty => Rtty with { Reverse = Rtty.EffectiveReverse(IsUpperSidebandSource) };

    private bool IsUpperSidebandSource => SourceMode is RigMode.Usb or RigMode.DataUsb;

    /// The selected receiver's mode (null for WebSDR or before the first read).
    private RigMode? SourceMode => _channelSetting switch
    {
        CwAudioChannel.Main => _rigInfo.MainMode,
        CwAudioChannel.Sub => _rigInfo.SubMode,
        _ => null,
    };

    private void ChangeRtty(Action apply, bool changed)
    {
        if (!changed)
        {
            return;
        }
        apply();
        AppSettings.SaveDigi();
        if (_mode == DigiMode.Rtty)
        {
            RebuildDecoder();
        }
        Changed?.Invoke();
    }

    private double SavedCenter(DigiMode mode) => mode.IsPsk() ? _settings.PskCenterHz : _settings.RttyCenterHz;

    // IDigiTxSource

    DigiMode IDigiTxSource.Mode => _mode;
    public double TrackedHz => Meters.TrackedHz;

    // Lifecycle (the window's open/close)

    public bool IsRunning => _running;

    public void Start()
    {
        if (_running)
        {
            return;
        }
        _running = true;
        RebuildDecoder();
        UpdateWebSdrTap();
    }

    public void Stop()
    {
        if (!_running)
        {
            return;
        }
        _running = false;
        StartNewLine();
        UpdateWebSdrTap();
        Changed?.Invoke();
    }

    // Tuning

    /// A click on the strip, or Rig Tones.
    public void SetCenter(double hz)
    {
        var clamped = Math.Clamp(hz, 50, DigiDecoder.StripSpanHz - 50);
        _centerHz = clamped;
        if (_mode.IsPsk())
        {
            _settings.PskCenterHz = clamped;
        }
        else
        {
            _settings.RttyCenterHz = clamped;
        }
        AppSettings.SaveDigi();
        lock (_meterLock)
        {
            _meters = _meters with { TrackedHz = clamped, Quality = 0 };
        }
        Enqueue(new CenterWork(clamped));
        Changed?.Invoke();
    }

    private void RebuildDecoder()
    {
        _generation++;
        ResetMeters();
        Enqueue(new RebuildWork(_mode, DecoderRtty, _centerHz, _settings.Afc, (float)_settings.Squelch));
    }

    private void ResetDecoder()
    {
        _generation++;
        ResetMeters();
        Enqueue(new ResetWork());
        StartNewLine();
    }

    private void ResetMeters()
    {
        lock (_meterLock)
        {
            _meters = _meters with { TrackedHz = _centerHz, Quality = 0 };
        }
    }

    public DigiMeters Meters
    {
        get
        {
            lock (_meterLock)
            {
                return _meters;
            }
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
        var channel = _channel;
        if (!_running || _decodingFile || _pausedForTransmit || sampleRate <= 0 || channel == CwAudioChannel.WebSdr)
        {
            return;
        }
        Enqueue(new SamplesWork(channel == CwAudioChannel.Main ? main : sub, sampleRate, _generation));
    }

    private void IngestWebSdr(float[] samples, int sampleRate)
    {
        if (!_running || _decodingFile || _pausedForTransmit || _channel != CwAudioChannel.WebSdr)
        {
            return;
        }
        Enqueue(new SamplesWork(samples, sampleRate, _generation));
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

    // WebSDR source (its own tap, like the CW receiver's)

    public WebSdrTapPhase WebSdrPhase { get; private set; } = WebSdrTapPhase.Stopped;
    public string? WebSdrFailure { get; private set; }
    public WebSdrState? WebSdr => _lastWebSdrState;

    private void UpdateWebSdrTap()
    {
        if (_running && _channelSetting == CwAudioChannel.WebSdr)
        {
            _webSdrTap ??= new WebSdrAudioTap(IngestWebSdr, (phase, detail) => _dispatcher.TryEnqueue(() =>
            {
                WebSdrPhase = phase;
                WebSdrFailure = detail;
                Changed?.Invoke();
            }));
            RefreshWebSdrState();
            _webSdrTap.Start();
            _webSdrTimer.Start();
        }
        else
        {
            _webSdrTimer.Stop();
            _webSdrTap?.Stop();
        }
    }

    private void RefreshWebSdrState()
    {
        var state = _webSdrState();
        _webSdrTap?.SetTarget(state?.BrowserProcessId);
        if (state != _lastWebSdrState)
        {
            _lastWebSdrState = state;
            Changed?.Invoke();
        }
    }

    // Rig

    public bool IsPausedForTransmit => _pausedForTransmit;

    /// The selected receiver's mode when it isn't one this decoder works in.
    public RigMode? UnsuitableSourceMode =>
        SourceMode is { } mode && !SuitableModes(_mode).Contains(mode) ? mode : null;

    /// RTTY is usually received in the rig's RTTY mode, PSK in DATA-U;
    /// either works in plain SSB too.
    internal static RigMode[] SuitableModes(DigiMode mode) => mode == DigiMode.Rtty
        ? [RigMode.Rtty, RigMode.Lsb, RigMode.Usb, RigMode.DataUsb]
        : [RigMode.DataUsb, RigMode.Usb, RigMode.Lsb];

    /// From MainWindow after every poll and on disconnect.
    public void RigInfoChanged(DigiRigInfo info)
    {
        if (info == _rigInfo)
        {
            return;
        }
        var oldReverse = DecoderRtty.Reverse;
        _rigInfo = info;
        // A sideband change flips the tones: rebuild the RTTY decoder.
        if (_mode == DigiMode.Rtty && _running && DecoderRtty.Reverse != oldReverse)
        {
            RebuildDecoder();
        }
        UpdateTransmitPause();
        Changed?.Invoke();
    }

    /// The RTTY/PSK sender is transmitting (covers the lag before the poll
    /// sees PTT, as with the CW sender).
    public void SetSenderActive(bool active)
    {
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
        // Don't let the first audio after TX finish a half-framed character
        // from before it.
        if (paused && _running)
        {
            ResetDecoder();
        }
    }

    // Files

    public bool IsDecodingFile => _decodingFile;

    /// Pauses live decoding, decodes the file into the same text under a
    /// header line (with the current mode and centre), then live resumes.
    public void DecodeFile(string path)
    {
        if (_decodingFile)
        {
            return;
        }
        _decodingFile = true;
        StartNewLine();
        Append($"— {Path.GetFileName(path)} —\n", transmit: false);
        // A decoder of its own on the worker, so the live one keeps its state.
        Enqueue(new FileWork(path, _mode, DecoderRtty, _centerHz, _settings.Afc, (float)_settings.Squelch));
        Changed?.Invoke();
    }

    // Text

    public IReadOnlyList<DigiTextRun> Runs => _runs;
    public string DecodedText => string.Concat(_runs.Select(r => r.Text));
    public bool HasText => _runs.Count > 0;

    public void ClearText()
    {
        _runs.Clear();
        Changed?.Invoke();
    }

    /// The sender's echo: transmitted characters, shown in their own colour.
    public void AppendTransmitted(string text)
    {
        if (_runs.Count == 0 || !_runs[^1].IsTransmit)
        {
            StartNewLine();
        }
        Append(text, transmit: true);
        Changed?.Invoke();
    }

    private void Append(string text, bool transmit)
    {
        if (text.Length == 0)
        {
            return;
        }
        if (_runs.Count > 0 && _runs[^1].IsTransmit == transmit)
        {
            _runs[^1] = _runs[^1] with { Text = _runs[^1].Text + text };
        }
        else
        {
            _runs.Add(new DigiTextRun(text, transmit));
        }
        Trim();
    }

    private void Trim()
    {
        var total = _runs.Sum(r => r.Text.Length);
        while (total > MaxTextLength && _runs.Count > 0)
        {
            var excess = total - MaxTextLength;
            if (_runs[0].Text.Length <= excess)
            {
                total -= _runs[0].Text.Length;
                _runs.RemoveAt(0);
            }
            else
            {
                _runs[0] = _runs[0] with { Text = _runs[0].Text[excess..] };
                total -= excess;
            }
        }
    }

    private void StartNewLine()
    {
        if (_runs.Count > 0 && _runs[^1].Text.Length > 0 && _runs[^1].Text[^1] != '\n')
        {
            Append("\n", _runs[^1].IsTransmit);
        }
    }

    // Worker

    private void Enqueue(Work work)
    {
        if (_queue.IsAddingCompleted)
        {
            return;
        }
        if (work is SamplesWork)
        {
            // Live audio: drop rather than block the audio thread if the
            // worker ever falls far behind.
            _queue.TryAdd(work);
        }
        else
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
                switch (work)
                {
                    case SamplesWork samples:
                        if (_decoder is { } decoder)
                        {
                            Publish(decoder.Process(samples.Samples, samples.SampleRate), samples.Generation);
                        }
                        break;
                    case RebuildWork rebuild:
                        _decoder = new DigiDecoder(rebuild.Mode, rebuild.Rtty, rebuild.CenterHz, rebuild.Afc, rebuild.Squelch);
                        break;
                    case ResetWork:
                        _decoder?.Reset();
                        break;
                    case CenterWork center:
                        _decoder?.SetCenter(center.Hz);
                        break;
                    case AfcWork afc:
                        _decoder?.SetAfc(afc.On);
                        break;
                    case SquelchWork squelch:
                        _decoder?.SetSquelch(squelch.Value);
                        break;
                    case FileWork file:
                        DecodeFileOnWorker(file);
                        break;
                }
            }
            catch (Exception ex)
            {
                AppLog.Write($"digi-decoder: {ex.Message}");
            }
        }
    }

    private void Publish(DigiDecoderOutput output, int generation)
    {
        if (generation != _generation)
        {
            return;
        }
        lock (_meterLock)
        {
            var serial = _meters.RowSerial;
            var row = _meters.Row;
            if (output.SpectrumRow is { } newRow)
            {
                serial++;
                row = newRow;
            }
            _meters = new DigiMeters(row, serial, output.CenterHz, output.Quality);
        }
        if (output.Text.Length > 0)
        {
            var text = output.Text;
            _dispatcher.TryEnqueue(() =>
            {
                if (generation != _generation)
                {
                    return;
                }
                Append(text, transmit: false);
                Changed?.Invoke();
            });
        }
    }

    private void DecodeFileOnWorker(FileWork work)
    {
        var decoder = new DigiDecoder(work.Mode, work.Rtty, work.CenterHz, work.Afc, work.Squelch);
        string? error = null;
        var text = new StringBuilder();
        try
        {
            using var reader = new MediaFoundationReader(work.Path);
            var provider = reader.ToSampleProvider();
            var channels = provider.WaveFormat.Channels;
            var sampleRate = provider.WaveFormat.SampleRate;
            var buffer = new float[FileChunkFrames * channels];
            int read;
            while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
            {
                var frames = read / channels;
                // The first channel, like the Mac's file path.
                var mono = new float[frames];
                for (var i = 0; i < frames; i++)
                {
                    mono[i] = buffer[i * channels];
                }
                var chunk = decoder.Process(mono, sampleRate).Text;
                if (chunk.Length > 0)
                {
                    _dispatcher.TryEnqueue(() =>
                    {
                        Append(chunk, transmit: false);
                        Changed?.Invoke();
                    });
                }
            }
        }
        catch (Exception ex)
        {
            error = Loc.F("digiReceiver.couldntRead", Path.GetFileName(work.Path), ex.Message);
            AppLog.Write($"digi-decoder: {error}");
        }
        _dispatcher.TryEnqueue(() =>
        {
            StartNewLine();
            _decodingFile = false;
            Changed?.Invoke();
            if (error is not null)
            {
                Error?.Invoke(error);
            }
        });
    }
}
