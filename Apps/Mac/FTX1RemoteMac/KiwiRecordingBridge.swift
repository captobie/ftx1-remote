import Foundation
import WebKit
import os

/// Drives the KiwiSDR page's own audio recorder for the WebSDR window's
/// Record button, and files the WAVs it saves into the app's Recordings
/// folder (`AudioRecorder.recordingsDirectory`).
///
/// **Why the Kiwi's recorder** (user decision, 2026-09-24): the page already
/// has one — `toggle_or_set_rec(set)`, the same function as its own "r"
/// key and record icon (checked in a live Kiwi's `kiwisdr.min.js`,
/// v1.902). It records the decoded 12 kHz audio *before* the page's
/// volume/mute, and on stop builds a WAV blob and "downloads" it through a
/// hidden `<a download>` click. `KiwiWebView`'s navigation delegate turns
/// that into a `WKDownload` and asks `destinationURL()` where to put it.
/// This is the only call the app makes into the page, and it only invokes
/// the page's own function — nothing is patched or injected.
///
/// Stopping is asynchronous — the file exists only once the download
/// finishes — so `stop()` waits for it (with a timeout) before the caller
/// reloads or unloads the page, which would otherwise drop the recording.
final class KiwiRecordingBridge {
    weak var webView: WKWebView?

    /// Called when the Kiwi saves a recording the app didn't ask to stop —
    /// in practice the Kiwi's own `owrx_close_cb`, which stops (and saves)
    /// any recording when its audio connection closes (e.g. a time limit
    /// or the station kicking the listener).
    var onUnexpectedSave: ((URL?) -> Void)?

    private static let logger = Logger(subsystem: "com.ftx1remote.mac", category: "websdr-recording")

    /// Label and start time of the segment being recorded — the saved
    /// file's name, like the rig's own recordings plus "KiwiSDR".
    private var segmentLabel = ""
    private var segmentStart = Date()
    private var stopContinuation: CheckedContinuation<URL?, Never>?

    /// Starts the Kiwi recording once the page's audio is actually running
    /// (it isn't until the page has connected — and, on a Kiwi that asks
    /// for a name first, until that's entered). Polls for up to a minute.
    /// Returns false if it never got going.
    ///
    /// The file is named from what the *Kiwi* is tuned to at that moment —
    /// read from the page's own `freq_displayed_kHz_str_with_freq_offset`/
    /// `cur_mode` (the globals its "copy frequency link" icon uses) — so the
    /// name is right even with Follow off or after tuning in the Kiwi
    /// itself. `fallbackLabel` (the rig frequency the page was loaded for)
    /// is used only if those aren't readable.
    @discardableResult
    func start(fallbackLabel: String) async -> Bool {
        let js = """
        (function() {
          if (typeof toggle_or_set_rec !== 'function' || typeof audio_running === 'undefined' || !audio_running) return null;
          if (!recording) toggle_or_set_rec(true);
          return [
            typeof freq_displayed_kHz_str_with_freq_offset === 'string' ? freq_displayed_kHz_str_with_freq_offset : '',
            typeof cur_mode === 'string' ? cur_mode : ''
          ];
        })()
        """
        for _ in 0..<120 {
            if Task.isCancelled { return false }
            if let result = try? await webView?.evaluateJavaScript(js) as? [String], result.count == 2 {
                segmentStart = Date()
                let label = Self.label(kHz: result[0], mode: result[1]) ?? fallbackLabel
                segmentLabel = label.isEmpty ? "KiwiSDR" : label + " KiwiSDR"
                Self.logger.info("recording started: \(self.segmentLabel, privacy: .public)")
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        Self.logger.error("recording never started: Kiwi audio not running")
        return false
    }

    /// "14047.55" + "cw" → "14.047.550 CW", the rig recordings' format.
    private static func label(kHz: String, mode: String) -> String? {
        guard let khz = Double(kHz), khz > 0 else { return nil }
        return AudioRecorder.label(frequencyHz: Int((khz * 1000).rounded()), modeName: mode.uppercased())
    }

    /// Stops the Kiwi recording and waits (up to 5 s) for its WAV to land
    /// in Recordings. Returns the saved file, or nil if nothing was being
    /// recorded, the page is gone, or the save didn't arrive in time.
    @discardableResult
    func stop() async -> URL? {
        guard let webView else { return nil }
        let js = """
        (function() {
          if (typeof recording === 'undefined' || !recording) return 'idle';
          toggle_or_set_rec(false);
          return 'stopped';
        })()
        """
        guard let result = try? await webView.evaluateJavaScript(js) as? String, result == "stopped" else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            stopContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, let pending = self.stopContinuation else { return }
                Self.logger.error("recording save timed out")
                self.stopContinuation = nil
                pending.resume(returning: nil)
            }
        }
    }

    // MARK: Download plumbing (called by KiwiWebView's coordinator)

    /// Where the Kiwi's saved WAV goes: Recordings, named like the app's
    /// own recordings, uniquified if the name is taken.
    func destinationURL() -> URL {
        var url = AudioRecorder.newRecordingURL(label: segmentLabel, date: segmentStart)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = AudioRecorder.newRecordingURL(label: "\(segmentLabel) \(n)", date: segmentStart)
            n += 1
        }
        pendingDestination = url
        return url
    }

    private var pendingDestination: URL?

    func downloadFinished(success: Bool) {
        var saved = success ? pendingDestination : nil
        pendingDestination = nil
        // A stop with no audio captured still saves a bare 44-byte WAV
        // header — not worth keeping.
        if let url = saved,
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
           size <= 44 {
            try? FileManager.default.removeItem(at: url)
            saved = nil
        }
        Self.logger.info("recording saved: \(saved?.lastPathComponent ?? "nothing", privacy: .public)")
        if let continuation = stopContinuation {
            stopContinuation = nil
            continuation.resume(returning: saved)
        } else {
            onUnexpectedSave?(saved)
        }
    }
}
