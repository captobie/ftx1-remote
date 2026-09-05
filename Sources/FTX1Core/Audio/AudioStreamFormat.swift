import Foundation

/// Fixed (not negotiated) format for the Mac → mobile client audio stream.
/// Mono/16-bit/8kHz is well above Nyquist for the rig's voice-bandwidth
/// audio (SSB/FM, ~300 Hz–3 kHz) and keeps bandwidth trivial (~16 KB/s) over
/// Tailscale without needing a codec dependency. Both `AudioStreamEncoder`
/// (Mac) and `RigWebSocketClient`/`AudioPlaybackEngine` reference this
/// rather than duplicating the numbers.
public enum AudioStreamFormat {
    public static let sampleRate: Double = 8000

    /// Prefixed to every audio frame sent server→client so `RigWebSocketClient`
    /// can tell it apart from a `RigStatePush` JSON frame before decoding.
    /// Valid JSON text can never start with this byte (JSON always starts
    /// with `{`), so a leading-byte check is enough — no need to touch the
    /// existing JSON wire types at all.
    public static let audioTag: UInt8 = 0x00

    /// Prepends the tag byte — what `RigWebSocketServer.broadcastAudio`
    /// actually sends over the wire.
    public static func frame(_ pcm: Data) -> Data {
        var framed = Data(capacity: pcm.count + 1)
        framed.append(audioTag)
        framed.append(pcm)
        return framed
    }

    /// Whether a just-received WebSocket message is one of these audio
    /// frames rather than `RigStatePush` JSON — checked by
    /// `RigWebSocketClient.handle(_:)` before attempting a JSON decode.
    public static func isAudioFrame(_ data: Data) -> Bool {
        data.first == audioTag && data.count > 1
    }

    /// The raw PCM payload of an audio frame, tag byte stripped. Only
    /// meaningful when `isAudioFrame(data)` is true.
    public static func payload(of data: Data) -> Data {
        data.dropFirst()
    }
}
