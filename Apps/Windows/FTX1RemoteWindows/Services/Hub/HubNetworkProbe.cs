using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace FTX1RemoteWindows.Services.Hub;

/// This PC's addresses an iPad can reach the hub at, plus the Tailscale and
/// Windows Firewall checks, for Settings → Mobile — the Windows side of the
/// Mac's MacNetworkAddresses. Everything here blocks (a tailscale.exe run,
/// the firewall's COM API, reverse DNS), so call it off the UI thread.
public static class HubNetworkProbe
{
    public sealed record Address(string InterfaceName, string Ip);

    public sealed record Snapshot(
        // Wi-Fi/Ethernet IPv4 addresses (not link-local, not Tailscale's).
        IReadOnlyList<Address> Lan,
        // "DESKTOP-ABC.local".
        string? LocalHostName,
        // This PC's tailnet IPv4 address (100.64.0.0/10), if Tailscale is up.
        string? TailnetIp,
        // Its MagicDNS name ("my-pc.tail1234.ts.net"), if known.
        string? TailnetName,
        bool TailscaleInstalled,
        // Null when the firewall couldn't be read.
        FirewallVerdict? Firewall);

    private static string TailscaleDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Tailscale");

    /// The Tailscale tray app, which Open Tailscale starts (it shows its
    /// window when already running).
    public static string TailscaleGuiPath => Path.Combine(TailscaleDirectory, "tailscale-ipn.exe");

    private static string TailscaleCliPath => Path.Combine(TailscaleDirectory, "tailscale.exe");

    public static Snapshot Read(string? appPath, int port)
    {
        var lan = new List<Address>();
        string? tailnetIp = null;
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up
                    || nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
                {
                    continue;
                }
                var properties = nic.GetIPProperties();
                // Hyper-V's and WSL's virtual switches have no gateway; a real
                // Wi-Fi or Ethernet network does.
                var hasGateway = properties.GatewayAddresses.Any(g =>
                    g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any));
                foreach (var unicast in properties.UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily != AddressFamily.InterNetwork)
                    {
                        continue;
                    }
                    var ip = unicast.Address.ToString();
                    if (HubConnectionInfo.IsTailnet(ip))
                    {
                        tailnetIp ??= ip;
                    }
                    else if (hasGateway && !ip.StartsWith("169.254.", StringComparison.Ordinal))
                    {
                        lan.Add(new Address(nic.Name, ip));
                    }
                }
            }
        }
        catch (NetworkInformationException ex)
        {
            AppLog.Write($"hub: reading the network interfaces failed: {ex.Message}");
        }

        string? localName = null;
        try
        {
            localName = Dns.GetHostName() + ".local";
        }
        catch (SocketException)
        {
        }

        var tailscaleInstalled = File.Exists(TailscaleGuiPath) || File.Exists(TailscaleCliPath);
        var tailnetName = tailnetIp is null ? null : ReadTailscaleSelfName() ?? ReverseTailnetName(tailnetIp);
        var firewall = appPath is null ? null : ReadFirewall(appPath, port);
        return new Snapshot(lan, localName, tailnetIp, tailnetName, tailscaleInstalled, firewall);
    }

    /// The MagicDNS name a tailnet address resolves to, or null (MagicDNS
    /// off, or not a tailnet name). Up to ~3 s.
    public static string? ReverseTailnetName(string ip)
    {
        if (!IPAddress.TryParse(ip, out var address))
        {
            return null;
        }
        try
        {
            var lookup = Dns.GetHostEntryAsync(address);
            return lookup.Wait(TimeSpan.FromSeconds(3)) ? HubConnectionInfo.MagicDnsName(lookup.Result.HostName) : null;
        }
        catch (Exception ex) when (ex is AggregateException or SocketException or ArgumentException)
        {
            return null;
        }
    }

    /// `tailscale status --json --peers=false`'s Self.DNSName; null if the
    /// CLI is missing, slow (3 s) or says nothing useful.
    private static string? ReadTailscaleSelfName()
    {
        if (!File.Exists(TailscaleCliPath))
        {
            return null;
        }
        try
        {
            using var process = Process.Start(new ProcessStartInfo(TailscaleCliPath, "status --json --peers=false")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            });
            if (process is null)
            {
                return null;
            }
            var output = process.StandardOutput.ReadToEndAsync();
            if (!process.WaitForExit(3000))
            {
                process.Kill();
                return null;
            }
            return output.Wait(1000) ? HubConnectionInfo.ParseTailscaleSelfName(output.Result) : null;
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or AggregateException)
        {
            return null;
        }
    }

    /// Windows Firewall through its own COM API (HNetCfg.FwPolicy2), which
    /// reads without admin rights. Null if it can't be read.
    private static FirewallVerdict? ReadFirewall(string appPath, int port)
    {
        try
        {
            if (Type.GetTypeFromProgID("HNetCfg.FwPolicy2") is not { } type
                || Activator.CreateInstance(type) is not { } instance)
            {
                return null;
            }
            dynamic policy = instance;
            var current = (FirewallProfiles)((int)policy.CurrentProfileTypes & (int)FirewallProfiles.All);
            FirewallProfiles enabled = FirewallProfiles.None, blockAll = FirewallProfiles.None;
            foreach (var profile in new[] { FirewallProfiles.Domain, FirewallProfiles.Private, FirewallProfiles.Public })
            {
                if ((bool)policy.FirewallEnabled[(int)profile])
                {
                    enabled |= profile;
                }
                if ((bool)policy.BlockAllInboundTraffic[(int)profile])
                {
                    blockAll |= profile;
                }
            }
            var rules = new List<FirewallRule>();
            foreach (dynamic rule in policy.Rules)
            {
                // NET_FW_RULE_DIR_IN = 1; skip the rest without reading them.
                if ((int)rule.Direction != 1)
                {
                    continue;
                }
                rules.Add(new FirewallRule(
                    Application: (string?)rule.ApplicationName,
                    Inbound: true,
                    Enabled: (bool)rule.Enabled,
                    Allow: (int)rule.Action == 1,
                    Profiles: (FirewallProfiles)((int)rule.Profiles & (int)FirewallProfiles.All),
                    Protocol: (int)rule.Protocol,
                    LocalPorts: (string?)rule.LocalPorts,
                    Service: (string?)rule.serviceName));
            }
            return FirewallCheck.Evaluate(current, enabled, blockAll, rules, appPath, port);
        }
        catch (Exception ex)
        {
            // Once a session: Settings → Mobile retries every 5 s.
            if (!_firewallErrorLogged)
            {
                _firewallErrorLogged = true;
                AppLog.Write($"hub: reading Windows Firewall failed: {ex.GetType().Name}: {ex.Message}");
            }
            return null;
        }
    }

    private static volatile bool _firewallErrorLogged;
}
