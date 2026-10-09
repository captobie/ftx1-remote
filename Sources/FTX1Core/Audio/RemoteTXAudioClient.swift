import Foundation
import Network
import os

/// Sends transmit audio to `Pi/ftx1-txaudio.py` (port 8533), which plays it
/// into the rig's USB audio input: raw 8 kHz mono Int16LE
/// (`AudioStreamFormat`), no framing — a dedicated write-only connection,
/// like the receive stream's `RemoteAudioStreamClient`.
///
/// One instance per transmission: created and `start()`ed on PTT press,
/// `finish()`ed on release. Audio sent before the connection is ready is
/// held (up to `maxPendingBytes`) so the first syllable isn't lost to the
/// connect. Never keys anything itself — keying stays a rigctld command.
/// The Pi side unkeys the rig if this connection drops or goes quiet
/// mid-transmission (its watchdog).
///
/// Used by the iPad's Pi direct (`PiDirectViewModel`) and the Mac hub in
/// `.remote` mode (`HubService`); each passes its own `logSubsystem`.
public actor RemoteTXAudioClient {
    public static let defaultPort: UInt16 = 8533

    private let connection: NWConnection
    private let logger: Logger
    private var isReady = false
    private var isFinished = false
    private var pending = Data()
    /// Half a second of 8 kHz Int16 audio — more than a Tailscale connect.
    private let maxPendingBytes = 8000
    private var bytesSent = 0

    public init(host: String, port: UInt16 = RemoteTXAudioClient.defaultPort, logSubsystem: String) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        logger = Logger(subsystem: logSubsystem, category: "tx-audio")
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handle(state) }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    public func send(_ pcm: Data) {
        guard !isFinished, !pcm.isEmpty else { return }
        guard isReady else {
            pending.append(pcm)
            if pending.count > maxPendingBytes {
                pending.removeFirst(pending.count - maxPendingBytes)
            }
            return
        }
        write(pcm)
    }

    /// Ends the stream once everything queued has gone out (the Pi then
    /// plays its buffer out and closes), or drops it if never connected.
    public func finish() {
        guard !isFinished else { return }
        isFinished = true
        logger.notice("finish — \(self.bytesSent) bytes sent")
        guard isReady else {
            connection.cancel()
            return
        }
        let connection = connection
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !isFinished else { return }
            isReady = true
            logger.notice("connected")
            if !pending.isEmpty {
                write(pending)
                pending = Data()
            }
        case .failed(let error):
            logger.error("connection failed: \(String(describing: error), privacy: .public)")
            isReady = false
            connection.cancel()
        case .waiting(let error):
            logger.error("waiting to connect: \(String(describing: error), privacy: .public)")
        default:
            break
        }
    }

    private func write(_ pcm: Data) {
        bytesSent += pcm.count
        connection.send(content: pcm, completion: .contentProcessed { _ in })
    }
}
