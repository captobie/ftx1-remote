using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace FTX1RemoteWindows.Services.FreeDv;

/// Plays FreeDV's decoded speech (mono 16 kHz) on this PC — the Mac's
/// AudioPlaybackEngine(squelchEnabled: false, 16 kHz, 0.25 s prebuffer). Its
/// own WASAPI stream beside the Main/Sub playback, on the same Settings →
/// Audio output device. The device is asked for again whenever it isn't
/// playing (unplugged, or blocked because it is the radio's own audio), at
/// most every few seconds.
///
/// UI thread only, except NAudio reading the queue.
public sealed class FreeDvSpeechPlayer : IFreeDvSpeechOutput
{
    private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(3);

    private readonly Func<(string? DeviceId, string? Blocked)> _resolve;
    private readonly SpeechQueue _queue = new();
    private MMDevice? _device;
    private WasapiOut? _output;
    private long _triedAt;

    /// <param name="resolve">The output device to use now, or why none may be
    /// (MainWindow applies the radio-feedback guard).</param>
    public FreeDvSpeechPlayer(Func<(string? DeviceId, string? Blocked)> resolve)
    {
        _resolve = resolve;
        Open();
    }

    public string? Problem { get; private set; }

    public float Volume
    {
        set => _queue.Volume = value;
    }

    public void Push(float[] speech)
    {
        if (_output is null)
        {
            if (Stopwatch.GetElapsedTime(_triedAt) < RetryDelay)
            {
                return;
            }
            Open();
        }
        if (_output is not null)
        {
            _queue.Push(speech);
        }
    }

    private void Open()
    {
        _triedAt = Stopwatch.GetTimestamp();
        var (deviceId, blocked) = _resolve();
        if (blocked is not null || deviceId is null)
        {
            Problem = blocked ?? Loc.S("audioPlayback.noAudioOutputDevice");
            return;
        }
        try
        {
            using (var enumerator = new MMDeviceEnumerator())
            {
                _device = enumerator.GetDevice(deviceId);
            }
            var mixRate = _device.AudioClient.MixFormat.SampleRate;
            ISampleProvider chain = _queue;
            if (mixRate != RadeDecoder.SpeechSampleRate)
            {
                chain = new WdlResamplingSampleProvider(chain, mixRate);
            }
            chain = new MonoToStereoSampleProvider(chain);
            var output = new WasapiOut(_device, AudioClientShareMode.Shared, useEventSync: true, latency: 60);
            _output = output;
            output.Init(chain);
            output.PlaybackStopped += (sender, e) =>
            {
                // Close() clears _output first, so this is only a stop the
                // app didn't ask for.
                if (!ReferenceEquals(sender, _output))
                {
                    return;
                }
                AppLog.Write($"freedv: playback stopped on its own: {e.Exception?.Message ?? "no error"}");
                Close();
                Problem = Loc.S("audioPlayback.outputDeviceStoppedRetrying");
                _triedAt = Stopwatch.GetTimestamp();
            };
            output.Play();
            Problem = null;
        }
        catch (Exception ex)
        {
            AppLog.Write($"freedv: playback start failed: {ex.Message}");
            Close();
            Problem = ex.Message;
        }
    }

    private void Close()
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
            }
            output.Dispose();
        }
        _device?.Dispose();
        _device = null;
        _queue.Clear();
    }

    public void Dispose() => Close();

    /// Speech waiting to play: starts once a little has built up (decoded
    /// audio comes in 120 ms pieces), and again after running dry.
    private sealed class SpeechQueue : ISampleProvider
    {
        private const int PrimeSamples = RadeDecoder.SpeechSampleRate / 4;
        /// The output's clock isn't the input's: beyond this, drop back to the
        /// prime level rather than let the delay grow.
        private const int MaxSamples = RadeDecoder.SpeechSampleRate * 2;

        private readonly object _lock = new();
        private readonly Queue<float> _samples = new();
        private bool _primed;
        private float _volume = 1;

        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(RadeDecoder.SpeechSampleRate, 1);

        public float Volume
        {
            set
            {
                lock (_lock)
                {
                    _volume = Math.Clamp(value, 0, 1);
                }
            }
        }

        public void Push(float[] speech)
        {
            lock (_lock)
            {
                foreach (var sample in speech)
                {
                    _samples.Enqueue(sample);
                }
                if (_samples.Count > MaxSamples)
                {
                    while (_samples.Count > PrimeSamples)
                    {
                        _samples.Dequeue();
                    }
                }
            }
        }

        public void Clear()
        {
            lock (_lock)
            {
                _samples.Clear();
                _primed = false;
            }
        }

        /// Always fills the whole request (silence where there's no speech),
        /// so the output keeps running between overs.
        public int Read(float[] buffer, int offset, int count)
        {
            lock (_lock)
            {
                if (!_primed && _samples.Count >= PrimeSamples)
                {
                    _primed = true;
                }
                for (var i = 0; i < count; i++)
                {
                    if (_primed && _samples.TryDequeue(out var sample))
                    {
                        buffer[offset + i] = sample * _volume;
                    }
                    else
                    {
                        _primed = false;
                        buffer[offset + i] = 0;
                    }
                }
            }
            return count;
        }
    }
}
