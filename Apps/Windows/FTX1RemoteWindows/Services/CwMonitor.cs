using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace FTX1RemoteWindows.Services;

/// The CW window's Monitor — the Mac's CWMonitor (Apps/Mac/FTX1RemoteMac/
/// CWMonitor.swift): a local sidetone for what the send pane keys. With the
/// rig remote (on the Pi) there's nothing to hear while its keyer memory
/// plays, so each chunk <see cref="CwSender"/> plays is synthesized here at
/// the rig's keyer speed and CW pitch ("KS"/"KP") and played on the audio
/// output (Settings → Audio, same device as the rig's receive audio).
///
/// It's a model of the keying, not a copy of it: PARIS timing from
/// <see cref="CwText.Keying"/>, started when the play command is sent, so
/// it runs a network hop ahead of the rig and ignores the rig's weighting.
/// Stop cuts it off with the rig. Not for the CW Key interface, which has
/// its own sidetone. UI thread only.
public sealed class CwMonitor
{
    /// The rig's default pitch, used until "KP" has been read.
    private const int DefaultPitchHz = 700;
    private const float Level = 0.25f;
    /// Rise/fall time, so elements don't click.
    private const double RampSeconds = 0.005;

    private readonly DispatcherQueue _dispatcher;
    private WasapiOut? _output;
    private MMDevice? _device;

    public CwMonitor(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
    }

    public bool IsEnabled
    {
        get => AppSettings.CwMonitor;
        set
        {
            if (value == AppSettings.CwMonitor)
            {
                return;
            }
            AppSettings.CwMonitor = value;
            if (!value)
            {
                Stop();
            }
        }
    }

    /// A chunk the rig is starting to key, or null when keying was stopped
    /// (<see cref="CwSender.Keying"/>).
    public void Handle(CwKeyingChunk? chunk)
    {
        if (chunk is null)
        {
            Stop();
            return;
        }
        if (IsEnabled)
        {
            Play(chunk);
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
            }
            output.Dispose();
        }
        _device?.Dispose();
        _device = null;
    }

    private void Play(CwKeyingChunk chunk)
    {
        Stop();
        var outputId = AudioPlayback.ResolveOutputId(AppSettings.AudioOutputDeviceId);
        if (outputId is null)
        {
            AppLog.Write("cw-monitor: no audio output device");
            return;
        }
        // Never into the rig's own USB audio (its transmit input), as for
        // recordings.
        var captureId = AppSettings.LocalAudioDeviceId;
        if (captureId.Length > 0 && LocalAudioCapture.IsSameAdapter(captureId, outputId))
        {
            AppLog.Write("cw-monitor: the audio output is the radio's own USB audio; not playing");
            return;
        }
        try
        {
            using (var enumerator = new MMDeviceEnumerator())
            {
                _device = enumerator.GetDevice(outputId);
            }
            var rate = _device.AudioClient.MixFormat.SampleRate;
            var samples = Render(chunk, rate);
            if (samples.Length == 0)
            {
                Stop();
                return;
            }
            ISampleProvider chain = new ArraySampleProvider(samples, rate);
            chain = new MonoToStereoSampleProvider(chain);
            var output = new WasapiOut(_device, AudioClientShareMode.Shared, useEventSync: true, latency: 60);
            output.Init(chain);
            output.PlaybackStopped += (sender, _) => _dispatcher.TryEnqueue(() =>
            {
                // Let the device go once the chunk is done, unless another
                // one started in the meantime.
                if (ReferenceEquals(sender, _output))
                {
                    Stop();
                }
            });
            _output = output;
            output.Play();
        }
        catch (Exception ex)
        {
            AppLog.Write($"cw-monitor: couldn't play: {ex.Message}");
            Stop();
        }
    }

    /// The chunk as a tone keyed on and off, with raised-cosine edges.
    private static float[] Render(CwKeyingChunk chunk, int rate)
    {
        var samplesPerUnit = (int)(1.2 / Math.Max(chunk.Wpm, 4) * rate);
        var runs = CwText.Keying(chunk.Text);
        var samples = new float[runs.Sum(run => run.Units) * samplesPerUnit];
        var step = 2 * Math.PI * (chunk.PitchHz ?? DefaultPitchHz) / rate;
        var ramp = Math.Max((int)(RampSeconds * rate), 1);
        var position = 0;
        foreach (var (down, units) in runs)
        {
            var length = units * samplesPerUnit;
            if (down)
            {
                var rampLength = Math.Min(ramp, length / 2);
                for (var index = 0; index < length; index++)
                {
                    var gain = Level;
                    if (index < rampLength)
                    {
                        gain *= (float)(0.5 - 0.5 * Math.Cos(Math.PI * index / rampLength));
                    }
                    else if (index >= length - rampLength)
                    {
                        gain *= (float)(0.5 - 0.5 * Math.Cos(Math.PI * (length - index) / rampLength));
                    }
                    samples[position + index] = gain * (float)Math.Sin(step * (position + index));
                }
            }
            position += length;
        }
        return samples;
    }

    /// Plays a rendered buffer once, then ends (so WasapiOut stops).
    private sealed class ArraySampleProvider(float[] samples, int rate) : ISampleProvider
    {
        private int _position;

        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(rate, 1);

        public int Read(float[] buffer, int offset, int count)
        {
            var available = Math.Min(count, samples.Length - _position);
            Array.Copy(samples, _position, buffer, offset, available);
            _position += available;
            return available;
        }
    }
}
