import FTX1Core
import SwiftUI

/// "Heard within" choices shared by the APRS station and message lists.
/// Measured from the moment the list is rendered — the lists re-render on
/// every new packet, so an entry can outlive its window by however long
/// the channel stays quiet.
enum APRSHeardWindow: Hashable, CaseIterable {
    case any, lastHour, last24Hours, last7Days

    var label: String {
        switch self {
        case .any: "Any Time"
        case .lastHour: "Last Hour"
        case .last24Hours: "Last 24 Hours"
        case .last7Days: "Last 7 Days"
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

    func includes(_ date: Date, now: Date = Date()) -> Bool {
        guard let seconds else { return true }
        return now.timeIntervalSince(date) <= seconds
    }
}

enum APRSListFilter {
    /// Case- and diacritic-insensitive match of `query` against any of
    /// `fields`; an empty (or all-whitespace) query matches everything.
    static func matches(_ query: String, _ fields: String?...) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return fields.contains { $0?.localizedStandardContains(query) ?? false }
    }

    /// The callsign without its SSID, uppercased — "n0call-9" → "N0CALL".
    static func baseCallsign(_ callsign: String) -> String {
        String(callsign.split(separator: "-", maxSplits: 1).first ?? "").uppercased()
    }
}

/// The Source segmented picker both APRS lists put in their toolbar.
struct APRSSourcePicker: View {
    @Binding var selection: APRSSource?

    var body: some View {
        Picker("Source", selection: $selection) {
            Text("All").tag(APRSSource?.none)
            Text("Main").tag(APRSSource?.some(.main))
            Text("Sub").tag(APRSSource?.some(.sub))
        }
        .pickerStyle(.segmented)
    }
}
