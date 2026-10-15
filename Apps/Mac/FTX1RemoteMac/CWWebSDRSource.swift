import Combine
import Foundation
import FTX1CW

/// The CW window's third source: what the WebSDR window is playing,
/// through `WebSDRAudioTap`. Mac-only, so it lives beside the shared
/// `CWReceiver` rather than in it: it follows the receiver's
/// `onSourceChanged` and runs the tap only while decoding is on with
/// `.webSDR` selected, feeding the receiver as `.webSDR`.
///
/// While the tap runs, the WebSDR window's Mute moves off the page and onto
/// the tap (`WebSDRAudioRouting`), so the page keeps playing into the tap.
final class CWWebSDRSource: ObservableObject {
    /// The tap's state while `.webSDR` is the source and decoding is on;
    /// `.stopped` otherwise.
    @Published private(set) var status = WebSDRAudioTap.Status.stopped

    private let routing: WebSDRAudioRouting
    private weak var receiver: CWReceiver?
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

    func attach(to receiver: CWReceiver) {
        self.receiver = receiver
        receiver.onSourceChanged = { [weak self] in self?.update() }
    }

    private var isWanted: Bool {
        guard let receiver else { return false }
        return receiver.isRunning && receiver.channel == .webSDR
    }

    private func update() {
        if isWanted {
            if tap == nil {
                tap = WebSDRAudioTap(
                    onSamples: { [weak self] samples, sampleRate in
                        self?.receiver?.ingest(samples: samples, sampleRate: sampleRate, channel: .webSDR)
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
