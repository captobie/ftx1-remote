import XCTest
@testable import FTX1Core

/// `KiwiReceiverSettings` against a real KiwiSDR, measuring the audio
/// level each setting produces. Skipped unless `KIWI_LIVE_HOST` and
/// `KIWI_LIVE_PASSWORD_FILE` are set (see `KiwiSDRClientLiveTests`).
final class KiwiReceiverLiveTests: XCTestCase {
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

    private func dBFS(_ samples: [Int16]) -> Double {
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return 10 * log10(max(sum / Double(max(samples.count, 1)), 1e-3) / (32768 * 32768))
    }

    /// Runs `stages` on one connection: each is applied, left to settle for
    /// 1.5 s, then measured for 3 s. Returns each stage's level.
    private func levels(start: KiwiReceiverSettings, stages: [(String, KiwiReceiverSettings)]) async throws -> [Double] {
        let client = KiwiSDRClient(hostPort: host, password: password,
                                   tuning: KiwiTuning(dialHz: 14_074_000, mode: .usb), receiver: start,
                                   logSubsystem: "com.ftx1remote.tests")
        await client.start()
        var results: [Double] = []
        var index = -1
        var stageStart = Date()
        var measured: [Int16] = []
        let started = Date()
        for await event in client.events {
            switch event {
            case .ready:
                stageStart = Date()
                index = 0
                await client.setReceiver(stages[0].1)
            case .audio(let chunk):
                guard index >= 0 else { continue }
                let elapsed = Date().timeIntervalSince(stageStart)
                if elapsed >= 1.5 { measured += chunk.samples }
                if elapsed >= 4.5 {
                    let level = dBFS(measured)
                    results.append(level)
                    print("LIVE \(stages[index].0): \(String(format: "%.1f", level)) dBFS")
                    measured = []
                    index += 1
                    stageStart = Date()
                    if index < stages.count {
                        await client.setReceiver(stages[index].1)
                    } else {
                        await client.stop()
                    }
                }
            case .closed(let error):
                XCTAssertNil(error)
            }
            if Date().timeIntervalSince(started) > 120 { await client.stop() }
        }
        return results
    }

    func testEachControlChangesTheAudio() async throws {
        var off = KiwiReceiverSettings()
        off.agc = false
        off.manualGain = 40
        var loud = off
        loud.manualGain = 80
        var agcSensitive = KiwiReceiverSettings()
        agcSensitive.threshold = -130
        var agcDull = KiwiReceiverSettings()
        agcDull.threshold = -50
        // At the default AGC level, as these are normally used (a very low
        // manual gain leaves LMS's output below one LSB).
        let plain = KiwiReceiverSettings()
        var nb = plain
        nb.noiseBlanker = .standard
        nb.gate = 5000
        nb.blankerThreshold = 0
        var wild = plain
        wild.noiseBlanker = .wild
        wild.wildThreshold = 0.05
        var wdsp = plain
        wdsp.select(noiseFilter: .wdsp)
        var lms = plain
        lms.select(noiseFilter: .lms)
        var notch = plain
        notch.noiseFilter = .wdsp
        notch.autonotch = true
        var spectral = plain
        spectral.select(noiseFilter: .spectral)
        let results = try await levels(start: KiwiReceiverSettings(), stages: [
            ("manual 40", off), ("manual 80", loud), ("back to 40", off),
            ("AGC thresh -130", agcSensitive), ("AGC thresh -50", agcDull),
            ("plain", plain), ("NB standard", nb), ("NB wild", wild), ("back to plain", plain),
            ("NR WDSP denoise", wdsp), ("NR WDSP notch", notch), ("NR LMS denoise", lms), ("NR spectral", spectral),
        ])
        XCTAssertEqual(results.count, 13)
        XCTAssertGreaterThan(results[1], results[0] + 25, "40 dB more manual gain")
        XCTAssertGreaterThan(results[3], results[4] + 3, "a lower threshold means more gain")
    }

    func testANewConnectionSendsTheSavedSettings() async throws {
        var quiet = KiwiReceiverSettings()
        quiet.agc = false
        quiet.manualGain = 20
        var loud = quiet
        loud.manualGain = 90
        // Stage 0 re-applies the start value, so nothing is sent for it.
        let quietLevel = try await levels(start: quiet, stages: [("started at manual 20", quiet)])
        let loudLevel = try await levels(start: loud, stages: [("started at manual 90", loud)])
        XCTAssertGreaterThan(loudLevel[0], quietLevel[0] + 40)
    }
}
