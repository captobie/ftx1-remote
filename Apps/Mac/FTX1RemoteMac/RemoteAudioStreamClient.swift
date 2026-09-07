import Foundation
import Network
import os

/// Connects to `ftx1-audiostream.service` running on the Pi (see
/// `Pi/ftx1-audiostream.py`) and delivers the rig's audio as raw Float32
/// samples, matching the shape `AudioCaptureEngine`'s local `AVAudioEngine`
/// tap already produces — `AudioCaptureEngine.process(samples:sampleRate:
/// bitmap:gain:)` can't tell the two sources apart.
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
    /// How many samples to accumulate before handing a chunk to
    /// `onSamples` — matches `AudioCaptureEngine.fftSize`, so a remote
    /// chunk covers about the same span of audio as one local-tap callback
    /// does.
    private let samplesPerChunk: Int
    private let reconnectDelay: Duration
    /// Invoked with each accumulated chunk — not hopped to the main actor
    /// here, same reasoning as `AudioCaptureEngine.process(buffer:bitmap:
    /// gain:)`: the FFT work it triggers should stay off the main thread.
    /// `AudioCaptureEngine` itself hops to the main actor only for its own
    /// `onNewFrame`/`onAudioSamples` output, same as the local-capture path.
    private let onSamples: @Sendable ([Float], Double) -> Void

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
        onSamples: @escaping @Sendable ([Float], Double) -> Void
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

        // Carries a leftover odd byte across reads when a TCP chunk splits
        // a 2-byte Int16 sample in half — raw byte-stream framing has no
        // guarantee reads land on sample boundaries.
        var pendingByte: UInt8?
        var accumulator: [Float] = []
        accumulator.reserveCapacity(samplesPerChunk)
        var totalBytesReceived = 0
        var lastLoggedAtByteCount = 0

        while running, !Task.isCancelled {
            let chunk = try await receive(on: conn)
            totalBytesReceived += chunk.count
            if totalBytesReceived - lastLoggedAtByteCount >= 32_000 {
                // Roughly every 2s of audio at 8kHz/16-bit mono — confirms
                // data is actually flowing, without logging every ~4KB read.
                lastLoggedAtByteCount = totalBytesReceived
                Self.logger.notice("received \(totalBytesReceived) bytes so far")
            }
            var bytes = [UInt8](chunk)
            if let pending = pendingByte {
                bytes.insert(pending, at: 0)
                pendingByte = nil
            }
            if bytes.count % 2 != 0 {
                pendingByte = bytes.removeLast()
            }
            var index = 0
            while index + 1 < bytes.count {
                let raw = Int16(bitPattern: UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
                accumulator.append(Float(raw) / 32768.0)
                index += 2
            }
            while accumulator.count >= samplesPerChunk {
                let toDeliver = Array(accumulator.prefix(samplesPerChunk))
                accumulator.removeFirst(samplesPerChunk)
                onSamples(toDeliver, sampleRate)
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
