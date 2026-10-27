import XCTest
@testable import FTX1Core

/// The keyer reply's codes must degrade to the English text: an older Mac
/// hub and the Windows hub send no codes, and a newer hub may send one this
/// client doesn't know.
final class CWKeyerReplyCodeTests: XCTestCase {
    private func decode(_ json: String) throws -> CWKeyerReply {
        try JSONDecoder().decode(CWKeyerReply.self, from: Data(json.utf8))
    }

    func testBusyPrefersAKnownCode() throws {
        let reply = try decode(#"{"type":"cw_keyer_reply","id":1,"busy":"the Mac's CW window","busyCode":"mac_cw_window"}"#)
        XCTAssertEqual(CWKeyerBusy(reply: reply), .holder(.macCWWindow))
    }

    func testBusyFallsBackToTextForAnUnknownOrMissingCode() throws {
        let unknown = try decode(#"{"type":"cw_keyer_reply","id":1,"busy":"the shack PC","busyCode":"some_future_holder"}"#)
        XCTAssertEqual(CWKeyerBusy(reply: unknown), .text("the shack PC"))
        let old = try decode(#"{"type":"cw_keyer_reply","id":1,"busy":"the Mac's CW window"}"#)
        XCTAssertEqual(CWKeyerBusy(reply: old), .text("the Mac's CW window"))
        let granted = try decode(#"{"type":"cw_keyer_reply","id":1}"#)
        XCTAssertNil(CWKeyerBusy(reply: granted))
    }

    func testAnUnknownErrorCodeStillDecodes() throws {
        let reply = try decode(#"{"type":"cw_keyer_reply","id":1,"error":"Something new","errorCode":"keyer_on_fire"}"#)
        XCTAssertNil(reply.errorCode.flatMap(CWKeyerReply.ErrorCode.init(rawValue:)))
        XCTAssertEqual(reply.error, "Something new")
    }

    func testEveryRigctldErrorRoundTripsThroughItsCode() {
        let all: [RigctldError] = [.notConnected, .badResponse, .connectTimedOut, .rawCommandTimedOut,
                                   .replyTimedOut, .connectionLost, .keyerMemoryRejected]
        for error in all {
            let back = RigctldError(keyerErrorCode: error.keyerErrorCode)
            XCTAssertEqual(back?.keyerErrorCode, error.keyerErrorCode)
        }
        XCTAssertNil(RigctldError(keyerErrorCode: .badSlot))
    }
}
