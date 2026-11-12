import AVFoundation
import Foundation
import XCTest
@testable import FTX1Core

/// APRS transmit: the encoder against the app's own decoder (through the
/// 8 kHz transmit path), the info fields, the receiver choice, the
/// transmitter's keying, and messaging's retries and acks.
@MainActor
final class APRSTransmitTests: XCTestCase {
    private var suiteName = ""
    private var directory: URL!

    override func setUp() async throws {
        suiteName = "APRSTransmitTests-\(UUID().uuidString)"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        let defaults = UserDefaults(suiteName: suiteName)!
        SettingsStore.use(defaults: defaults, dataDirectory: directory)
        defaults.set("N0CALL", forKey: StationSettings.callsignKey)
        defaults.set(true, forKey: APRSTransmitSettings.enabledKey)
        defaults.set(7, forKey: APRSTransmitSettings.ssidKey)
        defaults.set(41.708333, forKey: APRSTransmitSettings.latitudeKey)
        defaults.set(-72.72, forKey: APRSTransmitSettings.longitudeKey)
        defaults.set("Test station", forKey: APRSTransmitSettings.commentKey)
    }

    override func tearDown() async throws {
        SettingsStore.useStandard()
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Encoder

    /// 8 kHz (the transmit path's rate) up to 44.1 kHz, as the rig's audio
    /// comes back, then the app's demodulator.
    private func decodeAt8k(_ samples: [Float]) throws -> [AX25Frame] {
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let converter = try XCTUnwrap(AVAudioConverter(from: inFormat, to: outFormat))
        let padded = [Float](repeating: 0, count: 400) + samples + [Float](repeating: 0, count: 2000)
        let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(padded.count))!
        input.frameLength = AVAudioFrameCount(padded.count)
        padded.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: padded.count) }
        let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(padded.count * 6))!
        var given = false
        _ = converter.convert(to: output, error: nil) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        let upsampled = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        var demodulator = AFSKDemodulator(sampleRate: 44_100)
        var decoder = AX25FrameDecoder()
        var frames: [AX25Frame] = []
        var start = 0
        while start < upsampled.count {
            let end = min(start + 2048, upsampled.count)
            frames += decoder.process(bits: demodulator.process(samples: Array(upsampled[start..<end])))
            start = end
        }
        return frames
    }

    func testPacketAt8kHzRoundTrips() throws {
        let info = APRSOutgoing.message(to: "W1AW-9", text: "Hello from the test, 73!", id: "42")
        let frame = AX25Encoder.frame(destination: APRSTransmitSettings.destination, source: ("N0CALL", 7),
                                      path: [("WIDE1", 1), ("WIDE2", 1)], info: Array(info.utf8))
        let bits = AX25Encoder.lineBits(frame: frame, leadFlags: AX25Encoder.flags(forSeconds: 0.3), tailFlags: 3)
        let audio = AX25Encoder.afsk(lineBits: bits, sampleRate: 8000, amplitude: 0.5)
        let frames = try decodeAt8k(audio)
        XCTAssertEqual(frames.count, 1)
        let decoded = try XCTUnwrap(frames.first)
        XCTAssertEqual(decoded.source.displayString, "N0CALL-7")
        XCTAssertEqual(decoded.destination.callsign, "APZFTX")
        XCTAssertEqual(decoded.digipeaters.map(\.displayString), ["WIDE1-1", "WIDE2-1"])
        XCTAssertEqual(APRSPacket.parse(infoField: decoded.info), .message(to: "W1AW-9", text: "Hello from the test, 73!", messageID: "42"))
    }

    func testBeaconAt8kHzParsesBackToThePosition() throws {
        let info = try APRSMessaging.beaconInfo().get()
        let frame = AX25Encoder.frame(destination: APRSTransmitSettings.destination, source: ("N0CALL", 7),
                                      path: [], info: Array(info.utf8))
        let audio = AX25Encoder.afsk(lineBits: AX25Encoder.lineBits(frame: frame, leadFlags: 30, tailFlags: 3),
                                     sampleRate: 8000, amplitude: 0.5)
        let decoded = try XCTUnwrap(try decodeAt8k(audio).first)
        XCTAssertTrue(decoded.digipeaters.isEmpty)
        guard case .position(let lat, let lon, let table, let code, let comment) = APRSPacket.parse(infoField: decoded.info) else {
            return XCTFail("not a position: \(info)")
        }
        XCTAssertEqual(lat, 41.708333, accuracy: 0.0001)
        XCTAssertEqual(lon, -72.72, accuracy: 0.0001)
        XCTAssertEqual(table + code, "/-")
        XCTAssertEqual(comment, "Test station")
    }

    func testAddressesAndPaths() {
        XCTAssertEqual(AX25Encoder.address("n0call-9")?.callsign, "N0CALL")
        XCTAssertEqual(AX25Encoder.address("n0call-9")?.ssid, 9)
        XCTAssertNil(AX25Encoder.address("TOOLONGX"))
        XCTAssertNil(AX25Encoder.address("N0CALL-16"))
        XCTAssertNil(AX25Encoder.address("VP2E/K6NA"))
        XCTAssertEqual(AX25Encoder.path("WIDE1-1, WIDE2-1")?.count, 2)
        XCTAssertEqual(AX25Encoder.path("")?.count, 0)
        XCTAssertNil(AX25Encoder.path("WIDE1-1,BAD CALL"))
    }

    // MARK: - Info fields

    func testPositionFormat() {
        XCTAssertEqual(APRSOutgoing.position(latitude: 41.708333, longitude: -72.72, symbolTable: "/", symbolCode: "-", comment: "Home"),
                       "=4142.50N/07243.20W-Home")
        XCTAssertEqual(APRSOutgoing.position(latitude: -33.8688, longitude: 151.2093, symbolTable: "/", symbolCode: "-", comment: ""),
                       "=3352.13S/15112.56E-")
        // 59.999' rounds up into the next degree.
        XCTAssertEqual(APRSOutgoing.coordinate(41.99999, degreeDigits: 2, hemisphere: "N", ambiguity: 0), "4200.00N")
        XCTAssertEqual(APRSOutgoing.coordinate(41.708333, degreeDigits: 2, hemisphere: "N", ambiguity: 2), "4142.  N")
        XCTAssertEqual(APRSOutgoing.coordinate(72.72, degreeDigits: 3, hemisphere: "W", ambiguity: 4), "072  .  W")
    }

    func testMessageAndAckFormat() {
        XCTAssertEqual(APRSOutgoing.message(to: "w1aw", text: "hi {there} | ~", id: "7"), ":W1AW     :hi there}  {7")
        XCTAssertEqual(APRSOutgoing.ack(to: "W1AW-9", id: "12"), ":W1AW-9   :ack12")
        let long = String(repeating: "x", count: 80)
        XCTAssertEqual(APRSOutgoing.message(to: "W1AW", text: long, id: nil).count, 11 + 67)
    }

    func testRepliesParse() {
        XCTAssertEqual(APRSOutgoing.reply(text: "ack12", messageID: nil), .ack(id: "12"))
        XCTAssertEqual(APRSOutgoing.reply(text: "rej3", messageID: nil), .reject(id: "3"))
        XCTAssertEqual(APRSOutgoing.reply(text: "ack3}", messageID: nil), .ack(id: "3"))
        XCTAssertEqual(APRSOutgoing.reply(text: "Sure", messageID: "AB}12"), .ack(id: "12"))
        XCTAssertNil(APRSOutgoing.reply(text: "acknowledged, thanks", messageID: nil))
        XCTAssertNil(APRSOutgoing.reply(text: "hello", messageID: "5"))
        XCTAssertEqual(APRSOutgoing.idToAck("AB}12"), "AB")
        XCTAssertEqual(APRSOutgoing.idToAck("5"), "5")
        XCTAssertNil(APRSOutgoing.idToAck(nil))
    }

    // MARK: - Planner

    private func state(main: Int, mainMode: RigMode = .fm, sub: Int? = nil, subMode: RigMode? = .fm,
                       txSide: FilterSide = .main) -> RigState {
        var state = RigState()
        state.frequencyHz = main
        state.mode = mainMode
        state.secondaryFrequencyHz = sub
        state.secondaryMode = subMode
        state.txSide = txSide
        return state
    }

    private func plan(_ state: RigState, transmitEnabled: Bool = true) -> APRSTransmitDecision {
        APRSTransmitPlanner.plan(state: state, transmitEnabled: transmitEnabled, privileges: nil,
                                 aprsHz: 144_390_000, toleranceHz: 5_000)
    }

    func testPlannerPicksTheReceiverOnFrequency() {
        XCTAssertEqual(plan(state(main: 144_390_000)), .send(APRSTransmitPlan(side: .main, restoreSide: nil)))
        XCTAssertEqual(plan(state(main: 14_074_000, mainMode: .dataUSB, sub: 144_390_000)),
                       .send(APRSTransmitPlan(side: .sub, restoreSide: .main)))
        XCTAssertEqual(plan(state(main: 14_074_000, mainMode: .dataUSB, sub: 144_390_000, txSide: .sub)),
                       .send(APRSTransmitPlan(side: .sub, restoreSide: nil)))
        XCTAssertEqual(plan(state(main: 144_390_000, mainMode: .dataFM, sub: 144_390_000, txSide: .sub)),
                       .send(APRSTransmitPlan(side: .sub, restoreSide: nil)))
        // DATA-FM counts; MAIN's out-of-band HF frequency doesn't matter when SUB sends.
        XCTAssertEqual(plan(state(main: 5_000_000, mainMode: .am, sub: 144_391_000, subMode: .dataFM)),
                       .send(APRSTransmitPlan(side: .sub, restoreSide: .main)))
    }

    func testPlannerRefuses() {
        guard case .blocked = plan(state(main: 146_520_000, sub: 446_000_000)) else { return XCTFail("off frequency") }
        guard case .blocked = plan(state(main: 144_390_000, mainMode: .usb)) else { return XCTFail("wrong mode") }
        guard case .blocked = plan(state(main: 144_390_000), transmitEnabled: false) else { return XCTFail("transmit off") }
        var split = state(main: 144_390_000)
        split.splitEnabled = true
        guard case .blocked = plan(split) else { return XCTFail("split") }
        var single = state(main: 14_074_000, mainMode: .usb, sub: 144_390_000)
        single.singleReceive = true
        guard case .blocked = plan(single) else { return XCTFail("SUB not shown") }
        var scanning = state(main: 144_390_000)
        scanning.memoryScan = .scanning
        guard case .blocked = plan(scanning) else { return XCTFail("scanning") }
    }

    // MARK: - Transmitter

    func testTransmitterKeysSendsAudioAndRestoresTheSide() async {
        let link = FakeLink()
        link.decision = .send(APRSTransmitPlan(side: .sub, restoreSide: .main))
        let clock = FakeClock()
        let transmitter = APRSTransmitter(link: link, logSubsystem: "test", clock: clock, random: { 0 })
        var outcomes: [APRSSendOutcome] = []
        transmitter.onOutcome = { _, outcome in outcomes.append(outcome) }
        transmitter.enqueue(APRSOutgoingPacket(kind: .beacon, info: "=4142.50N/07243.20W-"))
        await waitUntil { !outcomes.isEmpty }
        XCTAssertEqual(outcomes, [.sent(.sub)])
        XCTAssertEqual(link.events, ["key sub", "unkey main"])
        // TXDELAY 400 ms + frame + tail, all of it.
        let seconds = Double(link.audioBytes / 2) / 8000
        XCTAssertGreaterThan(seconds, 0.5)
        XCTAssertLessThan(seconds, 1.5)
        XCTAssertFalse(transmitter.isTransmitting)
    }

    /// The in-transmission check judges the receiver the packet goes out
    /// on, not the old TX side (MAIN on an HF frequency the License blocks).
    func testMidPacketCheckJudgesThePlannedSide() async {
        let link = FakeLink()
        link.decision = .send(APRSTransmitPlan(side: .sub, restoreSide: .main))
        link.blockedSides = [.main]
        let transmitter = APRSTransmitter(link: link, logSubsystem: "test", clock: FakeClock(), random: { 0 })
        var outcomes: [APRSSendOutcome] = []
        transmitter.onOutcome = { _, outcome in outcomes.append(outcome) }
        transmitter.enqueue(APRSOutgoingPacket(kind: .beacon, info: "=x"))
        await waitUntil { !outcomes.isEmpty }
        XCTAssertEqual(outcomes, [.sent(.sub)])
        XCTAssertFalse(link.checkedSides.isEmpty)
        XCTAssertTrue(link.checkedSides.allSatisfy { $0 == .sub })
    }

    func testTransmitterWaitsForAClearChannel() async {
        let link = FakeLink()
        link.busyUntil = 3
        let clock = FakeClock()
        link.clock = clock
        let transmitter = APRSTransmitter(link: link, logSubsystem: "test", clock: clock, random: { 0 })
        var done = false
        transmitter.onOutcome = { _, _ in done = true }
        transmitter.enqueue(APRSOutgoingPacket(kind: .beacon, info: "=x"))
        await waitUntil { done }
        XCTAssertGreaterThanOrEqual(link.keyedAt ?? 0, 3)
    }

    func testTransmitterStopsWhenBlockedMidPacket() async {
        let link = FakeLink()
        let clock = FakeClock()
        link.clock = clock
        link.blockAfter = 0.2
        let transmitter = APRSTransmitter(link: link, logSubsystem: "test", clock: clock, random: { 0 })
        var outcomes: [APRSSendOutcome] = []
        transmitter.onOutcome = { _, outcome in outcomes.append(outcome) }
        transmitter.enqueue(APRSOutgoingPacket(kind: .beacon, info: "=x"))
        await waitUntil { !outcomes.isEmpty }
        XCTAssertEqual(outcomes, [.blocked("blocked")])
        XCTAssertEqual(link.events, ["key -", "unkey -"])
    }

    func testAcksJumpTheQueue() async {
        let link = FakeLink()
        let clock = FakeClock()
        let transmitter = APRSTransmitter(link: link, logSubsystem: "test", clock: clock, random: { 0 })
        var order: [APRSOutgoingPacket.Kind] = []
        transmitter.onOutcome = { packet, _ in order.append(packet.kind) }
        transmitter.enqueue(APRSOutgoingPacket(kind: .beacon, info: "=a"))
        await waitUntil { transmitter.queueCount == 0 }
        transmitter.enqueue(APRSOutgoingPacket(kind: .message("m"), info: ":X        :b{1"))
        transmitter.enqueue(APRSOutgoingPacket(kind: .ack(to: "X", id: "9"), info: ":X        :ack9"))
        await waitUntil { order.count == 3 }
        // The beacon was already on its way when the others came in.
        XCTAssertEqual(order, [.beacon, .ack(to: "X", id: "9"), .message("m")])
    }

    // MARK: - Messaging

    func testMessageRetriesUntilAcked() async {
        let link = FakeLink()
        let clock = FakeClock()
        let store = APRSStore()
        let transmitter = APRSTransmitter(link: link, logSubsystem: "test", clock: clock, random: { 0 })
        let messaging = APRSMessaging(store: store, transmitter: transmitter, logSubsystem: "test", clock: clock)
        transmitter.onOutcome = { messaging.handle($0, $1) }

        XCTAssertNil(messaging.send(text: "Hello", to: "w1aw-9"))
        let id = store.messages.last!.id
        await waitUntil { store.messages.last?.delivery?.attempts == 1 }
        XCTAssertEqual(store.messages.last?.from, "N0CALL-7")
        XCTAssertEqual(store.messages.last?.messageID, "1")

        clock.advance(by: 29); messaging.tick()
        XCTAssertEqual(link.keyCount, 1)
        clock.advance(by: 2); messaging.tick()
        await waitUntil { store.messages.last?.delivery?.attempts == 2 }

        // Their ack, which also isn't acked back.
        messaging.handleIncoming(from: "W1AW-9", to: "N0CALL-7", text: "ack1", messageID: nil)
        XCTAssertEqual(store.messages.first { $0.id == id }?.delivery?.state, .acked)
        clock.advance(by: 120); messaging.tick()
        XCTAssertEqual(link.keyCount, 2)
    }

    func testMessageFailsAfterTheLastTry() async {
        let link = FakeLink()
        let clock = FakeClock()
        let store = APRSStore()
        let transmitter = APRSTransmitter(link: link, logSubsystem: "test", clock: clock, random: { 0 })
        let messaging = APRSMessaging(store: store, transmitter: transmitter, logSubsystem: "test", clock: clock)
        transmitter.onOutcome = { messaging.handle($0, $1) }
        messaging.send(text: "Anyone?", to: "W1AW")
        for attempt in 1...APRSMessaging.retryDelays.count {
            await waitUntil { store.messages.last?.delivery?.attempts == attempt }
            clock.advance(by: APRSMessaging.retryDelays[attempt - 1] + 1)
            messaging.tick()
        }
        XCTAssertEqual(store.messages.last?.delivery?.state, .failed)
        XCTAssertEqual(link.keyCount, APRSMessaging.retryDelays.count)
    }

    func testBlockedAttemptsDontCount() async {
        let link = FakeLink()
        link.decision = .blocked("not on 144.390")
        let clock = FakeClock()
        let store = APRSStore()
        let transmitter = APRSTransmitter(link: link, logSubsystem: "test", clock: clock, random: { 0 })
        let messaging = APRSMessaging(store: store, transmitter: transmitter, logSubsystem: "test", clock: clock)
        transmitter.onOutcome = { messaging.handle($0, $1) }
        messaging.send(text: "Hi", to: "W1AW")
        await waitUntil { store.messages.last?.delivery?.note == "not on 144.390" }
        XCTAssertEqual(store.messages.last?.delivery?.attempts, 0)
        XCTAssertEqual(store.messages.last?.delivery?.state, .pending)
        link.decision = .send(APRSTransmitPlan(side: .main, restoreSide: nil))
        clock.advance(by: 31); messaging.tick()
        await waitUntil { store.messages.last?.delivery?.attempts == 1 }
    }

    func testIncomingMessagesToUsAreAckedOnce() async {
        let link = FakeLink()
        let clock = FakeClock()
        let store = APRSStore()
        let transmitter = APRSTransmitter(link: link, logSubsystem: "test", clock: clock, random: { 0 })
        let messaging = APRSMessaging(store: store, transmitter: transmitter, logSubsystem: "test", clock: clock)
        var sent: [String] = []
        transmitter.onOutcome = { packet, _ in sent.append(packet.info) }

        messaging.handleIncoming(from: "W1AW-9", to: "N0CALL-7", text: "Hi there", messageID: "AB}")
        messaging.handleIncoming(from: "W1AW-9", to: "N0CALL-7", text: "Hi there", messageID: "AB}")
        messaging.handleIncoming(from: "W1AW-9", to: "N0CALL", text: "Other SSID", messageID: "5")
        messaging.handleIncoming(from: "W1AW-9", to: "N0CALL-7", text: "No id", messageID: nil)
        await waitUntil { !sent.isEmpty }
        XCTAssertEqual(sent, [":W1AW-9   :ackAB"])

        // A retry after the repeat limit gets acked again.
        clock.advance(by: APRSMessaging.ackRepeatLimit + 1)
        messaging.handleIncoming(from: "W1AW-9", to: "N0CALL-7", text: "Hi there", messageID: "AB}")
        await waitUntil { sent.count == 2 }

        // Not with auto-ack off.
        SettingsStore.defaults.set(false, forKey: APRSTransmitSettings.autoAckKey)
        clock.advance(by: APRSMessaging.ackRepeatLimit + 1)
        messaging.handleIncoming(from: "W1AW-9", to: "N0CALL-7", text: "Again", messageID: "AC")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sent.count, 2)
    }

    func testStoreSkipsRepeatedMessages() {
        let store = APRSStore()
        let now = Date()
        XCTAssertTrue(store.recordMessage(from: "W1AW", to: "N0CALL", text: "Hi", messageID: "1", receivedAt: now, source: .main))
        XCTAssertFalse(store.recordMessage(from: "W1AW", to: "N0CALL", text: "Hi", messageID: "1", receivedAt: now + 30, source: .main))
        XCTAssertTrue(store.recordMessage(from: "W1AW", to: "N0CALL", text: "Hi", messageID: nil, receivedAt: now + 31, source: .main))
        XCTAssertTrue(store.recordMessage(from: "W1AW", to: "N0CALL", text: "Hi", messageID: "1", receivedAt: now + 3600, source: .main))
    }

    func testBeaconNeedsAPosition() {
        SettingsStore.defaults.removeObject(forKey: APRSTransmitSettings.latitudeKey)
        guard case .failure(.noPosition) = APRSMessaging.beaconInfo() else { return XCTFail() }
    }

    // MARK: - Helpers

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 where !condition() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }
}

/// Seconds that move only when slept through or advanced.
private final class FakeClock: APRSClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0

    func now() -> TimeInterval { lock.withLock { time } }
    func sleep(seconds: TimeInterval) async {
        advance(by: max(0, seconds))
        await Task.yield()
    }
    func advance(by seconds: TimeInterval) { lock.withLock { time += seconds } }
}

@MainActor
private final class FakeLink: APRSTransmitLink {
    var decision = APRSTransmitDecision.send(APRSTransmitPlan(side: .main, restoreSide: nil))
    var events: [String] = []
    var audioBytes = 0
    var keyCount = 0
    var clock: FakeClock?
    var busyUntil: TimeInterval = 0
    var keyedAt: TimeInterval?
    var blockAfter: TimeInterval?

    func aprsPlanTransmit() -> APRSTransmitDecision { decision }
    var blockedSides: Set<FilterSide> = []
    var checkedSides: [FilterSide] = []
    func aprsTransmitBlock(side: FilterSide) -> String? {
        checkedSides.append(side)
        if blockedSides.contains(side) { return "blocked \(side == .main ? "main" : "sub")" }
        guard let blockAfter, let keyedAt, let clock else { return nil }
        return clock.now() - keyedAt >= blockAfter ? "blocked" : nil
    }
    func aprsKey(switchTo side: FilterSide?) {
        events.append("key \(side.map { $0 == .main ? "main" : "sub" } ?? "-")")
        keyCount += 1
        keyedAt = clock?.now() ?? 0
    }
    func aprsUnkey(restoreSide: FilterSide?) {
        events.append("unkey \(restoreSide.map { $0 == .main ? "main" : "sub" } ?? "-")")
    }
    func aprsSendAudio(_ pcm: Data) { audioBytes += pcm.count }
    func aprsChannelBusy(side: FilterSide, within seconds: TimeInterval) -> Bool {
        (clock?.now() ?? 0) < busyUntil
    }
}
