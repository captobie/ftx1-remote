import Combine
import FT8Kit
import Foundation
import FTX1Core

/// Owns the current session's decoded FT8 or FT4 spots — what
/// `FT8ListView` (the Tools → FT8 or FT4 window) displays; one store per
/// mode (`HubService.ft8Store`/`ft4Store`). Fed by `FT8DecodeCoordinator`'s output,
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

    let mode: FT8Kit.Mode

    @Published private(set) var spots: [FT8Spot] = []
    @Published private(set) var cycleStatus: FT8DecodeCoordinator.CycleStatus = .idle
    @Published private(set) var lastCycleCompletedAt: Date?

    /// The sources this window offers. No WebSDR: its page tap is shared
    /// with the CW and RTTY/PSK windows, and nobody asked for it here.
    static let offeredChannels: [ReceiveAudioChannel] = [.main, .sub, .myKiwiSDR]

    /// The decoded source, saved per mode (`ft8.channel`/`ft4.channel`).
    /// `HubService` passes changes to the coordinator via `onChannelChanged`.
    @Published var channel: ReceiveAudioChannel {
        didSet {
            guard channel != oldValue else { return }
            UserDefaults.standard.set(channel.rawValue, forKey: channelKey)
            onChannelChanged?(channel)
        }
    }
    var onChannelChanged: ((ReceiveAudioChannel) -> Void)?

    /// Whether the window is open and decoding — read per Kiwi frame by
    /// the MyKiwiSDR source's `isWanted`, so not published.
    var isRunning = false

    /// SUB audio arrived in the last 2 s (a mono input never has any).
    @Published private(set) var isSubAudioAvailable = false
    private var lastSubAudioAt: Date?
    private static let subAudioTimeout: TimeInterval = 2

    private var channelKey: String { "\(mode.name.lowercased()).channel" }

    init(mode: FT8Kit.Mode) {
        self.mode = mode
        channel = ReceiveAudioChannel.restored(
            rawValue: UserDefaults.standard.string(forKey: "\(mode.name.lowercased()).channel"),
            offered: Self.offeredChannels
        )
    }

    /// Called for every MAIN and SUB chunk (main actor). Publishes only on a change.
    func noteAudio(from source: ReceiveAudioChannel) {
        let now = Date()
        switch source {
        case .sub:
            lastSubAudioAt = now
            if !isSubAudioAvailable { isSubAudioAvailable = true }
        case .main:
            guard isSubAudioAvailable else { return }
            if let lastSubAudioAt, now.timeIntervalSince(lastSubAudioAt) < Self.subAudioTimeout { return }
            isSubAudioAvailable = false
        case .webSDR, .myKiwiSDR:
            break
        }
    }

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

    /// Called when the Tools/FT8 (or FT4) window closes — clears the display but
    /// not any future persisted history, since there isn't one (see above).
    func clear() {
        spots = []
        cycleStatus = .idle
        lastCycleCompletedAt = nil
    }
}
