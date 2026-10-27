import Foundation
import XCTest
@testable import FTX1Core

/// The hub wire contract as files, shared with the Windows app's hub
/// (`Apps/Windows/README.md`, "Desktop hub for the iPad").
///
/// `Tests/WireFixtures/*.json` are `RigStatePush`es encoded by this
/// package: the Windows side checks its C# types against them. They're
/// compared byte for byte with what `RigState` encodes today, so adding,
/// renaming or retyping a field fails here until they're regenerated:
/// `REGENERATE_WIRE_FIXTURES=1 swift test --filter HubWireFixtureTests`.
///
/// `Tests/WireFixtures/windows/*.json` go the other way: pushes produced by
/// the Windows app's own C# code, committed from the Windows PC. Each must
/// decode here exactly as the iPad decodes it (`RigWebSocketClient`) — a
/// missing required field would otherwise only show as an iPad stuck on
/// "Connecting…".
final class HubWireFixtureTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("WireFixtures")

    /// 2026-10-15T12:00:00Z. `JSONEncoder`'s default date encoding is
    /// seconds since 2001-01-01T00:00:00Z, so this is 813758400.
    private static let lastUpdated = Date(timeIntervalSinceReferenceDate: 813_758_400)

    /// Every field set, so every key and every nested shape appears once.
    static var fullState: RigState {
        var state = RigState(
            frequencyHz: 14_047_500, mode: .cw, band: "20m", powerWatts: 9.5, swr: 1.3,
            ptt: true, lastUpdated: lastUpdated,
            secondaryFrequencyHz: 146_940_000, secondaryMode: .fm, powerLevel: 0.1,
            breakIn: true, keyerEnabled: true, cwSpeedWpm: 18, cwPitchHz: 700, bkDelayMs: 300,
            cwSpot: false, moniLevel: 50, cwMessageStatus: .playing,
            moxEnabled: false, attEnabled: false, preampMode: 1, tunerEnabled: true,
            displayContrast: 10, displayDimmer: 15, displayLevel: -5.5, displayPeak: 2,
            displayMarker: true, micGain: 50, amcLevel: 30, voxEnabled: false, voxGain: 40,
            voxDelayMs: 500, smeterDb: -12.5, dnfEnabled: false, agcMode: 2,
            micEQEnabled: false, procLevel: 25, nbLevel: 3, dnrLevel: 4,
            filterWidthIndex: 9, ifShiftHz: -120, notchEnabled: true, notchHz: 1500,
            contourEnabled: false, contourHz: 800, apfEnabled: true, apfHz: -20,
            narrowEnabled: false, narrowWidthHz: 500, filterSide: .sub, antSelect: 1,
            txwEnabled: false, splitEnabled: false, txSide: .main,
            squelchType: 1, ctcssToneIndex: 12, dcsCodeIndex: 3, repeaterShiftMode: 2,
            aprsBeaconType: 0, fmChannelStep: 5,
            c4fmCallsign: "W1AW", c4fmReflector: "AMERICA-LINK",
            aprsActive: true, aprsLastCallsign: "W1AW-9",
            aprsSubActive: true, aprsSubLastCallsign: "K6NA-7",
            vfoMemoryMode: .memory, memoryChannel: 2, memoryChannelTag: "RPT 2M",
            subVfoMemoryMode: .other(rawP2: 2), subMemoryChannel: 100,
            subMemoryChannelTag: "NOAA",
            memoryScan: .paused, memoryScanSide: .main,
            transmitEnabled: false
        )
        // Not in the memberwise init.
        state.subSmeterDb = 3.25
        state.singleReceive = false
        state.audioChannelsSwapped = true
        state.txMeters = TXMeterReadings(comp: 5, alc: 10, idd: 120, vdd: 138)
        return state
    }

    /// Only the fields `RigState`'s synthesized decoder requires.
    static var minimalState: RigState {
        RigState(frequencyHz: 7_074_000, mode: .dataUSB, ptt: false, lastUpdated: lastUpdated)
    }

    /// The enum shapes `fullState` can't show at once: `.vfo` on both
    /// sides, a stopped scan, MAIN filter side.
    static var vfoState: RigState {
        RigState(
            frequencyHz: 144_390_000, mode: .fm, lastUpdated: lastUpdated,
            secondaryFrequencyHz: 446_000_000, secondaryMode: .c4fm,
            filterSide: .main, vfoMemoryMode: .vfo, subVfoMemoryMode: .vfo,
            memoryScan: .stopped, memoryScanSide: .sub
        )
    }

    private static let cases: [(file: String, state: RigState)] = [
        ("rig-state-push.full.json", fullState),
        ("rig-state-push.minimal.json", minimalState),
        ("rig-state-push.vfo.json", vfoState),
    ]

    private static func encode(_ state: RigState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(RigStatePush(state: state))
        data.append(0x0A)
        return data
    }

    func testFixturesMatchRigState() throws {
        let regenerate = ProcessInfo.processInfo.environment["REGENERATE_WIRE_FIXTURES"] == "1"
        for (file, state) in Self.cases {
            let url = Self.fixtures.appendingPathComponent(file)
            let encoded = try Self.encode(state)
            if regenerate {
                try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
                try encoded.write(to: url)
                continue
            }
            let onDisk = try Data(contentsOf: url)
            XCTAssertEqual(
                String(decoding: onDisk, as: UTF8.self), String(decoding: encoded, as: UTF8.self),
                "\(file) is out of date with RigState — regenerate it (see this file's doc comment) and tell the Windows hub"
            )
        }
    }

    func testFixturesDecodeAsTheIPadDoes() throws {
        for (file, state) in Self.cases {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(file))
            let push = try JSONDecoder().decode(RigStatePush.self, from: data)
            XCTAssertEqual(push.type, "state", file)
            XCTAssertEqual(push.state, state, file)
        }
    }

    /// One of every `RigCommand`, as the iPad sends it. Values are ordinary
    /// examples, chosen so each payload shape shows (negative numbers,
    /// fractions, nested objects, enum raw values).
    static let allCommands: [RigCommand] = [
        .setFrequency(hz: 14_074_000),
        .setSecondaryFrequency(hz: 146_940_000),
        .swapActiveVFO,
        .setMode(.dataUSB),
        .setSecondaryMode(.c4fm),
        .setPTT(true),
        .setBand("20m"),
        .setPowerLevel(0.25),
        .setBreakIn(true),
        .setKeyer(true),
        .setCWSpeed(wpm: 18),
        .setCWPitch(hz: 700),
        .setBreakInDelay(ms: 300),
        .setCWSpot(false),
        .triggerZeroIn,
        .setMoniLevel(level: 50),
        .selectCWMessageChannel(2),
        .setCWMessageRecording(false),
        .playCWMessage(channel: 3),
        .playCWTextMemory(slot: 1),
        .setMox(false),
        .setAtt(true),
        .setPreamp(mode: 2),
        .setTuner(true),
        .triggerAntennaTune,
        .setDisplayContrast(10),
        .setDisplayDimmer(15),
        .setDisplayLevel(-5.5),
        .setDisplayPeak(2),
        .setDisplayMarker(true),
        .setMicGain(50),
        .setAMCLevel(30),
        .setVox(false),
        .setVoxGain(40),
        .setVoxDelay(ms: 500),
        .setDNF(true),
        .setAGC(mode: 2),
        .setMicEQ(false),
        .setProcLevel(25),
        .setNBLevel(3),
        .setDNRLevel(4),
        .setFilterWidth(9),
        .setIFShift(hz: -120),
        .setNotch(true),
        .setNotchFrequency(hz: 1500),
        .setContour(false),
        .setContourFrequency(hz: 800),
        .setAPF(true),
        .setAPFOffset(hz: -20),
        .setNarrow(true),
        .setFilterSide(.sub),
        .setAntSelect(1),
        .setTXW(false),
        .setTXSide(.sub),
        .setSquelchType(1),
        .setToneFreq(index: 12),
        .setDCSCode(index: 3),
        .setRepeaterShift(mode: 2),
        .setAPRSBeaconType(0),
        .setFMChannelStep(5),
        .setMenuItem(p1: 6, p2: 1, p3: 3, rawValue: "1"),
        .setVFOMemoryMode(memory: true),
        .setMemoryChannel(2),
        .stepMemoryChannel(up: true),
        .setSubMemoryChannel(100),
        .stepSubMemoryChannel(up: false),
        .recallMemoryChannel(channel: 278, sub: true),
        .setMemoryScan(.up, side: .main),
        .refreshMemoryList,
        .setAudioChannelsSwapped(true),
        .setTransmitEnabled(false),
    ]

    private static let commandsFile = "rig-commands.json"

    func testCommandsFixtureMatchesRigCommand() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var encoded = try encoder.encode(Self.allCommands)
        encoded.append(0x0A)
        let url = Self.fixtures.appendingPathComponent(Self.commandsFile)
        if ProcessInfo.processInfo.environment["REGENERATE_WIRE_FIXTURES"] == "1" {
            try encoded.write(to: url)
            return
        }
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(
            String(decoding: onDisk, as: UTF8.self), String(decoding: encoded, as: UTF8.self),
            "\(Self.commandsFile) is out of date with RigCommand — regenerate it and tell the Windows hub"
        )
        let decoded = try JSONDecoder().decode([RigCommand].self, from: onDisk)
        XCTAssertEqual(decoded, Self.allCommands)
    }

    /// A new `RigCommand` has to be added to `allCommands` (and so to the
    /// fixture the Windows hub tests against).
    func testCommandsFixtureCoversEveryCommand() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(Self.commandsFile))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let names = Set(objects.compactMap { $0["cmd"] as? String })
        let expected = Set(RigCommand.CommandName.allCases.map(\.rawValue))
        XCTAssertEqual(objects.count, expected.count, "one example per command")
        XCTAssertEqual(names.subtracting(expected), [], "unknown commands in the fixture")
        XCTAssertEqual(expected.subtracting(names), [], "commands missing from allCommands")
    }

    /// Receive-audio frames written by the Windows hub's C# code (phase 3):
    /// `windows/audio-<main|sub>-<tone>hz-<anything>.bin`, each one
    /// WebSocket frame as the iPad receives it — tag byte, then Int16LE
    /// mono PCM at 8 kHz — made by the hub's real downsampler from 1 s of
    /// a −6 dBFS sine at `<tone>` Hz. Checks the tag, that 1 s came out as
    /// ~8000 samples (the output rate), the tone's frequency (the rate
    /// again, and no aliasing) and its level (no gain or clipping). None
    /// yet is fine.
    func testWindowsHubAudioFrames() throws {
        let dir = Self.fixtures.appendingPathComponent("windows")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let pattern = try Regex(#"audio-(main|sub)-(\d+)hz-.*\.bin"#, as: (Substring, Substring, Substring).self)
        for url in files {
            guard let match = url.lastPathComponent.wholeMatch(of: pattern) else { continue }
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            let expectedTag = match.1 == "main" ? AudioStreamFormat.audioTag : AudioStreamFormat.subAudioTag
            XCTAssertEqual(data.first, expectedTag, "\(name): tag byte")
            let isRightKind = match.1 == "main"
                ? AudioStreamFormat.isAudioFrame(data) : AudioStreamFormat.isSubAudioFrame(data)
            XCTAssertTrue(isRightKind, "\(name): the iPad wouldn't read this as \(match.1) audio")
            let pcm = AudioStreamFormat.payload(of: data)
            XCTAssertEqual(pcm.count % 2, 0, "\(name): PCM isn't whole Int16 samples")
            let samples: [Double] = stride(from: pcm.startIndex, to: pcm.endIndex - 1, by: 2).map {
                Double(Int16(bitPattern: UInt16(pcm[$0]) | UInt16(pcm[$0 + 1]) << 8))
            }
            XCTAssertEqual(Double(samples.count), AudioStreamFormat.sampleRate, accuracy: 80,
                           "\(name): 1 s of input should be ~8000 samples at 8 kHz")

            // Skip the resampler's start-up transient, then count rising
            // zero crossings over whole seconds' worth of what's left.
            let body = Array(samples.dropFirst(400))
            guard body.count > 4000 else { continue }
            var crossings: [Int] = []
            for i in 1..<body.count where body[i - 1] < 0 && body[i] >= 0 { crossings.append(i) }
            let tone = Double(match.2)!
            if let first = crossings.first, let last = crossings.last, crossings.count > 10 {
                let measured = Double(crossings.count - 1) * AudioStreamFormat.sampleRate / Double(last - first)
                XCTAssertEqual(measured, tone, accuracy: tone * 0.01, "\(name): tone frequency")
            } else {
                XCTFail("\(name): no tone found")
            }
            let peak = body.map(abs).max() ?? 0
            XCTAssertEqual(peak / 32768, 0.5, accuracy: 0.1, "\(name): a −6 dBFS sine should peak near half scale")
        }
    }

    // MARK: Lists and Deep Settings reads (phase 4)

    /// Seconds since 2001 like `lastUpdated`: 2026-10-15T11:00:00Z.
    private static let heardAt = Date(timeIntervalSinceReferenceDate: 813_754_800)

    static var memoryListPush: MemoryListPush {
        MemoryListPush(list: MemoryListSnapshot(
            entries: [
                MemoryChannelEntry(channel: 1, frequencyHz: 146_520_000, modeCode: "4", toneMode: 0, shift: 0, tag: "CALL 2M"),
                MemoryChannelEntry(channel: 2, frequencyHz: 146_940_000, modeCode: "4", toneMode: 2, shift: 2, tag: nil),
                MemoryChannelEntry(channel: 101, frequencyHz: 14_074_000, modeCode: "C", toneMode: 0, shift: 0, tag: "FT8 20M"),
            ],
            scanned: heardAt,
            scanningChannel: nil
        ))
    }

    /// While the hub is reading the list: `scanningChannel` set, no
    /// `scanned` date yet.
    static var memoryListScanningPush: MemoryListPush {
        MemoryListPush(list: MemoryListSnapshot(
            entries: [MemoryChannelEntry(channel: 1, frequencyHz: 146_520_000, modeCode: "4", toneMode: 0, shift: 0, tag: nil)],
            scanned: nil,
            scanningChannel: 37
        ))
    }

    static var aprsListPush: APRSListPush {
        APRSListPush(
            stations: [
                APRSStation(callsign: "W1AW-9", latitude: 41.7147, longitude: -72.7272, symbolTable: "/", symbolCode: ">",
                            comment: "Mobile 146.520", lastHeardAt: heardAt, source: .main),
                APRSStation(callsign: "K6NA-7", lastHeardAt: heardAt.addingTimeInterval(30), source: .sub),
            ],
            messages: [
                APRSMessage(id: "6F1C2A4E-1111-4A2B-9C3D-000000000001", from: "W1AW-9", to: "DEMO",
                            text: "Hello from the hub", messageID: "12", receivedAt: heardAt, source: .main),
                APRSMessage(id: "6F1C2A4E-1111-4A2B-9C3D-000000000002", from: "K6NA-7", to: "BLNA",
                            text: "Net tonight 2000", receivedAt: heardAt.addingTimeInterval(60), source: .sub),
            ]
        )
    }

    private static let otherCases: [(file: String, encode: () throws -> Data, check: (Data) throws -> Void)] = [
        ("memory-list-push.json", { try encode(memoryListPush) },
         { XCTAssertEqual(try JSONDecoder().decode(MemoryListPush.self, from: $0), memoryListPush) }),
        ("memory-list-push.scanning.json", { try encode(memoryListScanningPush) },
         { XCTAssertEqual(try JSONDecoder().decode(MemoryListPush.self, from: $0), memoryListScanningPush) }),
        ("aprs-list-push.json", { try encode(aprsListPush) },
         { XCTAssertEqual(try JSONDecoder().decode(APRSListPush.self, from: $0), aprsListPush) }),
        ("menu-item-read-request.json", { try encode(MenuItemReadRequest(p1: 6, p2: 1, p3: 3)) },
         { XCTAssertEqual(try JSONDecoder().decode(MenuItemReadRequest.self, from: $0), MenuItemReadRequest(p1: 6, p2: 1, p3: 3)) }),
        ("menu-item-push.json", { try encode(MenuItemPush(p1: 6, p2: 1, p3: 3, value: "1")) },
         { XCTAssertEqual(try JSONDecoder().decode(MenuItemPush.self, from: $0), MenuItemPush(p1: 6, p2: 1, p3: 3, value: "1")) }),
        ("menu-item-push.unreadable.json", { try encode(MenuItemPush(p1: 6, p2: 1, p3: 3, value: nil)) },
         { XCTAssertEqual(try JSONDecoder().decode(MenuItemPush.self, from: $0), MenuItemPush(p1: 6, p2: 1, p3: 3, value: nil)) }),
        // Phase 6: the CW keyer pair (iPad → hub requests, hub → iPad replies).
        cwKeyer("cw-keyer-request.write.json", CWKeyerRequest(id: 7, slot: 1, text: "CQ CQ DE W1AW K")),
        cwKeyer("cw-keyer-request.check.json", CWKeyerRequest(id: 8, slot: 1, text: nil)),
        cwKeyer("cw-keyer-request.acquire.json", CWKeyerRequest(id: 9, action: .acquire)),
        cwKeyer("cw-keyer-request.release.json", CWKeyerRequest(id: 10, action: .release)),
        cwKeyer("cw-keyer-reply.stored.json", CWKeyerReply(id: 7, stored: "CQ CQ DE W1AW K", error: nil)),
        cwKeyer("cw-keyer-reply.checked.json", CWKeyerReply(id: 8, stored: nil, error: nil)),
        cwKeyer("cw-keyer-reply.error.json", CWKeyerReply(id: 7, stored: nil, error: "Keyer memory 9 doesn't exist (1–5)",
                                                          errorCode: "keyer_bad_slot")),
        cwKeyer("cw-keyer-reply.busy.json", CWKeyerReply(id: 9, stored: nil, error: nil, busy: "the Mac's CW window",
                                                         busyCode: "mac_cw_window")),
        cwKeyer("cw-keyer-reply.not-holder.json", CWKeyerReply(id: 11, stored: nil,
                                                               error: "The keyer isn't yours to write (held by another device on the hub)",
                                                               errorCode: "keyer_not_holder", busyCode: "other_hub_device")),
    ]

    private static func cwKeyer<T: Codable & Equatable>(_ file: String, _ value: T) -> (file: String, encode: () throws -> Data, check: (Data) throws -> Void) {
        (file, { try encode(value) }, { XCTAssertEqual(try JSONDecoder().decode(T.self, from: $0), value) })
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    func testListAndMenuFixturesMatchSwift() throws {
        let regenerate = ProcessInfo.processInfo.environment["REGENERATE_WIRE_FIXTURES"] == "1"
        for (file, encode, check) in Self.otherCases {
            let url = Self.fixtures.appendingPathComponent(file)
            let encoded = try encode()
            if regenerate {
                try encoded.write(to: url)
                continue
            }
            let onDisk = try Data(contentsOf: url)
            XCTAssertEqual(String(decoding: onDisk, as: UTF8.self), String(decoding: encoded, as: UTF8.self),
                           "\(file) is out of date — regenerate it and tell the Windows hub")
            try check(onDisk)
        }
    }

    // MARK: What the Windows hub wrote

    /// What `RigWebSocketClient.handle(_:)` does with a JSON frame: it tries
    /// each push in this order and takes the first that decodes (the list,
    /// menu and keyer pushes also need the right `type`). A frame nothing
    /// takes is dropped without a word on the iPad.
    private static func iPadReading(_ data: Data) -> String? {
        let decoder = JSONDecoder()
        if (try? decoder.decode(RigStatePush.self, from: data)) != nil { return "state" }
        if (try? decoder.decode(MemoryListPush.self, from: data)) != nil { return "memory_list" }
        if let push = try? decoder.decode(APRSListPush.self, from: data), push.type == APRSListPush.typeName { return "aprs_list" }
        if let push = try? decoder.decode(MenuItemPush.self, from: data), push.type == MenuItemPush.typeName { return "menu_item" }
        if let reply = try? decoder.decode(CWKeyerReply.self, from: data), reply.type == CWKeyerReply.typeName { return "cw_keyer_reply" }
        return nil
    }

    /// Pushes written by the Windows hub's C# code: each must be read by the
    /// iPad as the kind its own `type` says, and decode strictly as that
    /// type (so a missing required field fails here, not silently on the
    /// iPad). None yet is fine.
    func testWindowsHubPushesDecode() throws {
        let dir = Self.fixtures.appendingPathComponent("windows")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let type = try XCTUnwrap(object?["type"] as? String, "\(name): no \"type\"")
            XCTAssertEqual(Self.iPadReading(data), type, "\(name): the iPad doesn't read this as \"\(type)\"")
            do {
                switch type {
                case "state": _ = try JSONDecoder().decode(RigStatePush.self, from: data)
                case "memory_list": _ = try JSONDecoder().decode(MemoryListPush.self, from: data)
                case "aprs_list": _ = try JSONDecoder().decode(APRSListPush.self, from: data)
                case "menu_item": _ = try JSONDecoder().decode(MenuItemPush.self, from: data)
                case "cw_keyer_reply": _ = try JSONDecoder().decode(CWKeyerReply.self, from: data)
                default: XCTFail("\(name): unknown type \"\(type)\"")
                }
            } catch {
                XCTFail("\(name) doesn't decode as the iPad decodes it: \(error)")
            }
        }
    }
}
