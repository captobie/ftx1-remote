using FTX1RemoteWindows.Services.Hub;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// Settings → Mobile's OS-free logic (Services/Hub/HubConnectionInfo.cs):
/// tailnet addresses, MagicDNS names, and the Windows Firewall verdict for
/// the hub's port.
public class HubConnectionInfoTests
{
    private const string App = @"C:\Tools\FTX1Remote\FTX1RemoteWindows.exe";
    private const int Port = 8765;
    private const FirewallProfiles PrivatePublic = FirewallProfiles.Private | FirewallProfiles.Public;

    [Theory]
    [InlineData("100.64.0.1", true)]
    [InlineData("100.104.255.14", true)]
    [InlineData("100.127.255.255", true)]
    [InlineData("100.63.0.1", false)]
    [InlineData("100.128.0.1", false)]
    [InlineData("192.168.1.20", false)]
    [InlineData("fd7a:115c:a1e0::1", false)]
    public void RecognisesTailnetAddresses(string ip, bool expected) =>
        Assert.Equal(expected, HubConnectionInfo.IsTailnet(ip));

    [Theory]
    [InlineData("my-pc.tail1234.ts.net.", "my-pc.tail1234.ts.net")]
    [InlineData("ipad.example-tailnet.ts.net", "ipad.example-tailnet.ts.net")]
    [InlineData("old.user.beta.tailscale.net", "old.user.beta.tailscale.net")]
    [InlineData("DESKTOP-ABC123", null)]
    [InlineData("router.lan", null)]
    [InlineData("", null)]
    [InlineData(null, null)]
    public void AcceptsOnlyMagicDnsNames(string? name, string? expected) =>
        Assert.Equal(expected, HubConnectionInfo.MagicDnsName(name));

    [Fact]
    public void ShortNameIsTheFirstLabel()
    {
        Assert.Equal("my-pc", HubConnectionInfo.ShortName("my-pc.tail1234.ts.net"));
        Assert.Equal("my-pc", HubConnectionInfo.ShortName("my-pc"));
    }

    [Fact]
    public void ReadsTheSelfNameFromTailscaleStatus()
    {
        const string json = """
            {"Version":"1.76.1","BackendState":"Running",
             "Self":{"HostName":"my-pc","DNSName":"my-pc.tail1234.ts.net.","TailscaleIPs":["100.101.102.103"]},
             "CurrentTailnet":{"Name":"user@example.com","MagicDNSSuffix":"tail1234.ts.net","MagicDNSEnabled":true}}
            """;
        Assert.Equal("my-pc.tail1234.ts.net", HubConnectionInfo.ParseTailscaleSelfName(json));
    }

    [Theory]
    [InlineData("""{"Self":{"DNSName":"my-pc.tail1234.ts.net."},"CurrentTailnet":{"MagicDNSEnabled":false}}""")]
    [InlineData("""{"Self":{"DNSName":""}}""")]
    [InlineData("""{"BackendState":"Stopped","Self":null}""")]
    [InlineData("not json")]
    public void NoSelfNameWithoutMagicDns(string json) =>
        Assert.Null(HubConnectionInfo.ParseTailscaleSelfName(json));

    [Theory]
    [InlineData("*", true, true)]
    [InlineData("*", false, false)]
    [InlineData("8765", false, true)]
    [InlineData("80,443, 8765", false, true)]
    [InlineData("8000-9000", false, true)]
    [InlineData("8766-9000", false, false)]
    [InlineData("RPC", true, false)]
    public void PortLists(string ports, bool anyCounts, bool expected) =>
        Assert.Equal(expected, FirewallCheck.PortListIncludes(ports, Port, anyCounts));

    private static FirewallRule AppRule(bool allow, FirewallProfiles profiles, bool enabled = true, int protocol = 6,
        string? app = App, string ports = "*") =>
        new(app, Inbound: true, enabled, allow, profiles, protocol, ports, Service: null);

    private static FirewallVerdict Evaluate(FirewallProfiles current, params FirewallRule[] rules) =>
        FirewallCheck.Evaluate(current, FirewallProfiles.All, FirewallProfiles.None, rules, App, Port);

    [Fact]
    public void AllowRuleOnEveryCurrentNetworkAllows()
    {
        var verdict = Evaluate(PrivatePublic, AppRule(allow: true, FirewallProfiles.All, protocol: 256));
        Assert.Equal(new FirewallVerdict(FirewallVerdictKind.AllowsApp, PrivatePublic), verdict);
    }

    [Fact]
    public void AllowedOnPrivateOnlyIsMissingPublic()
    {
        // The usual result of answering Windows' prompt with Private only,
        // while Tailscale's adapter is a Public network.
        var verdict = Evaluate(PrivatePublic, AppRule(allow: true, FirewallProfiles.Private));
        Assert.Equal(new FirewallVerdict(FirewallVerdictKind.NoRule, FirewallProfiles.Public), verdict);
    }

    [Fact]
    public void BlockBeatsAllow()
    {
        var verdict = Evaluate(FirewallProfiles.Public,
            AppRule(allow: true, FirewallProfiles.All),
            AppRule(allow: false, FirewallProfiles.Public));
        Assert.Equal(new FirewallVerdict(FirewallVerdictKind.BlocksApp, FirewallProfiles.Public), verdict);
    }

    [Fact]
    public void IgnoresDisabledUdpOtherAppAndServiceRules()
    {
        var verdict = Evaluate(FirewallProfiles.Private,
            AppRule(allow: false, FirewallProfiles.All, enabled: false),
            AppRule(allow: false, FirewallProfiles.All, protocol: 17),
            AppRule(allow: false, FirewallProfiles.All, app: @"C:\Other\Other.exe"),
            new FirewallRule(App, Inbound: true, Enabled: true, Allow: false, FirewallProfiles.All, 6, "*", Service: "SomeSvc"),
            AppRule(allow: true, FirewallProfiles.Private));
        Assert.Equal(FirewallVerdictKind.AllowsApp, verdict.Kind);
    }

    [Fact]
    public void PortRuleWithoutAProgramCounts()
    {
        // README's New-NetFirewallRule with -LocalPort 8765, minus -Program.
        var verdict = Evaluate(FirewallProfiles.Public, AppRule(allow: true, FirewallProfiles.All, app: null, ports: "8765"));
        Assert.Equal(FirewallVerdictKind.AllowsApp, verdict.Kind);
        var anyPort = Evaluate(FirewallProfiles.Public, AppRule(allow: true, FirewallProfiles.All, app: null, ports: "*"));
        Assert.Equal(FirewallVerdictKind.NoRule, anyPort.Kind);
    }

    [Fact]
    public void AppPathMatchIgnoresCase()
    {
        var verdict = Evaluate(FirewallProfiles.Private, AppRule(allow: true, FirewallProfiles.All, app: App.ToUpperInvariant()));
        Assert.Equal(FirewallVerdictKind.AllowsApp, verdict.Kind);
    }

    [Fact]
    public void OffAndBlockAll()
    {
        var off = FirewallCheck.Evaluate(PrivatePublic, FirewallProfiles.Domain, FirewallProfiles.None, [], App, Port);
        Assert.Equal(FirewallVerdictKind.Off, off.Kind);
        var blockAll = FirewallCheck.Evaluate(PrivatePublic, FirewallProfiles.All, FirewallProfiles.Public,
            [AppRule(allow: true, FirewallProfiles.All)], App, Port);
        Assert.Equal(new FirewallVerdict(FirewallVerdictKind.BlocksAll, FirewallProfiles.Public), blockAll);
        // Off on the public network: only the private one is judged.
        var halfOff = FirewallCheck.Evaluate(PrivatePublic, FirewallProfiles.Private, FirewallProfiles.Public,
            [AppRule(allow: true, FirewallProfiles.Private)], App, Port);
        Assert.Equal(new FirewallVerdict(FirewallVerdictKind.AllowsApp, FirewallProfiles.Private), halfOff);
    }

    [Fact]
    public void NoCurrentNetworkJudgesPrivateAndPublic()
    {
        var verdict = Evaluate(FirewallProfiles.None);
        Assert.Equal(new FirewallVerdict(FirewallVerdictKind.NoRule, PrivatePublic), verdict);
    }
}
