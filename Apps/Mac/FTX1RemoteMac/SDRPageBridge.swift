import Foundation
import WebKit
import os

/// The WebSDR window's calls into the receiver page — only ever the page's
/// *own* functions and globals, nothing patched or injected. `platform`
/// picks which page's (KiwiSDR or classic WebSDR); `WebSDRFollowModel` sets
/// it for each load, and `detectPlatform()` corrects it once the page is up.
/// - its audio recorder, for Record (files the WAVs it saves into the app's
///   Recordings folder, `AudioRecorder.recordingsDirectory`);
/// - its mute, for the window's Mute button;
/// - its tuning globals, read-only, for click-to-tune (`readTuning`);
/// - WebSDR only: its `setfreqtune()` to retune in place, and its
///   `bandinfo` for the station's receive ranges.
///
/// **Why the page's own recorder** (user decision, 2026-09-24): both pages
/// have one. The Kiwi's is `toggle_or_set_rec(set)`, the same function as
/// its own "r" key and record icon (checked in a live Kiwi's
/// `kiwisdr.min.js`, v1.902); it records the decoded 12 kHz audio *before*
/// the page's volume/mute, and on stop builds a WAV blob and "downloads" it
/// through a hidden `<a download>` click. The WebSDR's is `record_click()`
/// (its record button; `record_start`/`record_stop` underneath, checked in
/// a live `websdr-base.js`, 2026-09-25); its stop only puts a "save" link
/// in the page (`#reccontrol a`, a blob with `download=`), which `stop()`
/// then clicks. Either way `KiwiWebView`'s navigation delegate turns the
/// save into a `WKDownload` and asks `destinationURL()` where to put it.
///
/// Stopping is asynchronous — the file exists only once the download
/// finishes — so `stop()` waits for it (with a timeout) before the caller
/// reloads, retunes or unloads the page, which would otherwise drop the
/// recording.
final class SDRPageBridge {
    weak var webView: WKWebView?
    /// Which page's functions to call. Set per load by `WebSDRFollowModel`;
    /// `detectPlatform()` overwrites it with what the page actually is.
    var platform: SDRPlatform = .kiwiSDR

    /// Called when the page saves a recording the app didn't ask to stop —
    /// in practice the Kiwi's own `owrx_close_cb`, which stops (and saves)
    /// any recording when its audio connection closes (e.g. a time limit
    /// or the station kicking the listener). A WebSDR never saves by itself.
    var onUnexpectedSave: ((URL?) -> Void)?

    private static let logger = Logger(subsystem: "com.ftx1remote.mac", category: "websdr-recording")

    /// Label and start time of the segment being recorded — the saved
    /// file's name, like the rig's own recordings plus "KiwiSDR"/"WebSDR".
    private var segmentLabel = ""
    private var segmentStart = Date()
    private var stopContinuation: CheckedContinuation<URL?, Never>?

    // MARK: Platform

    /// What the loaded page is, from its own globals: a WebSDR page defines
    /// `setfreqtune()` and `bandinfo`, a Kiwi page the `kiwi` object. Sets
    /// `platform` when recognized; nil (and `platform` untouched) otherwise.
    @discardableResult
    func detectPlatform() async -> SDRPlatform? {
        let js = """
        (function() {
          if (typeof setfreqtune === 'function' && typeof bandinfo !== 'undefined') return 'webSDR';
          if (typeof kiwi === 'object') return 'kiwiSDR';
          return null;
        })()
        """
        guard let raw = try? await webView?.evaluateJavaScript(js) as? String,
              let detected = SDRPlatform(rawValue: raw)
        else { return nil }
        platform = detected
        return detected
    }

    /// A WebSDR's receive ranges, in Hz, from its own `bandinfo` (each band
    /// is `centerfreq ± samplerate/2`, in kHz). nil on a Kiwi or on failure.
    func readBands() async -> [ClosedRange<Int>]? {
        guard platform == .webSDR else { return nil }
        let js = """
        (function() {
          if (typeof bandinfo === 'undefined') return null;
          return bandinfo.map(function(b) {
            return [Math.max(0, Math.round((b.centerfreq - b.samplerate / 2) * 1000)),
                    Math.round((b.centerfreq + b.samplerate / 2) * 1000)];
          });
        })()
        """
        guard let result = try? await webView?.evaluateJavaScript(js) as? [[NSNumber]] else { return nil }
        let bands = result.compactMap { pair -> ClosedRange<Int>? in
            guard pair.count == 2, pair[0].intValue <= pair[1].intValue else { return nil }
            return pair[0].intValue...pair[1].intValue
        }
        return bands.isEmpty ? nil : bands
    }

    /// The page's `<title>`, as a station name. Some WebSDR skins put the
    /// title in literal quotes ("\"WebSDR 2.1 Low at …\""), so those go too.
    func pageTitle() async -> String? {
        let title = try? await webView?.evaluateJavaScript("document.title") as? String
        return title?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
    }

    /// WebSDR only: retunes the loaded page through its own `setfreqtune()`
    /// — no reload, no reconnect. `value` is `WebSDRURLBuilder.tuneValue`'s
    /// "7074.00usb". Returns false if the page isn't a WebSDR page.
    @discardableResult
    func retuneInPlace(_ value: String) async -> Bool {
        guard platform == .webSDR,
              let literal = Self.jsStringLiteral(value)
        else { return false }
        let js = """
        (function() {
          if (typeof setfreqtune !== 'function') return false;
          setfreqtune(\(literal));
          return true;
        })()
        """
        return (try? await webView?.evaluateJavaScript(js) as? Bool) == true
    }

    private static func jsStringLiteral(_ s: String) -> String? {
        guard let data = try? JSONEncoder().encode(s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Recording

    /// Starts the page's recording once its audio is actually running (it
    /// isn't until the page has connected — and, on a Kiwi that asks for a
    /// name first, until that's entered). Polls for up to a minute.
    /// Returns false if it never got going.
    ///
    /// The file is named from what the *page* is tuned to at that moment —
    /// the Kiwi's `freq_displayed_kHz_str_with_freq_offset`/`cur_mode` (the
    /// globals its "copy frequency link" icon uses), the WebSDR's
    /// `nominalfreq()`/`mode` — so the name is right even with Follow off or
    /// after tuning in the page itself. `fallbackLabel` (the rig frequency
    /// the page was tuned for) is used only if those aren't readable.
    @discardableResult
    func start(fallbackLabel: String) async -> Bool {
        let js: String
        switch platform {
        case .kiwiSDR:
            js = """
            (function() {
              if (typeof toggle_or_set_rec !== 'function' || typeof audio_running === 'undefined' || !audio_running) return null;
              if (!recording) toggle_or_set_rec(true);
              return [
                typeof freq_displayed_kHz_str_with_freq_offset === 'string' ? freq_displayed_kHz_str_with_freq_offset : '',
                typeof cur_mode === 'string' ? cur_mode : ''
              ];
            })()
            """
        case .webSDR:
            // `record_click()` rather than `record_start()` so the page's
            // own start/stop button stays in step.
            js = """
            (function() {
              var bt = document.getElementById('recbutton');
              if (!bt || typeof record_click !== 'function' || typeof allloadeddone === 'undefined'
                  || !allloadeddone || !soundapplet) return null;
              if (bt.innerHTML != 'stop') record_click();
              return [nominalfreq().toFixed(2), String(mode)];
            })()
            """
        }
        for _ in 0..<120 {
            if Task.isCancelled { return false }
            if let result = try? await webView?.evaluateJavaScript(js) as? [String], result.count == 2 {
                segmentStart = Date()
                let label = Self.label(kHz: result[0], mode: result[1]) ?? fallbackLabel
                segmentLabel = label.isEmpty ? platform.displayName : label + " " + platform.displayName
                Self.logger.info("recording started: \(self.segmentLabel, privacy: .public)")
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        Self.logger.error("recording never started: page audio not running")
        return false
    }

    /// "14047.55" + "cw" → "14.047.550 CW", the rig recordings' format.
    private static func label(kHz: String, mode: String) -> String? {
        guard let khz = Double(kHz), khz > 0 else { return nil }
        return AudioRecorder.label(frequencyHz: Int((khz * 1000).rounded()), modeName: mode.uppercased())
    }

    /// Stops the page's recording and waits (up to 5 s) for its WAV to land
    /// in Recordings. Returns the saved file, or nil if nothing was being
    /// recorded, the page is gone, or the save didn't arrive in time.
    @discardableResult
    func stop() async -> URL? {
        guard let webView else { return nil }
        let js: String
        switch platform {
        case .kiwiSDR:
            js = """
            (function() {
              if (typeof recording === 'undefined' || !recording) return 'idle';
              toggle_or_set_rec(false);
              return 'stopped';
            })()
            """
        case .webSDR:
            js = """
            (function() {
              var bt = document.getElementById('recbutton');
              if (!bt || bt.innerHTML != 'stop') return 'idle';
              record_click();
              var save = document.querySelector('#reccontrol a');
              if (!save) return 'idle';
              save.click();
              return 'stopped';
            })()
            """
        }
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

    // MARK: Mute

    /// Mutes/unmutes the page's audio through its own mute, then asserts
    /// it for up to 30 s until the page is ready to take it:
    /// - Kiwi: `toggle_or_set_mute` (its speaker icon). A freshly loaded
    ///   page applies its `mute=` URL parameter itself once the frequency is
    ///   set (`muted_until_freq_set`), which would override an earlier call,
    ///   so this waits for that.
    /// - WebSDR: its "mute" checkbox + `setmute()` (what its M key does).
    ///   There's no URL parameter; `bodyonload` resets the checkbox, and the
    ///   audio start applies whatever the checkbox says — so this waits for
    ///   `bodyonload` to have run (`did_read_settings`, set in it) and sets
    ///   the checkbox, calling `setmute()` too if audio is already running.
    func setPageMuted(_ muted: Bool) async {
        let flag = muted ? 1 : 0
        let js: String
        switch platform {
        case .kiwiSDR:
            js = """
            (function() {
              if (typeof toggle_or_set_mute !== 'function' || typeof muted_until_freq_set === 'undefined' || muted_until_freq_set) return 'waiting';
              toggle_or_set_mute(\(flag));
              return 'done';
            })()
            """
        case .webSDR:
            js = """
            (function() {
              var cb = document.getElementById('mutecheckbox');
              if (!cb || typeof setmute !== 'function' || typeof did_read_settings === 'undefined' || !did_read_settings) return 'waiting';
              cb.checked = \(muted ? "true" : "false");
              if (soundapplet) setmute(\(flag));
              return 'done';
            })()
            """
        }
        for _ in 0..<60 {
            if Task.isCancelled { return }
            if let result = try? await webView?.evaluateJavaScript(js) as? String, result == "done" { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: Tuning (click-to-tune)

    /// What the page is tuned to, read from its own globals — the same ones
    /// its frequency field shows. Read-only; nothing in the page is called
    /// or patched.
    /// - Kiwi: `freq_displayed_Hz` plus `kiwi.freq_offset_Hz` (so a
    ///   converter-fed Kiwi reports the real RF frequency, the same
    ///   "displayed kHz" `?f=` takes) and `cur_mode`. nil until the page has
    ///   applied its initial frequency: the page clears
    ///   `muted_until_freq_set` right after that first tune, whatever its
    ///   `mute=` parameter — before that, `freq_displayed_Hz` can still be a
    ///   startup value.
    /// - WebSDR: `nominalfreq()` (kHz; the CW offset already accounted for)
    ///   and `mode`. nil until `allloadeddone` (its audio start), by which
    ///   point `?tune=` has long been applied.
    func readTuning() async -> (frequencyHz: Int, mode: String)? {
        let js: String
        switch platform {
        case .kiwiSDR:
            js = """
            (function() {
              if (typeof freq_displayed_Hz !== 'number' || typeof cur_mode !== 'string'
                  || typeof muted_until_freq_set === 'undefined' || muted_until_freq_set) return null;
              var offset = (typeof kiwi === 'object' && typeof kiwi.freq_offset_Hz === 'number') ? kiwi.freq_offset_Hz : 0;
              return [freq_displayed_Hz + offset, cur_mode];
            })()
            """
        case .webSDR:
            js = """
            (function() {
              if (typeof allloadeddone === 'undefined' || !allloadeddone || typeof nominalfreq !== 'function') return null;
              return [nominalfreq() * 1000, String(mode)];
            })()
            """
        }
        guard let result = try? await webView?.evaluateJavaScript(js) as? [Any], result.count == 2,
              let hz = (result[0] as? NSNumber)?.doubleValue, hz > 0,
              let mode = result[1] as? String
        else { return nil }
        return (Int(hz.rounded()), mode)
    }

    // MARK: Download plumbing (called by KiwiWebView's coordinator)

    /// Where the page's saved WAV goes: Recordings, named like the app's
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
