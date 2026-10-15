import Foundation
import XCTest
@testable import FTX1Core

/// Drives the Demo Mode rig through the app's real `RigctldClient` and
/// `CommandQueue` over loopback, so the simulator answers in exactly the
/// shapes the app parses.
final class SimulatedRigTests: XCTestCase {
    private var clock: TestClock!
    private var rig: SimulatedRig!
    private var server: SimulatedRigctldServer!
    private var client: RigctldClient!
    private var queue: CommandQueue!

    override func setUp() async throws {
        clock = TestClock()
        let clock = clock!
        rig = SimulatedRig(clock: { clock.now })
        server = SimulatedRigctldServer(rig: rig)
        let port = try await server.start()
        client = RigctldClient(host: "127.0.0.1", port: port)
        try await client.connect()
        queue = CommandQueue(rigctld: client)
    }

    override func tearDown() async throws {
        await client.disconnect()
        server.stop()
    }

    /// `CommandQueue` applies asynchronously; this waits for the command to
    /// have gone out.
    private func apply(_ command: RigCommand) async {
        let done = expectation(description: "applied")
        await queue.setOnCommandApplied { _, _ in done.fulfill() }
        await queue.enqueue(command)
        await fulfillment(of: [done], timeout: 5)
        await queue.setOnCommandApplied { _, _ in }
    }

    func testDumpCapsNamesTheFTX1() async throws {
        let port = try await serverPort()
        let probe = RigctldClient(host: "127.0.0.1", port: try XCTUnwrap(port))
        try await probe.connect()
        let model = try await probe.readRigModel()
        XCTAssertEqual(model, RigctldRigModel(number: 1051, manufacturer: "Yaesu", name: "FTX-1"))
    }

    private func serverPort() async throws -> UInt16? {
        // A second server on the same rig, for a client that disconnects
        // itself (readRigModel).
        let second = SimulatedRigctldServer(rig: rig)
        addTeardownBlock { second.stop() }
        return try await second.start()
    }

    func testFrequencyAndModeReadsAndSets() async throws {
        let main = try await client.getFrequency()
        XCTAssertEqual(main, 14_047_500)
        let mainMode = try await client.getModeCode(p1: 0)
        XCTAssertEqual(mainMode, "3")
        let sub = try await client.getFrequency(ofVFO: "Sub")
        XCTAssertEqual(sub, 144_390_000)
        let subMode = try await client.getModeCode(p1: 1)
        XCTAssertEqual(subMode, "4")

        await apply(.setFrequency(hz: 14_074_000))
        await apply(.setMode(.dataUSB))
        let tuned = try await client.getFrequency()
        XCTAssertEqual(tuned, 14_074_000)
        let mode = try await client.getMode()
        XCTAssertEqual(mode.mode, "PKTUSB")
        XCTAssertEqual(mode.passband, 2400)

        await apply(.setSecondaryFrequency(hz: 145_500_000))
        await apply(.setSecondaryMode(.am))
        let subTuned = try await client.getFrequency(ofVFO: "Sub")
        XCTAssertEqual(subTuned, 145_500_000)
        let subModeAfter = try await client.getModeCode(p1: 1)
        XCTAssertEqual(subModeAfter, "5")
        let active = try await client.getActiveVFO()
        XCTAssertEqual(active, "Main", "setSecondaryFrequency must leave MAIN active")

        await apply(.setMode(.c4fm))
        let c4fm = try await client.getModeCode(p1: 0)
        XCTAssertEqual(c4fm, "H")
    }

    func testUnknownRawCommandAnswersQuestionMark() async throws {
        let reply = try await client.sendRawCommand("ZZ9")
        XCTAssertEqual(reply, "?;")
        let level = try await client.getLevel("NOTALEVEL")
        XCTAssertNil(level)
    }

    func testMenuGridRegistersReadAndWrite() async throws {
        let breakIn = try await client.getRawBool("BI")
        XCTAssertEqual(breakIn, true)
        await apply(.setCWSpeed(wpm: 28))
        let speed = try await client.getRawInt("KS")
        XCTAssertEqual(speed, 28)
        await apply(.setCWPitch(hz: 600))
        let pitch = try await client.getRawInt("KP")
        XCTAssertEqual(pitch, 30)
        await apply(.setDisplayMarker(false))
        let marker = try await client.getRawBool("SS02")
        XCTAssertEqual(marker, false)
        await apply(.setDisplayLevel(-7.5))
        let level = try await client.getSpectrumScopeLevel()
        XCTAssertEqual(level, -7.5)
        await apply(.setDisplayContrast(12))
        let display = try await client.getDisplaySettings()
        XCTAssertEqual(display?.contrast, 12)
        await apply(.setTuner(true))
        let tuner = try await client.getTunerEnabled()
        XCTAssertEqual(tuner, true)
        await apply(.setPowerLevel(0.25))
        let power = try await client.getLevel("RFPOWER")
        XCTAssertEqual(power, 0.25)
    }

    func testDeepSettingsReadBackAWrite() async throws {
        // CW MEMORY 1 starts as TEXT, as the CW sender needs.
        let memoryType = try await client.getMenuItem(p1: 2, p2: 2, p3: 6)
        XCTAssertEqual(memoryType, "0")
        let item = try XCTUnwrap(DeepSettingsCatalog.items.first { if case .toggle = $0.valueType { return true } else { return false } })
        let before = try await client.getMenuItem(p1: item.p1, p2: item.p2, p3: item.p3)
        XCTAssertEqual(before, "0")
        await apply(.setMenuItem(p1: item.p1, p2: item.p2, p3: item.p3, rawValue: "1"))
        let after = try await client.getMenuItem(p1: item.p1, p2: item.p2, p3: item.p3)
        XCTAssertEqual(after, "1")
        // Every catalog item that has a value reads back decodable.
        for item in DeepSettingsCatalog.items.prefix(40) {
            switch item.valueType {
            case .readOnly, .action: continue
            default: break
            }
            let raw = try await client.getMenuItem(p1: item.p1, p2: item.p2, p3: item.p3)
            XCTAssertNotNil(raw.flatMap(item.decode), "\(item.id) \(item.label)")
        }
    }

    func testFilterStateReadsAndSets() async throws {
        let snapshot = await client.readFilterState(side: .main, mode: .cw)
        XCTAssertEqual(snapshot.widthIndex, 10)
        XCTAssertEqual(snapshot.shiftHz, 0)
        XCTAssertEqual(snapshot.notchRaw, 0)
        XCTAssertEqual(snapshot.notchCode.flatMap(IFNotch.hz(forCode:)), 1500)
        XCTAssertEqual(snapshot.apfCode.flatMap(IFContour.apfHz(forCode:)), 0)
        XCTAssertEqual(snapshot.narrowEnabled, false)
        XCTAssertEqual(snapshot.narrowWidthHz, 500)

        await apply(.setIFShift(hz: -240))
        await apply(.setNotch(true))
        await apply(.setFilterWidth(7))
        var state = RigState(mode: .cw)
        state.applyFilterSnapshot(await client.readFilterState(side: .main, mode: .cw), mode: .cw)
        XCTAssertEqual(state.ifShiftHz, -240)
        XCTAssertEqual(state.notchEnabled, true)
        XCTAssertEqual(state.filterWidthIndex, 7)

        // SUB is its own: unchanged.
        let sub = await client.readFilterState(side: .sub, mode: .fm)
        XCTAssertEqual(sub.widthIndex, 3)
        XCTAssertEqual(sub.shiftHz, 0)
        // N/W in FM moves "SH" to the narrow width.
        await apply(.setFilterSide(.sub))
        await apply(.setNarrow(true))
        let narrowed = try await client.getRawInt("SH1")
        XCTAssertEqual(narrowed, 2)
    }

    func testMemoryChannelsListRecallAndVM() async throws {
        let repeater = try await client.readMemoryChannel(2)
        XCTAssertEqual(repeater?.frequencyHz, 146_940_000)
        XCTAssertEqual(repeater?.modeName, "FM")
        XCTAssertEqual(repeater?.shiftName, "−")
        XCTAssertEqual(repeater?.toneName, "TONE")
        XCTAssertEqual(repeater?.tag, "DEMO RPT")
        let blank = try await client.readMemoryChannel(99)
        XCTAssertNil(blank)

        await apply(.recallMemoryChannel(channel: 4, sub: false))
        let mode = try await client.getRawInt("VM0")
        XCTAssertEqual(mode, 11)
        let channel = try await client.getRawInt("MC0")
        XCTAssertEqual(channel, 4)
        let hz = try await client.getFrequency()
        XCTAssertEqual(hz, 144_390_000)
        let tag = try await client.getMemoryChannelTag(channel: 4)
        XCTAssertEqual(tag, "APRS")

        await apply(.stepMemoryChannel(up: true))
        let stepped = try await client.getRawInt("MC0")
        XCTAssertEqual(stepped, 5)

        // Leaving Memory over CAT parks MAIN on the channel's values.
        await apply(.setVFOMemoryMode(memory: false))
        let parked = try await client.getFrequency()
        XCTAssertEqual(parked, 446_000_000)
        let vfo = try await client.getRawInt("VM0")
        XCTAssertEqual(vfo, 0)

        // SUB's step skips blank channels.
        await apply(.setSubMemoryChannel(15))
        await apply(.recallMemoryChannel(channel: 15, sub: true))
        await apply(.stepSubMemoryChannel(up: true))
        let wrapped = try await client.getRawInt("MC1")
        XCTAssertEqual(wrapped, 1)
    }

    func testSwapExchangesSidesAndAudioStaysWithTheReceiver() async throws {
        let before = rig.audioSnapshot()
        XCTAssertEqual(before.left.hz, 14_047_500)
        await apply(.swapActiveVFO)
        let main = try await client.getFrequency()
        let sub = try await client.getFrequency(ofVFO: "Sub")
        XCTAssertEqual(main, 144_390_000)
        XCTAssertEqual(sub, 14_047_500)
        let after = rig.audioSnapshot()
        XCTAssertEqual(after.left.hz, 14_047_500, "L stays with the physical receiver")
        XCTAssertEqual(after.right.hz, 144_390_000)

        // In single-receive display "SV" doesn't move the audio.
        try await client.setRawInt("FR", 1, digits: 2)
        await apply(.swapActiveVFO)
        let single = rig.audioSnapshot()
        XCTAssertEqual(single.left.hz, 144_390_000)
        XCTAssertFalse(single.left.receiving == single.right.receiving && single.right.receiving)
    }

    func testTXSideMovesCurrVFO() async throws {
        await apply(.setTXSide(.sub))
        let active = try await client.getActiveVFO()
        XCTAssertEqual(active, "Sub")
        let side = try await client.getRawDigit("FT")
        XCTAssertEqual(side, 1)
        await apply(.setFrequency(hz: 145_000_000))
        let sub = try await client.getFrequency(ofVFO: "Sub")
        XCTAssertEqual(sub, 145_000_000, "currVFO follows VS/FT")
    }

    func testMemoryScanStepsPausesOnTheRepeaterAndSkips() async throws {
        // After the first APRS burst (6 s), which would pause it on 4.
        clock.now = 8
        await apply(.recallMemoryChannel(channel: 1, sub: false))
        await apply(.setTXSide(.sub))
        await apply(.setMemoryScan(.up, side: .main))
        var info = try await client.getRadioInformation()
        XCTAssertEqual(info?.scan, .scanning)
        let side = try await client.getRawDigit("SC")
        XCTAssertEqual(side, 0)
        let txSide = try await client.getRawDigit("FT")
        XCTAssertEqual(txSide, 0, "a scan moves VS/FT to the scanning side")

        clock.now += 0.35
        let moved = try await client.getRawInt("MC0")
        XCTAssertNotEqual(moved, 1)

        // The repeater (channel 2) keys up at 12 s.
        clock.now = 14
        info = try await client.getRadioInformation()
        XCTAssertEqual(info?.scan, .paused)
        XCTAssertEqual(info?.squelchOpen, true)
        let paused = try await client.getRawInt("MC0")
        XCTAssertEqual(paused, 2)

        // Skip: on past it.
        await apply(.setMemoryScan(.up, side: .main))
        let skipped = try await client.getRawInt("MC0")
        XCTAssertEqual(skipped, 3)
        info = try await client.getRadioInformation()
        XCTAssertEqual(info?.scan, .scanning)

        // Any stop stops it, and "SC;" reads back the stop.
        await apply(.setMemoryScan(.off, side: .sub))
        info = try await client.getRadioInformation()
        XCTAssertEqual(info?.scan, .stopped)
    }

    func testScanResumesAfterTheRepeaterDrops() async throws {
        await apply(.recallMemoryChannel(channel: 1, sub: false))
        clock.now = 11.9
        await apply(.setMemoryScan(.up, side: .main))
        clock.now = 13
        var info = try await client.getRadioInformation()
        XCTAssertEqual(info?.scan, .paused)
        // Up 8 s; quiet for a second after that.
        clock.now = 20.5
        _ = try await client.getRadioInformation()
        clock.now = 21.6
        info = try await client.getRadioInformation()
        XCTAssertEqual(info?.scan, .scanning)
    }

    func testKeyerMemoryWritePlayAndStop() async throws {
        let stored = try await client.writeKeyerMemory(slot: 1, text: "CQ TEST DE DEMO")
        XCTAssertEqual(stored, "CQ TEST DE DEMO")
        do {
            _ = try await client.writeKeyerMemory(slot: 1, text: String(repeating: "E", count: 51))
            XCTFail("over 50 characters must be refused")
        } catch let error as RigctldError {
            XCTAssertEqual(error, .keyerMemoryRejected)
        }

        await apply(.playCWTextMemory(slot: 1))
        let keyed = try await client.getPTT()
        XCTAssertTrue(keyed)
        let raw = try await client.send("t currVFO")
        XCTAssertEqual(raw, "3")
        let info = try await client.getRadioInformation()
        XCTAssertEqual(info?.isTransmitting, true)

        // The PARIS-timed length at the rig's KS (20 WPM).
        clock.now += SimulatedMorse.duration(of: "CQ TEST DE DEMO", wpm: 20) - 0.1
        let stillKeyed = try await client.getPTT()
        XCTAssertTrue(stillKeyed)
        clock.now += 0.2
        let done = try await client.getPTT()
        XCTAssertFalse(done)

        await apply(.playCWTextMemory(slot: 1))
        await apply(.playCWTextMemory(slot: 0))
        let stopped = try await client.getPTT()
        XCTAssertFalse(stopped, "KY00 stops at once")

        // No BK-IN, no transmission.
        await apply(.setBreakIn(false))
        await apply(.playCWTextMemory(slot: 1))
        let blocked = try await client.getPTT()
        XCTAssertFalse(blocked)
    }

    func testPTTAndMeters() async throws {
        let strength = try await client.getLevel("STRENGTH")
        XCTAssertNotNil(strength)
        await apply(.setPTT(true))
        let ptt = try await client.getPTT()
        XCTAssertTrue(ptt)
        let watts = try await client.getLevel("RFPOWER_METER_WATTS")
        XCTAssertEqual(try XCTUnwrap(watts), 5, accuracy: 0.001, "CW: full carrier at the 5 W default")
        let swr = try await client.getLevel("SWR")
        XCTAssertEqual(try XCTUnwrap(swr), 1.25, accuracy: 0.001)
        let alc = try await client.getMeterReading(4)
        XCTAssertGreaterThan(try XCTUnwrap(alc), 0)
        await apply(.setPTT(false))
        let off = try await client.getLevel("RFPOWER_METER_WATTS")
        XCTAssertEqual(off, 0)
    }

    func testSMeterFollowsSignals() async throws {
        // MAIN on the beacon while it sends: about S8.
        clock.now = 1
        let beacon = try await client.getLevel("STRENGTH")
        XCTAssertEqual(try XCTUnwrap(beacon), -6, accuracy: 2)
        // SUB on 144.390 with no burst: exactly S0 (raw 0).
        clock.now = 2
        let quiet = try await client.getMeterReading(2)
        XCTAssertEqual(quiet, 0)
        // During the first APRS burst.
        clock.now = 6.5
        let burst = try await client.getMeterReading(2)
        XCTAssertGreaterThan(try XCTUnwrap(burst), 130)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
