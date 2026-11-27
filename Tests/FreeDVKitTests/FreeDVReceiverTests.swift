import AVFoundation
import FTX1Core
import XCTest
@testable import FreeDVKit

@MainActor
final class FreeDVReceiverTests: XCTestCase {
    /// Open Audio File: callsigns into the heard list (newest first), the
    /// speech into a 16 kHz WAV in the recordings folder.
    func testDecodeFileFillsHeardListAndSavesSpeech() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "rade_offair_50s", withExtension: "wav", subdirectory: "Resources"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FreeDVReceiverTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiver = FreeDVReceiver(logSubsystem: "com.ftx1remote.tests", recordingsDirectory: directory)

        receiver.decodeFile(at: fixture)
        XCTAssertTrue(receiver.isDecodingFile)
        let deadline = Date().addingTimeInterval(30)
        while receiver.isDecodingFile, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertNil(receiver.errorMessage)
        XCTAssertEqual(receiver.heard.map(\.callsign), ["VK3TPM", "VK5KVA"])
        XCTAssertTrue(receiver.heard.allSatisfy(\.fromFile))
        XCTAssertTrue(receiver.heard.allSatisfy { ($0.snrDB ?? 0) > 5 })
        let saved = try XCTUnwrap(receiver.lastDecodedFile)
        XCTAssertTrue(saved.lastPathComponent.contains("FreeDV rade_offair_50s"))
        let file = try AVAudioFile(forReading: saved)
        XCTAssertEqual(file.fileFormat.sampleRate, 16000)
        XCTAssertGreaterThan(Double(file.length) / 16000, 38)
    }

    func testFileWithoutFreeDVReportsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FreeDVReceiverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let noise = directory.appendingPathComponent("noise.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        do {
            let file = try AVAudioFile(forWriting: noise, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 5))
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float.random(in: -0.1...0.1) }
            try file.write(from: buffer)
        }
        let receiver = FreeDVReceiver(logSubsystem: "com.ftx1remote.tests", recordingsDirectory: directory)
        receiver.decodeFile(at: noise)
        while receiver.isDecodingFile { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(receiver.errorMessage)
        XCTAssertNil(receiver.lastDecodedFile)
        XCTAssertTrue(receiver.heard.isEmpty)
        // Only the noise file is left: the empty speech file was removed.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["noise.wav"])
    }

    /// freedv.org: LSB below 10 MHz, USB from 10 MHz up.
    func testSidebandByFrequency() {
        XCTAssertEqual(FreeDVSideband(frequencyHz: 3_643_000), .lower)
        XCTAssertEqual(FreeDVSideband(frequencyHz: 7_177_000), .lower)
        XCTAssertEqual(FreeDVSideband(frequencyHz: 9_999_999), .lower)
        XCTAssertEqual(FreeDVSideband(frequencyHz: 10_000_000), .upper)
        XCTAssertEqual(FreeDVSideband(frequencyHz: 14_236_000), .upper)
        XCTAssertEqual(FreeDVSideband(frequencyHz: 28_330_000), .upper)
        XCTAssertEqual(FreeDVSideband(frequencyHz: nil), .either)
        XCTAssertEqual(FreeDVSideband(frequencyHz: 0), .either)
    }

    func testModeHintFollowsTheBand() {
        let receiver = FreeDVReceiver(logSubsystem: "com.ftx1remote.tests")
        receiver.channel = .main
        // 20 m: USB or DATA-U.
        receiver.rigInfoChanged(FreeDVRigInfo(mainMode: .usb, mainFrequencyHz: 14_236_000))
        XCTAssertNil(receiver.modeHint)
        receiver.rigInfoChanged(FreeDVRigInfo(mainMode: .dataUSB, mainFrequencyHz: 14_236_000))
        XCTAssertNil(receiver.modeHint)
        receiver.rigInfoChanged(FreeDVRigInfo(mainMode: .lsb, mainFrequencyHz: 14_236_000))
        XCTAssertEqual(receiver.modeHint, FreeDVModeHint(mode: .lsb, expected: .upper))
        // 40 m: LSB.
        receiver.rigInfoChanged(FreeDVRigInfo(mainMode: .lsb, mainFrequencyHz: 7_177_000))
        XCTAssertNil(receiver.modeHint)
        receiver.rigInfoChanged(FreeDVRigInfo(mainMode: .usb, mainFrequencyHz: 7_177_000))
        XCTAssertEqual(receiver.modeHint, FreeDVModeHint(mode: .usb, expected: .lower))
        receiver.rigInfoChanged(FreeDVRigInfo(mainMode: .dataUSB, mainFrequencyHz: 7_177_000))
        XCTAssertEqual(receiver.modeHint, FreeDVModeHint(mode: .dataUSB, expected: .lower))
        // No frequency yet: either sideband, but not FM.
        receiver.rigInfoChanged(FreeDVRigInfo(mainMode: .lsb))
        XCTAssertNil(receiver.modeHint)
        receiver.rigInfoChanged(FreeDVRigInfo(mainMode: .fm))
        XCTAssertEqual(receiver.modeHint, FreeDVModeHint(mode: .fm, expected: .either))
        // SUB uses SUB's own frequency.
        receiver.rigInfoChanged(FreeDVRigInfo(mainMode: .usb, subMode: .lsb,
                                              mainFrequencyHz: 14_236_000, subFrequencyHz: 3_643_000))
        receiver.channel = .sub
        XCTAssertNil(receiver.modeHint)
    }
}
