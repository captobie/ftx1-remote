import Combine
import Foundation

/// The decoders' WebSDR source: what the WebSDR window is playing, through
/// one `WebSDRAudioTap` shared by every window that wants it (the CW
/// window, the RTTY/PSK window). Mac-only, so it lives beside the shared
/// receivers rather than in them.
///
/// Each consumer says whether it wants WebSDR audio right now and gets the
/// samples while it does; the tap runs while any consumer wants it. A
/// consumer calls `update()` whenever its answer may have changed (the
/// receivers' `onSourceChanged`).
///
/// While the tap runs, the WebSDR window's Mute moves off the page and onto
/// the tap (`WebSDRAudioRouting`), so the page keeps playing into the tap.
/// Two taps (one per window) would each try to own that hand-off, which is
/// why there is only one.
final class WebSDRAudioSource: ObservableObject {
    /// The tap's state while some consumer wants it; `.stopped` otherwise.
    @Published private(set) var status = WebSDRAudioTap.Status.stopped

    private struct Consumer {
        let isWanted: @MainActor () -> Bool
        let onSamples: @MainActor ([Float], Double) -> Void
    }

    private let routing: WebSDRAudioRouting
    private var consumers: [String: Consumer] = [:]
    /// Created on first use: the tap's permission prompt should only ever
    /// appear once someone picks the WebSDR source.
    private var tap: WebSDRAudioTap?
    private var muteCancellable: AnyCancellable?

    init(routing: WebSDRAudioRouting) {
        self.routing = routing
        // The WebSDR window's Mute, applied to the tap while it runs.
        muteCancellable = routing.$muteRequested
            .removeDuplicates()
            .sink { [weak self] muted in self?.tap?.setMuted(muted) }
    }

    /// Adds (or replaces) the consumer named `id`.
    func addConsumer(
        id: String,
        isWanted: @escaping @MainActor () -> Bool,
        onSamples: @escaping @MainActor ([Float], Double) -> Void
    ) {
        consumers[id] = Consumer(isWanted: isWanted, onSamples: onSamples)
        update()
    }

    private var isWanted: Bool {
        consumers.values.contains { $0.isWanted() }
    }

    /// Starts or stops the tap to match what the consumers want.
    func update() {
        if isWanted {
            if tap == nil {
                tap = WebSDRAudioTap(
                    onSamples: { [weak self] samples, sampleRate in
                        self?.deliver(samples, sampleRate: sampleRate)
                    },
                    onStatus: { [weak self] status in
                        self?.statusChanged(status)
                    }
                )
            }
            // Before `start()`, so a tap built while muted starts muted.
            tap?.setMuted(routing.muteRequested)
            tap?.start()
            // A quick switch away and back can restart a tap whose status
            // never changed, so recompute rather than wait for a callback.
            statusChanged(status)
        } else {
            // The page mutes itself again right away; the tap holds its
            // own mute a moment longer (see `WebSDRAudioTap.stop()`).
            routing.captureActive = false
            tap?.stop()
        }
    }

    private func deliver(_ samples: [Float], sampleRate: Double) {
        for consumer in consumers.values where consumer.isWanted() {
            consumer.onSamples(samples, sampleRate)
        }
    }

    private func statusChanged(_ status: WebSDRAudioTap.Status) {
        self.status = status
        // Only once the tap is attached (and so muted, if asked) does the
        // page unmute: no gap where both are open or both are muted.
        let attached = status == .capturing || status == .silent
        let active = attached && isWanted
        if routing.captureActive != active {
            routing.captureActive = active
        }
    }
}
