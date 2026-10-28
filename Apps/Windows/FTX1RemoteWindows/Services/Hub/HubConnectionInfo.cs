using System.Text.Json;

namespace FTX1RemoteWindows.Services.Hub;

/// The pieces of Settings → Mobile (the Mac's MobileSettingsTab.swift) that
/// don't touch the OS: which addresses are Tailscale's, MagicDNS names, and
/// what Windows Firewall's rules mean for the hub's port. The OS reads are
/// in HubNetworkProbe.cs. Compiled into the test project too, so keep it free
/// of Windows-only types.
public static class HubConnectionInfo
{
    /// Tailscale's address range, the shared-address space 100.64.0.0/10.
    public static bool IsTailnet(string ip)
    {
        var parts = ip.Split('.');
        return parts.Length == 4
            && int.TryParse(parts[0], out var a) && a == 100
            && int.TryParse(parts[1], out var b) && b is >= 64 and <= 127;
    }

    /// A MagicDNS name ("my-pc.tail1234.ts.net"), without the trailing dot;
    /// null for anything else. Windows answers a reverse lookup of its own
    /// addresses with its bare computer name, so only a tailnet domain counts.
    public static string? MagicDnsName(string? name)
    {
        var trimmed = name?.Trim().TrimEnd('.');
        if (string.IsNullOrEmpty(trimmed))
        {
            return null;
        }
        return trimmed.EndsWith(".ts.net", StringComparison.OrdinalIgnoreCase)
            || trimmed.EndsWith(".tailscale.net", StringComparison.OrdinalIgnoreCase)
            ? trimmed
            : null;
    }

    /// "my-pc" from "my-pc.tail1234.ts.net": works on the iPad too while
    /// MagicDNS is on.
    public static string ShortName(string name)
    {
        var dot = name.IndexOf('.');
        return dot > 0 ? name[..dot] : name;
    }

    /// This PC's MagicDNS name from `tailscale status --json`: Self.DNSName,
    /// unless the tailnet has MagicDNS turned off. Null if it can't be read.
    public static string? ParseTailscaleSelfName(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.TryGetProperty("CurrentTailnet", out var tailnet)
                && tailnet.ValueKind == JsonValueKind.Object
                && tailnet.TryGetProperty("MagicDNSEnabled", out var enabled)
                && enabled.ValueKind == JsonValueKind.False)
            {
                return null;
            }
            return root.TryGetProperty("Self", out var self)
                && self.ValueKind == JsonValueKind.Object
                && self.TryGetProperty("DNSName", out var dnsName)
                && dnsName.ValueKind == JsonValueKind.String
                ? MagicDnsName(dnsName.GetString())
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// Windows Firewall's network profiles (NET_FW_PROFILE_TYPE2).
[Flags]
public enum FirewallProfiles
{
    None = 0,
    Domain = 1,
    Private = 2,
    Public = 4,
    All = Domain | Private | Public,
}

/// One rule as INetFwRule reports it, the fields the hub's check needs.
/// Protocol: 6 TCP, 256 any. LocalPorts: "*", "8765", "8000-9000,8765"….
public sealed record FirewallRule(
    string? Application,
    bool Inbound,
    bool Enabled,
    bool Allow,
    FirewallProfiles Profiles,
    int Protocol,
    string? LocalPorts,
    string? Service);

public enum FirewallVerdictKind
{
    /// Off on every network this PC is on.
    Off,
    /// An enabled inbound allow rule covers every network this PC is on.
    AllowsApp,
    /// No rule for this app yet on <see cref="FirewallVerdict.Profiles"/>:
    /// Windows asks when the hub starts listening (or, if that was
    /// dismissed, blocks silently).
    NoRule,
    /// A block rule for this app on <see cref="FirewallVerdict.Profiles"/>
    /// (Windows makes one when its prompt is cancelled; block beats allow).
    BlocksApp,
    /// "Block all incoming connections" is on for <see cref="FirewallVerdict.Profiles"/>.
    BlocksAll,
}

/// <see cref="Profiles"/>: the networks the verdict is about (for the
/// problem kinds, the ones with the problem).
public sealed record FirewallVerdict(FirewallVerdictKind Kind, FirewallProfiles Profiles);

public static class FirewallCheck
{
    private static readonly FirewallProfiles[] Each = [FirewallProfiles.Domain, FirewallProfiles.Private, FirewallProfiles.Public];

    /// What Windows Firewall does with an inbound TCP connection to
    /// <paramref name="port"/> for the exe at <paramref name="appPath"/>, on
    /// the networks this PC is on (<paramref name="current"/>; none = judge
    /// Private and Public, the two a Wi-Fi or Tailscale adapter gets). The
    /// worst network wins.
    public static FirewallVerdict Evaluate(FirewallProfiles current, FirewallProfiles enabled, FirewallProfiles blockAll,
        IEnumerable<FirewallRule> rules, string appPath, int port)
    {
        if (current == FirewallProfiles.None)
        {
            current = FirewallProfiles.Private | FirewallProfiles.Public;
        }
        var on = current & enabled;
        if (on == FirewallProfiles.None)
        {
            return new FirewallVerdict(FirewallVerdictKind.Off, current);
        }
        var all = on & blockAll;
        if (all != FirewallProfiles.None)
        {
            return new FirewallVerdict(FirewallVerdictKind.BlocksAll, all);
        }
        var matching = rules.Where(r => r.Inbound && r.Enabled && Covers(r, appPath, port)).ToList();
        FirewallProfiles blocked = FirewallProfiles.None, unruled = FirewallProfiles.None;
        foreach (var profile in Each.Where(p => on.HasFlag(p)))
        {
            if (matching.Any(r => !r.Allow && r.Profiles.HasFlag(profile)))
            {
                blocked |= profile;
            }
            else if (!matching.Any(r => r.Allow && r.Profiles.HasFlag(profile)))
            {
                unruled |= profile;
            }
        }
        if (blocked != FirewallProfiles.None)
        {
            return new FirewallVerdict(FirewallVerdictKind.BlocksApp, blocked);
        }
        return unruled != FirewallProfiles.None
            ? new FirewallVerdict(FirewallVerdictKind.NoRule, unruled)
            : new FirewallVerdict(FirewallVerdictKind.AllowsApp, on);
    }

    /// A rule for this exe on a port that includes the hub's, or a rule for
    /// no program that names the hub's port. A service's rule, another
    /// program's, or an any-program any-port rule doesn't count.
    private static bool Covers(FirewallRule rule, string appPath, int port)
    {
        if (!string.IsNullOrEmpty(rule.Service) || rule.Protocol is not (6 or 256))
        {
            return false;
        }
        if (string.IsNullOrEmpty(rule.Application))
        {
            return PortListIncludes(rule.LocalPorts, port, anyCounts: false);
        }
        return SamePath(rule.Application, appPath) && PortListIncludes(rule.LocalPorts, port, anyCounts: true);
    }

    private static bool SamePath(string rulePath, string appPath) =>
        string.Equals(Environment.ExpandEnvironmentVariables(rulePath).Trim().Trim('"'), appPath,
            StringComparison.OrdinalIgnoreCase);

    public static bool PortListIncludes(string? ports, int port, bool anyCounts)
    {
        if (string.IsNullOrWhiteSpace(ports) || ports.Trim() == "*")
        {
            return anyCounts;
        }
        foreach (var part in ports.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            var dash = part.IndexOf('-');
            if (dash > 0)
            {
                if (int.TryParse(part[..dash], out var low) && int.TryParse(part[(dash + 1)..], out var high)
                    && port >= low && port <= high)
                {
                    return true;
                }
            }
            else if (int.TryParse(part, out var single) && single == port)
            {
                return true;
            }
        }
        return false;
    }
}
