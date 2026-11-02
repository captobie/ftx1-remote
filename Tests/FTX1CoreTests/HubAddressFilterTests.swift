import Network
import XCTest
@testable import FTX1Core

/// The same cases as the Windows hub's `HubWireTests`, so the two filters
/// can't drift apart unnoticed.
final class HubAddressFilterTests: XCTestCase {
    private func host(_ text: String) -> NWEndpoint.Host {
        if let address = IPv4Address(text) { return .ipv4(address) }
        if let address = IPv6Address(text) { return .ipv6(address) }
        XCTFail("Not an address: \(text)")
        return .name(text, nil)
    }

    func testAllowsLocalAndTailscale() {
        for address in [
            "127.0.0.1", "127.1.2.3", "100.64.0.1", "100.100.1.1", "100.127.255.255",
            "10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.255",
            "192.168.1.20", "169.254.10.10",
            "::1", "fd7a:115c:a1e0::1234", "fd7a:115c:a1e0:ab12::1", "fc00::1",
            "fdff:ffff::1", "fe80::1", "febf::1",
            "::ffff:192.168.1.20", "::ffff:100.100.1.1", "::ffff:127.0.0.1",
        ] {
            XCTAssertTrue(HubAddressFilter.isAllowed(host(address)), address)
        }
    }

    func testRefusesEverythingElse() {
        for address in [
            "8.8.8.8", "100.63.255.255", "100.128.0.1", "172.15.255.255", "172.32.0.1",
            "192.169.0.1", "169.255.0.1", "11.0.0.1", "0.0.0.0",
            "2001:4860:4860::8888", "fec0::1", "fe00::1", "::ffff:8.8.8.8", "::",
        ] {
            XCTAssertFalse(HubAddressFilter.isAllowed(host(address)), address)
        }
    }

    func testRefusesAnythingThatIsntAnAddress() {
        XCTAssertFalse(HubAddressFilter.isAllowed(NWEndpoint.Host.name("example.com", nil)))
        XCTAssertFalse(HubAddressFilter.isAllowed(NWEndpoint.unix(path: "/tmp/hub")))
    }

    func testSpotsAWebPagesHandshake() {
        XCTAssertTrue(HubAddressFilter.isFromWebPage(headers: [("Origin", "https://example.com")]))
        XCTAssertTrue(HubAddressFilter.isFromWebPage(headers: [("origin", "null")]))
        XCTAssertTrue(HubAddressFilter.isFromWebPage(headers: [("User-Agent", "x"), ("ORIGIN", "")]))
    }

    func testAcceptsAnAppsHandshake() {
        XCTAssertFalse(HubAddressFilter.isFromWebPage(headers: []))
        XCTAssertFalse(HubAddressFilter.isFromWebPage(headers: [("User-Agent", "FTX1RemoteiPad"), ("Accept", "*/*")]))
    }

    func testChecksAnEndpointsHost() {
        XCTAssertTrue(HubAddressFilter.isAllowed(NWEndpoint.hostPort(host: "192.168.1.20", port: 8765)))
        XCTAssertFalse(HubAddressFilter.isAllowed(NWEndpoint.hostPort(host: "8.8.8.8", port: 8765)))
    }
}
