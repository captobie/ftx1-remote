import FT8Kit
import FTX1Core
import Foundation

/// One decoded FT8 message, mapped from `FT8Kit.RawMessage` into the shape
/// this app displays and — eventually — would report to PSK Reporter (not
/// built yet; `reporterCallsign`/`reporterGrid` exist so that later addition
/// doesn't need to touch this model again). Mac-only, same reasoning as
/// `AudioCaptureEngine`/`APRSStation`: audio-derived, not shared with
/// mobile targets.
struct FT8Spot: Identifiable, Equatable {
    let id = UUID()
    let utcTimestamp: Date
    /// String, not an enum, so a future FT4 addition (see `FT8Kit.Mode`)
    /// doesn't need a model migration — just a different value here.
    let mode: String
    let messageText: String
    let audioFrequencyOffsetHz: Double
    /// `RigState.frequencyHz` captured at slot start, not decode-completion
    /// — see `FT8DecodeCoordinator.beginSlot`.
    let dialFrequencyHz: Int
    /// Sync-candidate score converted the same way ft8_lib's own demo does
    /// (`score * 0.5`) — an approximation of signal quality, not a
    /// calibrated noise-floor SNR. ft8_lib's own source marks this exact
    /// computation with `// TODO: compute better approximation of SNR`.
    let snrDb: Int
    let dtSeconds: Double
    let ldpcErrors: Int
    /// The callsign this message is addressed to, when the message's first
    /// field is itself a callsign rather than a token like CQ/DE/QRZ (which
    /// aren't addressed to anyone in particular).
    let toCallsign: String?
    /// The transmitting/spotted station — the last classified callsign
    /// field in the message. In both "CQ CALL GRID" and "TO_CALL DE_CALL
    /// REPORT" message shapes, that's the station that sent this
    /// transmission (the one worth reporting as heard).
    let spottedCallsign: String?
    let spottedGrid: String?
    let reportText: String?
    let reporterCallsign: String?
    let reporterGrid: String?

    var absoluteFrequencyHz: Double {
        Double(dialFrequencyHz) + audioFrequencyOffsetHz
    }

    init(coordinatorSpot: FT8DecodeCoordinator.Spot, mode: String = "FT8") {
        let message = coordinatorSpot.message
        let fields = message.fields

        utcTimestamp = coordinatorSpot.utcTimestamp
        self.mode = mode
        messageText = message.text
        audioFrequencyOffsetHz = message.frequencyOffsetHz
        dialFrequencyHz = coordinatorSpot.dialFrequencyHz
        snrDb = Int((Double(message.score) * 0.5).rounded())
        dtSeconds = message.dtSeconds
        ldpcErrors = message.ldpcErrors

        toCallsign = fields.first?.kind == .call ? fields.first?.text : nil
        spottedCallsign = fields.last(where: { $0.kind == .call })?.text
        spottedGrid = fields.first(where: { $0.kind == .grid })?.text
        reportText = fields.first(where: { $0.kind == .rst })?.text

        let callsign = StationSettings.callsign
        let gridSquare = StationSettings.gridSquare
        reporterCallsign = callsign.isEmpty ? nil : callsign
        reporterGrid = gridSquare.isEmpty ? nil : gridSquare
    }
}
