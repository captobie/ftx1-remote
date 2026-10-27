import AppKit
import FTX1Core
import SwiftUI
import UniformTypeIdentifiers

/// Settings → License: the license-class guardrail (`HubService.
/// privilegeChoice`/`customPrivileges`, see `TransmitGate`). Applies at
/// once like Enable Transmit, so Cancel never leaves it un-applied.
struct LicenseSettingsTab: View {
    @EnvironmentObject private var hub: HubService

    @State private var importError: String?

    var body: some View {
        ScrollView {
            Form {
                Picker("licenseSettingsTab.privileges", selection: $hub.privilegeChoice) {
                    Text("licenseSettingsTab.offAmateurBandsOnly").tag(PrivilegeChoice.off)
                    Divider()
                    ForEach(PrivilegePreset.allCases.filter(\.isUS), id: \.self) { preset in
                        Text(preset.displayName).tag(PrivilegeChoice.preset(preset))
                    }
                    Divider()
                    ForEach(PrivilegePreset.allCases.filter { !$0.isUS }, id: \.self) { preset in
                        Text(preset.displayName).tag(PrivilegeChoice.preset(preset))
                    }
                    Divider()
                    Text("licenseSettingsTab.custom").tag(PrivilegeChoice.custom)
                }
                Text("licenseSettingsTab.blocksPttMoxAntenna")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch hub.privilegeChoice {
                case .off:
                    EmptyView()
                case .preset(let preset):
                    presetSection(preset)
                case .custom:
                    customSection
                }
            }
            .padding(.top, 8)
            // Clear of the scroller, which otherwise covers the end of the
            // wrapped captions.
            .padding(.trailing, 20)
        }
        .alert("licenseSettingsTab.couldntImport", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: Presets

    @ViewBuilder
    private func presetSection(_ preset: PrivilegePreset) -> some View {
        Section {
            if preset.isUS {
                Text("licenseSettingsTab.47Cfr97301")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("licenseSettingsTab.theRegionsAmateurAllocations")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            segmentTable(preset.profile.segments)
            Button("licenseSettingsTab.copyToCustom") { copyToCustom(preset) }
        } header: {
            Text(preset.displayName)
        }
    }

    private func segmentTable(_ segments: [PrivilegeSegment]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
            GridRow {
                Text("licenseSettingsTab.fromMHz").bold()
                Text("licenseSettingsTab.toMHz").bold()
                Text("licenseSettingsTab.modes").bold()
            }
            .font(.caption)
            ForEach(segments) { segment in
                GridRow {
                    Text(Self.mhz(segment.lowerHz)).monospacedDigit()
                    Text(Self.mhz(segment.upperHz)).monospacedDigit()
                    Text(Self.modesLabel(segment))
                }
                .font(.caption)
            }
        }
    }

    private func copyToCustom(_ preset: PrivilegePreset) {
        if !hub.customPrivileges.segments.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "licenseSettingsTab.replaceYourCustomPrivileges")
            alert.informativeText = String(localized: "licenseSettingsTab.yourCustomTableSegments \(hub.customPrivileges.segments.count) \(preset.displayName)")
            alert.addButton(withTitle: String(localized: "licenseSettingsTab.replace"))
            alert.addButton(withTitle: String(localized: "common.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        hub.customPrivileges = PrivilegeProfile(name: String(localized: "licenseSettingsTab.customFrom \(preset.displayName)"),
                                                segments: preset.profile.segments)
        hub.privilegeChoice = .custom
    }

    // MARK: Custom

    private var customSection: some View {
        Section {
            TextField("common.name", text: $hub.customPrivileges.name, prompt: Text("licenseSettingsTab.eGUkFull"))
            if hub.customPrivileges.segments.isEmpty {
                Text("licenseSettingsTab.noSegmentsYetSo")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                if !hub.customPrivileges.segments.isEmpty {
                    GridRow {
                        Text("licenseSettingsTab.fromMHz").bold()
                        Text("licenseSettingsTab.toMHz").bold()
                        Text("CW").bold()
                        Text("licenseSettingsTab.phone").bold()
                        Text("licenseSettingsTab.data").bold()
                        Text("")
                    }
                    .font(.caption)
                }
                ForEach($hub.customPrivileges.segments) { $segment in
                    GridRow {
                        TextField("common.from", value: Self.mhzBinding($segment.lowerHz), format: Self.mhzFormat)
                            .labelsHidden()
                            .frame(width: 100)
                        TextField("common.to", value: Self.mhzBinding($segment.upperHz), format: Self.mhzFormat)
                            .labelsHidden()
                            .frame(width: 100)
                        ForEach(TransmitEmission.allCases, id: \.self) { emission in
                            Toggle(emission.displayName, isOn: Self.emissionBinding($segment.emissions, emission))
                                .labelsHidden()
                        }
                        HStack(spacing: 6) {
                            if let only = segment.onlyModes {
                                Text("licenseSettingsTab.only \(Self.modeList(only))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .help("licenseSettingsTab.fromThePresetThis")
                            }
                            if segment.lowerHz > segment.upperHz {
                                Text("licenseSettingsTab.fromIsAboveTo")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            Button {
                                hub.customPrivileges.segments.removeAll { $0.id == segment.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("licenseSettingsTab.removeThisSegment")
                        }
                    }
                }
            }
            HStack {
                Button("licenseSettingsTab.addSegment") { addSegment() }
                Menu("licenseSettingsTab.startFrom") {
                    ForEach(PrivilegePreset.allCases, id: \.self) { preset in
                        Button(preset.displayName) { copyToCustom(preset) }
                    }
                }
                .fixedSize()
                Spacer()
                Button("licenseSettingsTab.import") { importProfile() }
                Button("licenseSettingsTab.export") { exportProfile() }
                    .disabled(hub.customPrivileges.segments.isEmpty)
            }
            Text("licenseSettingsTab.frequenciesApplyWhenYou")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("licenseSettingsTab.customPrivileges")
        }
    }

    private func addSegment() {
        // Start where the rig is, if that's in an amateur band.
        let band = BandPlan.band(containing: TransmitGate.transmitFrequencyHz(of: hub.rigState))
        let range = band?.range ?? 14_000_000...14_350_000
        hub.customPrivileges.segments.append(
            PrivilegeSegment(lowerHz: range.lowerBound, upperHz: range.upperBound, emissions: [.cw]))
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let profile = try JSONDecoder().decode(PrivilegeProfile.self, from: Data(contentsOf: url))
            if !hub.customPrivileges.segments.isEmpty {
                let alert = NSAlert()
                alert.messageText = String(localized: "licenseSettingsTab.replaceYourCustomPrivileges")
                alert.informativeText = String(localized: "licenseSettingsTab.yourCustomTableIs \(profile.name) \(profile.segments.count) \(url.lastPathComponent)")
                alert.addButton(withTitle: String(localized: "licenseSettingsTab.replace"))
                alert.addButton(withTitle: String(localized: "common.cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            hub.customPrivileges = profile
        } catch {
            importError = String(localized: "licenseSettingsTab.isntAPrivilegesFile \(url.lastPathComponent)")
        }
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(hub.customPrivileges.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(hub.customPrivileges).write(to: url)
        } catch {
            importError = String(localized: "licenseSettingsTab.couldntWrite \(url.lastPathComponent) \(error.localizedDescription)")
        }
    }

    // MARK: Formatting

    private static let mhzFormat = FrequencyFormat.mhzField(fractionLength: 3...6)

    private static func mhz(_ hz: Int) -> String {
        (Double(hz) / 1_000_000).formatted(mhzFormat)
    }

    private static func mhzBinding(_ hz: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(hz.wrappedValue) / 1_000_000 },
                set: { hz.wrappedValue = Int(($0 * 1_000_000).rounded()) })
    }

    private static func emissionBinding(_ emissions: Binding<Set<TransmitEmission>>,
                                        _ emission: TransmitEmission) -> Binding<Bool> {
        Binding(get: { emissions.wrappedValue.contains(emission) },
                set: { on in
                    if on { emissions.wrappedValue.insert(emission) } else { emissions.wrappedValue.remove(emission) }
                })
    }

    private static func modesLabel(_ segment: PrivilegeSegment) -> String {
        if let only = segment.onlyModes { return modeList(only) }
        return TransmitEmission.allCases.filter(segment.emissions.contains).map(\.displayName).joined(separator: ", ")
    }

    private static func modeList(_ modes: Set<RigMode>) -> String {
        RigMode.allCases.filter(modes.contains).map(\.displayName).joined(separator: ", ")
    }
}
