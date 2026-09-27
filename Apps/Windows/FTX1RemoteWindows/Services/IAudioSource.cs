namespace FTX1RemoteWindows.Services;

/// Where the rig's audio comes from: the Pi's :8532 stream in Remote mode
/// (<see cref="RemoteAudioStreamClient"/>), a sound-card input on this PC in
/// Local mode (<see cref="LocalAudioCapture"/>). Either way the source hands
/// out Main (left) / Sub (right) float chunks of the same size, so the
/// squelch, swap routing and playback downstream can't tell them apart —
/// same idea as the Mac's AudioCaptureEngine feeding one process() entry
/// point from both its local tap and its remote client.
public interface IAudioSource : IAsyncDisposable
{
    /// Samples per second of the chunks this source delivers. Fixed for a
    /// source's lifetime once <see cref="Start"/> has returned.
    int SampleRate { get; }

    void Start();

    Task StopAsync();

    AudioLinkStatus GetStatus();
}
