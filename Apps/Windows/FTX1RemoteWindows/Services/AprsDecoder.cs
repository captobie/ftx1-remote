using System.Collections.Concurrent;
using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services;

/// Runs the AFSK → AX.25 → APRS pipeline on one audio channel — the Mac's
/// APRSDecoder (Apps/Mac/FTX1RemoteMac/APRSDecoder.swift). MainWindow hands
/// it chunks from the audio thread only while that channel's gate is open
/// (APRS on, VFO within tolerance of the APRS frequency); the DSP runs on
/// this decoder's own worker thread, so neither the audio thread nor the UI
/// waits on it. Decoded packets are raised on that worker thread — the
/// caller marshals them to the UI.
public sealed class AprsDecoder : IDisposable
{
    /// A station heard: position/symbol/comment are null when the packet
    /// didn't carry them (a status report has only a comment, a message or
    /// unparsed packet nothing), and AprsStore leaves null fields unchanged.
    public event Action<string, double?, double?, string?, string?, string?>? StationHeard;
    /// (from, to, text, message id).
    public event Action<string, string, string, string?>? MessageReceived;

    private readonly string _name;
    private readonly BlockingCollection<(float[] Samples, int SampleRate)> _queue = new(boundedCapacity: 256);
    private readonly Thread _worker;

    private AfskDemodulator? _demodulator;
    private int _demodulatorSampleRate;
    private Ax25FrameDecoder _frameDecoder = new();
    private readonly List<bool> _lineBits = [];
    private int _samplesSinceHeartbeat;

    /// <param name="name">"main"/"sub", for the log.</param>
    public AprsDecoder(string name)
    {
        _name = name;
        _worker = new Thread(Run) { IsBackground = true, Name = $"APRS decoder ({name})" };
        _worker.Start();
    }

    /// Cheap for the audio thread: queues the chunk (a fresh array from the
    /// audio source, not reused) and returns. If the worker ever falls ~12 s
    /// behind, chunks are dropped rather than queued without bound.
    public void Process(float[] samples, int sampleRate)
    {
        if (!_queue.IsAddingCompleted)
        {
            _queue.TryAdd((samples, sampleRate));
        }
    }

    public void Dispose() => _queue.CompleteAdding();

    private void Run()
    {
        foreach (var (samples, sampleRate) in _queue.GetConsumingEnumerable())
        {
            try
            {
                ProcessOnWorker(samples, sampleRate);
            }
            catch (Exception ex)
            {
                AppLog.Write($"aprs-decoder ({_name}): {ex.Message}");
            }
        }
    }

    private void ProcessOnWorker(float[] samples, int sampleRate)
    {
        // A new source (or device) means a new rate; the tone detector and
        // bit clock are tuned to one rate, so start over. The audio sources
        // here report integer rates, so the Mac's 0.5 Hz jitter tolerance
        // isn't needed.
        if (_demodulator is null || sampleRate != _demodulatorSampleRate)
        {
            AppLog.Write($"aprs-decoder ({_name}): demodulator (re)initialized at {sampleRate} Hz");
            _demodulator = new AfskDemodulator(sampleRate);
            _frameDecoder = new Ax25FrameDecoder();
            _demodulatorSampleRate = sampleRate;
        }

        _lineBits.Clear();
        _demodulator.Process(samples, _lineBits);
        foreach (var frame in _frameDecoder.Process(_lineBits))
        {
            AppLog.Write($"aprs-decoder ({_name}): frame from {frame.Source.DisplayString}");
            Handle(frame);
        }

        // Every ~30 s of audio (the Mac logs every 5 s, at debug level, which
        // app.log has no equivalent of), with cumulative stats: tells "no signal
        // reaching the decoder" (flags ~0) from "signal, but corrupt" (flags
        // and CRC/destuff failures climbing, nothing decoded).
        _samplesSinceHeartbeat += samples.Length;
        if (_samplesSinceHeartbeat >= sampleRate * 30)
        {
            _samplesSinceHeartbeat = 0;
            var s = _frameDecoder.Stats;
            AppLog.Write($"aprs-decoder ({_name}): heartbeat — flags:{s.FlagsFound} destuffFail:{s.DestuffFailures} tooShort:{s.TooShortFailures} crcFail:{s.CrcFailures} addrFail:{s.AddressParseFailures} decoded:{s.FramesDecoded}");
        }
    }

    private void Handle(Ax25Frame frame)
    {
        var source = frame.Source.DisplayString;
        var packet = AprsPacket.Parse(frame.Info);
        switch (packet)
        {
            case AprsPacket.Position p:
                StationHeard?.Invoke(source, p.Latitude, p.Longitude, p.SymbolTable, p.SymbolCode, p.Comment);
                break;
            case AprsPacket.Status s:
                StationHeard?.Invoke(source, null, null, null, null, s.Text);
                break;
            default:
                StationHeard?.Invoke(source, null, null, null, null, null);
                break;
        }
        if (packet is AprsPacket.Message m)
        {
            MessageReceived?.Invoke(source, m.To, m.Text, m.MessageId);
        }
    }
}
