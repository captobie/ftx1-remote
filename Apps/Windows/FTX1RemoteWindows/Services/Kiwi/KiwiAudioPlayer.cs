using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace FTX1RemoteWindows.Services;

/// Plays the KiwiSDR's audio (mono, ~11998.9 Hz, no squelch) on the output
/// device chosen under "Out" in the main window, or Windows' default — the
/// Mac's AudioPlaybackEngine as MyKiwiSDR uses it. A small jitter buffer
/// primed to <see cref="TargetSeconds"/> (a Kiwi frame is ~43 ms and the link
/// may cross Tailscale); a backlog above <see cref="MaxBufferedSeconds"/> is
/// dropped back to the target in one step, the Mac's KiwiPlayoutAdjuster
/// "backlog" rule (its slow ±5 ppm crossfaded corrections, worth ~19 ms an
/// hour, are not ported). Volume 0 is mute, so unmuting is immediate.
public sealed class KiwiAudioPlayer : ISampleProvider, IDisposable
{
    public const double TargetSeconds = 0.25;
    public const double MaxBufferedSeconds = 0.55;
    /// Volume changes ramp over ~10 ms instead of stepping.
    private const float GainStepPerSample = 1f / 120f;

    private readonly object _lock = new();
    private readonly float[] _ring;
    private readonly int _targetSamples;
    private readonly int _maxSamples;
    private int _readIndex;
    private int _count;
    private bool _primed;
    private float _volume;
    private float _currentGain;
    private WasapiOut? _output;

    public WaveFormat WaveFormat { get; }

    /// Underruns since the start (the buffer ran dry after being primed).
    public int Underruns { get; private set; }

    public KiwiAudioPlayer(double sampleRate, float volume)
    {
        var rate = (int)Math.Round(sampleRate);
        WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(rate, 1);
        _targetSamples = (int)(rate * TargetSeconds);
        _maxSamples = (int)(rate * MaxBufferedSeconds);
        _ring = new float[_maxSamples * 2];
        _volume = volume;
        _currentGain = volume;
    }

    /// Returns an error message on failure (no output device, in exclusive
    /// use, …) instead of throwing — no audio isn't a reason to drop the
    /// Kiwi session.
    public string? Start(string? outputDeviceId)
    {
        if (_output is not null)
        {
            return null;
        }
        if (outputDeviceId is null)
        {
            return Loc.S("audioPlayback.noAudioOutputDevice");
        }
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var device = enumerator.GetDevice(outputDeviceId);
            var mixRate = device.AudioClient.MixFormat.SampleRate;
            ISampleProvider chain = this;
            if (mixRate != WaveFormat.SampleRate)
            {
                chain = new WdlResamplingSampleProvider(chain, mixRate);
            }
            chain = new MonoToStereoSampleProvider(chain);
            var output = new WasapiOut(device, AudioClientShareMode.Shared, useEventSync: true, latency: 60);
            output.Init(chain);
            output.Play();
            _output = output;
            return null;
        }
        catch (Exception ex)
        {
            AppLog.Write($"kiwisdr: playback failed to start: {ex.Message}");
            return ex.Message;
        }
    }

    public void Stop()
    {
        var output = _output;
        _output = null;
        if (output is not null)
        {
            try
            {
                output.Stop();
            }
            catch
            {
                // Device already gone.
            }
            output.Dispose();
        }
        lock (_lock)
        {
            _count = 0;
            _readIndex = 0;
            _primed = false;
        }
    }

    public void Dispose() => Stop();

    /// 0…1; 0 is silent (mute).
    public float Volume
    {
        get { lock (_lock) { return _volume; } }
        set { lock (_lock) { _volume = value; } }
    }

    /// Seconds of audio queued ahead of the output.
    public double BufferedSeconds
    {
        get { lock (_lock) { return (double)_count / WaveFormat.SampleRate; } }
    }

    /// Queues one chunk (the Kiwi's Int16 samples).
    public void Push(short[] samples)
    {
        lock (_lock)
        {
            foreach (var sample in samples)
            {
                var write = (_readIndex + _count) % _ring.Length;
                _ring[write] = sample / 32768f;
                if (_count < _ring.Length)
                {
                    _count++;
                }
                else
                {
                    _readIndex = (_readIndex + 1) % _ring.Length;
                }
            }
            if (_count > _maxSamples)
            {
                // A stall released a burst: back to the target in one step.
                var drop = _count - _targetSamples;
                _readIndex = (_readIndex + drop) % _ring.Length;
                _count -= drop;
            }
            if (!_primed && _count >= _targetSamples)
            {
                _primed = true;
            }
        }
    }

    public int Read(float[] buffer, int offset, int count)
    {
        lock (_lock)
        {
            for (var i = 0; i < count; i++)
            {
                if (_currentGain < _volume)
                {
                    _currentGain = Math.Min(_volume, _currentGain + GainStepPerSample);
                }
                else if (_currentGain > _volume)
                {
                    _currentGain = Math.Max(_volume, _currentGain - GainStepPerSample);
                }
                if (_primed && _count > 0)
                {
                    buffer[offset + i] = _ring[_readIndex] * _currentGain;
                    _readIndex = (_readIndex + 1) % _ring.Length;
                    _count--;
                }
                else
                {
                    buffer[offset + i] = 0;
                    if (_primed)
                    {
                        // Ran dry: refill to the target before resuming.
                        _primed = false;
                        Underruns++;
                    }
                }
            }
        }
        return count;
    }
}
