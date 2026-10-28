import AppKit
import Combine
import Darwin
import SwiftUI
import SystemConfiguration

/// The hub's WebSocket server as Settings → Mobile shows it: whether it's
/// listening and who's connected. Set by `HubService` (listening, from its
/// rebind loop) and `RigWebSocketServer` (clients).
final class HubServerStatus: ObservableObject {
    let port: UInt16
    @Published var isListening = false
    @Published var clients: [HubClientInfo] = []

    init(port: UInt16) {
        self.port = port
    }
}

/// This Mac's addresses an iPad can reach the hub at, read from the
/// interfaces (`getifaddrs`), plus the Tailscale and firewall checks.
nonisolated enum MacNetworkAddresses {
    struct Address: Hashable, Sendable {
        /// "Wi-Fi", "Ethernet", … (the BSD name if there's no display name).
        let interfaceName: String
        let ip: String
    }

    struct Snapshot: Sendable {
        /// Wi-Fi/Ethernet addresses (IPv4, not link-local).
        var lan: [Address] = []
        /// This Mac's tailnet IPv4 address (100.64.0.0/10), if Tailscale is up.
        var tailnetIP: String?
        /// Its MagicDNS name ("my-mac.tailnet-name.ts.net"), if it resolves.
        var tailnetName: String?
        /// "My-Mac.local".
        var localHostName: String?
        var firewall: Firewall = .unknown
    }

    enum Firewall: Sendable {
        case unknown, off, allowsApp, blocksApp, blocksAll
    }

    /// Reads everything; blocking (reverse DNS, `socketfilterfw`), so call
    /// it off the main actor.
    static func snapshot() -> Snapshot {
        var snapshot = Snapshot()
        let names = interfaceDisplayNames()
        for (interface, ip) in ipv4Addresses() {
            if isTailnet(ip) {
                if snapshot.tailnetIP == nil { snapshot.tailnetIP = ip }
            } else if interface.hasPrefix("en"), !ip.hasPrefix("169.254.") {
                snapshot.lan.append(Address(interfaceName: names[interface] ?? interface, ip: ip))
            }
        }
        snapshot.tailnetName = snapshot.tailnetIP.flatMap(reverseName)
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? {
            snapshot.localHostName = name + ".local"
        }
        snapshot.firewall = firewallState()
        return snapshot
    }

    /// Tailscale's address range, the shared-address space 100.64.0.0/10.
    static func isTailnet(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// The Tailscale app, if installed (standalone or App Store build).
    static var tailscaleAppURL: URL? {
        ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"].lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    /// MagicDNS answers reverse lookups for tailnet addresses; nil if it
    /// doesn't (MagicDNS off) or the name isn't a real one.
    static func reverseName(_ ip: String) -> String? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard result == 0 else { return nil }
        var name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty || name == ip ? nil : name
    }

    private static func ipv4Addresses() -> [(String, String)] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [(String, String)] = []
        var next = first
        while let entry = next {
            next = entry.pointee.ifa_next
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append((String(cString: entry.pointee.ifa_name), ip))
        }
        return result
    }

    private static func interfaceDisplayNames() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names: [String: String] = [:]
        for interface in interfaces {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
               let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[bsd] = display
            }
        }
        return names
    }

    /// The macOS application firewall, from `socketfilterfw` (works
    /// without admin rights). Its output is English whatever the language.
    private static func firewallState() -> Firewall {
        let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        guard let global = run(tool, ["--getglobalstate"]) else { return .unknown }
        if global.contains("State = 0") { return .off }
        if global.contains("State = 2") { return .blocksAll }
        guard let app = run(tool, ["--getappblocked", Bundle.main.bundlePath]) else { return .unknown }
        return app.contains("is blocked") ? .blocksApp : .allowsApp
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Settings → Mobile: what to type into the iPad's Desktop hub host
/// field, whether the hub is reachable, and who's connected. Re-reads the
/// addresses every few seconds while shown, so joining a network or
/// starting Tailscale shows up without reopening Settings.
struct MobileSettingsTab: View {
    @EnvironmentObject private var hub: HubService

    var body: some View {
        MobileSettingsContent(status: hub.hubServerStatus)
    }
}

private struct MobileSettingsContent: View {
    @ObservedObject var status: HubServerStatus

    @State private var snapshot: MacNetworkAddresses.Snapshot?
    @State private var tailscaleAppURL: URL?
    /// MagicDNS names of connected clients, by IP.
    @State private var clientNames: [String: String] = [:]

    private static let tailscaleDownload = URL(string: "https://tailscale.com/download")!

    var body: some View {
        ScrollView {
            // Outside the Form: in its trailing column a long line ran off
            // the window's right edge.
            Text("settings.mobile.intro")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 8)
            Form {
                hubSection
                lanSection
                tailscaleSection
            }
            .padding(.top, 8)
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: status.clients.map(\.address)) { await resolveClientNames() }
    }

    // MARK: Hub

    @ViewBuilder private var hubSection: some View {
        Section {
            LabeledContent("settings.mobile.hubServer") {
                if status.isListening {
                    StatusLine(color: .green, text: String(localized: "settings.mobile.listeningOnPort \(String(status.port))"))
                } else {
                    StatusLine(color: .orange, text: String(localized: "settings.mobile.notListening \(String(status.port))"))
                }
            }
            LabeledContent("settings.mobile.firewall") { firewallText }
            LabeledContent("settings.mobile.connectedDevices") {
                if status.clients.isEmpty {
                    StatusLine(color: .secondary, text: String(localized: "settings.mobile.noDevicesConnected"))
                } else {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(status.clients) { client in
                            StatusLine(color: .green, text: describe(client))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        } header: {
            sectionHeader(String(localized: "settings.mobile.status"))
        }
    }

    @ViewBuilder private var firewallText: some View {
        switch snapshot?.firewall {
        case nil:
            Text("common.checking").foregroundStyle(.secondary)
        case .unknown:
            Text("—").foregroundStyle(.secondary)
        case .off:
            StatusLine(color: .green, text: String(localized: "settings.mobile.firewallOff"))
        case .allowsApp:
            StatusLine(color: .green, text: String(localized: "settings.mobile.firewallAllows"))
        case .blocksApp:
            StatusLine(color: .red, text: String(localized: "settings.mobile.firewallBlocksApp"))
        case .blocksAll:
            StatusLine(color: .red, text: String(localized: "settings.mobile.firewallBlocksAll"))
        }
    }

    private func describe(_ client: HubClientInfo) -> String {
        let since = client.connectedAt.formatted(date: .omitted, time: .shortened)
        if let name = clientNames[client.address] {
            return String(localized: "settings.mobile.clientNamed \(name) \(client.address) \(since)")
        }
        return String(localized: "settings.mobile.client \(client.address) \(since)")
    }

    // MARK: Tailscale

    @ViewBuilder private var tailscaleSection: some View {
        Section {
            if let snapshot, let ip = snapshot.tailnetIP {
                LabeledContent("settings.mobile.tailscale") {
                    StatusLine(color: .green, text: String(localized: "settings.mobile.tailscaleConnected"))
                }
                if let name = snapshot.tailnetName {
                    AddressRow(label: String(localized: "settings.mobile.magicDNSName"), value: name)
                    // The short name works on the iPad too while MagicDNS is
                    // on, and is what the host field's placeholder suggests.
                    if let short = name.split(separator: ".").first, String(short) != name {
                        AddressRow(label: String(localized: "settings.mobile.shortName"), value: String(short))
                    }
                }
                AddressRow(label: String(localized: "settings.mobile.tailscaleIP"), value: ip)
                Link(String(localized: "settings.mobile.getTailscaleForIPad"), destination: Self.tailscaleDownload)
            } else if snapshot != nil {
                LabeledContent("settings.mobile.tailscale") {
                    if tailscaleAppURL != nil {
                        StatusLine(color: .orange, text: String(localized: "settings.mobile.tailscaleNotConnected"))
                    } else {
                        StatusLine(color: .secondary, text: String(localized: "settings.mobile.tailscaleNotInstalled"))
                    }
                }
                Text("settings.mobile.tailscaleExplanation")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // The Form offers its full width to this column, past the
                    // window's edge; cap it so the text wraps.
                    .frame(maxWidth: 520, alignment: .leading)
                if let tailscaleAppURL {
                    Button("settings.mobile.openTailscale") {
                        NSWorkspace.shared.openApplication(at: tailscaleAppURL, configuration: .init())
                    }
                } else {
                    Link(destination: Self.tailscaleDownload) {
                        Label("settings.mobile.getTailscale", systemImage: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("common.checking").foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader(String(localized: "settings.mobile.fromAnywhere"))
        }
    }

    // MARK: Same network

    @ViewBuilder private var lanSection: some View {
        Section {
            if let snapshot {
                if snapshot.lan.isEmpty {
                    StatusLine(color: .orange, text: String(localized: "settings.mobile.noLocalNetwork"))
                } else {
                    ForEach(snapshot.lan, id: \.self) { address in
                        AddressRow(label: address.interfaceName, value: address.ip)
                    }
                    if let host = snapshot.localHostName {
                        AddressRow(label: String(localized: "settings.mobile.localHostName"), value: host)
                    }
                }
                Text("settings.mobile.sameNetworkNote")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // The Form offers its full width to this column, past the
                    // window's edge; cap it so the text wraps.
                    .frame(maxWidth: 520, alignment: .leading)
            } else {
                Text("common.checking").foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader(String(localized: "settings.mobile.onTheSameNetwork"))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 12)
    }

    private func refresh() async {
        snapshot = await Task.detached { MacNetworkAddresses.snapshot() }.value
        tailscaleAppURL = MacNetworkAddresses.tailscaleAppURL
    }

    /// Tailnet clients only: a LAN address rarely has a reverse name, and
    /// looking one up can stall for seconds.
    private func resolveClientNames() async {
        let addresses = Set(status.clients.map(\.address)).filter(MacNetworkAddresses.isTailnet)
        let missing = addresses.subtracting(clientNames.keys)
        guard !missing.isEmpty else { return }
        let resolved = await Task.detached {
            missing.reduce(into: [String: String]()) { names, ip in
                if let name = MacNetworkAddresses.reverseName(ip) {
                    names[ip] = name.split(separator: ".").first.map(String.init) ?? name
                }
            }
        }.value
        clientNames.merge(resolved) { _, new in new }
    }
}

/// A coloured dot and a line of text.
private struct StatusLine: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
        }
    }
}

/// An address to type into the iPad, selectable, with a copy button.
private struct AddressRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "common.copy"))
            }
        }
    }
}
