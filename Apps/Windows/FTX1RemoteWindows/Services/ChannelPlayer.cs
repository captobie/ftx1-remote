using NAudio.Wave;

namespace FTX1RemoteWindows.Services;

/// One receiver's playback path (Main or Sub): a small jitter buffer, the
/// virtual squelch, volume and mute. The Windows counterpart of one of the
/// Mac's two AudioPlaybackEngine instances (HubService.mainAudioPlayback/
/// subAudioPlayback), but as an NAudio sample provider so
/// <see cref="AudioPlayback"/> can mix both into a single output.
///
/// <see cref="Push"/> runs on the network thread, <see cref="Read"/> on
/// NAudio's playback thread; everything shared between them is under
/// <see cref="_lock"/>.
public sealed class ChannelPlayer : ISampleProvider
{
    /// Buffered before playback starts (and again after any underrun) —
    /// absorbs ordinary Tailscale jitter. Same 120 ms as the Mac's
    /// AudioPlaybackEngine.prebufferTargetSeconds.
    private const double PrimeSeconds = 0.12;
    /// Above this much buffered audio, the oldest is dropped back down to
    /// the prime level. The Pi's sound card and this PC's don't share a
    /// clock, and a network stall releases a burst — without a cap, latency
    /// would creep up for the whole session.
    private const double MaxBufferedSeconds = 0.5;
    /// Gain changes (mute, volume, squelch opening/closing) ramp over
    /// ~10 ms instead of stepping, so they don't click.
    private const float GainStepPerSample = 1f / 441f;

    private readonly object _lock = new();
    private readonly float[] _ring;
    private int _readIndex;
    private int _count;
    private bool _primed;
    private readonly int _primeSamples;
    private readonly int _maxSamples;

    private readonly SquelchGate _gate;
    private float _volume;
    private bool _muted;
    private float _currentGain;

    public ChannelPlayer(float volume, float squelchThreshold, bool muted)
    {
        WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(RemoteAudioStreamClient.SampleRate, 1);
        _ring = new float[RemoteAudioStreamClient.SampleRate];
        _primeSamples = (int)(RemoteAudioStreamClient.SampleRate * PrimeSeconds);
        _maxSamples = (int)(RemoteAudioStreamClient.SampleRate * MaxBufferedSeconds);
        _gate = new SquelchGate(squelchThreshold);
        _volume = volume;
        _muted = muted;
    }

    public WaveFormat WaveFormat { get; }

    public float Volume
    {
        get { lock (_lock) return _volume; }
        set { lock (_lock) _volume = Math.Clamp(value, 0f, 1f); }
    }

    public float SquelchThreshold
    {
        get { lock (_lock) return _gate.Threshold; }
        set { lock (_lock) _gate.Threshold = value; }
    }

    /// Gates output only — samples keep flowing and the gate keeps updating
    /// while muted, same as the Mac's mute toggles (which don't stop/start
    /// the engine either), so unmuting is instant.
    public bool IsMuted
    {
        get { lock (_lock) return _muted; }
        set { lock (_lock) _muted = value; }
    }

    public bool IsSquelchOpen
    {
        get { lock (_lock) return _gate.IsOpen; }
    }

    public void Push(float[] samples)
    {
        var rms = SquelchGate.Rms(samples);
        lock (_lock)
        {
            _gate.Update(rms);
            foreach (var s in samples)
            {
                if (_count == _ring.Length)
                {
                    _readIndex = (_readIndex + 1) % _ring.Length;
                    _count--;
                }
                _ring[(_readIndex + _count) % _ring.Length] = s;
                _count++;
            }
            if (_count > _maxSamples)
            {
                var drop = _count - _primeSamples;
                _readIndex = (_readIndex + drop) % _ring.Length;
                _count -= drop;
            }
        }
    }

    public void Reset()
    {
        lock (_lock)
        {
            _readIndex = 0;
            _count = 0;
            _primed = false;
        }
    }

    /// Always fills the whole request (silence where there's no audio) —
    /// the mixer upstream expects a continuous source.
    public int Read(float[] buffer, int offset, int count)
    {
        lock (_lock)
        {
            if (!_primed && _count >= _primeSamples)
            {
                _primed = true;
            }
            var target = _muted || !_gate.IsOpen ? 0f : _volume;
            for (var i = 0; i < count; i++)
            {
                float sample = 0;
                if (_primed)
                {
                    if (_count > 0)
                    {
                        sample = _ring[_readIndex];
                        _readIndex = (_readIndex + 1) % _ring.Length;
                        _count--;
                    }
                    else
                    {
                        // Underrun: go back to buffering so the next audio
                        // doesn't play sample-by-sample as it trickles in.
                        _primed = false;
                    }
                }
                if (_currentGain < target)
                {
                    _currentGain = Math.Min(target, _currentGain + GainStepPerSample);
                }
                else if (_currentGain > target)
                {
                    _currentGain = Math.Max(target, _currentGain - GainStepPerSample);
                }
                buffer[offset + i] = sample * _currentGain;
            }
        }
        return count;
    }
}
