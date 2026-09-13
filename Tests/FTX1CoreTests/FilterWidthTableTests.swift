import XCTest
@testable import FTX1Core

final class FilterWidthTableTests: XCTestCase {
    /// The whole feature hinges on the same raw index meaning a different
    /// bandwidth per mode (CAT manual Table 5).
    func testSameIndexMapsToDifferentHzPerMode() {
        XCTAssertEqual(FilterWidthTable.hz(forIndex: 17, mode: .usb), 2700)
        XCTAssertEqual(FilterWidthTable.hz(forIndex: 17, mode: .lsb), 2700)
        XCTAssertEqual(FilterWidthTable.hz(forIndex: 17, mode: .cw), 2400)
        XCTAssertEqual(FilterWidthTable.hz(forIndex: 17, mode: .dataUSB), 2400)
        XCTAssertEqual(FilterWidthTable.hz(forIndex: 17, mode: .rtty), 2400)
    }

    func testColumnSizesMatchTheManual() {
        XCTAssertEqual(FilterWidthTable.entries(for: .usb).count, 23)
        XCTAssertEqual(FilterWidthTable.entries(for: .cw).count, 21)
        XCTAssertEqual(FilterWidthTable.entries(for: .am).count, 2)
        XCTAssertEqual(FilterWidthTable.entries(for: .fm).count, 2)
        XCTAssertEqual(FilterWidthTable.entries(for: .dataFM).count, 2)
        XCTAssertTrue(FilterWidthTable.entries(for: .c4fm).isEmpty)
        XCTAssertTrue(FilterWidthTable.entries(for: .unknown).isEmpty)
    }

    func testColumnEndpoints() {
        XCTAssertEqual(FilterWidthTable.hz(forIndex: 1, mode: .usb), 300)
        XCTAssertEqual(FilterWidthTable.hz(forIndex: 23, mode: .usb), 4000)
        XCTAssertEqual(FilterWidthTable.hz(forIndex: 1, mode: .cw), 50)
        XCTAssertEqual(FilterWidthTable.hz(forIndex: 21, mode: .cw), 4000)
        XCTAssertNil(FilterWidthTable.hz(forIndex: 22, mode: .cw))
        XCTAssertEqual(FilterWidthTable.hz(forIndex: 2, mode: .am), 9000)
        XCTAssertEqual(FilterWidthTable.hz(forIndex: 3, mode: .fm), 16000)
    }

    func testEntriesAreAscendingByIndex() {
        for mode in RigMode.allCases {
            let indices = FilterWidthTable.entries(for: mode).map(\.index)
            XCTAssertEqual(indices, indices.sorted(), "\(mode) column out of order")
            XCTAssertEqual(Set(indices).count, indices.count, "\(mode) column has duplicate indices")
        }
    }

    func testOnlySSBAndCWDataColumnsAreAdjustable() {
        XCTAssertTrue(FilterWidthTable.isAdjustable(mode: .usb))
        XCTAssertTrue(FilterWidthTable.isAdjustable(mode: .cw))
        XCTAssertTrue(FilterWidthTable.isAdjustable(mode: .dataUSB))
        XCTAssertFalse(FilterWidthTable.isAdjustable(mode: .am))
        XCTAssertFalse(FilterWidthTable.isAdjustable(mode: .fm))
        XCTAssertFalse(FilterWidthTable.isAdjustable(mode: .c4fm))
    }

    func testNeighborStepsThroughColumnGaps() {
        // AM's column is indices 1 and 2 only; FM's is 2 and 3.
        XCTAssertEqual(FilterWidthTable.neighborIndex(of: 1, mode: .am, narrower: false), 2)
        XCTAssertEqual(FilterWidthTable.neighborIndex(of: 3, mode: .fm, narrower: true), 2)
        XCTAssertEqual(FilterWidthTable.neighborIndex(of: 17, mode: .usb, narrower: true), 16)
        XCTAssertEqual(FilterWidthTable.neighborIndex(of: 17, mode: .usb, narrower: false), 18)
    }

    func testNeighborIsNilAtColumnEndsAndOffColumn() {
        XCTAssertNil(FilterWidthTable.neighborIndex(of: 1, mode: .usb, narrower: true))
        XCTAssertNil(FilterWidthTable.neighborIndex(of: 23, mode: .usb, narrower: false))
        XCTAssertNil(FilterWidthTable.neighborIndex(of: 21, mode: .cw, narrower: false))
        // Index 23 is valid in SSB but not in the CW column.
        XCTAssertNil(FilterWidthTable.neighborIndex(of: 23, mode: .cw, narrower: true))
        XCTAssertNil(FilterWidthTable.neighborIndex(of: 0, mode: .usb, narrower: false))
    }

    func testLabels() {
        XCTAssertEqual(FilterWidthTable.label(forIndex: 17, mode: .usb), "2700 Hz")
        XCTAssertEqual(FilterWidthTable.label(forIndex: 0, mode: .usb), "Default")
        XCTAssertEqual(FilterWidthTable.label(forIndex: nil, mode: .usb), "—")
        // Stale cross-mode index: 23 exists for SSB, not for CW.
        XCTAssertEqual(FilterWidthTable.label(forIndex: 23, mode: .cw), "—")
        XCTAssertEqual(FilterWidthTable.label(forIndex: 17, mode: .c4fm), "—")
    }
}
