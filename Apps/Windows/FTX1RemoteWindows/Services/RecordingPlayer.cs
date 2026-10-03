using FTX1RemoteWindows.Settings;
using Microsoft.UI.Dispatching;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace FTX1RemoteWindows.Services;

/// Plays one recording at a time for the Recordings window — the Mac's
/// RecordingPlayer (an AVAudioPlayer). A plain file player on its own WASAPI
/// stream, separate from AudioPlayback's live Main/Sub mix, so a recording
/// plays over (not instead of) the rig.
///
/// Uses the output chosen in Settings → Audio, or Windows' default, like
/// the live audio — and refuses the radio's own USB audio for the same
/// reason live playback does: it would feed the rig's transmit input.
public sealed class RecordingPlayer : IDisposable
{
    private readonly DispatcherQueue _dispatcher;
    private WasapiOut? _output;
    private MMDevice? _device;
    private WaveFileReader? _reader;

    /// The recording playing now, or null. Changes are raised on the UI
    /// thread, including when a file plays to its end.
    public string? PlayingPath { get; private set; }
    public event Action? Changed;

    public RecordingPlayer(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
    }

    /// Returns an error message instead of throwing.
    public string? Play(Recording recording)
    {
        Stop();
        var outputId = AudioPlayback.ResolveOutputId(AppSettings.AudioOutputDeviceId);
        if (outputId is null)
        {
            return "There's no audio output device.";
        }
        var captureId = AppSettings.LocalAudioDeviceId;
        if (captureId.Length > 0 && LocalAudioCapture.IsSameAdapter(captureId, outputId))
        {
            return "The audio output is the radio's own USB audio, which would feed its transmit input. Pick your speakers in Settings → Audio (or as Windows' default output).";
        }
        try
        {
            var reader = new WaveFileReader(recording.Path);
            _reader = reader;
            using (var enumerator = new MMDeviceEnumerator())
            {
                _device = enumerator.GetDevice(outputId);
                var mixRate = _device.AudioClient.MixFormat.SampleRate;
                ISampleProvider chain = reader.ToSampleProvider();
                if (chain.WaveFormat.Channels == 1)
                {
                    chain = new MonoToStereoSampleProvider(chain);
                }
                else if (chain.WaveFormat.Channels > 2)
                {
                    throw new NotSupportedException($"{chain.WaveFormat.Channels}-channel files aren't supported");
                }
                // Resampled here rather than left to WasapiOut, as in AudioPlayback.
                if (chain.WaveFormat.SampleRate != mixRate)
                {
                    chain = new WdlResamplingSampleProvider(chain, mixRate);
                }
                var output = new WasapiOut(_device, AudioClientShareMode.Shared, useEventSync: true, latency: 100);
                output.Init(chain);
                output.PlaybackStopped += (sender, _) => _dispatcher.TryEnqueue(() =>
                {
                    // Only the current output's end clears the state; a
                    // stopped one's late event is ignored.
                    if (ReferenceEquals(sender, _output))
                    {
                        Stop();
                    }
                });
                _output = output;
                output.Play();
            }
            PlayingPath = recording.Path;
            Changed?.Invoke();
            return null;
        }
        catch (Exception ex)
        {
            AppLog.Write($"recordings: couldn't play {recording.Name}: {ex.Message}");
            Stop();
            return $"Couldn't play \"{recording.Name}\": {ex.Message}";
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
        _reader?.Dispose();
        _reader = null;
        if (PlayingPath is not null)
        {
            PlayingPath = null;
            Changed?.Invoke();
        }
    }

    public void Dispose() => Stop();
}
