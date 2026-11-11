using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services;

/// The decoders' MyKiwiSDR source: the MyKiwiSDR window's decoded Kiwi audio,
/// handed straight from LocalSdrModel to the CW and RTTY/PSK receivers — the
/// Mac's LocalSDRAudioSource. Unlike the WebSDR source there is no page output
/// to tap: the samples come from the client before the window's volume and
/// mute, at the rate the Kiwi reports (~11998.9 Hz; both decoders resample).
///
/// Consumers register (IsWanted, OnSamples) and call <see cref="Update"/> when
/// their answer may have changed. The producer checks <see cref="IsWanted"/>
/// before converting each frame, so nothing is done per frame while no decoder
/// listens. <see cref="Changed"/> fires only on transitions (status, mode).
/// Never connects anything: picking the source while the MyKiwiSDR window is
/// closed or disconnected just shows NotConnected.
///
/// UI thread only.
public sealed class LocalSdrAudioSource
{
    public enum SourceStatus
    {
        /// No MyKiwiSDR session (window closed, or not connected yet).
        NotConnected,
        Receiving,
        /// Connected, but next to nothing arriving for a while.
        Silent,
    }

    private sealed record Consumer(Func<bool> IsWanted, Action<float[], int> OnSamples);

    /// Silence: below −80 dBFS for 3 s, as the WebSDR source's.
    private const float SilenceThreshold = 1e-4f;
    private static readonly TimeSpan SilenceDuration = TimeSpan.FromSeconds(3);

    private readonly Dictionary<string, Consumer> _consumers = [];
    private double? _sampleRate;
    private DateTime? _quietSince;

    public SourceStatus Status { get; private set; } = SourceStatus.NotConnected;

    /// The Kiwi's demodulation as a rig mode while connected, null otherwise.
    public RigMode? Mode { get; private set; }

    /// Status or mode changed.
    public event Action? Changed;

    /// Whether any decoder is listening — the producer skips its per-frame
    /// work while none is.
    public bool IsWanted { get; private set; }

    public void AddConsumer(string id, Func<bool> isWanted, Action<float[], int> onSamples)
    {
        _consumers[id] = new Consumer(isWanted, onSamples);
        Update();
    }

    public void Update()
    {
        var wanted = _consumers.Values.Any(c => c.IsWanted());
        // Silence is only tracked while frames are delivered.
        if (wanted && !IsWanted)
        {
            _quietSince = null;
        }
        IsWanted = wanted;
    }

    // Producer (LocalSdrModel)

    /// The Kiwi's audio is ready at sampleRate.
    public void SessionStarted(double sampleRate, KiwiSdrMode mode)
    {
        _sampleRate = sampleRate;
        _quietSince = null;
        SetStatus(SourceStatus.Receiving);
        ModeChanged(mode);
    }

    public void ModeChanged(KiwiSdrMode kiwiMode)
    {
        if (_sampleRate is null)
        {
            return;
        }
        var rigMode = kiwiMode.ToRigMode();
        if (Mode != rigMode)
        {
            Mode = rigMode;
            Changed?.Invoke();
        }
    }

    /// Disconnect, a dropped connection, or the window closing.
    public void SessionEnded()
    {
        _sampleRate = null;
        _quietSince = null;
        var changed = Mode is not null;
        Mode = null;
        if (!SetStatus(SourceStatus.NotConnected) && changed)
        {
            Changed?.Invoke();
        }
    }

    /// One Kiwi frame, before volume/mute. Call only while <see cref="IsWanted"/>.
    public void Deliver(short[] pcm)
    {
        if (_sampleRate is not { } rate || pcm.Length == 0)
        {
            return;
        }
        var samples = new float[pcm.Length];
        for (var i = 0; i < pcm.Length; i++)
        {
            samples[i] = pcm[i] / 32768f;
        }
        TrackSilence(samples);
        // The arrays are queued by the receivers as they are: one copy each.
        foreach (var consumer in _consumers.Values.Where(c => c.IsWanted()).ToList())
        {
            consumer.OnSamples((float[])samples.Clone(), (int)Math.Round(rate));
        }
    }

    private void TrackSilence(float[] samples)
    {
        var peak = 0f;
        foreach (var sample in samples)
        {
            peak = Math.Max(peak, Math.Abs(sample));
        }
        if (peak > SilenceThreshold)
        {
            _quietSince = null;
            SetStatus(SourceStatus.Receiving);
        }
        else if (_quietSince is { } since)
        {
            if (DateTime.UtcNow - since >= SilenceDuration)
            {
                SetStatus(SourceStatus.Silent);
            }
        }
        else
        {
            _quietSince = DateTime.UtcNow;
        }
    }

    private bool SetStatus(SourceStatus status)
    {
        if (Status == status)
        {
            return false;
        }
        Status = status;
        Changed?.Invoke();
        return true;
    }
}
