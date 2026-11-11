import XCTest
@testable import FTX1Core

/// `KiwiWaterfallClient` beside a `KiwiSDRClient` against a real KiwiSDR
/// (same `KIWI_LIVE_HOST` / `KIWI_LIVE_PASSWORD_FILE` as
/// `KiwiSDRClientLiveTests`, skipped without them). Checks the waterfall
/// shares the sound stream's channel, rows at the requested zoom/start,
/// the FT8 sub-band at 7074 kHz where the geometry puts it, a pan arriving
/// in the headers, and both streams freeing the channel.
final class KiwiWaterfallLiveTests: XCTestCase {
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

    private func waitForUsers(_ expected: Int, within seconds: Double) async throws -> Int {
        let asked = Date()
        var count = try await users()
        while count != expected, Date().timeIntervalSince(asked) < seconds {
            try await Task.sleep(for: .milliseconds(500))
            count = try await users()
        }
        return count
    }

    func testWaterfallBesideSound() async throws {
        let before = try await users()
        let timestamp = Date()
        let sound = KiwiSDRClient(hostPort: host, password: password,
                                  tuning: KiwiTuning(dialHz: 7_074_000, mode: .usb), timestamp: timestamp,
                                  logSubsystem: "com.ftx1remote.tests")
        await sound.start()
        var soundReady = false
        for await event in sound.events {
            if case .ready = event { soundReady = true; break }
            if case .closed(let error) = event { return XCTFail("sound closed: \(String(describing: error))") }
        }
        XCTAssertTrue(soundReady)
        // Keep the sound stream drained.
        let drain = Task { for await _ in sound.events {} }

        let waterfall = KiwiWaterfallClient(hostPort: host, password: password, timestamp: timestamp,
                                            logSubsystem: "com.ftx1remote.tests")
        await waterfall.start()
        var geometry: KiwiWaterfallGeometry?
        var cal = 0
        var rows: [(row: KiwiWaterfallFrame, at: Date)] = []
        var start8 = 0
        var panRequestedAt: Date?
        var panStart = 0
        var panSeenAt: Date?
        var rowsBeforePanSeen = 0
        var usersDuring: Int?
        let began = Date()
        for await event in waterfall.events {
            switch event {
            case .ready(let g, let c):
                geometry = g
                cal = c
                start8 = g.start(centredOn: 7_074_000 + 1_500, zoom: 8)
                await waterfall.setView(zoom: 8, start: start8)
            case .row(let row):
                rows.append((row, Date()))
                let atZoom8 = rows.filter { $0.row.zoom == 8 && $0.row.xBin == start8 }.count
                if atZoom8 == 40, panRequestedAt == nil, let geometry {
                    usersDuring = try await waitForUsers(before + 1, within: 12)
                    panStart = start8 + 100 * geometry.unitsPerBin(zoom: 8)
                    panRequestedAt = Date()
                    rowsBeforePanSeen = 0
                    await waterfall.setView(zoom: 8, start: panStart)
                } else if let requested = panRequestedAt, panSeenAt == nil {
                    if row.xBin == panStart {
                        panSeenAt = Date()
                        _ = requested
                    } else {
                        rowsBeforePanSeen += 1
                    }
                } else if panSeenAt != nil, rows.count > 10 + rows.firstIndex(where: { $0.row.xBin == panStart })! {
                    await waterfall.stop()
                }
            case .closed(let error):
                XCTAssertNil(error)
            }
            if Date().timeIntervalSince(began) > 40 { await waterfall.stop() }
        }
        await sound.stop()
        drain.cancel()

        let g = try XCTUnwrap(geometry)
        print("LIVE WF: bandwidth \(g.bandwidthHz) fft \(g.fftSize) zoom_max \(g.zoomMax) cal \(cal), \(rows.count) rows")
        XCTAssertEqual(usersDuring, before + 1, "the waterfall takes no channel of its own")

        // Rate: rows per second over the run.
        if let first = rows.first?.at, let last = rows.last?.at, rows.count > 1 {
            print("LIVE WF: \(String(format: "%.1f", Double(rows.count - 1) / last.timeIntervalSince(first))) rows/s")
        }
        // FT8: average the zoom-8 rows; the 7074.2–7077.0 kHz band should
        // be brighter than the span's median.
        let zoom8 = rows.filter { $0.row.zoom == 8 && $0.row.xBin == start8 }.map(\.row)
        XCTAssertGreaterThanOrEqual(zoom8.count, 40)
        var mean = [Double](repeating: 0, count: g.fftSize)
        for row in zoom8 { for (i, b) in row.bins.enumerated() { mean[i] += Double(b) / Double(zoom8.count) } }
        let lo = Int(g.column(hz: 7_074_200, start: start8, zoom: 8))
        let hi = Int(g.column(hz: 7_077_000, start: start8, zoom: 8))
        let ft8 = mean[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        let median = mean.sorted()[g.fftSize / 2]
        let peakColumn = mean.indices.max { mean[$0] < mean[$1] }!
        print("LIVE WF: FT8 columns \(lo)–\(hi) mean \(String(format: "%.1f", ft8)) vs median \(String(format: "%.1f", median)) (dBm \(KiwiWaterfallFrame.dBm(UInt8(ft8), cal: cal)) vs \(KiwiWaterfallFrame.dBm(UInt8(median), cal: cal))); brightest column \(peakColumn) = \(String(format: "%.2f", g.hz(column: Double(peakColumn) + 0.5, start: start8, zoom: 8) / 1000)) kHz")
        // On a busy 40 m the segment's average barely beats the median
        // (gaps between signals); its brightest column clearly does.
        let ft8Peak = mean[lo...hi].max()!
        print("LIVE WF: FT8 peak \(String(format: "%.1f", ft8Peak)), ft8 mean \(String(format: "%.1f", ft8))")
        XCTAssertGreaterThan(ft8Peak, median + 4, "FT8 activity where the geometry puts 7074 kHz")

        let requested = try XCTUnwrap(panRequestedAt)
        let seen = try XCTUnwrap(panSeenAt, "a row at the panned start")
        print("LIVE WF: pan seen \(Int(seen.timeIntervalSince(requested) * 1000)) ms after the request, \(rowsBeforePanSeen) older rows (some buffered during the /status wait) handled first")

        let after = try await waitForUsers(before, within: 15)
        XCTAssertEqual(after, before, "both streams closed")
    }
}
