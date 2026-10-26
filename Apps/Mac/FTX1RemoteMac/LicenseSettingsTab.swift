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
                Picker("Privileges", selection: $hub.privilegeChoice) {
                    Text("Off (amateur bands only)").tag(PrivilegeChoice.off)
                    Divider()
                    ForEach(PrivilegePreset.allCases.filter(\.isUS), id: \.self) { preset in
                        Text(preset.displayName).tag(PrivilegeChoice.preset(preset))
                    }
                    Divider()
                    ForEach(PrivilegePreset.allCases.filter { !$0.isUS }, id: \.self) { preset in
                        Text(preset.displayName).tag(PrivilegeChoice.preset(preset))
                    }
                    Divider()
                    Text("Custom").tag(PrivilegeChoice.custom)
                }
                Text("Blocks PTT, MOX, antenna tuning, CW sending and the CW key — from this Mac and from every connected client — unless the transmitting side's signal fits inside these privileges, in its mode. Tuning or changing mode out of them while transmitting unkeys the rig. A guardrail only: you remain responsible for operating within your license.")
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
        .alert("Couldn't import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
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
                Text("47 CFR §97.301/§97.305 as of October 2026, continental US. 60 m is the five channels; 70 cm is 420–450 MHz without the Line A exclusion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The region's amateur allocations as outer band edges, every mode allowed — not any country's rules. Copy it to Custom and edit it to your license.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            segmentTable(preset.profile.segments)
            Button("Copy to Custom…") { copyToCustom(preset) }
        } header: {
            Text(preset.displayName)
        }
    }

    private func segmentTable(_ segments: [PrivilegeSegment]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
            GridRow {
                Text("From (MHz)").bold()
                Text("To (MHz)").bold()
                Text("Modes").bold()
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
            alert.messageText = "Replace your custom privileges?"
            alert.informativeText = "Your custom table (\(hub.customPrivileges.segments.count) segments) is replaced by a copy of \(preset.displayName)."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        hub.customPrivileges = PrivilegeProfile(name: "Custom (from \(preset.displayName))",
                                                segments: preset.profile.segments)
        hub.privilegeChoice = .custom
    }

    // MARK: Custom

    private var customSection: some View {
        Section {
            TextField("Name", text: $hub.customPrivileges.name, prompt: Text("e.g. UK Full"))
            if hub.customPrivileges.segments.isEmpty {
                Text("No segments yet, so every transmission is blocked. Add segments, or copy a preset and edit it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                if !hub.customPrivileges.segments.isEmpty {
                    GridRow {
                        Text("From (MHz)").bold()
                        Text("To (MHz)").bold()
                        Text("CW").bold()
                        Text("Phone").bold()
                        Text("Data").bold()
                        Text("")
                    }
                    .font(.caption)
                }
                ForEach($hub.customPrivileges.segments) { $segment in
                    GridRow {
                        TextField("From", value: Self.mhzBinding($segment.lowerHz), format: Self.mhzFormat)
                            .labelsHidden()
                            .frame(width: 100)
                        TextField("To", value: Self.mhzBinding($segment.upperHz), format: Self.mhzFormat)
                            .labelsHidden()
                            .frame(width: 100)
                        ForEach(TransmitEmission.allCases, id: \.self) { emission in
                            Toggle(emission.displayName, isOn: Self.emissionBinding($segment.emissions, emission))
                                .labelsHidden()
                        }
                        HStack(spacing: 6) {
                            if let only = segment.onlyModes {
                                Text("only \(Self.modeList(only))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .help("From the preset this table was copied from; the other modes of the ticked kinds are refused here.")
                            }
                            if segment.lowerHz > segment.upperHz {
                                Text("From is above To")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            Button {
                                hub.customPrivileges.segments.removeAll { $0.id == segment.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this segment")
                        }
                    }
                }
            }
            HStack {
                Button("Add Segment") { addSegment() }
                Menu("Start From") {
                    ForEach(PrivilegePreset.allCases, id: \.self) { preset in
                        Button(preset.displayName) { copyToCustom(preset) }
                    }
                }
                .fixedSize()
                Spacer()
                Button("Import…") { importProfile() }
                Button("Export…") { exportProfile() }
                    .disabled(hub.customPrivileges.segments.isEmpty)
            }
            Text("Frequencies apply when you press Return or leave the field. A signal has to fit inside segments that allow its kind of emission — sidebands included (LSB reaches 2.9 kHz below the dial, FM ±8 kHz). The amateur bands stay the outer limit.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Custom privileges")
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
                alert.messageText = "Replace your custom privileges?"
                alert.informativeText = "Your custom table is replaced by “\(profile.name)” (\(profile.segments.count) segments) from \(url.lastPathComponent)."
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            hub.customPrivileges = profile
        } catch {
            importError = "\(url.lastPathComponent) isn't a privileges file exported from FTX1Remote."
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
            importError = "Couldn't write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Formatting

    private static let mhzFormat = FloatingPointFormatStyle<Double>.number
        .precision(.fractionLength(3...6))
        .grouping(.never)

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
