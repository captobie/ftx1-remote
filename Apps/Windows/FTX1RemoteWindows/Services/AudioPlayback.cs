using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace FTX1RemoteWindows.Services;

/// Plays the rig's Main and Sub audio on the default Windows output device.
/// Both channels are mixed into one WASAPI shared-mode stream, not two
/// separate outputs like the Mac's two AVAudioEngines — one device stream
/// is simpler here and each channel still has its own mute/volume/squelch.
/// Like the Mac, both play centered, not panned L/R.
///
/// Resamples the source's rate to the output device's mix rate itself (WDL resampler)
/// rather than leaving it to WasapiOut, so the path doesn't depend on
/// whichever fallback WasapiOut would pick for an unsupported format.
public sealed class AudioPlayback : IDisposable
{
    public ChannelPlayer Main { get; }
    public ChannelPlayer Sub { get; }

    private WasapiOut? _output;

    public AudioPlayback(ChannelPlayer main, ChannelPlayer sub)
    {
        Main = main;
        Sub = sub;
    }

    public bool IsRunning => _output is not null;

    /// Returns an error message on failure (no output device, device in
    /// exclusive use, ...) instead of throwing — no audio isn't a reason to
    /// fail the rig connection.
    /// <paramref name="sampleRate"/> is the rate of the samples the audio
    /// source will push (<see cref="IAudioSource.SampleRate"/>).
    public string? Start(int sampleRate)
    {
        if (_output is not null)
        {
            return null;
        }
        Main.Configure(sampleRate);
        Sub.Configure(sampleRate);
        try
        {
            int mixRate;
            using (var enumerator = new MMDeviceEnumerator())
            using (var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia))
            {
                mixRate = device.AudioClient.MixFormat.SampleRate;
            }

            var mixer = new MixingSampleProvider(WaveFormat.CreateIeeeFloatWaveFormat(sampleRate, 1))
            {
                ReadFully = true,
            };
            mixer.AddMixerInput(Main);
            mixer.AddMixerInput(Sub);

            ISampleProvider chain = mixer;
            if (mixRate != sampleRate)
            {
                chain = new WdlResamplingSampleProvider(chain, mixRate);
            }
            chain = new MonoToStereoSampleProvider(chain);

            var output = new WasapiOut(AudioClientShareMode.Shared, useEventSync: true, latency: 60);
            output.Init(chain);
            output.Play();
            _output = output;
            Debug.WriteLine($"audio-playback: started, device mix rate {mixRate} Hz");
            return null;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"audio-playback: start failed: {ex}");
            Stop();
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
            }
            output.Dispose();
        }
        Main.Reset();
        Sub.Reset();
    }

    public void Dispose() => Stop();
}
