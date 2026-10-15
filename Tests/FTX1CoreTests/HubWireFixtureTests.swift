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

    /// Pushes written by the Windows hub's C# code. None yet is fine.
    func testWindowsHubPushesDecode() throws {
        let dir = Self.fixtures.appendingPathComponent("windows")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            let data = try Data(contentsOf: url)
            do {
                let push = try JSONDecoder().decode(RigStatePush.self, from: data)
                XCTAssertEqual(push.type, "state", url.lastPathComponent)
            } catch {
                XCTFail("\(url.lastPathComponent) doesn't decode as the iPad decodes it: \(error)")
            }
        }
    }
}
