using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using FTX1RemoteWindows.Services.Hub;

namespace FTX1RemoteWindows.Services;

/// Local mode's transmit audio for the Desktop hub (Apps/Windows/README.md,
/// "Desktop hub for the iPad", phase 5): plays an iPad's microphone into
/// the rig's USB audio input — the Settings → Audio "Transmit audio output"
/// device — the Mac's pass-through AudioPlaybackEngine(squelchEnabled:
/// false) on TXAudioOutputSettings. No squelch, no volume. One instance per
/// transmission: playback starts once <see cref="Prebuffer"/> has arrived
/// (network jitter), and <see cref="Finish"/> lets the buffer play out
/// before closing the device.
public sealed class LocalTxAudioPlayer : ITxAudioSink
{
    private static readonly TimeSpan Prebuffer = TimeSpan.FromMilliseconds(60);
    /// The longest Finish waits for the buffer to drain.
    private static readonly TimeSpan MaxTail = TimeSpan.FromSeconds(1);

    private readonly BufferedWaveProvider _buffer = new(new WaveFormat(8000, 16, 1))
    {
        BufferDuration = TimeSpan.FromSeconds(2),
        DiscardOnBufferOverflow = true,
        ReadFully = true,
    };
    private readonly MMDevice _device;
    private readonly WasapiOut _output;
    private bool _playing;
    private bool _finished;
    private int _closed;

    private LocalTxAudioPlayer(MMDevice device)
    {
        _device = device;
        var mix = device.AudioClient.MixFormat;
        ISampleProvider chain = _buffer.ToSampleProvider();
        if (mix.SampleRate != 8000)
        {
            chain = new WdlResamplingSampleProvider(chain, mix.SampleRate);
        }
        if (mix.Channels >= 2)
        {
            chain = new MonoToStereoSampleProvider(chain);
        }
        _output = new WasapiOut(device, AudioClientShareMode.Shared, useEventSync: true, latency: 60);
        _output.Init(chain);
    }

    /// Opens <paramref name="deviceId"/>, or says why not. An empty id is
    /// "none": never Windows' default output, which could be the speakers
    /// (or the rig, without anyone meaning to transmit through it).
    public static LocalTxAudioPlayer? Open(string deviceId, string deviceName, out string? error)
    {
        error = null;
        if (deviceId.Length == 0)
        {
            error = "no Transmit audio output device set (Settings → Audio)";
            return null;
        }
        MMDevice? device = null;
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            device = enumerator.GetDevice(deviceId);
            if (device.State != DeviceState.Active)
            {
                error = $"Transmit audio output \"{deviceName}\" isn't connected";
                device.Dispose();
                return null;
            }
            var player = new LocalTxAudioPlayer(device);
            AppLog.Write($"tx-audio: playing to {device.FriendlyName} (mix rate {device.AudioClient.MixFormat.SampleRate} Hz)");
            return player;
        }
        catch (Exception ex)
        {
            device?.Dispose();
            error = $"Transmit audio output \"{deviceName}\" couldn't be opened: {ex.Message}";
            return null;
        }
    }

    public void Send(byte[] pcm)
    {
        if (_finished)
        {
            return;
        }
        _buffer.AddSamples(pcm, 0, pcm.Length);
        if (!_playing && _buffer.BufferedDuration >= Prebuffer)
        {
            StartPlaying();
        }
    }

    public void Finish()
    {
        if (_finished)
        {
            return;
        }
        _finished = true;
        if (!_playing && _buffer.BufferedBytes > 0)
        {
            StartPlaying();
        }
        _ = Task.Run(async () =>
        {
            // The iPad unkeys ~300 ms after release; this is the prebuffer's
            // tail.
            var deadline = DateTime.UtcNow + MaxTail;
            while (_buffer.BufferedBytes > 0 && DateTime.UtcNow < deadline)
            {
                await Task.Delay(20);
            }
            await Task.Delay(80);
            Close();
        });
    }

    private void StartPlaying()
    {
        try
        {
            _output.Play();
            _playing = true;
        }
        catch (Exception ex)
        {
            AppLog.Write($"tx-audio: playback start failed: {ex.Message}");
            _finished = true;
            Close();
        }
    }

    private void Close()
    {
        if (Interlocked.Exchange(ref _closed, 1) != 0)
        {
            return;
        }
        try
        {
            _output.Stop();
        }
        catch
        {
        }
        _output.Dispose();
        _device.Dispose();
    }
}
