import CFT8Lib
import XCTest
@testable import FT8Kit

/// The grid-field corrections in `FT8Decoder.classified`, through the real
/// `ftx_message_decode`: payloads are packed by ft8_lib's own encoder, then
/// the 15-bit grid value is rewritten where a sender packing "RR73" as a
/// locator would put it (ft8_lib's encoder always uses the RR73 report
/// code, so it can't produce that payload itself).
final class FT8FieldClassificationTests: XCTestCase {
    private func packed(_ text: String) throws -> ftx_message_t {
        var message = ftx_message_t()
        ftx_message_init(&message)
        let rc = ftx_message_encode(&message, &FT8CallsignHashStub.interface, text)
        XCTAssertEqual(rc, FTX_MESSAGE_RC_OK, text)
        return message
    }

    /// Standard message (i3 = 1): ir is bit 58 (payload[7] & 0x20), the
    /// grid is bits 59–73 (payload[7] & 0x1F, payload[8], payload[9] >> 6).
    private func settingGrid(_ message: ftx_message_t, igrid4: UInt16, ir: Bool) -> ftx_message_t {
        var message = message
        withUnsafeMutableBytes(of: &message.payload) { p in
            p[7] = (p[7] & 0xC0) | (ir ? 0x20 : 0) | UInt8((igrid4 >> 10) & 0x1F)
            p[8] = UInt8((igrid4 >> 2) & 0xFF)
            p[9] = (p[9] & 0x3F) | UInt8((igrid4 & 0x03) << 6)
        }
        return message
    }

    private static let rr73AsGrid: UInt16 = ((17 * 18 + 17) * 10 + 7) * 10 + 3

    func testRR73PackedAsGridIsAToken() throws {
        let message = settingGrid(try packed("K1ABC W9XYZ FN42"), igrid4: Self.rr73AsGrid, ir: false)
        let decoded = try XCTUnwrap(FT8Decoder.decodedText(for: message))
        XCTAssertEqual(decoded.text, "K1ABC W9XYZ RR73")
        XCTAssertEqual(decoded.fields.last, FT8Kit.MessageField(kind: .token, text: "RR73"))
        XCTAssertFalse(decoded.fields.contains { $0.kind == .grid })
    }

    func testRR73ReportCodeStaysAToken() throws {
        let decoded = try XCTUnwrap(FT8Decoder.decodedText(for: try packed("K1ABC W9XYZ RR73")))
        XCTAssertEqual(decoded.fields.last, FT8Kit.MessageField(kind: .token, text: "RR73"))
    }

    func testGridWithAcknowledgementSplits() throws {
        let message = settingGrid(try packed("K1ABC W9XYZ FN42"), igrid4: ((5 * 18 + 13) * 10 + 4) * 10 + 2, ir: true)
        let decoded = try XCTUnwrap(FT8Decoder.decodedText(for: message))
        XCTAssertEqual(decoded.text, "K1ABC W9XYZ R FN42")
        XCTAssertEqual(Array(decoded.fields.suffix(2)), [
            FT8Kit.MessageField(kind: .token, text: "R"),
            FT8Kit.MessageField(kind: .grid, text: "FN42"),
        ])
    }

    func testPlainGridUnchanged() throws {
        let decoded = try XCTUnwrap(FT8Decoder.decodedText(for: try packed("CQ W9XYZ EN52")))
        XCTAssertEqual(decoded.fields.last, FT8Kit.MessageField(kind: .grid, text: "EN52"))
    }
}
