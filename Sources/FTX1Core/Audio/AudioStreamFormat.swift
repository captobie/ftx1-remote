import Foundation

/// Fixed (not negotiated) format for the Mac → mobile client audio stream.
/// Mono/16-bit/8kHz is well above Nyquist for the rig's voice-bandwidth
/// audio (SSB/FM, ~300 Hz–3 kHz) and keeps bandwidth trivial (~16 KB/s per
/// channel) over Tailscale without needing a codec dependency. Both
/// `AudioStreamEncoder` (Mac) and `RigWebSocketClient`/`AudioPlaybackEngine`
/// reference this rather than duplicating the numbers.
///
/// Main and Sub (2026-09-18) are two independently-tagged frame streams at
/// this same fixed mono/8kHz format, not one interleaved-stereo stream —
/// deliberately mirroring the local/remote *capture* side's "two fully
/// parallel mono pipelines" shape (see repo CLAUDE.md, "Dual Main/Sub audio
/// channels") rather than the Pi's interleaved-stereo wire format, since
/// that would require rewriting `AudioStreamEncoder`/`AudioPlaybackEngine`
/// (both hardcoded mono) instead of just reusing them twice.
public enum AudioStreamFormat {
    public static let sampleRate: Double = 8000

    /// Prefixed to every Main-channel audio frame sent server→client so
    /// `RigWebSocketClient` can tell it apart from a `RigStatePush` JSON
    /// frame before decoding. Valid JSON text can never start with this
    /// byte (JSON always starts with `{`), so a leading-byte check is
    /// enough — no need to touch the existing JSON wire types at all.
    public static let audioTag: UInt8 = 0x00

    /// Sub-channel counterpart to `audioTag` — a client that predates this
    /// (or a hub build older than this) simply never sees frames tagged
    /// this way, same "never fires" fallback `onAudioData`'s doc comment
    /// already describes for `audioTag`.
    public static let subAudioTag: UInt8 = 0x01

    /// Transmit audio, the other way: client→server frames carrying the
    /// iPad's microphone, same mono/8kHz Int16 format, sent only while the
    /// client holds PTT. `RigWebSocketServer` checks this before trying a
    /// `RigCommand` JSON decode, and forwards frames only from the client
    /// that keyed.
    public static let txAudioTag: UInt8 = 0x02

    /// Prepends the Main tag byte — what `RigWebSocketServer.broadcastAudio`
    /// actually sends over the wire.
    public static func frame(_ pcm: Data) -> Data {
        tagged(pcm, with: audioTag)
    }

    /// Prepends the Sub tag byte — what `RigWebSocketServer.broadcastSubAudio`
    /// sends.
    public static func subFrame(_ pcm: Data) -> Data {
        tagged(pcm, with: subAudioTag)
    }

    /// Prepends the transmit tag byte — what `RigWebSocketClient.
    /// sendTXAudio(_:)` sends.
    public static func txFrame(_ pcm: Data) -> Data {
        tagged(pcm, with: txAudioTag)
    }

    private static func tagged(_ pcm: Data, with tag: UInt8) -> Data {
        var framed = Data(capacity: pcm.count + 1)
        framed.append(tag)
        framed.append(pcm)
        return framed
    }

    /// Whether a just-received WebSocket message is a Main-channel audio
    /// frame rather than `RigStatePush` JSON or a Sub-channel frame —
    /// checked by `RigWebSocketClient.handle(_:)` before attempting a JSON
    /// decode.
    public static func isAudioFrame(_ data: Data) -> Bool {
        data.first == audioTag && data.count > 1
    }

    /// Sub-channel counterpart to `isAudioFrame(_:)`.
    public static func isSubAudioFrame(_ data: Data) -> Bool {
        data.first == subAudioTag && data.count > 1
    }

    /// Whether a message received by the hub is a transmit audio frame
    /// rather than `RigCommand` JSON.
    public static func isTXAudioFrame(_ data: Data) -> Bool {
        data.first == txAudioTag && data.count > 1
    }

    /// The raw PCM payload of an audio frame (Main, Sub or transmit), tag byte
    /// stripped. Only meaningful when `isAudioFrame(data)` or
    /// `isSubAudioFrame(data)` is true — both use the same one-byte tag
    /// width, so a single stripping function covers either.
    public static func payload(of data: Data) -> Data {
        data.dropFirst()
    }
}
