import SwiftUI

/// Which APRS list S.LIST/M.LIST opens.
public enum APRSListKind: Hashable, Sendable {
    case stations, messages
}

/// "Heard within" choices shared by the APRS station and message lists.
/// Measured from the moment the list is rendered — the lists re-render on
/// every new packet, so an entry can outlive its window by however long
/// the channel stays quiet.
public enum APRSHeardWindow: Hashable, CaseIterable {
    case any, lastHour, last24Hours, last7Days

    public var label: String {
        switch self {
        case .any: String(localized: "aprsListFilter.anyTime", bundle: .module)
        case .lastHour: String(localized: "aprsListFilter.lastHour", bundle: .module)
        case .last24Hours: String(localized: "aprsListFilter.last24Hours", bundle: .module)
        case .last7Days: String(localized: "aprsListFilter.last7Days", bundle: .module)
        }
    }

    private var seconds: TimeInterval? {
        switch self {
        case .any: nil
        case .lastHour: 3600
        case .last24Hours: 86_400
        case .last7Days: 604_800
        }
    }

    public func includes(_ date: Date, now: Date = Date()) -> Bool {
        guard let seconds else { return true }
        return now.timeIntervalSince(date) <= seconds
    }
}

public enum APRSListFilter {
    /// Case- and diacritic-insensitive match of `query` against any of
    /// `fields`; an empty (or all-whitespace) query matches everything.
    public static func matches(_ query: String, _ fields: String?...) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return fields.contains { $0?.localizedStandardContains(query) ?? false }
    }

    /// The callsign without its SSID, uppercased — "n0call-9" → "N0CALL".
    public static func baseCallsign(_ callsign: String) -> String {
        String(callsign.split(separator: "-", maxSplits: 1).first ?? "").uppercased()
    }

    /// APRS bulletins and announcements are addressed "BLN0"–"BLNZ" plus
    /// optional group name (APRS 1.0.1, ch. 14).
    public static func isBulletin(_ message: APRSMessage) -> Bool {
        message.to.uppercased().hasPrefix("BLN")
    }

    /// Telemetry metadata ("PARM.", "UNIT.", "EQNS.", "BITS.") that a
    /// station sends as a message, usually to itself, to label its
    /// telemetry channels (APRS 1.0.1, ch. 13) — not a message for a human.
    public static func isTelemetryDefinition(_ message: APRSMessage) -> Bool {
        ["PARM.", "UNIT.", "EQNS.", "BITS."].contains { message.text.hasPrefix($0) }
    }
}

/// The Source segmented picker both APRS lists put in their toolbar.
public struct APRSSourcePicker: View {
    @Binding var selection: APRSSource?

    public init(selection: Binding<APRSSource?>) {
        _selection = selection
    }

    public var body: some View {
        Picker(String(localized: "common.source", bundle: .module), selection: $selection) {
            Text("aprsListFilter.all", bundle: .module).tag(APRSSource?.none)
            Text("Main").tag(APRSSource?.some(.main))
            Text("Sub").tag(APRSSource?.some(.sub))
        }
        .pickerStyle(.segmented)
    }
}
