using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace FTX1RemoteWindows.Services.FreeDv;

/// The FreeDV sender's microphone — the Mac's FreeDVMicrophone: WASAPI
/// shared-mode capture of Settings → Audio → FreeDV microphone ("" =
/// Windows' default recording device), running only while the sender
/// transmits (so Windows' microphone indicator is on only then). Opened afresh
/// for each over, so a device change applies at the next one. Delivers the
/// first channel, at the device's rate, on the capture thread.
public sealed class FreeDvMicrophone(Func<string> deviceId) : IFreeDvMicrophone
{
    private MMDevice? _device;
    private WasapiCapture? _capture;

    /// The device the next over would use: the chosen one while it's active,
    /// or the default when none is chosen. Null if that isn't available (a
    /// chosen device never falls back to another microphone).
    public static string? Resolve(string chosenId)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = Open(enumerator, chosenId);
            return device.State == DeviceState.Active ? device.ID : null;
        }
        catch
        {
            return null;
        }
    }

    private static MMDevice Open(MMDeviceEnumerator enumerator, string id) => id.Length > 0
        ? enumerator.GetDevice(id)
        : enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia);

    public void Start(Action<float[], int> onSamples, Action<string> onFailed)
    {
        Stop();
        var id = Resolve(deviceId()) ?? throw new InvalidOperationException(Loc.S("freeDvMic.notConnected"));
        try
        {
            using (var enumerator = new MMDeviceEnumerator())
            {
                _device = enumerator.GetDevice(id);
            }
            var capture = new WasapiCapture(_device, useEventSync: true, audioBufferMillisecondsLength: 20);
            _capture = capture;
            var format = capture.WaveFormat;
            var reader = LocalAudioCapture.SampleReader(format)
                ?? throw new InvalidOperationException(Loc.F("localAudioCapture.unsupportedCaptureFormatX", format));
            var rate = format.SampleRate;
            var bytesPerFrame = format.BlockAlign;
            capture.DataAvailable += (_, e) =>
            {
                var samples = new float[e.BytesRecorded / bytesPerFrame];
                for (var i = 0; i < samples.Length; i++)
                {
                    samples[i] = reader(e.Buffer, i * bytesPerFrame);
                }
                if (samples.Length > 0 && ReferenceEquals(capture, _capture))
                {
                    onSamples(samples, rate);
                }
            };
            capture.RecordingStopped += (_, e) =>
            {
                // Stop() clears _capture first, so this is only a stop the
                // app didn't ask for.
                if (ReferenceEquals(capture, _capture))
                {
                    var reason = e.Exception is { } ex ? LocalAudioCapture.Describe(ex) : Loc.S("localAudioCapture.captureStopped");
                    AppLog.Write($"freedv-tx: microphone stopped: {reason}");
                    onFailed(Loc.F("freeDvMic.couldntStart", reason));
                }
            };
            capture.StartRecording();
            AppLog.Write($"freedv-tx: microphone started: {_device.FriendlyName} {format}");
        }
        catch (Exception ex)
        {
            Stop();
            throw new InvalidOperationException(Loc.F("freeDvMic.couldntStart", LocalAudioCapture.Describe(ex)), ex);
        }
    }

    public void Stop()
    {
        var capture = _capture;
        _capture = null;
        if (capture is not null)
        {
            try
            {
                capture.StopRecording();
                capture.Dispose();
            }
            catch (Exception ex)
            {
                AppLog.Write($"freedv-tx: microphone stop: {ex.Message}");
            }
        }
        _device?.Dispose();
        _device = null;
    }
}
