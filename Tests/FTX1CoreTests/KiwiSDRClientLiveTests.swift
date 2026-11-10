import XCTest
@testable import FTX1Core

/// `KiwiSDRClient` against a real KiwiSDR. Skipped unless
/// `KIWI_LIVE_HOST` ("host:port") and `KIWI_LIVE_PASSWORD_FILE` (a file
/// holding the user password, so it never appears on a command line) are
/// set. Checks connect, audio, retune on the open socket, the
/// wrong-password error, and that stopping frees the channel (/status).
final class KiwiSDRClientLiveTests: XCTestCase {
    private var host = ""
    private var password = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["KIWI_LIVE_HOST"], let file = env["KIWI_LIVE_PASSWORD_FILE"] else {
            throw XCTSkip("KIWI_LIVE_HOST / KIWI_LIVE_PASSWORD_FILE not set")
        }
        self.host = host
        password = try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .newlines)
    }

    private func users() async throws -> Int {
        let url = try XCTUnwrap(URL(string: "http://\(host)/status"))
        let (data, _) = try await URLSession.shared.data(from: url)
        return try XCTUnwrap(KiwiStatus(String(decoding: data, as: UTF8.self)).users)
    }

    func testListenRetuneAndClose() async throws {
        let before = try await users()
        let client = KiwiSDRClient(hostPort: host, password: password,
                                   tuning: KiwiTuning(dialHz: 14_074_000, mode: .usb),
                                   logSubsystem: "com.ftx1remote.tests")
        await client.start()
        var rate: Double?
        var frames: [KiwiAudioChunk] = []
        var retunedAt: Int?
        var retuneSeen: Int?
        var modeChangeSeen = false
        var statusDuring: Task<Int, Error>?
        let started = Date()
        for await event in client.events {
            switch event {
            case .ready(let sampleRate):
                rate = sampleRate
            case .audio(let chunk):
                frames.append(chunk)
                if frames.count == 50 {
                    // /status lags by seconds; check it beside the stream.
                    let expected = before + 1
                    statusDuring = Task {
                        let asked = Date()
                        var during = try await self.users()
                        while during != expected, Date().timeIntervalSince(asked) < 12 {
                            try await Task.sleep(for: .milliseconds(500))
                            during = try await self.users()
                        }
                        return during
                    }
                    retunedAt = frames.count
                    await client.tune(frequencyHz: 7_074_000, mode: .lsb)
                } else if retunedAt != nil, retuneSeen == nil, chunk.flags.contains(.newFrequency) {
                    retuneSeen = frames.count
                    await client.tune(frequencyHz: 7_030_000, mode: .cw)
                } else if retuneSeen != nil, frames.count > retuneSeen! + 1, chunk.flags.contains(.newFrequency) {
                    modeChangeSeen = true
                    _ = try await statusDuring?.value
                    await client.stop()
                }
            case .closed(let error):
                XCTAssertNil(error)
            }
            if Date().timeIntervalSince(started) > 30 { await client.stop() }
        }
        let during = try await statusDuring?.value
        XCTAssertEqual(during, before + 1, "our channel shows in /status")
        let sampleRate = try XCTUnwrap(rate)
        XCTAssertEqual(sampleRate, 12000, accuracy: 10)
        XCTAssertGreaterThan(frames.count, 50)
        XCTAssertTrue(frames.contains { chunk in chunk.samples.contains { $0 != 0 } }, "real audio")
        XCTAssertNotNil(retuneSeen, "retune marked by flag 0x04")
        XCTAssertTrue(modeChangeSeen, "mode change marked by flag 0x04")
        // No sequence gap across either retune.
        let sequences = frames.map(\.sequence)
        for (a, b) in zip(sequences, sequences.dropFirst()) { XCTAssertEqual(b, a &+ 1) }
        print("LIVE: rate \(sampleRate), \(frames.count) frames, retune after \(retuneSeen! - retunedAt!) frames, smeter \(frames.last!.smeterDBm) dBm")

        // The Kiwi updates /status a few seconds after the socket closes.
        let stopped = Date()
        var after = try await users()
        while after != before, Date().timeIntervalSince(stopped) < 15 {
            try await Task.sleep(for: .milliseconds(500))
            after = try await users()
        }
        XCTAssertEqual(after, before, "channel freed after stop()")
        print("LIVE: /status back to \(after) user(s) \(String(format: "%.1f", Date().timeIntervalSince(stopped))) s after stop()")
    }

    func testWrongPassword() async throws {
        let client = KiwiSDRClient(hostPort: host, password: password + "-wrong",
                                   tuning: KiwiTuning(dialHz: 14_074_000, mode: .usb),
                                   logSubsystem: "com.ftx1remote.tests")
        await client.start()
        var result: KiwiSDRError??
        for await event in client.events {
            if case .closed(let error) = event { result = error }
        }
        XCTAssertEqual(result, .some(.badPassword))
    }

    func testUnreachable() async throws {
        let client = KiwiSDRClient(hostPort: "127.0.0.1:1", password: "",
                                   tuning: KiwiTuning(dialHz: 14_074_000, mode: .usb),
                                   logSubsystem: "com.ftx1remote.tests")
        await client.start()
        var result: KiwiSDRError?
        for await event in client.events {
            if case .closed(let error) = event { result = error }
        }
        guard case .unreachable = result else { return XCTFail("got \(String(describing: result))") }
    }
}
