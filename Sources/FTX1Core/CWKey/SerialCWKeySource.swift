#if os(macOS)
import Darwin
import Foundation
import os

/// The Arduino key interface (`cw_keyer/cw_keyer.ino`) on a USB serial
/// port, at 115200 8N1.
///
/// Opening the port resets an UNO (its DTR pulses the reset line), so the
/// link sits in `.opening` until the device talks — its banner ~1.5 s
/// later, or a heartbeat if the banner was cut off. Bytes before that
/// (the tail of a line from before the reset, noise) are dropped by the
/// assembler. If the port fails, the device is unplugged or the port
/// can't be opened, the source reports `.failed` and tries again every
/// `retryInterval` until `stop`.
///
/// Every line is stamped with the host clock right after the `read` that
/// returned it, on the source's own queue — the clock sync needs the
/// arrival time, not when a consumer got round to it.
public final class SerialCWKeySource: CWKeySource, @unchecked Sendable {
    public let events: AsyncStream<CWKeySourceEvent>
    private let continuation: AsyncStream<CWKeySourceEvent>.Continuation

    public var retryInterval: Double = 1.0
    /// Seconds from opening the port with nothing parseable heard before
    /// the link reports that, so a wrong port shows as such.
    public var silentPortTimeout: Double = 4.0

    private let queue = DispatchQueue(label: "com.ftx1remote.cw-key-source", qos: .userInteractive)
    private let clock: CWHostClock
    private let logger: Logger

    // Queue-confined.
    private var path: String
    private var running = false
    private var port: POSIXSerialPort?
    private var readSource: DispatchSourceRead?
    private var assembler = CWKeyLineAssembler()
    private var readBuffer = [UInt8](repeating: 0, count: 256)
    private var link: CWKeyLinkState = .closed
    /// Bumped on every open/close so a stale retry or timeout is ignored.
    private var generation = 0

    public init(path: String, clock: CWHostClock = CWMonotonicClock(), logSubsystem: String) {
        self.path = path
        self.clock = clock
        logger = Logger(subsystem: logSubsystem, category: "cw-key")
        (events, continuation) = AsyncStream.makeStream(of: CWKeySourceEvent.self)
    }

    deinit {
        continuation.finish()
    }

    public func start() {
        queue.async { [self] in
            running = true
            openPort()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            closePort()
            report(.closed)
        }
    }

    /// Switches to another port (restarting if running).
    public func setPath(_ newPath: String) {
        queue.async { [self] in
            guard newPath != path else { return }
            path = newPath
            guard running else { return }
            closePort()
            // After the cancel handler has closed the old descriptor.
            queue.async { [self] in openPort() }
        }
    }

    /// Sends a host command ("?", "W20", "T0"…) with its newline.
    public func send(command: String) {
        queue.async { [self] in
            guard let port else { return }
            do {
                try port.write(Array((command + "\n").utf8))
            } catch {
                logger.notice("command \(command, privacy: .public) not sent: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Queue-confined

    private func openPort() {
        guard running, port == nil else { return }
        generation += 1
        let opened = POSIXSerialPort(path: path)
        do {
            try opened.open(baudRate: speed_t(B115200))
        } catch {
            fail("\(error)")
            return
        }
        port = opened
        assembler.reset()
        report(.opening)
        logger.info("opened \(self.path, privacy: .public)")

        let source = DispatchSource.makeReadSource(fileDescriptor: opened.fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        // Dispatch's rule: close the descriptor only once the source is
        // cancelled.
        source.setCancelHandler { opened.close() }
        source.resume()
        readSource = source

        let thisOpen = generation
        queue.asyncAfter(deadline: .now() + silentPortTimeout) { [weak self] in
            guard let self, self.generation == thisOpen, self.link == .opening else { return }
            self.report(.failed("No key interface answering on \(self.path)"))
            // Stays open: an UNO that is just slow to boot still connects.
        }
    }

    private func readAvailable() {
        guard let port else { return }
        while true {
            let count: Int?
            do {
                count = try port.readAvailable(into: &readBuffer)
            } catch {
                fail("Key interface disconnected")
                return
            }
            guard let count else { return }
            let received = clock.now()
            for line in assembler.feed(readBuffer[..<count]) {
                switch line {
                case .banner(let id, let version):
                    logger.info("banner \(id, privacy: .public) v\(version)")
                    report(.connected(deviceID: id, version: version))
                case .heartbeat where !link.isConnected:
                    report(.connected(deviceID: "?", version: 0))
                default:
                    break
                }
                continuation.yield(.line(line, hostReceived: received))
            }
        }
    }

    private func fail(_ message: String) {
        let wasOpen = port != nil
        closePort()
        report(.failed(message))
        if wasOpen { logger.notice("\(message, privacy: .public)") }
        guard running else { return }
        let thisFailure = generation
        queue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
            guard let self, self.generation == thisFailure else { return }
            self.openPort()
        }
    }

    private func closePort() {
        generation += 1
        if let readSource {
            readSource.cancel()   // closes the port
        } else {
            port?.close()
        }
        readSource = nil
        port = nil
    }

    private func report(_ state: CWKeyLinkState) {
        guard state != link else { return }
        link = state
        continuation.yield(.link(state))
    }
}
#endif
