import Foundation

/// The key interface link, as a `CWKeySource` reports it.
public enum CWKeyLinkState: Sendable, Equatable {
    /// Not started, or stopped.
    case closed
    /// Port opening, or open and waiting for the device (the UNO resets
    /// when its port opens, and talks ~1.5 s later).
    case opening
    /// The device is talking: its banner, or a valid heartbeat if the
    /// banner was missed (`deviceID` "?" then).
    case connected(deviceID: String, version: Int)
    /// Failed; the source retries by itself.
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { true } else { false }
    }
}

/// What a key source delivers.
public enum CWKeySourceEvent: Sendable, Equatable {
    /// A line from the device, with the host time (`CWHostClock`, seconds)
    /// its bytes were read — taken by the reader, before any hop to
    /// another thread, since the clock sync measures transport delay.
    case line(CWKeyLine, hostReceived: Double)
    case link(CWKeyLinkState)
}

/// Where straight-key events come from. Serial (the Arduino interface,
/// `SerialCWKeySource` on the Mac) today; a WebSocket relay from a remote
/// client, MIDI or BLE later — they all deliver the same line events
/// (`docs/cw-protocol.md`), so `CWStraightKeyEngine` can't tell them
/// apart.
public protocol CWKeySource: AnyObject, Sendable {
    /// One stream for the source's lifetime; it finishes when the source
    /// is deallocated.
    var events: AsyncStream<CWKeySourceEvent> { get }
    /// Starts (or restarts) the link. Reconnects by itself until `stop`.
    func start()
    /// Closes the link; reports `.closed`.
    func stop()
}

/// Drives the rig's key line.
public protocol CWKeyer: AnyObject {
    /// Opens the keying port with the line up (confirmed).
    func open() throws
    /// Sets the key line. A throw means the line state is unknown: the
    /// caller must get it released (`release`, `reopen`) before giving up
    /// on the keyer.
    func setKeyed(_ keyed: Bool) throws
    /// Key-up, confirmed by reading the line back; throws if it can't be
    /// set or still reads as key-down.
    func release() throws
    /// Closes and opens the port again (which leaves the line up).
    func reopen() throws
    /// Releases the line (best effort, unconfirmed) and closes.
    func close()
}

/// The host's monotonic clock in seconds — the same time base as
/// `DispatchTime`, so deadlines can be handed to dispatch timers.
public protocol CWHostClock: Sendable {
    func now() -> Double
}

public struct CWMonotonicClock: CWHostClock {
    public init() {}
    public func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// Which modem-control line keys the rig — the FTX-1's CW SETTING → MODE
/// CW → PC KEYING menu (OFF / RTS / DTR) has to name the same one. Used on
/// the Mac (`ModemLineCWKeyer`) and sent to the Pi (`cw_hello`).
public enum CWKeyingLine: String, CaseIterable, Sendable, Codable {
    case rts = "RTS"
    case dtr = "DTR"
}
