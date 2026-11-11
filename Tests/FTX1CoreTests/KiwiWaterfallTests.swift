import XCTest
@testable import FTX1Core

/// The KiwiSDR waterfall stream: frame parsing against frames captured
/// from a KiwiSDR 2 (v1.902, `Tests/KiwiSDRFixtures/`), the bin ↔ Hz
/// arithmetic, row placement and the colour auto-range.
final class KiwiWaterfallTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("KiwiSDRFixtures")

    private let geometry = KiwiWaterfallGeometry(bandwidthHz: 30_000_000, fftSize: 1024, zoomMax: 14)

    private func row(_ name: String) throws -> KiwiWaterfallFrame {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        guard case .waterfall(let frame) = KiwiProtocol.parseFrame(data) else {
            XCTFail("\(name) isn't a W/F frame")
            throw CocoaError(.coderInvalidValue)
        }
        return frame
    }

    // MARK: - Frames

    func testZoom0Frame() throws {
        let frame = try row("wf-zoom0.bin")
        XCTAssertEqual(frame.xBin, 0)
        XCTAssertEqual(frame.zoom, 0)
        XCTAssertFalse(frame.isCompressed)
        XCTAssertEqual(frame.bins.count, 1024)
    }

    func testZoom8Frame() throws {
        let frame = try row("wf-zoom8.bin")
        XCTAssertEqual(frame.xBin, 3_923_300)
        XCTAssertEqual(frame.zoom, 8)
        XCTAssertEqual(frame.flags, 0)
        XCTAssertEqual(frame.sequence, 164)
        XCTAssertEqual(frame.bins.count, 1024)
        // 7015.4–7132.6 kHz, bin 512 = 7074.0 kHz (README).
        XCTAssertEqual(geometry.hz(column: 0, start: frame.xBin, zoom: 8), 7_015_407, accuracy: 1)
        XCTAssertEqual(geometry.hz(column: 1024, start: frame.xBin, zoom: 8), 7_132_595, accuracy: 1)
        XCTAssertEqual(geometry.hz(column: 512, start: frame.xBin, zoom: 8) / 1000, 7074.0, accuracy: 0.06)
        XCTAssertEqual(geometry.column(hz: 7_074_000, start: frame.xBin, zoom: 8), 512, accuracy: 0.5)
        // The FT8 sub-band sits around bin 512: brighter than the band's median.
        let bytes = [UInt8](frame.bins)
        let around = bytes[505..<540].max()!
        let median = bytes.sorted()[512]
        XCTAssertGreaterThan(around, median)
    }

    func testDBm() {
        XCTAssertEqual(KiwiWaterfallFrame.dBm(255, cal: -13), -13)
        XCTAssertEqual(KiwiWaterfallFrame.dBm(155, cal: -13), -113)
        XCTAssertEqual(KiwiWaterfallFrame.dBm(55, cal: 0), -200)
    }

    func testCompressedFlag() {
        var bytes = [UInt8]("W/F".utf8) + [0]
        bytes += [0, 0, 0, 0]          // x_bin
        bytes += [3, 0, 1, 0]          // zoom 3, flags 1 << 16
        bytes += [7, 0, 0, 0]          // sequence
        bytes += [UInt8](repeating: 0, count: 8)
        guard case .waterfall(let frame) = KiwiProtocol.parseFrame(Data(bytes)) else { return XCTFail() }
        XCTAssertEqual(frame.zoom, 3)
        XCTAssertTrue(frame.isCompressed)
        XCTAssertEqual(frame.sequence, 7)
    }

    // MARK: - Commands and URL

    func testCommands() {
        XCTAssertEqual(KiwiProtocol.waterfallSetupCommands(identUser: "FTX1Remote"), [
            "SET zoom=0 start=0",
            "SET maxdb=0 mindb=-100",
            "SET wf_comp=0",
            "SET wf_speed=4",
            "SET ident_user=FTX1Remote",
        ])
        XCTAssertEqual(KiwiProtocol.waterfallView(zoom: 8, start: 3_923_264), "SET zoom=8 start=3923264")
    }

    func testWaterfallURLSharesTheTimestamp() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(KiwiProtocol.waterfallURL(hostPort: "192.168.0.225:8073", timestamp: date)?.absoluteString,
                       "ws://192.168.0.225:8073/1800000000/W/F")
        XCTAssertEqual(KiwiProtocol.soundURL(hostPort: "192.168.0.225", timestamp: date)?.absoluteString,
                       "ws://192.168.0.225:8073/1800000000/SND")
    }

    // MARK: - Geometry

    func testSpans() {
        XCTAssertEqual(geometry.maxBins, 16_777_216)
        XCTAssertEqual(geometry.spanHz(zoom: 0), 30_000_000)
        XCTAssertEqual(geometry.spanHz(zoom: 8), 117_187.5)
        XCTAssertEqual(geometry.binHz(zoom: 8), 114.44, accuracy: 0.01)
        XCTAssertEqual(geometry.unitsPerBin(zoom: 8), 64)
        XCTAssertEqual(geometry.unitsPerBin(zoom: 14), 1)
        XCTAssertEqual(geometry.spanUnits(zoom: 0), geometry.maxBins)
        XCTAssertEqual(geometry.clampZoom(20), 14)
        // A different Kiwi: 32 MHz, 2048 bins.
        let other = KiwiWaterfallGeometry(bandwidthHz: 32_000_000, fftSize: 2048, zoomMax: 14)
        XCTAssertEqual(other.spanHz(zoom: 1), 16_000_000)
        XCTAssertEqual(other.hz(xBin: Double(other.maxBins) / 2), 16_000_000)
    }

    func testStartClampingAndCentring() {
        // Centred on 7074 kHz at zoom 8: aligned to 64 units, 7074 near bin 512.
        let start = geometry.start(centredOn: 7_074_000, zoom: 8)
        XCTAssertEqual(start % 64, 0)
        XCTAssertEqual(geometry.column(hz: 7_074_000, start: start, zoom: 8), 512, accuracy: 1)
        // Clamped at the bottom and the top of the band.
        XCTAssertEqual(geometry.start(centredOn: 10_000, zoom: 8), 0)
        XCTAssertEqual(geometry.start(centredOn: 29_990_000, zoom: 8),
                       geometry.maxBins - geometry.spanUnits(zoom: 8))
        XCTAssertEqual(geometry.clampStart(-5, zoom: 3), 0)
        XCTAssertEqual(geometry.start(centredOn: 15_000_000, zoom: 0), 0, "zoom 0 is the whole band")
        XCTAssertEqual(geometry.clampStart(3_923_300, zoom: 8), 3_923_328, "rounded to a whole bin")
    }

    func testBinsToShift() {
        XCTAssertEqual(geometry.binsToShift(from: (1000 * 64, 8), to: (1010 * 64, 8)), 10)
        XCTAssertEqual(geometry.binsToShift(from: (1010 * 64, 8), to: (1000 * 64, 8)), -10)
        XCTAssertEqual(geometry.binsToShift(from: (3_923_300, 8), to: (3_923_300 + 31, 8)), 0)
        XCTAssertEqual(geometry.binsToShift(from: (3_923_300, 8), to: (3_923_300 + 33, 8)), 1)
        XCTAssertNil(geometry.binsToShift(from: (0, 8), to: (0, 9)))
    }

    // MARK: - Placement

    func testPlacement() {
        XCTAssertEqual(KiwiWaterfallPlacement.place(row: (0, 0), anchor: nil, geometry: geometry), .append)
        XCTAssertEqual(KiwiWaterfallPlacement.place(row: (640, 8), anchor: (640, 8), geometry: geometry), .append)
        XCTAssertEqual(KiwiWaterfallPlacement.place(row: (640 + 128, 8), anchor: (640, 8), geometry: geometry),
                       .shift(bins: 2))
        XCTAssertEqual(KiwiWaterfallPlacement.place(row: (640, 9), anchor: (640, 8), geometry: geometry), .rezoom)
    }

    func testColumnMapZoomIn() {
        // Zoom 8 → 9 around the middle: each old bin covers two new columns.
        let from = (xBin: 1_000 * 64, zoom: 8)
        let to = (xBin: from.xBin + 256 * 64, zoom: 9)
        let map = KiwiWaterfallPlacement.columnMap(from: from, to: to, geometry: geometry)
        XCTAssertEqual(map.count, 1024)
        XCTAssertEqual(Array(map.prefix(4)), [256, 256, 257, 257])
        XCTAssertEqual(map.last, 767)
    }

    func testColumnMapZoomOut() {
        // Zoom 9 → 8 keeping the middle: the old picture is squeezed into
        // the middle half, the sides blank.
        let from = (xBin: 1_256 * 64, zoom: 9)
        let to = (xBin: 1_000 * 64, zoom: 8)
        let map = KiwiWaterfallPlacement.columnMap(from: from, to: to, geometry: geometry)
        XCTAssertEqual(map[0], -1)
        XCTAssertEqual(map[255], -1)
        XCTAssertEqual(map[256], 1)
        XCTAssertEqual(map[767], 1023)
        XCTAssertEqual(map[768], -1)
    }

    func testColumnMapSameZoomIsAShift() {
        let map = KiwiWaterfallPlacement.columnMap(from: (640, 8), to: (640 + 3 * 64, 8), geometry: geometry)
        XCTAssertEqual(map[0], 3)
        XCTAssertEqual(map[1020], 1023)
        XCTAssertEqual(map[1021], -1)
    }

    // MARK: - Panning to keep the passband visible

    func testTuningInsideTheSpanDoesNotPan() {
        let start = geometry.start(centredOn: 7_074_000, zoom: 8)
        XCTAssertNil(geometry.startKeeping(lowHz: 7_074_300, highHz: 7_076_700, start: start, zoom: 8))
        XCTAssertNil(geometry.startKeeping(lowHz: 7_030_000, highHz: 7_032_400, start: start, zoom: 8))
    }

    func testNearTheEdgePansJustEnough() throws {
        let start = geometry.start(centredOn: 7_074_000, zoom: 8)
        let right = geometry.hz(column: 1024, start: start, zoom: 8)
        // Passband ending 2 kHz short of the right edge (inside the 10% margin).
        let newStart = try XCTUnwrap(geometry.startKeeping(lowHz: right - 4_400, highHz: right - 2_000,
                                                           start: start, zoom: 8))
        XCTAssertGreaterThan(newStart, start)
        let newRight = geometry.hz(column: 1024, start: newStart, zoom: 8)
        let margin = geometry.spanHz(zoom: 8) * 0.1
        XCTAssertEqual(newRight - (right - 2_000), margin, accuracy: geometry.binHz(zoom: 8))
    }

    func testFarAwayCentres() throws {
        let start = geometry.start(centredOn: 7_074_000, zoom: 8)
        let newStart = try XCTUnwrap(geometry.startKeeping(lowHz: 14_074_300, highHz: 14_076_700,
                                                           start: start, zoom: 8))
        XCTAssertEqual(geometry.column(hz: 14_075_500, start: newStart, zoom: 8), 512, accuracy: 1)
    }

    func testBandEdgeClampsAndStops() {
        let start = geometry.start(centredOn: 20_000, zoom: 8)
        XCTAssertEqual(start, 0)
        XCTAssertNil(geometry.startKeeping(lowHz: 10_300, highHz: 12_700, start: 0, zoom: 8),
                     "already at the bottom of the band")
    }

    // MARK: - Auto range

    func testAutoRangeFromARow() throws {
        let frame = try row("wf-zoom8.bin")
        var range = KiwiWaterfallAutoRange()
        XCTAssertTrue(range.add(frame.bins, cal: -13))
        XCTAssertTrue(range.isSettled)
        let bytes = [UInt8](frame.bins).filter { Int($0) > 65 + 13 }.sorted()
        let median = Double(KiwiWaterfallFrame.dBm(bytes[bytes.count / 2], cal: -13))
        XCTAssertEqual(range.floorDBm, median - 5, accuracy: 1)
        XCTAssertGreaterThanOrEqual(range.ceilingDBm, range.floorDBm + 40)

        let steps = range.paletteSteps(cal: -13)
        XCTAssertEqual(steps.count, 256)
        XCTAssertEqual(steps[0], 0)
        XCTAssertEqual(steps[255], 255)
        XCTAssertEqual(steps, steps.sorted(), "monotonic")
    }

    func testAutoRangeSmoothsAndSkipsMaskedRows() {
        var range = KiwiWaterfallAutoRange(rowsPerMeasurement: 1, smoothing: 0.5)
        let quiet = Data(repeating: 140, count: 1024)     // −128 dBm at cal −13
        XCTAssertTrue(range.add(quiet, cal: -13))
        XCTAssertEqual(range.floorDBm, -133)
        let loud = Data(repeating: 160, count: 1024)      // −108
        XCTAssertTrue(range.add(loud, cal: -13))
        XCTAssertEqual(range.floorDBm, -123, "half way")
        XCTAssertFalse(range.add(Data(repeating: 50, count: 1024), cal: -13), "all masked")
        XCTAssertEqual(range.floorDBm, -123)
    }
}
