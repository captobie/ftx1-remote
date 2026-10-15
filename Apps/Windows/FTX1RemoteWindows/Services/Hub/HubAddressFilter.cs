using System.Net;
using System.Net.Sockets;

namespace FTX1RemoteWindows.Services.Hub;

/// Who may connect to the hub (user decision, 2026-10-15): this PC,
/// Tailscale and the local network. Kestrel listens on every interface, so
/// HubServer checks each connection's remote address against this before
/// the WebSocket upgrade. Compiled into the test project too.
public static class HubAddressFilter
{
    private static readonly (IPAddress Network, int PrefixLength)[] AllowedV4 =
    [
        (IPAddress.Parse("127.0.0.0"), 8),      // loopback
        (IPAddress.Parse("100.64.0.0"), 10),    // Tailscale (CGNAT range)
        (IPAddress.Parse("10.0.0.0"), 8),
        (IPAddress.Parse("172.16.0.0"), 12),
        (IPAddress.Parse("192.168.0.0"), 16),
        (IPAddress.Parse("169.254.0.0"), 16),   // link-local
    ];

    private static readonly (IPAddress Network, int PrefixLength)[] AllowedV6 =
    [
        (IPAddress.IPv6Loopback, 128),
        (IPAddress.Parse("fd7a:115c:a1e0::"), 48), // Tailscale
        (IPAddress.Parse("fc00::"), 7),            // unique local
        (IPAddress.Parse("fe80::"), 10),           // link-local
    ];

    public static bool IsAllowed(IPAddress? address)
    {
        if (address is null)
        {
            return false;
        }
        // Kestrel's dual-mode socket reports IPv4 clients as ::ffff:a.b.c.d.
        if (address.IsIPv4MappedToIPv6)
        {
            address = address.MapToIPv4();
        }
        var ranges = address.AddressFamily switch
        {
            AddressFamily.InterNetwork => AllowedV4,
            AddressFamily.InterNetworkV6 => AllowedV6,
            _ => [],
        };
        return ranges.Any(r => InPrefix(address, r.Network, r.PrefixLength));
    }

    private static bool InPrefix(IPAddress address, IPAddress network, int prefixLength)
    {
        var a = address.GetAddressBytes();
        var n = network.GetAddressBytes();
        if (a.Length != n.Length)
        {
            return false;
        }
        var fullBytes = prefixLength / 8;
        for (var i = 0; i < fullBytes; i++)
        {
            if (a[i] != n[i])
            {
                return false;
            }
        }
        var remainingBits = prefixLength % 8;
        if (remainingBits == 0)
        {
            return true;
        }
        var mask = (byte)(0xFF << (8 - remainingBits));
        return (a[fullBytes] & mask) == (n[fullBytes] & mask);
    }
}
