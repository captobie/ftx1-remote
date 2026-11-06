import FTX1Core
import XCTest
@testable import FTX1Digi

private final class FakeClock: DigiSenderClock, @unchecked Sendable {
    var time: TimeInterval = 1000
    func now() -> TimeInterval { time }
    func sleep(seconds: TimeInterval) async {
        time += max(seconds, 0.001)
        await Task.yield()
    }
}

@MainActor
private final class FakeLink: DigiTransmitLink {
    let clock: FakeClock
    var block: String?
    var digiTransmitMode: RigMode? = .dataUSB
    var keyed = false
    /// When set, the rig reports unkeyed from this time on.
    var rigDropsKeyAt: TimeInterval?
    var keyHistory: [Bool] = []
    var audio: [Float] = []
    /// (clock time, total samples sent by then) per chunk.
    var deliveries: [(time: TimeInterval, total: Int)] = []

    init(clock: FakeClock) { self.clock = clock }

    func digiTransmitBlock(keyedBySender: Bool) -> String? { block }
    var digiRigIsKeyed: Bool {
        if let rigDropsKeyAt, clock.now() >= rigDropsKeyAt { return false }
        return keyed
    }
    func digiSetKeyed(_ keyed: Bool) {
        self.keyed = keyed
        keyHistory.append(keyed)
    }
    func digiSendAudio(_ pcm: Data) {
        pcm.withUnsafeBytes { raw in
            for value in raw.bindMemory(to: Int16.self) {
                audio.append(Float(Int16(littleEndian: value)) / 32768)
            }
        }
        deliveries.append((clock.now(), audio.count))
    }
}

@MainActor
final class DigiSenderTests: XCTestCase {
    private var clock: FakeClock!
    private var link: FakeLink!
    private var receiver: DigiReceiver!
    private var sender: DigiSender!

    override func setUp() async throws {
        clock = FakeClock()
        link = FakeLink(clock: clock)
        receiver = DigiReceiver(logSubsystem: "test")
        receiver.mode = .bpsk31
        receiver.setCenter(1000)
        sender = DigiSender(link: link, receiver: receiver, logSubsystem: "test", clock: clock)
        sender.levelDb = -6
    }

    private func waitUntilIdle(limit: Int = 2_000_000) async {
        var spins = 0
        while sender.state != .idle, spins < limit {
            await Task.yield()
            spins += 1
        }
    }

    private func decode(_ audio: [Float], mode: DigiMode, centerHz: Double) -> String {
        let decoder = DigiDecoder(mode: mode, rttySettings: RTTYSettings(), centerHz: centerHz, afc: true, squelch: 0)
        return decoder.process(samples: audio, sampleRate: 8000).text
    }

    func testTypeaheadThenRXSendsTextAndUnkeys() async {
        var echo = ""
        sender.onEcho = { echo += $0 }
        sender.edit(to: "cq test de w1aw")
        sender.transmit()
        XCTAssertEqual(sender.state, .transmitting)
        XCTAssertEqual(link.keyHistory, [true])
        // Typed while transmitting.
        for _ in 0..<20 { await Task.yield() }
        sender.append(" k")
        sender.finish()
        await waitUntilIdle()
        XCTAssertEqual(sender.state, .idle)
        XCTAssertEqual(link.keyHistory, [true, false])
        XCTAssertEqual(sender.text, "")
        XCTAssertEqual(echo, "cq test de w1aw k\n")
        XCTAssertTrue(decode(link.audio, mode: .bpsk31, centerHz: 1000).contains("cq test de w1aw k"))
    }

    func testAudioStaysJustAheadOfRealTime() async {
        sender.edit(to: "pacing")
        sender.transmit()
        sender.finish()
        await waitUntilIdle()
        let start = link.deliveries.first!.time
        for delivery in link.deliveries {
            let ahead = Double(delivery.total) / 8000 - (delivery.time - start)
            XCTAssertLessThanOrEqual(ahead, DigiSender.lead + Double(DigiSender.chunk) / 8000 + 0.001)
            XCTAssertGreaterThan(ahead, 0)
        }
    }

    func testUnkeyWaitsForTheAudioToPlayOut() async {
        sender.edit(to: "e")
        sender.transmit()
        sender.finish()
        let begin = clock.now()
        await waitUntilIdle()
        let audioSeconds = Double(link.audio.count) / 8000
        XCTAssertGreaterThanOrEqual(clock.now() - begin, audioSeconds + 0.29)
    }

    func testStopUnkeysAtOnceAndDropsTheBox() async {
        sender.edit(to: "a long line that won't all go out")
        sender.transmit()
        for _ in 0..<50 { await Task.yield() }
        sender.stop()
        XCTAssertEqual(sender.state, .idle)
        XCTAssertEqual(link.keyHistory, [true, false])
        XCTAssertEqual(sender.text, "")
        let sentSoFar = link.audio.count
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(link.audio.count, sentSoFar, "no audio after Stop")
    }

    func testTransmitLimit() async {
        sender.transmit() // idles forever
        await waitUntilIdle(limit: 20_000_000)
        XCTAssertEqual(sender.state, .idle)
        XCTAssertEqual(link.keyHistory.last, false)
        XCTAssertEqual(sender.message, String(localized: "digiSender.limitReached", bundle: Bundle.module(for: DigiSender.self)))
        XCTAssertEqual(Double(link.audio.count) / 8000, DigiSender.transmitLimit, accuracy: 0.5)
    }

    func testGateClosingMidTransmissionStops() async {
        sender.transmit()
        while clock.now() < 1001 { await Task.yield() }
        link.block = "Enable Transmit is off"
        await waitUntilIdle()
        XCTAssertEqual(sender.message, "Enable Transmit is off")
        XCTAssertEqual(link.keyHistory, [true, false])
    }

    func testRigUnkeyingElsewhereStops() async {
        link.rigDropsKeyAt = 1003
        sender.transmit()
        await waitUntilIdle()
        XCTAssertEqual(link.keyHistory, [true, false])
        XCTAssertGreaterThanOrEqual(clock.now(), 1004)
        XCTAssertLessThan(clock.now(), 1004.2)
    }

    func testRefusedWhenBlockedOrWrongMode() {
        link.block = "transmit is locked"
        sender.transmit()
        XCTAssertEqual(sender.state, .idle)
        XCTAssertEqual(sender.message, "transmit is locked")
        link.block = nil
        link.digiTransmitMode = .fm
        sender.transmit()
        XCTAssertEqual(sender.state, .idle)
        XCTAssertNotNil(sender.message)
        XCTAssertTrue(link.keyHistory.isEmpty)
    }

    func testSentTextCantBeEdited() async {
        sender.edit(to: "abc")
        sender.transmit()
        while sender.sentCount < 2 { await Task.yield() }
        let sent = sender.sentCount
        XCTAssertEqual(sender.edit(to: "x"), "abc", "deleting sent text is refused")
        XCTAssertEqual(sender.edit(to: "abcdef"), "abcdef")
        sender.clearUnsent()
        XCTAssertEqual(sender.text.count, max(sent, sender.sentCount))
        sender.stop()
    }

    func testRTTYOnDataUSendsMarkHigh() async {
        receiver.mode = .rtty
        receiver.rttyReverse = false
        receiver.setCenter(2210)
        link.digiTransmitMode = .dataUSB
        sender.edit(to: "RYRY DE W1AW")
        sender.transmit()
        sender.finish()
        await waitUntilIdle()
        // Heard on an upper sideband: decoder flips for USB as well.
        var settings = RTTYSettings()
        settings.reverse = settings.effectiveReverse(upperSideband: true)
        let decoder = DigiDecoder(mode: .rtty, rttySettings: settings, centerHz: 2210, afc: true, squelch: 0)
        XCTAssertTrue(decoder.process(samples: link.audio, sampleRate: 8000).text.contains("RYRY DE W1AW"))
    }

    func testMacroExpansion() {
        let macro = DigiMacro(label: "Answer", text: "{TX}{CALL} de {MYCALL} k{RX}")
        let expansion = try? macro.expanded(myCall: "W1AW", myGrid: "FN31", theirCall: "K6NA").get()
        XCTAssertEqual(expansion, DigiMacro.Expansion(text: "K6NA de W1AW k", startsTransmit: true, endsTransmit: true))
        if case .success = macro.expanded(myCall: "W1AW", myGrid: "", theirCall: "") {
            XCTFail("an empty Their call must be refused")
        }
    }
}

private extension Bundle {
    /// FTX1Digi's resource bundle, for comparing localized messages.
    static func module(for type: AnyClass) -> Bundle {
        let main = Bundle(for: type)
        let candidates = [main.resourceURL, Bundle.main.resourceURL, main.bundleURL.deletingLastPathComponent()]
        for candidate in candidates.compactMap({ $0 }) {
            let url = candidate.appendingPathComponent("FTX1Core_FTX1Digi.bundle")
            if let bundle = Bundle(url: url) { return bundle }
        }
        return main
    }
}
