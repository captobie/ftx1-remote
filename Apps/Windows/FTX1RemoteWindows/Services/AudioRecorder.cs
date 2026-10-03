namespace FTX1RemoteWindows.Services;

/// The CW page's RECORD — the Mac's AudioRecorder: writes the rig's Main
/// audio (the same routed channel the waterfall, APRS and CW decoders get,
/// so it follows a Main/Sub swap) to a WAV in Recordings. The Recordings
/// window (the CW page's PLAY) browses what this writes.
///
/// 16-bit PCM at the audio source's rate (44.1 kHz from the Pi, the input
/// device's rate in Local mode), ~5.3 MB/min — the Mac writes 32-bit float,
/// but 16 bits is plenty for receive audio and halves the size. The file is
/// created on the first block after Start, as on the Mac, since only the
/// audio path knows the rate; MainWindow stops a recording when the audio
/// stops, so one file never mixes two sources' rates.
///
/// Ingest runs on the audio source's thread and writes there (a 2048-sample
/// block about 21 times a second); Start/Stop run on the UI thread. The
/// lock keeps Stop from finishing the file under a write.
public sealed class AudioRecorder
{
    private readonly object _lock = new();
    private SdrAudioFileWriter? _writer;
    private byte[] _buffer = [];

    public bool IsRecording
    {
        get
        {
            lock (_lock)
            {
                return _writer is not null;
            }
        }
    }

    /// The file being written, for the Recordings window (null while not
    /// recording).
    public string? CurrentPath
    {
        get
        {
            lock (_lock)
            {
                return _writer?.Path;
            }
        }
    }

    /// <paramref name="label"/> is the frequency/mode when recording starts
    /// ("147.380.000 FM"), folded into the file name like the Mac's.
    public void Start(string label)
    {
        lock (_lock)
        {
            if (_writer is not null)
            {
                return;
            }
            _writer = new SdrAudioFileWriter(Recordings.NewRecordingPath(label, DateTime.Now), "audio-recorder");
        }
        AppLog.Write($"audio-recorder: started ({label})");
    }

    /// Finishes the file. Returns its path, or null if no audio arrived
    /// (nothing is left on disk then).
    public string? Stop()
    {
        SdrAudioFileWriter? writer;
        string? path;
        lock (_lock)
        {
            writer = _writer;
            _writer = null;
            path = writer?.Finish();
        }
        if (writer is not null)
        {
            AppLog.Write(path is null
                ? "audio-recorder: stopped, no audio arrived — nothing saved"
                : $"audio-recorder: saved {Path.GetFileName(path)}");
        }
        return path;
    }

    /// From the audio route, unconditionally — a cheap no-op while not
    /// recording.
    public void Ingest(float[] samples, int sampleRate)
    {
        if (Volatile.Read(ref _writer) is null || samples.Length == 0)
        {
            return;
        }
        lock (_lock)
        {
            if (_writer is not { } writer)
            {
                return;
            }
            var bytes = samples.Length * 2;
            if (_buffer.Length != bytes)
            {
                _buffer = new byte[bytes];
            }
            for (var i = 0; i < samples.Length; i++)
            {
                var value = (short)Math.Round(Math.Clamp(samples[i], -1f, 1f) * short.MaxValue);
                _buffer[2 * i] = (byte)value;
                _buffer[2 * i + 1] = (byte)(value >> 8);
            }
            writer.Append(_buffer, sampleRate);
        }
    }
}
