using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace FTX1RemoteWindows.Services;

/// Plays the rig's Main and Sub audio on the output device chosen under
/// "Out" in the window, or Windows' default output.
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
    private MMDevice? _device;

    /// Active output devices, for the picker.
    public static List<(string Id, string Name)> ListOutputDevices()
    {
        var result = new List<(string, string)>();
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            {
                result.Add((device.ID, device.FriendlyName));
                device.Dispose();
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"audio-playback: device enumeration failed: {ex.Message}");
        }
        return result;
    }

    /// The output device playback would use for <paramref name="chosenId"/>:
    /// that device while it's active, otherwise (empty = "Windows default",
    /// or unplugged) the current default output. Null if there's no output
    /// device at all.
    public static string? ResolveOutputId(string chosenId)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            if (chosenId.Length > 0)
            {
                try
                {
                    using var chosen = enumerator.GetDevice(chosenId);
                    if (chosen.State == DeviceState.Active)
                    {
                        return chosen.ID;
                    }
                }
                catch
                {
                    // Removed since it was picked — fall back to default.
                }
            }
            using var fallback = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            return fallback.ID;
        }
        catch
        {
            return null;
        }
    }

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
    /// source will push (<see cref="IAudioSource.SampleRate"/>);
    /// <paramref name="outputDeviceId"/> comes from <see cref="ResolveOutputId"/>.
    /// Playback stays on that device even if Windows' default changes later.
    public string? Start(int sampleRate, string? outputDeviceId)
    {
        if (_output is not null)
        {
            return null;
        }
        Main.Configure(sampleRate);
        Sub.Configure(sampleRate);
        try
        {
            if (outputDeviceId is null)
            {
                return "no audio output device";
            }
            using (var enumerator = new MMDeviceEnumerator())
            {
                _device = enumerator.GetDevice(outputDeviceId);
            }
            var mixRate = _device.AudioClient.MixFormat.SampleRate;

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

            var output = new WasapiOut(_device, AudioClientShareMode.Shared, useEventSync: true, latency: 60);
            output.Init(chain);
            output.Play();
            _output = output;
            Debug.WriteLine($"audio-playback: started on {_device.FriendlyName}, mix rate {mixRate} Hz");
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
        _device?.Dispose();
        _device = null;
        Main.Reset();
        Sub.Reset();
    }

    public void Dispose() => Stop();
}
