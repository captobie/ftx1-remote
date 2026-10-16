namespace FTX1RemoteWindows.Services.Hub;

/// Where one transmission's audio goes: the Pi's ftx1-txaudio.py in Remote
/// mode (<see cref="RemoteTxAudioClient"/>), the Transmit audio output
/// device in Local mode (LocalTxAudioPlayer). One instance per
/// transmission, opened on its first frame.
public interface ITxAudioSink
{
    /// One chunk of 8 kHz mono Int16LE PCM (AudioStreamFormat, tag stripped).
    void Send(byte[] pcm);

    /// Unkey: let what's queued play out, then close.
    void Finish();
}

/// What a TX audio frame from a hub client did, for the log and the tests.
public enum TxFrameResult
{
    Sent,
    /// The rig isn't keyed through the hub (or keyed for another client).
    DroppedNotKeyed,
    /// No sink could be opened (Local mode with no Transmit audio output).
    DroppedNoSink,
}

/// The hub's transmit audio state (Apps/Windows/README.md, "Desktop hub for
/// the iPad", phase 5) — the Mac's HubService.handleTXAudio/endTXAudio and
/// its silence watchdog, as a plain class driven by MainWindow on the UI
/// thread with the time passed in, so it's unit-tested without timers.
///
/// "Keyed" is the state this app sets when it keys the rig for a hub
/// client (<see cref="Keyed"/>), not what the poll last read: a frame that
/// arrives right behind its client's ptt=true must find it set. Frames are
/// accepted only from the client that keyed; HubServer has already dropped
/// any that aren't from the PTT holder.
///
/// Not thread-safe: every call on one thread (the UI thread in the app).
public sealed class HubTransmitAudio(Func<ITxAudioSink?> openSink)
{
    /// No frame for this long while keyed through the hub unkeys — an iPad
    /// suspended mid-press keeps its socket open, so the holder-disconnect
    /// unkey wouldn't fire. The Mac's txAudioSilenceLimit; also the Pi's own
    /// SILENCE_LIMIT.
    public static readonly TimeSpan SilenceLimit = TimeSpan.FromMilliseconds(1500);

    private ITxAudioSink? _sink;
    private bool _sinkUnavailable;
    private long _lastAudioAtMs;
    private bool _silenceReported;

    /// The client the rig is keyed for through the hub, or null.
    public int? KeyedBy { get; private set; }

    public bool IsKeyed => KeyedBy is not null;

    /// A sink is open (a transmission's audio is flowing to it).
    public bool HasSink => _sink is not null;

    /// The rig was just keyed for <paramref name="clientId"/>. The watchdog
    /// counts from here too, so a client that keys and never sends audio is
    /// unkeyed as well (the Mac arms it on the first frame only).
    public void Keyed(int clientId, long nowMs)
    {
        KeyedBy = clientId;
        _lastAudioAtMs = nowMs;
        _silenceReported = false;
        _sinkUnavailable = false;
    }

    /// The rig was unkeyed (any reason): the sink finishes. Returns the
    /// client it had been keyed for, or null if it wasn't keyed through the
    /// hub.
    public int? Unkeyed()
    {
        var was = KeyedBy;
        KeyedBy = null;
        _silenceReported = false;
        EndSink();
        return was;
    }

    /// One TX audio frame's payload from <paramref name="clientId"/>.
    public TxFrameResult Frame(int clientId, byte[] pcm, long nowMs)
    {
        if (KeyedBy is not { } keyed)
        {
            // Unkeyed some other way: close a sink left open, as the Mac's
            // handleTXAudio does.
            EndSink();
            return TxFrameResult.DroppedNotKeyed;
        }
        if (keyed != clientId)
        {
            return TxFrameResult.DroppedNotKeyed;
        }
        _lastAudioAtMs = nowMs;
        if (_sink is null)
        {
            if (_sinkUnavailable)
            {
                return TxFrameResult.DroppedNoSink;
            }
            _sink = openSink();
            if (_sink is null)
            {
                // Logged once by the opener; not retried every frame.
                _sinkUnavailable = true;
                return TxFrameResult.DroppedNoSink;
            }
        }
        _sink.Send(pcm);
        return TxFrameResult.Sent;
    }

    /// True once when keyed through the hub and no frame has arrived for
    /// <see cref="SilenceLimit"/>; the caller unkeys. Polled (the hub's
    /// 100 ms timer), so it fires 1.5–1.6 s after the last frame.
    public bool TakeSilenceExpired(long nowMs)
    {
        if (!IsKeyed || _silenceReported || nowMs - _lastAudioAtMs < SilenceLimit.TotalMilliseconds)
        {
            return false;
        }
        _silenceReported = true;
        return true;
    }

    private void EndSink()
    {
        var sink = _sink;
        _sink = null;
        sink?.Finish();
    }
}
