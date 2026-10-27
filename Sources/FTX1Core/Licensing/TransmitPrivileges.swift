import Foundation

/// What a privilege segment allows, in the FCC's broad terms (47 CFR
/// §97.305's "CW", "phone", "RTTY, data"). Image (SSTV) has no rig mode of
/// its own here: sent through DATA-U it counts as data, through USB/LSB as
/// phone.
public enum TransmitEmission: String, Codable, Sendable, CaseIterable, Hashable {
    case cw
    case phone
    case data

    public var displayName: String {
        switch self {
        case .cw: "CW"
        case .phone: String(localized: "transmitPrivileges.phone", bundle: .module)
        case .data: String(localized: "transmitPrivileges.data", bundle: .module)
        }
    }
}

public extension RigMode {
    /// The emission this mode transmits. C4FM is digital *voice*, which the
    /// FCC counts as phone; DATA-FM and RTTY are data. Nil for `.unknown`,
    /// so nothing keys before the mode has been read.
    var transmitEmission: TransmitEmission? {
        switch self {
        case .cw: .cw
        case .usb, .lsb, .am, .fm, .c4fm: .phone
        case .rtty, .dataUSB, .dataFM: .data
        case .unknown: nil
        }
    }

    /// The spectrum a transmission at `dialHz` occupies — what has to fit
    /// inside the privileges, not just the dial frequency (an LSB signal
    /// at 7.176 MHz reaches down to 7.173). Approximations: SSB and DATA-U
    /// use the FTX-1's default SSB TX BPF (100–2900 Hz, menu SSB TX BPF
    /// SEL); CW ±100 Hz of keying sidebands; RTTY ±300 Hz (170 Hz shift);
    /// AM ±3 kHz; FM and DATA-FM ±8 kHz (16K0F3E); C4FM ±6.25 kHz (a
    /// 12.5 kHz channel). Nil for `.unknown`.
    func occupiedSpectrum(dialHz: Int) -> ClosedRange<Int>? {
        switch self {
        case .usb, .dataUSB: (dialHz + 100)...(dialHz + 2_900)
        case .lsb: (dialHz - 2_900)...(dialHz - 100)
        case .cw: (dialHz - 100)...(dialHz + 100)
        case .rtty: (dialHz - 300)...(dialHz + 300)
        case .am: (dialHz - 3_000)...(dialHz + 3_000)
        case .fm, .dataFM: (dialHz - 8_000)...(dialHz + 8_000)
        case .c4fm: (dialHz - 6_250)...(dialHz + 6_250)
        case .unknown: nil
        }
    }
}

/// A stretch of spectrum and what may be sent in it. `onlyModes` narrows
/// the emissions further where the rules name specific modes (US 60 m:
/// USB, CW and data only; Novice/Technician 28.3–28.5 MHz: SSB and CW).
public struct PrivilegeSegment: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var lowerHz: Int
    public var upperHz: Int
    public var emissions: Set<TransmitEmission>
    public var onlyModes: Set<RigMode>?

    public init(id: UUID = UUID(), lowerHz: Int, upperHz: Int,
                emissions: Set<TransmitEmission>, onlyModes: Set<RigMode>? = nil) {
        self.id = id
        self.lowerHz = lowerHz
        self.upperHz = upperHz
        self.emissions = emissions
        self.onlyModes = onlyModes
    }

    public func allows(_ mode: RigMode) -> Bool {
        guard let emission = mode.transmitEmission, emissions.contains(emission) else { return false }
        return onlyModes?.contains(mode) ?? true
    }

    /// Ignores `id`, so a copied preset compares equal to its source.
    public func sameContent(as other: PrivilegeSegment) -> Bool {
        lowerHz == other.lowerHz && upperHz == other.upperHz
            && emissions == other.emissions && onlyModes == other.onlyModes
    }
}

/// A set of transmit privileges: a US license class, an ITU region's
/// allocation, or the operator's own table.
public struct PrivilegeProfile: Codable, Sendable, Hashable {
    public var name: String
    public var segments: [PrivilegeSegment]

    public init(name: String, segments: [PrivilegeSegment]) {
        self.name = name
        self.segments = segments
    }

    /// Whether a transmission in `mode` at `dialHz` fits entirely inside
    /// segments that allow that mode. Neighbouring segments that both
    /// allow it are treated as one, so CW right at the US 20 m phone edge
    /// (allowed on both sides) passes.
    public func allows(dialHz: Int, mode: RigMode) -> Bool {
        guard let occupied = mode.occupiedSpectrum(dialHz: dialHz) else { return false }
        let ranges = segments
            .filter { $0.allows(mode) && $0.lowerHz <= $0.upperHz }
            .map { $0.lowerHz...$0.upperHz }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged.contains { $0.contains(occupied.lowerBound) && $0.contains(occupied.upperBound) }
    }
}

/// Which privileges the transmit gate applies: off (just the amateur bands,
/// `BandPlan`), a built-in preset, or the operator's custom table.
public enum PrivilegeChoice: Hashable, Sendable {
    case off
    case preset(PrivilegePreset)
    case custom

    /// Stored form (`rawValue`), so a later preset added in between never
    /// shifts what's saved.
    public var rawValue: String {
        switch self {
        case .off: "off"
        case .preset(let preset): preset.rawValue
        case .custom: "custom"
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "custom": self = .custom
        default: self = PrivilegePreset(rawValue: rawValue).map { .preset($0) } ?? .off
        }
    }
}
