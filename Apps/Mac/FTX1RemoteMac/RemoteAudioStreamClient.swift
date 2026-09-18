import Foundation
import Network
import os

/// Connects to `ftx1-audiostream.service` running on the Pi (see
/// `Pi/ftx1-audiostream.py`) and delivers the rig's audio as two parallel
/// Float32 sample streams — Main (left channel) and Sub (right channel).
/// The FTX-1's USB audio-out is genuinely stereo whenever dual-VFO display
/// is active (Main=L, Sub=R; confirmed directly against this hardware —
/// see the Main/Sub audio-isolation notes in the repo's CLAUDE.md), and
/// `ftx1-audiostream.py` now sends that interleaved, 4 bytes per stereo
/// frame (2-byte Main sample, then 2-byte Sub sample, both 16-bit signed
/// LE) — this type undoes the interleaving.
///
/// `main` is handed to `AudioCaptureEngine.process(samples:sampleRate:
/// bitmap:gain:)`, the exact same entry point the local `AVAudioEngine` tap
/// feeds, so every existing downstream consumer (waterfall, APRS, FT8,
/// Mac-local playback, iPad relay) keeps working unchanged, fed a
/// genuinely isolated Main channel instead of the old `channels 1`
/// ALSA-negotiated one (which turned out to sum Main+Sub rather than
/// cleanly pick one — see CLAUDE.md). `sub` isn't consumed by any of that
/// yet — see `AudioCaptureEngine.logRemoteChannelDiagnostics` for the
/// current (diagnostic-only) use.
///
/// Deliberately a raw TCP byte stream, not the WebSocket/JSON protocol
/// `RigWebSocketClient` uses: this is a dedicated, audio-only connection,
/// separate from the rigctld link, so there's no need for
/// `AudioStreamFormat`'s tag-byte framing (that exists only to tell audio
/// apart from JSON `RigStatePush` frames on the *shared* Mac→iPad
/// connection).
///
/// Owns its own connect/retry loop, independent of `RigctldClient`'s — the
/// audio link and the CAT link are two separate TCP connections to two
/// separate Pi-side services, and one can drop while the other stays up.
actor RemoteAudioStreamClient {
    private let host: String
    private let port: UInt16
    private let sampleRate: Double
    /// How many samples (per channel) to accumulate before handing a chunk
    /// to `onSamples` — matches `AudioCaptureEngine.fftSize`, so a remote
    /// chunk covers about the same span of audio as one local-tap callback
    /// does.
    private let samplesPerChunk: Int
    private let reconnectDelay: Duration
    /// Invoked with each accumulated chunk — not hopped to the main actor
    /// here, same reasoning as `AudioCaptureEngine.process(buffer:bitmap:
    /// gain:)`: the FFT work it triggers should stay off the main thread.
    /// `AudioCaptureEngine` itself hops to the main actor only for its own
    /// `onNewFrame`/`onAudioSamples` output, same as the local-capture path.
    private let onSamples: @Sendable (_ main: [Float], _ sub: [Float], _ sampleRate: Double) -> Void

    private var running = false
    private var loopTask: Task<Void, Never>?

    /// Diagnostic-only — check via Console.app (subsystem
    /// "com.ftx1remote.mac", category "remote-audio"). Added because,
    /// unlike the rigctld link, nothing about this connection's state was
    /// visible anywhere before — a silent connect failure here would look
    /// identical to "connected but the Pi isn't sending anything" from the
    /// waterfall's perspective (blank either way).
    private static let logger = Logger(subsystem: "com.ftx1remote.mac", category: "remote-audio")

    init(
        host: String,
        port: UInt16 = 8532,
        // 44100, not AudioStreamFormat.sampleRate (8000, the Mac→iPad
        // relay's own separate wire format) — raised 2026-09-07 to match
        // Pi/ftx1-audiostream.py's own capture rate, after 8kHz left
        // AFSKDemodulator with too little timing resolution to reliably
        // decode APRS (see that Python file's doc comment for the full
        // reasoning). This is a genuinely different concern from the
        // iPad relay's rate, hence the separate constant rather than
        // reusing AudioStreamFormat's.
        sampleRate: Double = 44100,
        samplesPerChunk: Int = 2048,
        reconnectDelay: Duration = .seconds(3),
        onSamples: @escaping @Sendable (_ main: [Float], _ sub: [Float], _ sampleRate: Double) -> Void
    ) {
        self.host = host
        self.port = port
        self.sampleRate = sampleRate
        self.samplesPerChunk = samplesPerChunk
        self.reconnectDelay = reconnectDelay
        self.onSamples = onSamples
    }

    func start() {
        guard !running else { return }
        Self.logger.notice("start() — connecting to \(self.host, privacy: .public):\(self.port)")
        running = true
        loopTask = Task { await self.connectionLoop() }
    }

    func stop() {
        Self.logger.notice("stop()")
        running = false
        loopTask?.cancel()
        loopTask = nil
    }

    private func connectionLoop() async {
        while running, !Task.isCancelled {
            do {
                try await receiveUntilDisconnected()
            } catch {
                // Whether this was a connect failure or a mid-stream drop,
                // the response is the same: wait, then try a fresh
                // connection. Nothing here distinguishes "Pi unreachable"
                // from "stream ended" — same open gap as the rigctld link's
                // .failed state (see repo root CLAUDE.md's Option A notes).
                Self.logger.error("connection attempt failed: \(String(describing: error), privacy: .public)")
            }
            guard running, !Task.isCancelled else { return }
            try? await Task.sleep(for: reconnectDelay)
        }
    }

    private func receiveUntilDisconnected() async throws {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { conn.cancel() }

        let readyGuard = ContinuationGuard()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    readyGuard.resumeOnce(continuation, with: .success(()))
                case .failed(let error):
                    readyGuard.resumeOnce(continuation, with: .failure(error))
                case .cancelled:
                    readyGuard.resumeOnce(continuation, with: .failure(RemoteAudioStreamError.disconnected))
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        Self.logger.notice("connected")

        // Carries 0-3 leftover bytes across reads when a TCP chunk splits a
        // 4-byte stereo frame (2-byte Main sample + 2-byte Sub sample) —
        // raw byte-stream framing has no guarantee reads land on frame
        // boundaries.
        let bytesPerFrame = 4
        var pendingBytes: [UInt8] = []
        var mainAccumulator: [Float] = []
        var subAccumulator: [Float] = []
        mainAccumulator.reserveCapacity(samplesPerChunk)
        subAccumulator.reserveCapacity(samplesPerChunk)
        var totalBytesReceived = 0
        var lastLoggedAtByteCount = 0
        // Heartbeat every ~30s of audio, derived from the configured rate
        // (16-bit stereo, so 4 bytes per frame) — confirms data is actually
        // flowing without logging every ~4KB read. This was a fixed 32,000
        // bytes, chosen when the stream was 8kHz mono ("every ~2s"); after
        // the 2026-09-07 raise to 44.1kHz that same constant fired every
        // ~0.37s, nearly three lines a second, for as long as the app was
        // connected — scale with both the rate and the per-frame byte count
        // so this doesn't happen again the next time either changes.
        let bytesPerHeartbeat = Int(sampleRate) * bytesPerFrame * 30

        while running, !Task.isCancelled {
            let chunk = try await receive(on: conn)
            totalBytesReceived += chunk.count
            if totalBytesReceived - lastLoggedAtByteCount >= bytesPerHeartbeat {
                lastLoggedAtByteCount = totalBytesReceived
                Self.logger.notice("received \(totalBytesReceived) bytes so far")
            }
            var bytes = pendingBytes
            bytes.append(contentsOf: chunk)
            let usableFrameCount = bytes.count / bytesPerFrame
            let usableByteCount = usableFrameCount * bytesPerFrame
            pendingBytes = Array(bytes.suffix(bytes.count - usableByteCount))

            var index = 0
            while index < usableByteCount {
                let left = Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
                let right = Int16(bitPattern: UInt16(bytes[index + 2]) | (UInt16(bytes[index + 3]) << 8))
                mainAccumulator.append(Float(left) / 32768.0)
                subAccumulator.append(Float(right) / 32768.0)
                index += bytesPerFrame
            }
            while mainAccumulator.count >= samplesPerChunk {
                let mainChunk = Array(mainAccumulator.prefix(samplesPerChunk))
                let subChunk = Array(subAccumulator.prefix(samplesPerChunk))
                mainAccumulator.removeFirst(samplesPerChunk)
                subAccumulator.removeFirst(samplesPerChunk)
                onSamples(mainChunk, subChunk, sampleRate)
            }
        }
    }

    private func receive(on conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: RemoteAudioStreamError.disconnected)
                } else {
                    continuation.resume(throwing: RemoteAudioStreamError.disconnected)
                }
            }
        }
    }
}

enum RemoteAudioStreamError: Error {
    case disconnected
}

/// Guards a `CheckedContinuation` against being resumed more than once —
/// mirrors `RigctldClient`'s identical private helper (not shared across
/// the module boundary for one small utility). `NWConnection.
/// stateUpdateHandler` can fire `.ready` and then later `.failed` on the
/// same connection, and resuming twice is a crash.
private final class ContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var didResume = false

    nonisolated init() {}

    nonisolated func resumeOnce(_ continuation: CheckedContinuation<Void, Error>, with result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(with: result)
    }
}
