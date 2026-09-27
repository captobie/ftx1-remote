using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace FTX1RemoteWindows.Services;

/// Local mode's audio source: captures the rig's USB audio from a sound-card
/// input on this PC (the FTX-1's own codec shows up as a Windows recording
/// device) with WASAPI shared mode, at whatever rate/format the device runs
/// at. The Windows counterpart of the Mac's .local AVAudioEngine tap.
///
/// The FTX-1's USB audio is stereo with dual-VFO display: Main left, Sub
/// right (see root CLAUDE.md, "Dual Main/Sub audio channels"). Windows only
/// delivers both if the recording device's format is 2-channel (Sound
/// settings → the device → Advanced). A mono device gives Main only and Sub
/// stays silent — reported through <see cref="AudioLinkStatus.Detail"/>.
///
/// Delivers chunks of 2048 samples per channel like the Pi client, not
/// WASAPI's own ~10 ms buffers: the squelch gate judges one chunk's RMS at
/// a time and was tuned on chunks that size.
///
/// If the device is missing or capture stops with an error (unplugged,
/// radio powered off), it retries every few seconds.
public sealed class LocalAudioCapture : IAudioSource
{
    private const int SamplesPerChunk = 2048;
    private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan StallThreshold = TimeSpan.FromSeconds(2);

    private readonly string _deviceId;
    private readonly Action<float[], float[]> _onSamples;

    private CancellationTokenSource? _cts;
    private Task? _loopTask;

    private readonly object _statusLock = new();
    private AudioLinkPhase _phase = AudioLinkPhase.Stopped;
    private string? _detail;
    private bool _capturing;
    private long _lastDataTicks;
    private float _leftRms;
    private float _rightRms;

    private readonly float[] _left = new float[SamplesPerChunk];
    private readonly float[] _right = new float[SamplesPerChunk];
    private int _filled;

    public LocalAudioCapture(string deviceId, Action<float[], float[]> onSamples)
    {
        _deviceId = deviceId;
        _onSamples = onSamples;
        // Known before capture starts so playback can be set up at the same
        // rate; the retry loop keeps using this device's shared-mode rate.
        using var enumerator = new MMDeviceEnumerator();
        using var device = enumerator.GetDevice(deviceId);
        SampleRate = device.AudioClient.MixFormat.SampleRate;
    }

    public int SampleRate { get; }

    /// Active capture devices, for the picker.
    public static List<(string Id, string Name)> ListDevices()
    {
        var result = new List<(string, string)>();
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            {
                result.Add((device.ID, device.FriendlyName));
                device.Dispose();
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"local-audio: device enumeration failed: {ex.Message}");
        }
        return result;
    }

    /// True when <paramref name="renderDeviceId"/> is the same audio adapter
    /// as <paramref name="captureDeviceId"/> — for the FTX-1's codec, playing
    /// there would feed the rig's own TX audio input.
    public static bool IsSameAdapter(string captureDeviceId, string renderDeviceId)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            using var capture = enumerator.GetDevice(captureDeviceId);
            using var render = enumerator.GetDevice(renderDeviceId);
            return string.Equals(capture.DeviceFriendlyName, render.DeviceFriendlyName, StringComparison.Ordinal);
        }
        catch
        {
            return false;
        }
    }

    public void Start()
    {
        if (_loopTask is not null)
        {
            return;
        }
        _cts = new CancellationTokenSource();
        var token = _cts.Token;
        _loopTask = Task.Run(() => CaptureLoopAsync(token));
    }

    public async Task StopAsync()
    {
        if (_cts is null)
        {
            return;
        }
        _cts.Cancel();
        try
        {
            if (_loopTask is not null)
            {
                await _loopTask.ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
        }
        _cts.Dispose();
        _cts = null;
        _loopTask = null;
        lock (_statusLock)
        {
            _phase = AudioLinkPhase.Stopped;
            _detail = null;
            _capturing = false;
        }
    }

    public ValueTask DisposeAsync() => new(StopAsync());

    public AudioLinkStatus GetStatus()
    {
        lock (_statusLock)
        {
            var phase = _phase;
            var detail = _detail;
            if (_capturing && Stopwatch.GetElapsedTime(_lastDataTicks) > StallThreshold)
            {
                // WASAPI normally delivers buffers (silence included) all
                // the time, so a long gap means the device stopped feeding.
                phase = AudioLinkPhase.DeviceUnavailable;
                detail = "the input device stopped delivering audio";
            }
            return new AudioLinkStatus(phase, detail, _leftRms, _rightRms);
        }
    }

    private async Task CaptureLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            string? error;
            try
            {
                error = await CaptureUntilStoppedAsync(token).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                error = Describe(ex);
            }
            if (token.IsCancellationRequested)
            {
                return;
            }
            Debug.WriteLine($"local-audio: capture stopped: {error}");
            lock (_statusLock)
            {
                _phase = AudioLinkPhase.DeviceUnavailable;
                _detail = error;
                _capturing = false;
            }
            try
            {
                await Task.Delay(RetryDelay, token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    /// Returns the reason capture ended (null only when cancelled).
    private async Task<string?> CaptureUntilStoppedAsync(CancellationToken token)
    {
        using var enumerator = new MMDeviceEnumerator();
        MMDevice device;
        try
        {
            device = enumerator.GetDevice(_deviceId);
        }
        catch (Exception)
        {
            return "the selected input device isn't available (unplugged or disabled?)";
        }
        if (device.State is var state && state != DeviceState.Active)
        {
            device.Dispose();
            return $"the selected input device is {state.ToString().ToLowerInvariant()}";
        }

        using var capture = new WasapiCapture(device, useEventSync: true, audioBufferMillisecondsLength: 50);
        var format = capture.WaveFormat;
        var reader = SampleReader(format);
        if (reader is null)
        {
            return $"unsupported capture format ({format})";
        }
        var channels = format.Channels;
        var bytesPerFrame = format.BlockAlign;

        var stopped = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        capture.DataAvailable += (_, e) =>
        {
            var frames = e.BytesRecorded / bytesPerFrame;
            for (var i = 0; i < frames; i++)
            {
                var offset = i * bytesPerFrame;
                var left = reader(e.Buffer, offset);
                var right = channels >= 2 ? reader(e.Buffer, offset + bytesPerFrame / channels) : 0f;
                AppendFrame(left, right);
            }
            lock (_statusLock)
            {
                _lastDataTicks = Stopwatch.GetTimestamp();
            }
        };
        capture.RecordingStopped += (_, e) =>
            stopped.TrySetResult(e.Exception is { } ex ? Describe(ex) : "capture stopped");

        _filled = 0;
        capture.StartRecording();
        lock (_statusLock)
        {
            _phase = AudioLinkPhase.Streaming;
            _detail = channels >= 2
                ? $"{device.FriendlyName}, {format.SampleRate} Hz"
                : $"{device.FriendlyName}, {format.SampleRate} Hz — mono, so no Sub audio (set the device to 2 channels in Windows Sound settings)";
            _capturing = true;
            _lastDataTicks = Stopwatch.GetTimestamp();
        }
        Debug.WriteLine($"local-audio: capturing {device.FriendlyName} {format}");

        using (token.Register(() => stopped.TrySetResult(null)))
        {
            var reason = await stopped.Task.ConfigureAwait(false);
            try
            {
                capture.StopRecording();
            }
            catch
            {
            }
            device.Dispose();
            return reason;
        }
    }

    private void AppendFrame(float left, float right)
    {
        _left[_filled] = left;
        _right[_filled] = right;
        _filled++;
        if (_filled < SamplesPerChunk)
        {
            return;
        }
        _filled = 0;
        var leftChunk = (float[])_left.Clone();
        var rightChunk = (float[])_right.Clone();
        lock (_statusLock)
        {
            _leftRms = SquelchGate.Rms(leftChunk);
            _rightRms = SquelchGate.Rms(rightChunk);
        }
        _onSamples(leftChunk, rightChunk);
    }

    /// KSDATAFORMAT_SUBTYPE_IEEE_FLOAT — the SubFormat of a float
    /// WAVEFORMATEXTENSIBLE, which is what shared-mode WASAPI reports.
    private static readonly Guid IeeeFloatSubFormat = new("00000003-0000-0010-8000-00aa00389b71");

    /// Reads one sample at a byte offset as a float in -1…1, for the
    /// formats WASAPI shared mode hands out (almost always 32-bit float).
    private static Func<byte[], int, float>? SampleReader(WaveFormat format)
    {
        var isFloat = format.Encoding == WaveFormatEncoding.IeeeFloat
            || (format is WaveFormatExtensible ext && ext.SubFormat == IeeeFloatSubFormat);
        return (isFloat, format.BitsPerSample) switch
        {
            (true, 32) => (b, o) => BitConverter.ToSingle(b, o),
            (false, 16) => (b, o) => BitConverter.ToInt16(b, o) / 32768f,
            (false, 24) => (b, o) => ((b[o] << 8) | (b[o + 1] << 16) | (b[o + 2] << 24)) / 2147483648f,
            (false, 32) => (b, o) => BitConverter.ToInt32(b, o) / 2147483648f,
            _ => null,
        };
    }

    private static string Describe(Exception ex) =>
        ex is UnauthorizedAccessException || (ex is COMException com && com.HResult == unchecked((int)0x80070005))
            ? "Windows denied microphone access — turn on Settings → Privacy & security → Microphone → \"Let desktop apps access your microphone\""
            : ex.Message;
}
