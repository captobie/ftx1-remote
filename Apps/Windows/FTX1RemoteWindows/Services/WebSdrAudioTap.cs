using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;

namespace FTX1RemoteWindows.Services;

/// The WebSDR window as MainWindow sees it, for the CW window's WebSDR
/// source: its WebView2 browser process (whose process tree plays the
/// page's audio), and whether it's connected and muted.
public readonly record struct WebSdrState(uint? BrowserProcessId, bool Connected, bool Muted);

public enum WebSdrTapPhase
{
    Stopped,
    /// The WebSDR window isn't open, or its web view hasn't started.
    WaitingForWebSdr,
    Capturing,
    /// Capturing, but next to nothing for a while: the page is muted, not
    /// connected, or not playing.
    Silent,
    Failed,
}

/// Captures what the WebSDR window is playing, for the CW decoder's WebSDR
/// source — the Mac's WebSDRAudioTap (a Core Audio process tap there), done
/// here with Windows' process-loopback capture (Windows 10 2004 / Windows 11):
/// the audio of the WebView2 browser process and its children, where
/// Chromium's audio service runs, and nothing of this app's own (the rig's
/// playback). Nothing is added to the KiwiSDR/WebSDR/OpenWebRX pages.
///
/// Unlike the Mac's tap, Windows can't keep the speakers silent while still
/// capturing: muting the WebView2's audio session (or the page) silences the
/// capture too (tested 2026-10-03: session mute and volume 0 both give exact
/// zeros), so the WebSDR has to be audible to decode — user decision. The CW
/// window says so when the WebSDR window is muted.
///
/// Delivers mono float chunks (channels averaged) at 48 kHz from its own
/// capture thread; status changes come on that thread too. The target
/// process is set from the UI thread (<see cref="SetTarget"/>); a new one
/// restarts the capture.
public sealed class WebSdrAudioTap : IDisposable
{
    private readonly Action<float[], int> _onSamples;
    private readonly Action<WebSdrTapPhase, string?> _onStatus;
    private readonly object _lock = new();
    private CancellationTokenSource? _run;
    private Task? _loop;
    private uint? _target;
    private WebSdrTapPhase _phase = WebSdrTapPhase.Stopped;

    private const int SampleRate = 48_000;
    private const int Channels = 2;
    /// Delivered in chunks of this many frames (~43 ms), like the Mac's.
    private const int ChunkFrames = 2048;
    /// About -80 dBFS: a muted page doesn't always deliver exact zeros.
    private const float SilenceLevel = 1e-4f;
    private static readonly TimeSpan SilenceTimeout = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(3);

    public WebSdrAudioTap(Action<float[], int> onSamples, Action<WebSdrTapPhase, string?> onStatus)
    {
        _onSamples = onSamples;
        _onStatus = onStatus;
    }

    /// The WebView2 browser process to capture, or null when there's none.
    public void SetTarget(uint? processId)
    {
        lock (_lock)
        {
            if (processId == _target)
            {
                return;
            }
            _target = processId;
            if (_run is not null)
            {
                Restart();
            }
        }
    }

    public void Start()
    {
        lock (_lock)
        {
            if (_run is null)
            {
                Restart();
            }
        }
    }

    public void Stop()
    {
        lock (_lock)
        {
            _run?.Cancel();
            _run = null;
        }
        SetPhase(WebSdrTapPhase.Stopped, null);
    }

    public void Dispose() => Stop();

    private void Restart()
    {
        _run?.Cancel();
        var run = new CancellationTokenSource();
        _run = run;
        var target = _target;
        var previous = _loop;
        _loop = Task.Run(async () =>
        {
            if (previous is not null)
            {
                // One capture at a time.
                await previous.ConfigureAwait(false);
            }
            await LoopAsync(target, run.Token).ConfigureAwait(false);
        });
    }

    private async Task LoopAsync(uint? target, CancellationToken token)
    {
        if (target is not { } pid)
        {
            SetPhase(WebSdrTapPhase.WaitingForWebSdr, null, token);
            return;
        }
        while (!token.IsCancellationRequested)
        {
            try
            {
                await CaptureAsync(pid, token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                AppLog.Write($"websdr-tap: capture of process {pid} failed: {ex.Message}");
                SetPhase(WebSdrTapPhase.Failed, ex.Message, token);
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

    private async Task CaptureAsync(uint pid, CancellationToken token)
    {
        var activated = await ProcessLoopbackActivation.ActivateAsync(pid, includeTree: true).ConfigureAwait(false);
        var client = new AudioClient((IAudioClient)activated);
        try
        {
            // A process-loopback client has no mix format of its own; the
            // format is ours to choose and the audio engine converts to it.
            var format = WaveFormat.CreateIeeeFloatWaveFormat(SampleRate, Channels);
            client.Initialize(AudioClientShareMode.Shared,
                AudioClientStreamFlags.Loopback | AudioClientStreamFlags.EventCallback | AudioClientStreamFlags.AutoConvertPcm,
                200_000, 0, format, Guid.Empty);
            using var ready = new AutoResetEvent(false);
            client.SetEventHandle(ready.SafeWaitHandle.DangerousGetHandle());
            var capture = client.AudioCaptureClient;
            client.Start();
            AppLog.Write($"websdr-tap: capturing process {pid} and its children");
            SetPhase(WebSdrTapPhase.Capturing, null, token);

            var chunk = new float[ChunkFrames];
            var filled = 0;
            var lastSound = Stopwatch.StartNew();
            while (!token.IsCancellationRequested)
            {
                ready.WaitOne(100);
                while (capture.GetNextPacketSize() > 0)
                {
                    var buffer = capture.GetBuffer(out var frames, out var flags);
                    var silent = (flags & AudioClientBufferFlags.Silent) != 0;
                    for (var i = 0; i < frames; i++)
                    {
                        float sample = 0;
                        if (!silent)
                        {
                            unsafe
                            {
                                var p = (float*)buffer + i * Channels;
                                sample = (p[0] + p[1]) * 0.5f;
                            }
                        }
                        chunk[filled++] = sample;
                        if (filled == ChunkFrames)
                        {
                            if (Peak(chunk) > SilenceLevel)
                            {
                                lastSound.Restart();
                            }
                            _onSamples(chunk, SampleRate);
                            chunk = new float[ChunkFrames];
                            filled = 0;
                        }
                    }
                    capture.ReleaseBuffer(frames);
                }
                SetPhase(lastSound.Elapsed > SilenceTimeout ? WebSdrTapPhase.Silent : WebSdrTapPhase.Capturing, null, token);
            }
        }
        finally
        {
            try
            {
                client.Stop();
            }
            catch (Exception)
            {
            }
            client.Dispose();
        }
        token.ThrowIfCancellationRequested();
    }

    private static float Peak(float[] samples)
    {
        var peak = 0f;
        foreach (var s in samples)
        {
            var a = Math.Abs(s);
            if (a > peak)
            {
                peak = a;
            }
        }
        return peak;
    }

    /// A cancelled run (stopped, or replaced by a new target) reports nothing
    /// more, so a late status can't overwrite the current one.
    private void SetPhase(WebSdrTapPhase phase, string? detail, CancellationToken token = default)
    {
        lock (_lock)
        {
            if (token.IsCancellationRequested)
            {
                return;
            }
            if (phase == _phase && phase != WebSdrTapPhase.Failed)
            {
                return;
            }
            _phase = phase;
        }
        _onStatus(phase, detail);
    }
}

/// ActivateAudioInterfaceAsync for a process-loopback IAudioClient — the one
/// piece NAudio doesn't wrap. AUDIOCLIENT_ACTIVATION_PARAMS goes in a
/// PROPVARIANT blob.
internal static class ProcessLoopbackActivation
{
    private const string ProcessLoopbackDevice = "VAD\\Process_Loopback";
    private static readonly Guid AudioClientInterfaceId = new("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
    private const int ActivationTypeProcessLoopback = 1;
    private const int LoopbackModeIncludeTree = 0;
    private const int LoopbackModeExcludeTree = 1;
    private const short VtBlob = 65;

    [DllImport("Mmdevapi.dll", ExactSpelling = true, PreserveSig = false)]
    private static extern void ActivateAudioInterfaceAsync(
        [MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        IntPtr activationParams,
        IActivateAudioInterfaceCompletionHandler completionHandler,
        out IActivateAudioInterfaceAsyncOperation activationOperation);

    public static async Task<object> ActivateAsync(uint processId, bool includeTree)
    {
        // AUDIOCLIENT_ACTIVATION_PARAMS { ActivationType; { TargetProcessId; ProcessLoopbackMode } }.
        var parameters = Marshal.AllocHGlobal(12);
        // PROPVARIANT (24 bytes on x64): vt at 0, blob.cbSize at 8, blob.pBlobData at 16.
        var variant = Marshal.AllocHGlobal(24);
        try
        {
            Marshal.WriteInt32(parameters, 0, ActivationTypeProcessLoopback);
            Marshal.WriteInt32(parameters, 4, (int)processId);
            Marshal.WriteInt32(parameters, 8, includeTree ? LoopbackModeIncludeTree : LoopbackModeExcludeTree);
            for (var i = 0; i < 24; i++)
            {
                Marshal.WriteByte(variant, i, 0);
            }
            Marshal.WriteInt16(variant, 0, VtBlob);
            Marshal.WriteInt32(variant, 8, 12);
            Marshal.WriteIntPtr(variant, 16, parameters);
            var handler = new CompletionHandler();
            ActivateAudioInterfaceAsync(ProcessLoopbackDevice, AudioClientInterfaceId, variant, handler, out _);
            return await handler.Task.ConfigureAwait(false);
        }
        finally
        {
            Marshal.FreeHGlobal(variant);
            Marshal.FreeHGlobal(parameters);
        }
    }

    /// Must be agile (IAgileObject): the completion arrives on a system
    /// thread.
    private sealed class CompletionHandler : IActivateAudioInterfaceCompletionHandler, IAgileObject
    {
        private readonly TaskCompletionSource<object> _completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task<object> Task => _completion.Task;

        public void ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation)
        {
            operation.GetActivateResult(out var result, out var activated);
            if (result != 0)
            {
                _completion.SetException(Marshal.GetExceptionForHR(result) ?? new COMException("Activation failed", result));
            }
            else
            {
                _completion.SetResult(activated);
            }
        }
    }
}

[ComImport, Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IActivateAudioInterfaceCompletionHandler
{
    void ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation);
}

[ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IActivateAudioInterfaceAsyncOperation
{
    void GetActivateResult(out int activateResult, [MarshalAs(UnmanagedType.IUnknown)] out object activatedInterface);
}

[ComImport, Guid("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAgileObject
{
}
