import Foundation

/// Which reading the analog meter's lower scale shows — the app-side
/// counterpart of the rig's touch-the-meter METER screen (operation manual
/// p.20). Purely a local display choice, per device (`UserDefaults`-backed
/// via `@AppStorage(MeterSettings.key)`): it never touches the rig's own MS
/// (METER SW) setting, so changing it here doesn't change what the radio's
/// display shows. The upper S scale is fixed, same as on the rig.
///
/// The rig's selector also offers TEMP (final amplifier temperature); it's
/// omitted here because CAT's RM (READ METER) has no temperature source
/// (its P1 covers S main/sub, COMP, ALC, PO, SWR, IDD, VDD only).
public enum MeterSelection: String, CaseIterable, Sendable {
    case po, comp, alc, vdd, id, swr

    /// The rig's button label.
    public var title: String {
        switch self {
        case .po: "PO"
        case .comp: "COMP"
        case .alc: "ALC"
        case .vdd: "VDD"
        case .id: "ID"
        case .swr: "SWR"
        }
    }

    /// One-line description, shown in the picker like the manual's callouts.
    public var detail: String {
        switch self {
        case .po: "RF power output"
        case .comp: "Speech processor compression"
        case .alc: "Relative ALC voltage"
        case .vdd: "Final amplifier drain voltage"
        case .id: "Final amplifier drain current"
        case .swr: "Standing wave ratio"
        }
    }

    /// Unit label drawn at the scale's right end, if any.
    public var unit: String? { self == .po ? "W" : nil }

    /// Labeled tick positions along the sweep (0.0 hard left ... 1.0 hard
    /// right). PO and SWR mirror the rig's printed scales; the raw-valued
    /// meters (COMP/ALC/ID/VDD) get a generic 0-100% scale because the CAT
    /// manual gives no calibration from RM's 0-255 to dB/amps/volts — retune
    /// against the rig's own display if exact units are wanted.
    public var ticks: [(label: String, fraction: Double)] {
        switch self {
        case .po:
            [("0", 0.11), ("1", 0.33), ("5", 0.55), ("10", 0.72), ("15", 0.88)]
        case .swr:
            SMeterScale.swrTicks
        case .comp, .alc, .vdd, .id:
            [("0", 0.10), ("25", 0.325), ("50", 0.54), ("75", 0.76), ("100", 0.88)]
        }
    }

    /// Needle fraction for this meter, nil (no reading) resting the needle.
    public func fraction(from readings: MeterReadings) -> Double {
        switch self {
        case .po:
            guard let w = readings.powerWatts else { return 0 }
            return Self.piecewise(w, [(0, 0.11), (1, 0.33), (5, 0.55), (10, 0.72), (15, 0.88)])
        case .swr:
            return SMeterScale.fraction(forSWR: readings.swr)
        case .comp: return Self.rawFraction(readings.tx?.comp)
        case .alc: return Self.rawFraction(readings.tx?.alc)
        case .vdd: return Self.rawFraction(readings.tx?.vdd)
        case .id: return Self.rawFraction(readings.tx?.idd)
        }
    }

    private static func rawFraction(_ raw: Int?) -> Double {
        guard let raw else { return 0 }
        return 0.10 + 0.78 * Double(min(max(raw, 0), 255)) / 255
    }

    private static func piecewise(_ x: Double, _ anchors: [(Double, Double)]) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for (a, b) in zip(anchors, anchors.dropFirst()) where x <= b.0 {
            return a.1 + (x - a.0) / (b.0 - a.0) * (b.1 - a.1)
        }
        return last.1
    }
}

/// The inputs the lower scale can draw from.
public struct MeterReadings: Sendable {
    public var powerWatts: Double?
    public var swr: Double?
    public var tx: TXMeterReadings?

    public init(powerWatts: Double?, swr: Double?, tx: TXMeterReadings?) {
        self.powerWatts = powerWatts
        self.swr = swr
        self.tx = tx
    }
}

/// Raw RM (READ METER) values, 0-255, for the meters hamlib has no level
/// for. Only read while transmitting — see `HubService.refreshFastTier`.
public struct TXMeterReadings: Codable, Equatable, Sendable {
    public var comp: Int?
    public var alc: Int?
    public var idd: Int?
    public var vdd: Int?

    public init(comp: Int? = nil, alc: Int? = nil, idd: Int? = nil, vdd: Int? = nil) {
        self.comp = comp
        self.alc = alc
        self.idd = idd
        self.vdd = vdd
    }
}

public enum MeterSettings {
    public static let key = "appearance.meterSelection"
    /// The Sub meter's own selection, like the rig's separate SUB-side METER SW.
    public static let subKey = "appearance.meterSelectionSub"
}
