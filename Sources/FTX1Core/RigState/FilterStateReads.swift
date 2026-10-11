import Foundation

/// One read of a receiver's filter state — the ten fields `RigState` holds
/// for the selected filter side (`RigState.filterSide`). nil = not read (or
/// the read failed); `RigState.applyFilterSnapshot` keeps the last known
/// value then. Shared by the Mac hub (`HubService`'s slow tier and
/// side-switch/swap/NAR refreshes) and the iPad's Pi-direct route
/// (`PiDirectViewModel`), so the two read the rig the same way.
public struct FilterSnapshot: Sendable, Equatable {
    public var widthIndex: Int?
    public var shiftHz: Int?
    public var notchRaw: Int?
    public var notchCode: Int?
    public var contourRaw: Int?
    public var contourHzRaw: Int?
    public var apfRaw: Int?
    public var apfCode: Int?
    public var narrowEnabled: Bool?
    public var narrowWidthHz: Int?

    public init() {}
}

/// One step of a filter read: fills its field(s) of the snapshot. `mode` is
/// the filtered receiver's mode (the NAR WIDTH preset is per mode).
public typealias FilterSnapshotRead = @Sendable (RigctldClient, FilterSide, RigMode, inout FilterSnapshot) async -> Void

public enum FilterStateReads {
    /// Every read in a full snapshot, in order. All mnemonics carry the
    /// side's P1 ("0" MAIN / "1" SUB; hardware-probed 2026-09-19 that Sub
    /// replies mirror Main's shapes). Each is best-effort (`try?`). The
    /// Pi-direct route runs these a few per poll tick; the hub all at once.
    public static let all: [FilterSnapshotRead] = [
        width,
        // "IS" answers with a signed value, which getRawInt can't parse —
        // dedicated helper, see RigctldClient.getIFShiftHz().
        { rigctld, side, _, snapshot in snapshot.shiftHz = try? await rigctld.getIFShiftHz(side: side) },
        // "BP<p1>0"/"BP<p1>1": manual notch on/off and frequency, both
        // 3-digit fields, so on/off goes through getRawInt (!= 0) — see
        // IFNotch. (A Sub side in a mode without a notch can answer a
        // non-numeric frequency like "F35"; getRawInt returns nil then.)
        { rigctld, side, _, snapshot in snapshot.notchRaw = try? await rigctld.getRawInt("BP\(side.p1)0") },
        { rigctld, side, _, snapshot in snapshot.notchCode = try? await rigctld.getRawInt("BP\(side.p1)1") },
        // "CO<p1>0".."CO<p1>3": CONTOUR on/off + frequency, APF on/off +
        // offset — all 4-digit fields, see IFContour.
        { rigctld, side, _, snapshot in snapshot.contourRaw = try? await rigctld.getRawInt("CO\(side.p1)0") },
        { rigctld, side, _, snapshot in snapshot.contourHzRaw = try? await rigctld.getRawInt("CO\(side.p1)1") },
        { rigctld, side, _, snapshot in snapshot.apfRaw = try? await rigctld.getRawInt("CO\(side.p1)2") },
        { rigctld, side, _, snapshot in snapshot.apfCode = try? await rigctld.getRawInt("CO\(side.p1)3") },
        // "NA<p1>": a plain single-digit boolean, so getRawBool is right.
        { rigctld, side, _, snapshot in snapshot.narrowEnabled = try? await rigctld.getRawBool("NA\(side.p1)") },
        narrowPreset,
    ]

    /// "SH<p1>" reads WIDTH with P1 baked in; the reply's P2 (always "0")
    /// lands as the value's leading digit, discarded for free by
    /// `Int(...)` — see RigState.filterWidthIndex.
    public static let width: FilterSnapshotRead = { rigctld, side, _, snapshot in
        snapshot.widthIndex = try? await rigctld.getRawInt("SH\(side.p1)")
    }

    /// The mode's NAR WIDTH preset (Deep Settings item, generic "EX"
    /// passthrough) — what the rig really filters at while NARROW is on in
    /// SSB/CW/RTTY/DATA, since "SH" keeps reporting the wide setting there.
    /// See NarrowWidthPreset. No read for a mode without one.
    public static let narrowPreset: FilterSnapshotRead = { rigctld, _, mode, snapshot in
        guard let item = NarrowWidthPreset.item(for: mode),
              let raw = try? await rigctld.getMenuItem(p1: item.p1, p2: item.p2, p3: item.p3)
        else { return }
        snapshot.narrowWidthHz = NarrowWidthPreset.hz(forRawValue: raw, mode: mode)
    }
}

public extension RigctldClient {
    /// Reads `side`'s whole filter state directly (bypassing any
    /// `CommandQueue`, like the poll loops). `mode` is *that side's* mode.
    func readFilterState(side: FilterSide, mode: RigMode) async -> FilterSnapshot {
        var snapshot = FilterSnapshot()
        for read in FilterStateReads.all {
            await read(self, side, mode, &snapshot)
        }
        return snapshot
    }
}

public extension RigCommand {
    /// The commands that address one receiver's filter (`RigState.
    /// filterSide`) — the ones `CommandQueue` routes by side.
    var isFilterSideCommand: Bool {
        switch self {
        case .setFilterWidth, .setIFShift, .setNotch, .setNotchFrequency, .setContour,
             .setContourFrequency, .setAPF, .setAPFOffset, .setNarrow:
            return true
        default:
            return false
        }
    }
}

public extension RigState {
    /// Publishes a `FilterSnapshot`, keeping the last known value for any
    /// field not read. `mode` is the filtered side's mode: `narrowWidthHz`
    /// is cleared (not held over) when it has no preset, so AM/FM never
    /// inherit an SSB value.
    mutating func applyFilterSnapshot(_ snapshot: FilterSnapshot, mode: RigMode) {
        filterWidthIndex = snapshot.widthIndex ?? filterWidthIndex
        ifShiftHz = snapshot.shiftHz ?? ifShiftHz
        notchEnabled = snapshot.notchRaw.map { $0 != 0 } ?? notchEnabled
        notchHz = snapshot.notchCode.flatMap(IFNotch.hz(forCode:)) ?? notchHz
        contourEnabled = snapshot.contourRaw.map { $0 != 0 } ?? contourEnabled
        contourHz = snapshot.contourHzRaw.flatMap { IFContour.contourRangeHz.contains($0) ? $0 : nil } ?? contourHz
        apfEnabled = snapshot.apfRaw.map { $0 != 0 } ?? apfEnabled
        apfHz = snapshot.apfCode.flatMap(IFContour.apfHz(forCode:)) ?? apfHz
        narrowEnabled = snapshot.narrowEnabled ?? narrowEnabled
        narrowWidthHz = NarrowWidthPreset.item(for: mode) == nil ? nil : (snapshot.narrowWidthHz ?? narrowWidthHz)
    }

    /// Blanks the ten side-specific filter fields (on a side switch, until
    /// the new side's values are read).
    mutating func clearFilterFields() {
        filterWidthIndex = nil
        ifShiftHz = nil
        notchEnabled = nil
        notchHz = nil
        contourEnabled = nil
        contourHz = nil
        apfEnabled = nil
        apfHz = nil
        narrowEnabled = nil
        narrowWidthHz = nil
    }

    /// The optimistic update for a filter-side command (`isFilterSideCommand`)
    /// applied to the selected side; false (and nothing changed) for any
    /// other command.
    @discardableResult
    mutating func applyFilterCommand(_ command: RigCommand) -> Bool {
        switch command {
        case .setFilterWidth(let index): filterWidthIndex = index
        case .setIFShift(let hz): ifShiftHz = IFShift.snapped(hz)
        case .setNotch(let on): notchEnabled = on
        case .setNotchFrequency(let hz): notchHz = IFNotch.snappedHz(hz)
        case .setContour(let on): contourEnabled = on
        case .setContourFrequency(let hz): contourHz = IFContour.snappedContourHz(hz)
        case .setAPF(let on): apfEnabled = on
        case .setAPFOffset(let hz): apfHz = IFContour.snappedAPFHz(hz)
        case .setNarrow(let on): narrowEnabled = on
        default: return false
        }
        return true
    }
}
