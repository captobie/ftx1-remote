import Foundation
import os

/// Which receiver an APRS packet goes out on, and the TX side to put back
/// afterwards.
public struct APRSTransmitPlan: Equatable, Sendable {
    public var side: FilterSide
    /// The TX side before the packet, when the packet needs the other one.
    public var restoreSide: FilterSide?

    public init(side: FilterSide, restoreSide: FilterSide?) {
        self.side = side
        self.restoreSide = restoreSide
    }
}

public enum APRSTransmitDecision: Equatable, Sendable {
    case send(APRSTransmitPlan)
    case blocked(String)
}

/// Picks the receiver for an APRS packet: MAIN or SUB, whichever is on the
/// APRS frequency in FM or DATA-FM (the current TX side first), then the
/// transmit gate judged as if that side transmitted.
public enum APRSTransmitPlanner {
    public static let modes: Set<RigMode> = [.fm, .dataFM]

    public static func plan(state: RigState, transmitEnabled: Bool, privileges: PrivilegeProfile?,
                            aprsHz: Int, toleranceHz: Int) -> APRSTransmitDecision {
        if state.memoryScan == .scanning || state.memoryScan == .paused {
            return .blocked(String(localized: "aprsTransmit.memoryScan", bundle: .module))
        }
        if state.splitEnabled == true {
            return .blocked(String(localized: "aprsTransmit.split", bundle: .module))
        }
        func onFrequency(_ hz: Int?) -> Bool {
            guard let hz, hz > 0 else { return false }
            return abs(hz - aprsHz) <= toleranceHz
        }
        let mainOn = onFrequency(state.frequencyHz)
        let subReceives = state.singleReceive != true
        let subOn = subReceives && onFrequency(state.secondaryFrequencyHz)
        let mainOK = mainOn && modes.contains(state.mode)
        let subOK = subOn && state.secondaryMode.map(modes.contains) == true

        let current = state.txSide ?? .main
        let side: FilterSide
        if current == .sub, subOK {
            side = .sub
        } else if mainOK {
            side = .main
        } else if subOK {
            side = .sub
        } else {
            let frequency = FrequencyFormat.mhz(aprsHz, fractionDigits: 3)
            if mainOn || subOn {
                return .blocked(String(localized: "aprsTransmit.wrongMode \(frequency)", bundle: .module))
            }
            return .blocked(String(localized: "aprsTransmit.notOnFrequency \(frequency)", bundle: .module))
        }

        var transmitting = state
        transmitting.txSide = side
        if let reason = TransmitGate.blockReason(transmitEnabled: transmitEnabled, state: transmitting, privileges: privileges) {
            return .blocked(reason)
        }
        return .send(APRSTransmitPlan(side: side, restoreSide: side == current ? nil : current))
    }
}

/// What the APRS transmitter needs from the app. The Mac's `HubService`
/// implements it.
@MainActor
public protocol APRSTransmitLink: AnyObject {
    /// Before keying: the receiver to use, or why not now (incl. no rig,
    /// no transmit audio path, the rig keyed by something else).
    func aprsPlanTransmit() -> APRSTransmitDecision
    /// While keyed: why it must stop now, nil when it may go on — judged
    /// for `side`, the receiver the packet is going out on, not the TX side
    /// the rig reports (it may not have caught up with the switch yet).
    func aprsTransmitBlock(side: FilterSide) -> String?
    /// Keys the rig, first moving the TX side to `switchTo` when given —
    /// in that order (the gate was already judged for that side by
    /// `aprsPlanTransmit`).
    func aprsKey(switchTo side: FilterSide?)
    /// Unkeys, then puts the TX side back to `restoreSide` when given.
    func aprsUnkey(restoreSide: FilterSide?)
    /// 16-bit little-endian mono PCM at 8 kHz (`AudioStreamFormat`).
    func aprsSendAudio(_ pcm: Data)
    /// Packet audio heard on that receiver within `seconds`.
    func aprsChannelBusy(side: FilterSide, within seconds: TimeInterval) -> Bool
}

/// Time for the transmitter and messaging; replaced in tests.
public protocol APRSClock: Sendable {
    /// Seconds on a monotonic clock.
    func now() -> TimeInterval
    func sleep(seconds: TimeInterval) async
}

public struct SystemAPRSClock: APRSClock {
    public init() {}
    public func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// One packet waiting to go out.
public struct APRSOutgoingPacket: Sendable {
    public enum Kind: Equatable, Sendable {
        case beacon
        /// The `APRSMessage.id` of an own message.
        case message(String)
        /// To this call, for this id.
        case ack(to: String, id: String)
    }

    public var kind: Kind
    public var info: String

    public init(kind: Kind, info: String) {
        self.kind = kind
        self.info = info
    }
}

public enum APRSSendOutcome: Equatable, Sendable {
    case sent(FilterSide)
    case blocked(String)
}

/// Sends APRS packets one at a time: waits for a clear channel, switches
/// the TX side to the receiver on the APRS frequency if needed, keys,
/// plays TXDELAY flags + the frame as 8 kHz Bell 202 audio paced just
/// ahead of real time, unkeys once it has played out, and puts the TX side
/// back.
@MainActor
public final class APRSTransmitter: ObservableObject {
    @Published public private(set) var isTransmitting = false
    @Published public private(set) var queueCount = 0

    /// Each packet's outcome, in order.
    public var onOutcome: ((APRSOutgoingPacket, APRSSendOutcome) -> Void)?

    public static let sampleRate = 8000.0
    static let lead: TimeInterval = 0.25
    static let tick: TimeInterval = 0.02
    static let chunk = 160
    /// After the last sample: the lead still to play plus the output's own buffer.
    static let unkeyDelay: TimeInterval = lead + 0.3
    static let tailFlags = 3
    /// The channel must have been quiet this long.
    static let clearFor: TimeInterval = 1.5
    /// Longest wait for a clear channel before sending anyway.
    static let maxChannelWait: TimeInterval = 10
    /// Between two packets of ours.
    static let packetGap: TimeInterval = 1.0

    private weak var link: APRSTransmitLink?
    private let clock: APRSClock
    private let logger: Logger
    /// Waiting, in order; the one being sent is `current`.
    private var queue: [APRSOutgoingPacket] = []
    private var current: APRSOutgoingPacket?
    private var loop: Task<Void, Never>?
    private var random: () -> Double
    /// The TX side to put back after the packet being sent.
    private var activeRestore: FilterSide?

    public init(link: APRSTransmitLink, logSubsystem: String, clock: APRSClock = SystemAPRSClock(),
                random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.link = link
        self.clock = clock
        self.random = random
        logger = Logger(subsystem: logSubsystem, category: "aprs-tx")
    }

    /// Acks go ahead of everything else; the rest in order.
    public func enqueue(_ packet: APRSOutgoingPacket) {
        if case .ack = packet.kind {
            let firstNonAck = queue.firstIndex { if case .ack = $0.kind { false } else { true } } ?? queue.count
            queue.insert(packet, at: firstNonAck)
        } else {
            queue.append(packet)
        }
        queueCount = queue.count
        if loop == nil {
            loop = Task { [weak self] in await self?.run() }
        }
    }

    /// Waiting or being sent.
    public func isQueued(_ kind: APRSOutgoingPacket.Kind) -> Bool {
        current?.kind == kind || queue.contains { $0.kind == kind }
    }

    /// Drops a waiting packet (not the one being sent).
    public func remove(_ kind: APRSOutgoingPacket.Kind) {
        queue.removeAll { $0.kind == kind }
        queueCount = queue.count
    }

    /// Unkeys now and drops the queue (Enable Transmit off, link lost).
    public func stopAll(reason: String) {
        loop?.cancel()
        loop = nil
        let dropped = (current.map { [$0] } ?? []) + queue
        current = nil
        queue = []
        queueCount = 0
        if isTransmitting {
            link?.aprsUnkey(restoreSide: activeRestore)
            activeRestore = nil
            isTransmitting = false
            logger.notice("APRS TX stopped: \(reason, privacy: .public)")
        }
        for packet in dropped { onOutcome?(packet, .blocked(reason)) }
    }

    private func run() async {
        while !Task.isCancelled, !queue.isEmpty {
            let packet = queue.removeFirst()
            current = packet
            queueCount = queue.count
            let outcome = await send(packet)
            guard !Task.isCancelled else { return }
            current = nil
            onOutcome?(packet, outcome)
            if case .sent = outcome, !queue.isEmpty {
                await clock.sleep(seconds: Self.packetGap)
            }
        }
        loop = nil
    }

    private func send(_ packet: APRSOutgoingPacket) async -> APRSSendOutcome {
        guard let link else { return .blocked("No link") }
        guard let call = APRSTransmitSettings.sourceCall, let source = AX25Encoder.address(call) else {
            return .blocked(String(localized: "aprsTransmit.noCallsign", bundle: .module))
        }
        guard let path = AX25Encoder.path(APRSTransmitSettings.path) else {
            return .blocked(String(localized: "aprsTransmit.badPath", bundle: .module))
        }

        // Wait for a clear channel (bounded), then a short random delay so
        // two stations waiting for the same gap don't both go.
        let waitStart = clock.now()
        var plan: APRSTransmitPlan
        while true {
            switch link.aprsPlanTransmit() {
            case .blocked(let reason): return .blocked(reason)
            case .send(let chosen): plan = chosen
            }
            if clock.now() - waitStart < Self.maxChannelWait,
               link.aprsChannelBusy(side: plan.side, within: Self.clearFor) {
                await clock.sleep(seconds: 0.25)
                if Task.isCancelled { return .blocked("cancelled") }
                continue
            }
            await clock.sleep(seconds: 0.1 + 0.4 * random())
            if Task.isCancelled { return .blocked("cancelled") }
            switch link.aprsPlanTransmit() {
            case .blocked(let reason): return .blocked(reason)
            case .send(let chosen): plan = chosen
            }
            break
        }

        let frame = AX25Encoder.frame(destination: APRSTransmitSettings.destination, source: source,
                                      path: path, info: Array(packet.info.utf8))
        let bits = AX25Encoder.lineBits(frame: frame,
                                        leadFlags: AX25Encoder.flags(forSeconds: Double(APRSTransmitSettings.txDelayMs) / 1000),
                                        tailFlags: Self.tailFlags)
        let level = Float(pow(10, APRSTransmitSettings.levelDb / 20))
        let samples = AX25Encoder.afsk(lineBits: bits, sampleRate: Self.sampleRate, amplitude: level)

        link.aprsKey(switchTo: plan.restoreSide != nil ? plan.side : nil)
        isTransmitting = true
        activeRestore = plan.restoreSide
        logger.notice("APRS TX on \(plan.side.displayName, privacy: .public): \(call, privacy: .public)>\(packet.info, privacy: .public)")
        defer {
            isTransmitting = false
            activeRestore = nil
        }

        let start = clock.now()
        var sent = 0
        while sent < samples.count {
            if Task.isCancelled { return .blocked("cancelled") }
            if let reason = link.aprsTransmitBlock(side: plan.side) {
                link.aprsUnkey(restoreSide: plan.restoreSide)
                logger.notice("APRS TX stopped: \(reason, privacy: .public)")
                return .blocked(reason)
            }
            let target = min(samples.count, Int(((clock.now() - start + Self.lead) * Self.sampleRate).rounded()))
            while sent < target {
                let end = min(target, sent + Self.chunk)
                link.aprsSendAudio(Self.pcm(samples[sent..<end]))
                sent = end
            }
            if sent < samples.count { await clock.sleep(seconds: Self.tick) }
        }
        let playedOut = start + Double(samples.count) / Self.sampleRate + Self.unkeyDelay - Self.lead
        await clock.sleep(seconds: max(0, playedOut - clock.now()))
        link.aprsUnkey(restoreSide: plan.restoreSide)
        return .sent(plan.side)
    }

    static func pcm(_ samples: ArraySlice<Float>) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample)) * 32767).littleEndian
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        return data
    }
}
