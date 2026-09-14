import Combine
import Foundation

/// Owns the current session's decoded FT8 spots — what `FT8ListView` (the
/// Digital → FT8 window) displays. Fed by `FT8DecodeCoordinator`'s output,
/// which always arrives on the main actor (same contract as
/// `APRSDecoder`'s callbacks), so this itself doesn't need to be an actor.
///
/// Deliberately NOT `@Published` on `HubService` itself — spots arrive in
/// bursts of up to a few dozen per ~15s decode cycle, which would otherwise
/// re-render the whole main window on every cycle. Same isolation rule as
/// `ScopeFrameStore`/`APRSStore` (see CLAUDE.md's high-rate-state note).
///
/// Unlike `APRSStore`, holds no disk persistence — FT8 spots are treated as
/// current-session state, not a cross-launch history, so there's nothing to
/// load/save here.
@MainActor
final class FT8Store: ObservableObject {
    /// Generous enough to cover a long operating session's worth of spots
    /// without unbounded growth; APRS's `maxStations`/`maxMessages` default
    /// to 1,000 for the same "bound it, don't tune it precisely" reasoning.
    static let maxSpots = 2_000

    @Published private(set) var spots: [FT8Spot] = []
    @Published private(set) var cycleStatus: FT8DecodeCoordinator.CycleStatus = .idle
    @Published private(set) var lastCycleCompletedAt: Date?

    func record(_ newSpots: [FT8Spot]) {
        guard !newSpots.isEmpty else { return }
        spots.append(contentsOf: newSpots)
        if spots.count > Self.maxSpots {
            spots.removeFirst(spots.count - Self.maxSpots)
        }
        lastCycleCompletedAt = Date()
    }

    func updateCycleStatus(_ status: FT8DecodeCoordinator.CycleStatus) {
        cycleStatus = status
    }

    /// Called when the Digital/FT8 window closes — clears the display but
    /// not any future persisted history, since there isn't one (see above).
    func clear() {
        spots = []
        cycleStatus = .idle
        lastCycleCompletedAt = nil
    }
}
