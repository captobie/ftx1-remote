import XCTest
@testable import FTX1Core

final class NarrowWidthPresetTests: XCTestCase {
    func testAddressesComeFromTheCatalog() {
        let ssb = NarrowWidthPreset.item(for: .usb)
        XCTAssertEqual([ssb?.p1, ssb?.p2, ssb?.p3], [1, 1, 16])
        XCTAssertEqual(NarrowWidthPreset.item(for: .lsb)?.tab, "MODE SSB")
        let data = NarrowWidthPreset.item(for: .dataUSB)
        XCTAssertEqual([data?.p1, data?.p2, data?.p3], [1, 4, 16])
        let rtty = NarrowWidthPreset.item(for: .rtty)
        XCTAssertEqual([rtty?.p1, rtty?.p2, rtty?.p3], [1, 5, 13])
        let cw = NarrowWidthPreset.item(for: .cw)
        XCTAssertEqual([cw?.p1, cw?.p2, cw?.p3], [2, 1, 13])
        for mode in [RigMode.am, .fm, .dataFM, .c4fm, .unknown] {
            XCTAssertNil(NarrowWidthPreset.item(for: mode), "\(mode)")
        }
    }

    func testRawIndexMapsToHzPerModeList() {
        // SSB list: index 10 is 2100 Hz; DATA/RTTY/CW list: index 10 is 600 Hz.
        XCTAssertEqual(NarrowWidthPreset.hz(forRawValue: "10", mode: .usb), 2100)
        XCTAssertEqual(NarrowWidthPreset.hz(forRawValue: "10", mode: .dataUSB), 600)
        XCTAssertEqual(NarrowWidthPreset.hz(forRawValue: "10", mode: .cw), 600)
        XCTAssertEqual(NarrowWidthPreset.hz(forRawValue: "00", mode: .usb), 300)
        XCTAssertEqual(NarrowWidthPreset.hz(forRawValue: "16", mode: .dataUSB), 2400)
        XCTAssertNil(NarrowWidthPreset.hz(forRawValue: "99", mode: .usb))
        XCTAssertNil(NarrowWidthPreset.hz(forRawValue: "abc", mode: .usb))
        XCTAssertNil(NarrowWidthPreset.hz(forRawValue: "10", mode: .am))
    }
}
