import FTX1Core
import SwiftUI

/// The CW window's Log QSO pane, under the send pane: logs the contact to
/// the logbook chosen in Settings → Logbook through `QSOLogger`. The call
/// is `CWSender.theirCall` — the same field `{CALL}` macros read and a
/// click on a decoded callsign fills. Frequency, mode and power come from
/// the rig's transmitting side when Log QSO is clicked.
///
/// Time on is set when the call goes from empty to filled (or by the reset
/// button); time off is the moment Log QSO is clicked. After MacLoggerDX
/// confirms the QSO the fields clear for the next one (user decision);
/// anything short of that keeps them so it can be checked and retried.
struct CWLogPane: View {
    @EnvironmentObject private var hub: HubService
    @EnvironmentObject private var sender: CWSender
    @EnvironmentObject private var workedStations: WorkedStationsStore

    @AppStorage(LogbookSettings.loggerKey) private var loggerRawValue = LogbookSettings.Logger.none.rawValue
    @State private var rstSent = Self.defaultRST
    @State private var rstReceived = Self.defaultRST
    @State private var name = ""
    @State private var comment = ""
    @State private var timeOn: Date?
    @State private var isLogging = false
    @State private var result: Result?
    /// Set (never read) so uppercasing a typed letter can put the cursor
    /// back where it was — see `uppercaseCall`.
    @State private var callSelection: TextSelection?

    private static let defaultRST = "599"

    private enum Result {
        case success(String)
        case warning(String)
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(spacing: 8) {
                Button {
                    lookUp()
                } label: {
                    Label("Lookup", systemImage: "magnifyingglass")
                }
                .help("Look this call up in MacLoggerDX (its call field, QRZ data and worked-before line)")
                .disabled(normalizedCall.isEmpty)
                TextField("Their call", text: $sender.theirCall, selection: $callSelection)
                    .frame(width: 120)
                    .help("The station you're working — also {CALL} in macros. Click a callsign in the decoded text to fill it in.")
                timeOnView
                CWWorkedSummary(call: normalizedCall)
            }
            HStack(spacing: 8) {
                labeled("RST sent") { TextField("", text: $rstSent).frame(width: 50) }
                labeled("rcvd") { TextField("", text: $rstReceived).frame(width: 50) }
                TextField("Name", text: $name).frame(width: 120)
                TextField("Comment", text: $comment)
            }
            HStack(spacing: 10) {
                CWLogRigReadout()
                resultView
                Spacer()
                Button {
                    log()
                } label: {
                    Label("Log QSO", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("l", modifiers: .command)
                .help("Log this QSO (⌘L)")
                .disabled(isLogging || normalizedCall.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onChange(of: sender.theirCall) { old, new in
            let wasEmpty = old.trimmingCharacters(in: .whitespaces).isEmpty
            let isEmpty = new.trimmingCharacters(in: .whitespaces).isEmpty
            if isEmpty {
                timeOn = nil
            } else if wasEmpty {
                timeOn = .now
                result = nil
            }
            // Callsigns are all caps; this runs again for the uppercased
            // value, which the checks above leave alone.
            let uppercased = new.uppercased()
            if uppercased != new { uppercaseCall(from: old, typed: new, to: uppercased) }
        }
    }

    private var header: some View {
        let logger = LogbookSettings.Logger(rawValue: loggerRawValue) ?? .none
        return HStack {
            Text("Log QSO").font(.headline)
            Spacer()
            Text(logger == .none ? "No logbook — choose one in Settings → Logbook" : "To \(logger.displayName)")
                .font(.caption)
                .foregroundStyle(logger == .none ? .orange : .secondary)
        }
    }

    private var timeOnView: some View {
        HStack(spacing: 4) {
            Text("On").foregroundStyle(.secondary)
            Text(timeOn.map(Self.utcTime) ?? "—")
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 90, alignment: .leading)
            Button {
                timeOn = .now
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Set the time on to now")
        }
    }

    @ViewBuilder
    private var resultView: some View {
        if isLogging {
            ProgressView().controlSize(.small)
            Text("Logging…").foregroundStyle(.secondary)
        } else if let result {
            switch result {
            case .success(let text):
                Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .warning(let text):
                Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .failure(let text):
                Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }

    private func labeled(_ title: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            field()
        }
    }

    private var normalizedCall: String {
        sender.theirCall.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// Sends the call to the logbook for its own lookup, with the
    /// transmitting side's frequency and mode. Needs the rig: MacLoggerDX
    /// ignores a Status with a 0 Hz dial frequency (tested 2026-10-07), and
    /// a made-up one would land in its entry panel.
    private func lookUp() {
        let call = normalizedCall
        guard !call.isEmpty else { return }
        let tx = hub.rigState.transmitter
        guard hub.connectionState == .connected, let frequencyHz = tx.frequencyHz, frequencyHz > 0 else {
            result = .failure("Connect to the rig first — MacLoggerDX ignores a lookup without a frequency")
            return
        }
        let mode = tx.mode.flatMap(ADIFMode.init)?.mode ?? tx.mode?.displayName ?? ""
        Task {
            if let problem = await QSOLogger.lookUp(call: call, dialFrequencyHz: frequencyHz, mode: mode) {
                result = .failure(problem)
            } else {
                result = .success("Looking up \(call) in \(LogbookSettings.logger.displayName)")
            }
        }
    }

    private func log() {
        let call = normalizedCall
        guard !call.isEmpty, !isLogging else { return }
        let rig = hub.rigState
        guard hub.connectionState == .connected else {
            result = .failure("Not connected to the rig — frequency and mode unknown")
            return
        }
        let tx = rig.transmitter
        guard let frequencyHz = tx.frequencyHz, frequencyHz > 0 else {
            result = .failure("The transmitting side's frequency isn't known yet")
            return
        }
        guard let mode = tx.mode.flatMap(ADIFMode.init) else {
            result = .failure("Can't log in \(tx.mode?.displayName ?? "an unknown mode")")
            return
        }
        let end = Date.now
        let qso = LoggedQSO(
            call: call,
            start: timeOn ?? end,
            end: end,
            frequencyHz: frequencyHz,
            mode: mode.mode,
            submode: mode.submode,
            rstSent: rstSent.trimmingCharacters(in: .whitespaces),
            rstReceived: rstReceived.trimmingCharacters(in: .whitespaces),
            txPower: rig.powerLevel.map { String(Int(($0 * 100).rounded())) } ?? "",
            comments: comment.trimmingCharacters(in: .whitespaces),
            name: name.trimmingCharacters(in: .whitespaces),
            myCall: StationSettings.callsign,
            myGrid: StationSettings.gridSquare
        )
        isLogging = true
        result = nil
        Task {
            let outcome = await QSOLogger.log(qso)
            isLogging = false
            switch outcome {
            case .logged:
                result = .success("\(call) logged")
                workedStations.reload()
                // Only clear if nothing was typed for a new QSO meanwhile.
                if normalizedCall == call { clear() }
            case .sentUnconfirmed(let reason):
                result = .warning("\(reason) — check MacLoggerDX before logging \(call) again")
            case .failed(let reason):
                result = .failure(reason)
            }
        }
    }

    /// Replaces the call with its uppercase form and puts the cursor back
    /// after what was just typed — replacing the field's text otherwise
    /// moves it to the end. The cursor position is worked out from the
    /// edit (everything after it is the text old and new share at the end)
    /// rather than read from `callSelection`, whose index can belong to a
    /// different copy of the string and trap when measured against this one.
    private func uppercaseCall(from old: String, typed: String, to uppercased: String) {
        let unchangedTail = zip(old.reversed(), typed.reversed()).prefix { $0 == $1 }.count
        let caret = typed.count - unchangedTail
        sender.theirCall = uppercased
        // After the field has taken the new text, or it moves the cursor
        // to the end again.
        DispatchQueue.main.async {
            let text = sender.theirCall
            let offset = min(max(caret, 0), text.count)
            callSelection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: offset))
        }
    }

    private func clear() {
        sender.theirCall = ""
        rstSent = Self.defaultRST
        rstReceived = Self.defaultRST
        name = ""
        comment = ""
        timeOn = nil
    }

    private static func utcTime(_ date: Date) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) UTC",
            timeZone: .gmt,
            calendar: Calendar(identifier: .gregorian)
        ))
    }
}

/// Worked-before for the call being entered: how often, the last QSO, and
/// whether the band the rig transmits on is new for this station.
private struct CWWorkedSummary: View {
    @EnvironmentObject private var workedStations: WorkedStationsStore
    let call: String

    var body: some View {
        Group {
            if call.isEmpty {
                EmptyView()
            } else if let problem = workedStations.problem {
                Text("Worked before: \(problem)").foregroundStyle(.secondary)
            } else if let summary = workedStations.worked.summary(of: call) {
                summaryText(summary)
            } else {
                // Link blue, the decoded text's color for a call never worked.
                Label("New station", systemImage: "sparkles").foregroundStyle(Color(nsColor: .linkColor))
            }
        }
        .font(.callout)
        .lineLimit(1)
    }

    private func summaryText(_ summary: WorkedStations.Summary) -> some View {
        let last = summary.last
        let date = last.date.formatted(.iso8601.year().month().day())
        var text = "Worked \(summary.count)× · last \(date) \(last.band.lowercased()) \(last.mode)"
        let newBand = workedStations.band.map { !summary.bands.contains($0.lowercased()) } ?? false
        if newBand, let band = workedStations.band {
            text += " · new on \(band)"
        }
        return Text(text)
            .foregroundStyle(newBand ? Color.orange : Color.green)
            .help(summary.bands.sorted().joined(separator: ", "))
    }
}

/// What will be logged from the rig: the transmitting side's frequency,
/// mode and RF power setting. Its own struct so the rig's polling only
/// re-renders this line, not the text fields.
private struct CWLogRigReadout: View {
    @EnvironmentObject private var hub: HubService

    var body: some View {
        let rig = hub.rigState
        let tx = rig.transmitter
        HStack(spacing: 8) {
            Text(tx.frequencyHz.flatMap { $0 > 0 ? String(format: "%.4f MHz", Double($0) / 1_000_000) : nil } ?? "— MHz")
            Text(tx.mode?.displayName ?? "—")
            Text(rig.powerLevel.map { "\(Int(($0 * 100).rounded())) W" } ?? "— W")
        }
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(hub.connectionState == .connected ? .primary : .tertiary)
        .help("Logged from the transmitting side: frequency, mode and RF power setting")
    }
}

extension RigState {
    /// MAIN or SUB, whichever transmits — the same rule as the VFO boxes'
    /// TXRX caption (`mainTxRxLabel`); `secondaryFrequencyHz`/
    /// `secondaryMode` are SUB's. What a QSO is logged with, and the band
    /// worked-before compares against.
    var transmitter: (frequencyHz: Int?, mode: RigMode?) {
        if splitEnabled == true || txSide == .sub {
            return (secondaryFrequencyHz, secondaryMode)
        }
        return (frequencyHz, mode)
    }
}
