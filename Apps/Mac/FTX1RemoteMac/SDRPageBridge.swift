import Foundation
import WebKit
import os

/// The WebSDR window's calls into the receiver page — only ever the page's
/// *own* functions and globals, nothing patched or injected. `platform`
/// picks which page's (KiwiSDR, classic WebSDR or OpenWebRX);
/// `WebSDRFollowModel` sets it for each load, and `detectPlatform()`
/// corrects it once the page is up.
/// - its audio recorder, for Record (files the WAVs it saves into the app's
///   Recordings folder, `AudioRecorder.recordingsDirectory`);
/// - its mute, for the window's Mute button;
/// - its tuning globals, read-only, for click-to-tune (`readTuning`);
/// - WebSDR only: its `setfreqtune()` to retune in place, and its
///   `bandinfo` for the station's receive ranges.
/// - OpenWebRX only: its demodulator panel to retune in place, its profile
///   list box (`sdr_profile_changed()`, what choosing a profile there does)
///   to switch profiles, and its `status.json` for each profile's range.
///
/// **OpenWebRX recording is the one exception to "nothing injected"**: it
/// has no recorder of its own, so `start()` adds one Web Audio node of the
/// app's own (`startOpenWebRXTap`), connected to the page's existing
/// `audioEngine.audioNode` alongside its volume/mute gain, which posts the
/// audio to the app (`receiveTapAudio`) for `SDRAudioFileWriter`. Additive
/// only — nothing in the page is replaced or patched.
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
          if (typeof sdr_profile_changed === 'function' && typeof Modes === 'object') return 'openWebRX';
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
    /// is `centerfreq ± samplerate/2`, in kHz); an OpenWebRX's from its
    /// profiles (`readOpenWebRXProfiles`). nil on a Kiwi or on failure.
    func readBands() async -> [ClosedRange<Int>]? {
        if platform == .openWebRX {
            await readOpenWebRXProfiles()
            return openWebRXProfiles.isEmpty ? nil : openWebRXProfiles.map(\.range)
        }
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
    /// An OpenWebRX's title is the same on every server, so its receiver
    /// name (from `readBands`) is used instead.
    func pageTitle() async -> String? {
        if platform == .openWebRX { return openWebRXReceiverName }
        let title = try? await webView?.evaluateJavaScript("document.title") as? String
        return title?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
    }

    /// Retunes the loaded page without a reload or reconnect: a WebSDR
    /// through its own `setfreqtune()`, an OpenWebRX through
    /// `retuneOpenWebRX`. Returns false if the page isn't one of those, or
    /// didn't take the tuning.
    @discardableResult
    func retuneInPlace(frequencyHz: Int, modeToken: String?) async -> Bool {
        switch platform {
        case .kiwiSDR: return false
        case .webSDR: return await retuneWebSDR(WebSDRURLBuilder.tuneValue(frequencyHz: frequencyHz, modeToken: modeToken))
        case .openWebRX: return await retuneOpenWebRX(frequencyHz: frequencyHz, modulation: modeToken)
        }
    }

    /// `value` is `WebSDRURLBuilder.tuneValue`'s "7074.00usb".
    private func retuneWebSDR(_ value: String) async -> Bool {
        guard let literal = Self.jsStringLiteral(value) else { return false }
        let js = """
        (function() {
          if (typeof setfreqtune !== 'function') return false;
          setfreqtune(\(literal));
          return true;
        })()
        """
        return (try? await webView?.evaluateJavaScript(js) as? Bool) == true
    }

    // MARK: OpenWebRX profiles

    /// An OpenWebRX profile the page can switch to: its list box value
    /// ("sdr_id|profile_id") and the range it covers.
    struct OpenWebRXProfile: Equatable {
        let id: String
        let range: ClosedRange<Int>
    }

    /// The loaded OpenWebRX's profiles, in its own order; read on each page
    /// load by `readBands`. Empty on other platforms.
    private(set) var openWebRXProfiles: [OpenWebRXProfile] = []
    private var openWebRXReceiverName: String?

    /// Joins the page's profile list box (id + "<SDR name> <profile name>",
    /// the only place the ids are) with its `status.json` (names + center
    /// frequency and sample rate, the only place the ranges are) — both
    /// built from the same names server-side (`owrx/sdr.py`). The list box
    /// is filled from the WebSocket, so this waits for it (≤10 s).
    ///
    /// `status.json` lists every *enabled* SDR whether or not its hardware
    /// is present — a stock config's placeholder Airspy/SDRplay entries
    /// show up as HF coverage the server can't actually tune.
    private func readOpenWebRXProfiles() async {
        openWebRXProfiles = []
        openWebRXReceiverName = nil
        let js = """
        for (let i = 0; i < 40 && !$('#openwebrx-sdr-profiles-listbox option').length; i++) {
          await new Promise(function(r) { setTimeout(r, 250); });
        }
        const response = await fetch('status.json', {cache: 'no-store'});
        const status = await response.json();
        const byName = {};
        status.sdrs.forEach(function(s) {
          s.profiles.forEach(function(p) { byName[s.name + ' ' + p.name] = p; });
        });
        const profiles = [];
        $('#openwebrx-sdr-profiles-listbox option').each(function() {
          const p = byName[$(this).text()];
          if (p) profiles.push([this.value, Math.max(0, Math.round(p.center_freq - p.sample_rate / 2)),
                                Math.round(p.center_freq + p.sample_rate / 2)]);
        });
        return [status.receiver && status.receiver.name || '', profiles];
        """
        guard let webView,
              let result = try? await webView.callAsyncJavaScript(js, contentWorld: .page) as? [Any],
              result.count == 2,
              let rows = result[1] as? [[Any]]
        else {
            Self.logger.error("couldn't read the OpenWebRX profiles")
            return
        }
        openWebRXProfiles = rows.compactMap { row in
            guard row.count == 3, let id = row[0] as? String,
                  let lo = (row[1] as? NSNumber)?.intValue, let hi = (row[2] as? NSNumber)?.intValue, lo <= hi
            else { return nil }
            return OpenWebRXProfile(id: id, range: lo...hi)
        }
        // A stock config's receiver name is the placeholder "[Callsign]".
        if let name = result[0] as? String, !name.isEmpty, !name.hasPrefix("[") {
            openWebRXReceiverName = name
        }
    }

    /// Tunes the page's demodulator to `frequencyHz` (and `modulation`, when
    /// given) — `DemodulatorPanel.setMode` and the demodulator's
    /// `set_offset_frequency`, what its mode buttons and frequency field do.
    /// A frequency outside the profile the SDR is on first switches to the
    /// first profile that covers it, the way choosing it in the page's list
    /// box does; the page then gets a new center frequency over its
    /// WebSocket and restarts its demodulator, so this retries (≤15 s)
    /// until the new profile is in place. While that restart is pending
    /// (`centerFreqTimeout`), `panel.center_freq` is still the old one, so
    /// the frequency can't be set against the wrong center.
    ///
    /// Note a profile switch retunes the SDR for every listener of that
    /// server — fine for the operator's own receiver, which is what this is
    /// for.
    private func retuneOpenWebRX(frequencyHz: Int, modulation: String?) async -> Bool {
        let profile = openWebRXProfiles.first { $0.range.contains(frequencyHz) }?.id
        let js = """
        var panel = $('#openwebrx-panel-receiver').demodulatorPanel();
        if (!panel || !panel.getDemodulator() || !panel.center_freq || panel.centerFreqTimeout) return 'waiting';
        if (Math.abs(f - panel.center_freq) > bandwidth / 2) {
          if (!profile) return 'outside';
          if (currentprofile.toString() !== profile) {
            $('#openwebrx-sdr-profiles-listbox').val(profile);
            sdr_profile_changed();
          }
          return 'waiting';
        }
        if (mod) panel.setMode(mod);
        panel.getDemodulator().set_offset_frequency(f - panel.center_freq);
        return 'done';
        """
        let arguments: [String: Any] = ["f": frequencyHz, "mod": modulation ?? NSNull(), "profile": profile ?? NSNull()]
        for _ in 0..<60 {
            if Task.isCancelled { return false }
            guard let webView else { return false }
            let result = try? await webView.callAsyncJavaScript(js, arguments: arguments, contentWorld: .page) as? String
            switch result {
            case "done": return true
            case "outside":
                Self.logger.notice("OpenWebRX has no profile covering \(frequencyHz) Hz")
                return false
            default: try? await Task.sleep(for: .milliseconds(250))
            }
        }
        Self.logger.error("OpenWebRX retune to \(frequencyHz) Hz timed out")
        return false
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
        case .openWebRX:
            js = Self.openWebRXTapScript
        }
        for _ in 0..<120 {
            if Task.isCancelled { return false }
            if let result = try? await webView?.evaluateJavaScript(js) as? [String], result.count == 2 {
                segmentStart = Date()
                let label = Self.label(kHz: result[0], mode: result[1]) ?? fallbackLabel
                segmentLabel = label.isEmpty ? platform.displayName : label + " " + platform.displayName
                if platform == .openWebRX { tapWriter = SDRAudioFileWriter(url: uniqueRecordingURL()) }
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
        case .openWebRX:
            return await stopOpenWebRXTap()
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

    // MARK: OpenWebRX recording (app-side tap)

    /// The message handler `KiwiWebView` registers for the tap's audio.
    static let tapMessageHandlerName = "ftx1SDRAudio"

    /// The file the current OpenWebRX recording goes to; nil while not
    /// recording one (late chunks after a stop are dropped).
    private var tapWriter: SDRAudioFileWriter?

    /// Installs the tap once the page's audio is running (its AudioWorklet
    /// node exists and the context isn't suspended) and returns the page's
    /// tuning for the file name, like the other platforms' start scripts;
    /// null until then. A `ScriptProcessorNode` on the page's own
    /// `AudioContext`, fed from `audioEngine.audioNode` — the decoded,
    /// resampled audio, before the page's volume/mute `gainNode`, so muting
    /// doesn't silence a recording (same as a Kiwi's). Its output is zeroed
    /// and only connected onward because WebKit doesn't run an unconnected
    /// processor; nothing extra is heard. Each 4096-frame block is posted as
    /// base64 little-endian Int16 with the context's rate. A tap left over
    /// from an earlier start is removed first.
    private static let openWebRXTapScript = """
    (function() {
      if (typeof audioEngine === 'undefined' || !audioEngine || !audioEngine.audioNode || !audioEngine.audioContext
          || audioEngine.audioContext.state !== 'running' || typeof $ !== 'function'
          || !window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.\(tapMessageHandlerName)) return null;
      var ctx = audioEngine.audioContext;
      if (window.ftx1RecorderTap) {
        try { audioEngine.audioNode.disconnect(window.ftx1RecorderTap); } catch (e) {}
        try { window.ftx1RecorderTap.disconnect(); } catch (e) {}
        window.ftx1RecorderTap = null;
      }
      var tap = ctx.createScriptProcessor(4096, 1, 1);
      tap.onaudioprocess = function(e) {
        e.outputBuffer.getChannelData(0).fill(0);
        var input = e.inputBuffer.getChannelData(0);
        var pcm = new Int16Array(input.length);
        for (var i = 0; i < input.length; i++) {
          var v = Math.max(-1, Math.min(1, input[i]));
          pcm[i] = v < 0 ? v * 0x8000 : v * 0x7fff;
        }
        var bytes = new Uint8Array(pcm.buffer), bin = '';
        for (var j = 0; j < bytes.length; j += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(j, j + 0x8000));
        window.webkit.messageHandlers.\(tapMessageHandlerName).postMessage({rate: ctx.sampleRate, pcm: btoa(bin)});
      };
      audioEngine.audioNode.connect(tap);
      tap.connect(ctx.destination);
      window.ftx1RecorderTap = tap;
      var panel = $('#openwebrx-panel-receiver').demodulatorPanel();
      var demod = panel && panel.getDemodulator();
      if (!demod || !panel.center_freq) return ['', ''];
      return [((panel.center_freq + demod.get_offset_frequency()) / 1000).toFixed(2), String(demod.get_modulation())];
    })()
    """

    /// A tap block from the page (`KiwiWebView`'s message handler).
    func receiveTapAudio(_ body: Any) {
        guard platform == .openWebRX, let tapWriter,
              let message = body as? [String: Any],
              let rate = (message["rate"] as? NSNumber)?.doubleValue,
              let encoded = message["pcm"] as? String,
              let pcm = Data(base64Encoded: encoded)
        else { return }
        tapWriter.append(pcm: pcm, sampleRate: rate)
    }

    /// Removes the tap (if the page is still there) and closes the file.
    private func stopOpenWebRXTap() async -> URL? {
        guard let writer = tapWriter else { return nil }
        tapWriter = nil
        _ = try? await webView?.evaluateJavaScript("""
        (function() {
          var tap = window.ftx1RecorderTap;
          if (!tap) return 'idle';
          try { audioEngine.audioNode.disconnect(tap); } catch (e) {}
          try { tap.disconnect(); } catch (e) {}
          tap.onaudioprocess = null;
          window.ftx1RecorderTap = null;
          return 'stopped';
        })()
        """)
        let saved = await writer.finish()
        Self.logger.info("recording saved: \(saved?.lastPathComponent ?? "nothing", privacy: .public)")
        return saved
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
    /// - OpenWebRX: its `toggleMute()` (its speaker button; the button's
    ///   `muted` class is its state). No URL parameter either; it waits for
    ///   the button and the audio engine to exist.
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
        case .openWebRX:
            js = """
            (function() {
              var bt = $('.openwebrx-mute-button');
              if (!bt.length || typeof toggleMute !== 'function' || typeof audioEngine === 'undefined' || !audioEngine) return 'waiting';
              if (bt.hasClass('muted') !== \(muted ? "true" : "false")) toggleMute();
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
    /// - OpenWebRX: its demodulator's offset plus the panel's center
    ///   frequency, and its modulation (a digimode reports the one under
    ///   it). nil while there's no demodulator or a profile switch is still
    ///   restarting it.
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
        case .openWebRX:
            js = """
            (function() {
              if (typeof $ !== 'function') return null;
              var panel = $('#openwebrx-panel-receiver').demodulatorPanel();
              var demod = panel && panel.getDemodulator();
              if (!demod || !panel.center_freq || panel.centerFreqTimeout) return null;
              return [panel.center_freq + demod.get_offset_frequency(), String(demod.get_modulation())];
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
        let url = uniqueRecordingURL()
        pendingDestination = url
        return url
    }

    private func uniqueRecordingURL() -> URL {
        var url = AudioRecorder.newRecordingURL(label: segmentLabel, date: segmentStart)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = AudioRecorder.newRecordingURL(label: "\(segmentLabel) \(n)", date: segmentStart)
            n += 1
        }
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
