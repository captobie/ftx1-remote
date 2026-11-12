import Combine
import Foundation
import os

/// The APRS side of transmitting: position beacons (Beacon Now and the
/// optional interval), this station's messages with retries until acked,
/// and acks for messages addressed to this station. Everything goes out
/// through an `APRSTransmitter`; nothing does while Settings → APRS →
/// Transmit is off.
@MainActor
public final class APRSMessaging: ObservableObject {
    /// The last beacon's outcome, for the windows' status line.
    @Published public private(set) var beaconStatus: String?
    @Published public private(set) var lastBeaconAt: Date?
    /// When the interval beacon fires next (nil: interval off or transmit off).
    @Published public private(set) var nextBeaconAt: Date?

    /// Seconds to wait after each transmission of a message before sending
    /// it again; one entry per transmission (so 5 tries), the last being
    /// how long to wait for the ack before giving up.
    public static let retryDelays: [TimeInterval] = [30, 60, 120, 240, 240]
    /// A message not sent in this long (transmit blocked all along) fails.
    public static let giveUpAfter: TimeInterval = 15 * 60
    /// Same message from the same station acked at most this often.
    public static let ackRepeatLimit: TimeInterval = 20
    /// Retry after a blocked attempt.
    static let blockedRetry: TimeInterval = 30

    private let store: APRSStore
    private let transmitter: APRSTransmitter
    private let clock: APRSClock
    private let date: () -> Date
    private let logger: Logger

    private struct Pending {
        var created: TimeInterval
        var nextAttempt: TimeInterval
    }
    /// Own messages still waiting for an ack, by `APRSMessage.id`.
    private var pending: [String: Pending] = [:]
    private var lastAcked: [String: TimeInterval] = [:]
    private var nextBeacon: TimeInterval?
    private var timer: Task<Void, Never>?
    private var defaultsObserver: AnyCancellable?

    private static let messageCounterKey = "aprs.tx.messageCounter"

    public init(store: APRSStore, transmitter: APRSTransmitter, logSubsystem: String,
                clock: APRSClock = SystemAPRSClock(), date: @escaping () -> Date = Date.init) {
        self.store = store
        self.transmitter = transmitter
        self.clock = clock
        self.date = date
        logger = Logger(subsystem: logSubsystem, category: "aprs-tx")
        APRSTransmitSettings.registerDefaults()
        // Own messages left pending by the last run aren't resumed: mark them.
        for message in store.messages where message.delivery?.state == .pending {
            store.updateDelivery(id: message.id) {
                $0.state = .failed
                $0.note = String(localized: "aprsMessaging.appQuit", bundle: .module)
            }
        }
    }

    /// Starts the once-a-second housekeeping (retries, interval beacon).
    public func start() {
        guard timer == nil else { return }
        settingsChanged()
        defaultsObserver = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.clock.sleep(seconds: 1)
                self?.tick()
            }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        defaultsObserver = nil
    }

    // MARK: - Beacon

    /// The beacon's info field, or why there's none to send.
    public static func beaconInfo() -> Result<String, APRSSetupProblem> {
        guard APRSTransmitSettings.sourceCall != nil else { return .failure(.noCallsign) }
        guard let latitude = APRSTransmitSettings.latitude, let longitude = APRSTransmitSettings.longitude,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return .failure(.noPosition) }
        let symbol = Array(APRSTransmitSettings.symbol)
        guard symbol.count == 2, symbol.allSatisfy({ $0.isASCII }) else { return .failure(.badSymbol) }
        guard AX25Encoder.path(APRSTransmitSettings.path) != nil else { return .failure(.badPath) }
        return .success(APRSOutgoing.position(latitude: latitude, longitude: longitude, symbolTable: symbol[0],
                                              symbolCode: symbol[1], comment: APRSTransmitSettings.comment,
                                              ambiguity: APRSTransmitSettings.ambiguity))
    }

    public func beaconNow() {
        guard APRSTransmitSettings.enabled else {
            beaconStatus = APRSSetupProblem.transmitOff.message
            return
        }
        switch Self.beaconInfo() {
        case .failure(let problem):
            beaconStatus = problem.message
        case .success(let info):
            guard !transmitter.isQueued(.beacon) else { return }
            beaconStatus = String(localized: "aprsMessaging.beaconQueued", bundle: .module)
            transmitter.enqueue(APRSOutgoingPacket(kind: .beacon, info: info))
        }
        scheduleBeacon(from: clock.now())
    }

    private func settingsChanged() {
        let wanted = APRSTransmitSettings.enabled && APRSTransmitSettings.beaconMinutes > 0
        if !wanted {
            nextBeacon = nil
            if nextBeaconAt != nil { nextBeaconAt = nil }
        } else if nextBeacon == nil || intervalChanged {
            scheduleBeacon(from: clock.now())
        }
        if !APRSTransmitSettings.enabled, transmitter.queueCount > 0 || transmitter.isTransmitting {
            transmitter.stopAll(reason: APRSSetupProblem.transmitOff.message)
        }
    }

    private var scheduledMinutes = 0
    private var intervalChanged: Bool { scheduledMinutes != APRSTransmitSettings.beaconMinutes }

    private func scheduleBeacon(from now: TimeInterval) {
        let minutes = APRSTransmitSettings.beaconMinutes
        scheduledMinutes = minutes
        guard APRSTransmitSettings.enabled, minutes > 0 else {
            nextBeacon = nil
            nextBeaconAt = nil
            return
        }
        let seconds = TimeInterval(minutes * 60)
        nextBeacon = now + seconds
        nextBeaconAt = date().addingTimeInterval(seconds)
    }

    // MARK: - Messages

    /// Queues a message to `addressee`; it's listed in M.LIST at once and
    /// sent until acked. Returns why not, if it can't be.
    @discardableResult
    public func send(text: String, to addressee: String) -> APRSSetupProblem? {
        guard APRSTransmitSettings.enabled else { return .transmitOff }
        guard let myCall = APRSTransmitSettings.sourceCall else { return .noCallsign }
        let to = addressee.trimmingCharacters(in: .whitespaces).uppercased()
        guard !to.isEmpty, to.count <= 9, APRSOutgoing.sanitized(to) == to, !to.contains(":") else { return .badAddressee }
        let body = String(APRSOutgoing.sanitized(text, forMessage: true).prefix(APRSOutgoing.maxMessageLength))
            .trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return .emptyMessage }
        let id = nextMessageID()
        let message = APRSMessage(from: myCall, to: to, text: body, messageID: id, receivedAt: date(),
                                  delivery: APRSDelivery(state: .pending))
        store.recordOutgoing(message)
        let now = clock.now()
        pending[message.id] = Pending(created: now, nextAttempt: now)
        attempt(message.id)
        return nil
    }

    /// Sends it once more (a failed or cancelled one starts over).
    public func resend(messageID id: String) {
        guard let message = store.messages.first(where: { $0.id == id }), message.delivery != nil else { return }
        store.updateDelivery(id: id) {
            $0.state = .pending
            $0.attempts = 0
            $0.note = nil
        }
        let now = clock.now()
        pending[id] = Pending(created: now, nextAttempt: now)
        attempt(id)
    }

    public func cancel(messageID id: String) {
        pending[id] = nil
        transmitter.remove(.message(id))
        store.updateDelivery(id: id) {
            guard $0.state == .pending else { return }
            $0.state = .cancelled
        }
    }

    /// 1…99999, persisted, so ids don't repeat soon across launches.
    private func nextMessageID() -> String {
        let defaults = SettingsStore.defaults
        let next = defaults.integer(forKey: Self.messageCounterKey) % 99_999 + 1
        defaults.set(next, forKey: Self.messageCounterKey)
        return String(next)
    }

    private func attempt(_ id: String) {
        guard let message = store.messages.first(where: { $0.id == id }), message.delivery?.state == .pending,
              let messageID = message.messageID else {
            pending[id] = nil
            return
        }
        guard !transmitter.isQueued(.message(id)) else { return }
        // Not sent until the transmitter's outcome says so.
        pending[id]?.nextAttempt = .infinity
        transmitter.enqueue(APRSOutgoingPacket(kind: .message(id),
                                               info: APRSOutgoing.message(to: message.to, text: message.text, id: messageID)))
    }

    /// The transmitter's outcome for a packet of ours.
    public func handle(_ packet: APRSOutgoingPacket, _ outcome: APRSSendOutcome) {
        let now = clock.now()
        switch packet.kind {
        case .beacon:
            switch outcome {
            case .sent(let side):
                lastBeaconAt = date()
                beaconStatus = String(localized: "aprsMessaging.beaconSent \(side.displayName)", bundle: .module)
            case .blocked(let reason):
                beaconStatus = String(localized: "aprsMessaging.beaconNotSent \(reason)", bundle: .module)
            }
        case .ack(let to, let id):
            if case .blocked(let reason) = outcome {
                logger.notice("ack \(id, privacy: .public) to \(to, privacy: .public) not sent: \(reason, privacy: .public)")
            }
        case .message(let id):
            guard pending[id] != nil else { return }
            switch outcome {
            case .sent:
                var attempts = 0
                store.updateDelivery(id: id) {
                    guard $0.state == .pending else { return }
                    $0.attempts += 1
                    $0.note = nil
                    attempts = $0.attempts
                }
                guard attempts > 0 else { pending[id] = nil; return }
                let delay = Self.retryDelays[min(attempts, Self.retryDelays.count) - 1]
                pending[id]?.nextAttempt = now + delay
            case .blocked(let reason):
                store.updateDelivery(id: id) { $0.note = reason }
                pending[id]?.nextAttempt = now + Self.blockedRetry
            }
        }
    }

    /// Once a second: due retries, give-ups, the interval beacon.
    public func tick() {
        let now = clock.now()
        for (id, entry) in pending where entry.nextAttempt <= now {
            let delivery = store.messages.first { $0.id == id }?.delivery
            guard let delivery, delivery.state == .pending else {
                pending[id] = nil
                continue
            }
            if delivery.attempts >= Self.retryDelays.count {
                pending[id] = nil
                store.updateDelivery(id: id) {
                    $0.state = .failed
                    $0.note = String(localized: "aprsMessaging.noAck", bundle: .module)
                }
            } else if now - entry.created > Self.giveUpAfter {
                pending[id] = nil
                store.updateDelivery(id: id) { $0.state = .failed }
            } else {
                attempt(id)
            }
        }
        if let nextBeacon, now >= nextBeacon {
            // A missed beacon (setup incomplete, transmit blocked) just
            // waits for the next interval.
            beaconNow()
        }
        lastAcked = lastAcked.filter { now - $0.value < Self.ackRepeatLimit }
    }

    // MARK: - Received

    /// Every decoded message (both receivers): acks for our messages, and
    /// an ack back for messages to us that carry an id.
    public func handleIncoming(from: String, to: String, text: String, messageID: String?) {
        guard let myCall = APRSTransmitSettings.sourceCall,
              to.trimmingCharacters(in: .whitespaces).uppercased() == myCall else { return }
        let sender = from.uppercased()

        switch APRSOutgoing.reply(text: text, messageID: messageID) {
        case .ack(let id)?:
            settle(from: sender, id: id, as: .acked)
        case .reject(let id)?:
            settle(from: sender, id: id, as: .rejected)
        case nil:
            break
        }

        // A plain "ack"/"rej" has no id of its own; a message (incl. one
        // with a reply-ack) gets acked.
        guard let id = APRSOutgoing.idToAck(messageID), APRSTransmitSettings.enabled, APRSTransmitSettings.autoAck,
              AX25Encoder.address(sender) != nil else { return }
        let key = sender + "|" + id
        let now = clock.now()
        if let last = lastAcked[key], now - last < Self.ackRepeatLimit { return }
        let kind = APRSOutgoingPacket.Kind.ack(to: sender, id: id)
        guard !transmitter.isQueued(kind) else { return }
        lastAcked[key] = now
        transmitter.enqueue(APRSOutgoingPacket(kind: kind, info: APRSOutgoing.ack(to: sender, id: id)))
    }

    private func settle(from sender: String, id: String, as state: APRSDelivery.State) {
        guard let message = store.messages.last(where: {
            $0.delivery != nil && $0.to.uppercased() == sender && $0.messageID == id
        }) else { return }
        pending[message.id] = nil
        transmitter.remove(.message(message.id))
        store.updateDelivery(id: message.id) {
            $0.state = state
            $0.note = nil
        }
        logger.notice("message \(id, privacy: .public) to \(sender, privacy: .public) \(state.rawValue, privacy: .public)")
    }
}

/// Why APRS can't transmit yet, worded for the user.
public enum APRSSetupProblem: Error, Equatable, Sendable {
    case transmitOff
    case noCallsign
    case noPosition
    case badSymbol
    case badPath
    case badAddressee
    case emptyMessage

    public var message: String {
        switch self {
        case .transmitOff: String(localized: "aprsMessaging.transmitOff", bundle: .module)
        case .noCallsign: String(localized: "aprsTransmit.noCallsign", bundle: .module)
        case .noPosition: String(localized: "aprsMessaging.noPosition", bundle: .module)
        case .badSymbol: String(localized: "aprsMessaging.badSymbol", bundle: .module)
        case .badPath: String(localized: "aprsTransmit.badPath", bundle: .module)
        case .badAddressee: String(localized: "aprsMessaging.badAddressee", bundle: .module)
        case .emptyMessage: String(localized: "aprsMessaging.emptyMessage", bundle: .module)
        }
    }
}
