import Foundation
import Network

/// Who may connect to the Mac's hub: this Mac, Tailscale and the local
/// network, the same list as the Windows hub's `HubAddressFilter.cs` (keep
/// them in step). The hub has no login and `NWListener` listens on every
/// interface, so `RigWebSocketServer` checks each connection against this
/// before anything is sent to it or read from it.
public enum HubAddressFilter {
    private struct Range {
        let network: [UInt8]
        let prefixLength: Int

        func contains(_ address: [UInt8]) -> Bool {
            guard address.count == network.count else { return false }
            let fullBytes = prefixLength / 8
            guard address.prefix(fullBytes) == network.prefix(fullBytes) else { return false }
            let remainingBits = prefixLength % 8
            guard remainingBits != 0 else { return true }
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - remainingBits))
            return address[fullBytes] & mask == network[fullBytes] & mask
        }
    }

    private static let allowedV4: [Range] = [
        Range(network: [127, 0, 0, 0], prefixLength: 8),      // loopback
        Range(network: [100, 64, 0, 0], prefixLength: 10),    // Tailscale (CGNAT range)
        Range(network: [10, 0, 0, 0], prefixLength: 8),
        Range(network: [172, 16, 0, 0], prefixLength: 12),
        Range(network: [192, 168, 0, 0], prefixLength: 16),
        Range(network: [169, 254, 0, 0], prefixLength: 16),   // link-local
    ]

    private static let allowedV6: [Range] = [
        Range(network: [UInt8](repeating: 0, count: 15) + [1], prefixLength: 128), // loopback
        Range(network: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0] + [UInt8](repeating: 0, count: 10),
              prefixLength: 48),                              // Tailscale
        Range(network: [0xFC] + [UInt8](repeating: 0, count: 15), prefixLength: 7),      // unique local
        Range(network: [0xFE, 0x80] + [UInt8](repeating: 0, count: 14), prefixLength: 10), // link-local
    ]

    /// Whether a WebSocket handshake came from a web page. Browsers always
    /// send `Origin` on one and the apps never do. The hub refuses these: a
    /// page open on an allowed machine could otherwise connect through
    /// `localhost` and send commands, including keying the radio.
    public static func isFromWebPage(headers: [(name: String, value: String)]) -> Bool {
        headers.contains { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }
    }

    /// False for anything that isn't an IP address.
    public static func isAllowed(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        return isAllowed(host)
    }

    public static func isAllowed(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            return isAllowedV4([UInt8](address.rawValue))
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            // A dual-stack listener can report IPv4 clients as ::ffff:a.b.c.d.
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return isAllowedV4(Array(bytes.suffix(4)))
            }
            return allowedV6.contains { $0.contains(bytes) }
        default:
            return false
        }
    }

    private static func isAllowedV4(_ bytes: [UInt8]) -> Bool {
        allowedV4.contains { $0.contains(bytes) }
    }
}
