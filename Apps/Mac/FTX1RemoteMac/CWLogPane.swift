import FTX1CW
import FTX1Core
import SwiftUI

/// The CW window's Log QSO pane, under the send pane: logs the contact to
/// the logbook chosen in Settings → Logbook through `QSOLogger`. The call
/// is `CWSender.theirCall` — the same field `{CALL}` macros read and a
/// click on a decoded callsign fills. Frequency, mode and power come from
/// the rig's transmitting side when Log QSO is clicked.
///
/// Time on is set when the call goes from empty to filled (or by the reset
/// button); time off is the moment Log QSO is clicked. After every logbook
/// it went to confirms the QSO (MacLoggerDX and/or Wavelog) the fields
/// clear for the next one (user decision); anything short of that keeps
/// them so it can be checked and retried. If MacLoggerDX took it but
/// Wavelog didn't, "Retry Wavelog" resends that same QSO to Wavelog alone
/// (user decision), so MacLoggerDX never gets a second copy; it stays
/// offered until it works or is dismissed, even once a new call is typed.
struct CWLogPane: View {
    @EnvironmentObject private var hub: HubService
    @EnvironmentObject private var sender: CWSender
    @EnvironmentObject private var workedStations: WorkedStationsStore

    @AppStorage(LogbookSettings.loggerKey) private var loggerRawValue = LogbookSettings.Logger.none.rawValue
    @AppStorage(LogbookSettings.wavelogEnabledKey) private var wavelogEnabled = false
    @State private var rstSent = Self.defaultRST
    @State private var rstReceived = Self.defaultRST
    @State private var name = ""
    @State private var comment = ""
    @State private var timeOn: Date?
    @State private var isLogging = false
    @State private var result: Result?
    /// A QSO the primary logbook took and Wavelog didn't.
    @State private var wavelogRetry: LoggedQSO?
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
                if let wavelogRetry {
                    retryWavelogButtons(wavelogRetry)
                }
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
        let targets = (logger == .none ? [] : [logger.displayName]) + (wavelogEnabled ? ["Wavelog"] : [])
        return HStack {
            Text("Log QSO").font(.headline)
            Spacer()
            Text(targets.isEmpty ? "No logbook — choose one in Settings → Logbook" : "To \(targets.joined(separator: " + "))")
                .font(.caption)
                .foregroundStyle(targets.isEmpty ? .orange : .secondary)
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

    private func retryWavelogButtons(_ qso: LoggedQSO) -> some View {
        HStack(spacing: 4) {
            Button {
                retryWavelog(qso)
            } label: {
                Label("Retry Wavelog (\(qso.call))", systemImage: "arrow.clockwise")
            }
            .help("Send \(qso.call) to Wavelog again, as it was logged — not to \(LogbookSettings.logger.displayName)")
            .disabled(isLogging)
            Button {
                wavelogRetry = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Don't send \(qso.call) to Wavelog")
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
        guard QSOLogger.hasLogbook else {
            result = .failure("No logbook is selected in Settings → Logbook")
            return
        }
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
            let outcomes = await QSOLogger.log(qso)
            isLogging = false
            show(outcomes, for: qso)
        }
    }

    /// One line for both logbooks: the primary's outcome first, then
    /// Wavelog's when it went wrong (or was a duplicate).
    private func show(_ outcomes: QSOLogger.Outcomes, for qso: LoggedQSO) {
        let call = qso.call
        let primaryName = LogbookSettings.logger.displayName
        var wavelogNote: String?
        var wavelogOK = true
        switch outcomes.wavelog {
        case nil, .logged:
            break
        case .alreadyLogged:
            wavelogNote = "already in Wavelog"
        case .sentUnconfirmed(let reason), .failed(let reason):
            wavelogNote = "Wavelog: \(reason)"
            wavelogOK = false
        }
        func withWavelog(_ text: String) -> String {
            wavelogNote.map { "\(text) · \($0)" } ?? text
        }

        switch outcomes.primary {
        case nil:
            // Wavelog alone: Log QSO again is the retry.
            if wavelogOK {
                result = .success(withWavelog("\(call) logged to Wavelog"))
                if normalizedCall == call { clear() }
            } else {
                result = .failure(withWavelog("\(call) not logged"))
            }
        case .logged, .alreadyLogged:
            workedStations.reload()
            if wavelogOK {
                let to = outcomes.wavelog == nil ? primaryName : "\(primaryName) and Wavelog"
                result = .success(withWavelog("\(call) logged to \(to)"))
                // Only clear if nothing was typed for a new QSO meanwhile.
                if normalizedCall == call { clear() }
            } else {
                wavelogRetry = qso
                result = .warning(withWavelog("\(call) logged to \(primaryName)"))
            }
        case .sentUnconfirmed(let reason):
            if !wavelogOK { wavelogRetry = qso }
            result = .warning(withWavelog("\(reason) — check \(primaryName) before logging \(call) again"))
        case .failed(let reason):
            // Nothing reached the primary: Log QSO again resends both, and
            // Wavelog's duplicate check absorbs a second copy there.
            result = .failure(withWavelog(reason))
        }
    }

    private func retryWavelog(_ qso: LoggedQSO) {
        guard !isLogging else { return }
        isLogging = true
        result = nil
        Task {
            let outcome = await QSOLogger.logToWavelog(qso)
            isLogging = false
            switch outcome {
            case .logged, .alreadyLogged:
                wavelogRetry = nil
                result = .success(outcome == .logged ? "\(qso.call) logged to Wavelog" : "\(qso.call) was already in Wavelog")
                if normalizedCall == qso.call { clear() }
            case .sentUnconfirmed(let reason), .failed(let reason):
                result = .failure("Wavelog: \(reason)")
            }
        }
    }

    /// Replaces the call with its uppercase form, cursor kept in place —
    /// see `UppercaseEdit`.
    private func uppercaseCall(from old: String, typed: String, to uppercased: String) {
        let caret = UppercaseEdit.caretOffset(old: old, typed: typed)
        sender.theirCall = uppercased
        // After the field has taken the new text, or it moves the cursor
        // to the end again.
        DispatchQueue.main.async {
            callSelection = UppercaseEdit.selection(in: sender.theirCall, at: caret)
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
            Text(tx.frequencyHz.flatMap { $0 > 0 ? "\(FrequencyFormat.mhz($0, fractionDigits: 4)) MHz" : nil } ?? "— MHz")
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

/// Typing in capitals for the CW window's text fields (Their call, the
/// send line): the field's text is replaced with its uppercase form, which
/// moves the cursor to the end, so the views put it back. The cursor's
/// position is worked out from the edit — everything after it is the text
/// the old and new values share at the end — rather than read from the
/// field's `TextSelection`, whose index can belong to a different copy of
/// the string and trapped (`String.distance`) when measured against this
/// one (2026-10-07).
enum UppercaseEdit {
    /// The cursor's character offset right after the edit that turned
    /// `old` into `typed`.
    static func caretOffset(old: String, typed: String) -> Int {
        let unchangedTail = zip(old.reversed(), typed.reversed()).prefix { $0 == $1 }.count
        return typed.count - unchangedTail
    }

    /// An insertion point at `offset` characters into `text`, clamped.
    static func selection(in text: String, at offset: Int) -> TextSelection {
        let clamped = min(max(offset, 0), text.count)
        return TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: clamped))
    }
}
