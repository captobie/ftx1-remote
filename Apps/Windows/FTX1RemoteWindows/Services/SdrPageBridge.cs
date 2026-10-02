using System.Globalization;
using System.Text.Json;
using FTX1RemoteWindows.Models;
using Microsoft.Web.WebView2.Core;

namespace FTX1RemoteWindows.Services;

/// The one WebView2 environment every web view in this app shares (the
/// WebSDR page and the Stations window's websdr.org tab). WebView2 refuses
/// a second environment with different options on the same profile folder,
/// hence one shared instance.
/// - Profile in %LOCALAPPDATA%\FTX1RemoteWindows\WebView2 (an unpackaged
///   app's default is next to the .exe), persistent, so the Kiwi's own
///   localStorage — its saved name/callsign, `last_mode`, `last_zoom`,
///   volume — survives reloads and restarts, like WebKit's default store
///   on the Mac.
/// - Autoplay without a user gesture: Kiwis gate audio behind a "click to
///   start" overlay for the browser's autoplay policy; lifting it is what
///   lets a reload after a retune keep playing (the Mac's
///   mediaTypesRequiringUserActionForPlayback = []).
public static class SdrWebViewEnvironment
{
    private static Task<CoreWebView2Environment>? _environment;

    public static Task<CoreWebView2Environment> GetAsync() =>
        _environment ??= CoreWebView2Environment.CreateWithOptionsAsync(
            null,
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FTX1RemoteWindows", "WebView2"),
            new CoreWebView2EnvironmentOptions { AdditionalBrowserArguments = "--autoplay-policy=no-user-gesture-required" }).AsTask();
}

/// The WebSDR window's calls into the receiver page — the Mac's
/// SDRPageBridge, with the same JavaScript: only ever the page's *own*
/// functions and globals, nothing patched or injected. `Platform` picks
/// which page's (KiwiSDR or classic WebSDR); WebSdrFollowModel sets it for
/// each load, and DetectPlatformAsync corrects it once the page is up.
/// - its audio recorder, for Record (the WAVs it saves go to
///   Recordings.Directory);
/// - its mute, for the window's Mute button;
/// - its tuning globals, read-only, for click-to-tune (ReadTuningAsync);
/// - WebSDR only: its `setfreqtune()` to retune in place, and its
///   `bandinfo` for the station's receive ranges.
///
/// **Why the page's own recorder** (user decision on the Mac, 2026-09-24):
/// both pages have one. The Kiwi's is `toggle_or_set_rec(set)`, the same
/// function as its own "r" key; it records the decoded 12 kHz audio
/// *before* the page's volume/mute, and on stop "downloads" a WAV blob
/// through a hidden `<a download>` click. The WebSDR's is `record_click()`;
/// its stop only puts a "save" link in the page (`#reccontrol a`), which
/// StopAsync then clicks. Either way WebView2 raises DownloadStarting,
/// which WebSdrWindow hands to OnDownloadStarting here.
///
/// Stopping is asynchronous — the file exists only once the download
/// finishes — so StopAsync waits for it (with a timeout) before the caller
/// reloads, retunes or unloads the page, which would otherwise drop the
/// recording.
public sealed class SdrPageBridge
{
    public CoreWebView2? WebView { get; set; }

    /// Which page's functions to call. Set per load by WebSdrFollowModel;
    /// DetectPlatformAsync overwrites it with what the page actually is.
    public SdrPlatform Platform { get; set; } = SdrPlatform.KiwiSdr;

    /// Called when the page saves a recording the app didn't ask to stop —
    /// in practice the Kiwi's own `owrx_close_cb`, which stops (and saves)
    /// any recording when its audio connection closes (e.g. a time limit
    /// or the station kicking the listener). A WebSDR never saves by itself.
    public event Action<string?>? UnexpectedSave;

    /// Label and start time of the segment being recorded — the saved
    /// file's name, like the rig's own recordings plus "KiwiSDR"/"WebSDR".
    private string _segmentLabel = "";
    private DateTime _segmentStart = DateTime.Now;
    private TaskCompletionSource<string?>? _stopCompletion;
    private string? _pendingDestination;

    /// Runs `js` in the page; its JSON result, or null on failure, no page,
    /// or a JS null/undefined.
    private async Task<JsonElement?> EvalAsync(string js)
    {
        if (WebView is not { } webView)
        {
            return null;
        }
        try
        {
            var json = await webView.ExecuteScriptAsync(js);
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined
                ? null
                : doc.RootElement.Clone();
        }
        catch
        {
            // Page navigating away, web view closed, malformed reply.
            return null;
        }
    }

    private async Task<string?> EvalStringAsync(string js) =>
        await EvalAsync(js) is { ValueKind: JsonValueKind.String } e ? e.GetString() : null;

    // Platform

    /// What the loaded page is, from its own globals: a WebSDR page defines
    /// `setfreqtune()` and `bandinfo`, a Kiwi page the `kiwi` object. Sets
    /// Platform when recognized; null (and Platform untouched) otherwise.
    public async Task<SdrPlatform?> DetectPlatformAsync()
    {
        const string js = """
            (function() {
              if (typeof setfreqtune === 'function' && typeof bandinfo !== 'undefined') return 'webSDR';
              if (typeof kiwi === 'object') return 'kiwiSDR';
              return null;
            })()
            """;
        SdrPlatform? detected = await EvalStringAsync(js) switch
        {
            "webSDR" => SdrPlatform.WebSdr,
            "kiwiSDR" => SdrPlatform.KiwiSdr,
            _ => null,
        };
        if (detected is { } platform)
        {
            Platform = platform;
        }
        return detected;
    }

    /// A WebSDR's receive ranges, in Hz, from its own `bandinfo` (each band
    /// is `centerfreq ± samplerate/2`, in kHz). null on a Kiwi or on failure.
    public async Task<List<FrequencyRange>?> ReadBandsAsync()
    {
        if (Platform != SdrPlatform.WebSdr)
        {
            return null;
        }
        const string js = """
            (function() {
              if (typeof bandinfo === 'undefined') return null;
              return bandinfo.map(function(b) {
                return [Math.max(0, Math.round((b.centerfreq - b.samplerate / 2) * 1000)),
                        Math.round((b.centerfreq + b.samplerate / 2) * 1000)];
              });
            })()
            """;
        if (await EvalAsync(js) is not { ValueKind: JsonValueKind.Array } result)
        {
            return null;
        }
        var bands = new List<FrequencyRange>();
        foreach (var pair in result.EnumerateArray())
        {
            if (pair.ValueKind == JsonValueKind.Array && pair.GetArrayLength() == 2
                && pair[0].TryGetDouble(out var lo) && pair[1].TryGetDouble(out var hi) && lo <= hi)
            {
                bands.Add(new FrequencyRange((long)lo, (long)hi));
            }
        }
        return bands.Count > 0 ? bands : null;
    }

    /// The page's `<title>`, as a station name. Some WebSDR skins put the
    /// title in literal quotes, so those go too.
    public async Task<string?> PageTitleAsync() =>
        (await EvalStringAsync("document.title"))?.Trim().Trim('"', '\'').Trim();

    /// WebSDR only: retunes the loaded page through its own `setfreqtune()`
    /// — no reload, no reconnect. `value` is WebSdrUrlBuilder.TuneValue's
    /// "7074.00usb". Returns false if the page isn't a WebSDR page.
    public async Task<bool> RetuneInPlaceAsync(string value)
    {
        if (Platform != SdrPlatform.WebSdr)
        {
            return false;
        }
        var js = $$"""
            (function() {
              if (typeof setfreqtune !== 'function') return false;
              setfreqtune({{JsonSerializer.Serialize(value)}});
              return true;
            })()
            """;
        return await EvalAsync(js) is { ValueKind: JsonValueKind.True };
    }

    // Recording

    /// Starts the page's recording once its audio is actually running (it
    /// isn't until the page has connected — and, on a Kiwi that asks for a
    /// name first, until that's entered). Polls for up to a minute.
    /// Returns false if it never got going.
    ///
    /// The file is named from what the *page* is tuned to at that moment —
    /// the Kiwi's `freq_displayed_kHz_str_with_freq_offset`/`cur_mode`, the
    /// WebSDR's `nominalfreq()`/`mode` — so the name is right even with
    /// Follow off or after tuning in the page itself. `fallbackLabel` (the
    /// rig frequency the page was tuned for) is used only if those aren't
    /// readable.
    public async Task<bool> StartAsync(string fallbackLabel, CancellationToken token)
    {
        var js = Platform == SdrPlatform.KiwiSdr
            ? """
              (function() {
                if (typeof toggle_or_set_rec !== 'function' || typeof audio_running === 'undefined' || !audio_running) return null;
                if (!recording) toggle_or_set_rec(true);
                return [
                  typeof freq_displayed_kHz_str_with_freq_offset === 'string' ? freq_displayed_kHz_str_with_freq_offset : '',
                  typeof cur_mode === 'string' ? cur_mode : ''
                ];
              })()
              """
            // `record_click()` rather than `record_start()` so the page's
            // own start/stop button stays in step.
            : """
              (function() {
                var bt = document.getElementById('recbutton');
                if (!bt || typeof record_click !== 'function' || typeof allloadeddone === 'undefined'
                    || !allloadeddone || !soundapplet) return null;
                if (bt.innerHTML != 'stop') record_click();
                return [nominalfreq().toFixed(2), String(mode)];
              })()
              """;
        for (var i = 0; i < 120; i++)
        {
            if (token.IsCancellationRequested)
            {
                return false;
            }
            if (await EvalAsync(js) is { ValueKind: JsonValueKind.Array } result && result.GetArrayLength() == 2)
            {
                _segmentStart = DateTime.Now;
                var label = Label(result[0].GetString() ?? "", result[1].GetString() ?? "") ?? fallbackLabel;
                _segmentLabel = label.Length == 0 ? Platform.DisplayName() : label + " " + Platform.DisplayName();
                AppLog.Write($"websdr-recording: started: {_segmentLabel}");
                return true;
            }
            try
            {
                await Task.Delay(500, token);
            }
            catch (OperationCanceledException)
            {
                return false;
            }
        }
        AppLog.Write("websdr-recording: never started: page audio not running");
        return false;
    }

    /// "14047.55" + "cw" → "14.047.550 CW", the rig recordings' format.
    private static string? Label(string kHz, string mode)
    {
        if (!double.TryParse(kHz, NumberStyles.Float, CultureInfo.InvariantCulture, out var khz) || khz <= 0)
        {
            return null;
        }
        return Recordings.Label((long)Math.Round(khz * 1000), mode.ToUpperInvariant());
    }

    /// Stops the page's recording and waits (up to 5 s) for its WAV to land
    /// in Recordings. Returns the saved file, or null if nothing was being
    /// recorded, the page is gone, or the save didn't arrive in time.
    public async Task<string?> StopAsync()
    {
        if (WebView is null)
        {
            return null;
        }
        var js = Platform == SdrPlatform.KiwiSdr
            ? """
              (function() {
                if (typeof recording === 'undefined' || !recording) return 'idle';
                toggle_or_set_rec(false);
                return 'stopped';
              })()
              """
            : """
              (function() {
                var bt = document.getElementById('recbutton');
                if (!bt || bt.innerHTML != 'stop') return 'idle';
                record_click();
                var save = document.querySelector('#reccontrol a');
                if (!save) return 'idle';
                save.click();
                return 'stopped';
              })()
              """;
        // Armed before the script runs: the save can finish before
        // ExecuteScriptAsync's reply is back.
        var completion = new TaskCompletionSource<string?>();
        _stopCompletion = completion;
        if (await EvalStringAsync(js) != "stopped")
        {
            if (ReferenceEquals(_stopCompletion, completion))
            {
                _stopCompletion = null;
            }
            return null;
        }
        var finished = await Task.WhenAny(completion.Task, Task.Delay(TimeSpan.FromSeconds(5)));
        if (finished != completion.Task)
        {
            AppLog.Write("websdr-recording: save timed out");
            if (ReferenceEquals(_stopCompletion, completion))
            {
                _stopCompletion = null;
            }
            return null;
        }
        return completion.Task.Result;
    }

    // Mute

    /// Mutes/unmutes the page's audio through its own mute, then asserts
    /// it for up to 30 s until the page is ready to take it:
    /// - Kiwi: `toggle_or_set_mute` (its speaker icon). A freshly loaded
    ///   page applies its `mute=` URL parameter itself once the frequency is
    ///   set (`muted_until_freq_set`), which would override an earlier call,
    ///   so this waits for that.
    /// - WebSDR: its "mute" checkbox + `setmute()` (what its M key does).
    ///   There's no URL parameter; `bodyonload` resets the checkbox, and the
    ///   audio start applies whatever the checkbox says — so this waits for
    ///   `bodyonload` to have run (`did_read_settings`) and sets the
    ///   checkbox, calling `setmute()` too if audio is already running.
    public async Task SetPageMutedAsync(bool muted, CancellationToken token)
    {
        var flag = muted ? 1 : 0;
        var js = Platform == SdrPlatform.KiwiSdr
            ? $$"""
              (function() {
                if (typeof toggle_or_set_mute !== 'function' || typeof muted_until_freq_set === 'undefined' || muted_until_freq_set) return 'waiting';
                toggle_or_set_mute({{flag}});
                return 'done';
              })()
              """
            : $$"""
              (function() {
                var cb = document.getElementById('mutecheckbox');
                if (!cb || typeof setmute !== 'function' || typeof did_read_settings === 'undefined' || !did_read_settings) return 'waiting';
                cb.checked = {{(muted ? "true" : "false")}};
                if (soundapplet) setmute({{flag}});
                return 'done';
              })()
              """;
        for (var i = 0; i < 60; i++)
        {
            if (token.IsCancellationRequested)
            {
                return;
            }
            if (await EvalStringAsync(js) == "done")
            {
                return;
            }
            try
            {
                await Task.Delay(500, token);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    // Tuning (click-to-tune)

    /// What the page is tuned to, read from its own globals — the same ones
    /// its frequency field shows. Read-only; nothing in the page is called
    /// or patched.
    /// - Kiwi: `freq_displayed_Hz` plus `kiwi.freq_offset_Hz` (so a
    ///   converter-fed Kiwi reports the real RF frequency) and `cur_mode`.
    ///   null until the page has applied its initial frequency (the page
    ///   clears `muted_until_freq_set` right after that first tune).
    /// - WebSDR: `nominalfreq()` (kHz; the CW offset already accounted for)
    ///   and `mode`. null until `allloadeddone` (its audio start), by which
    ///   point `?tune=` has long been applied.
    public async Task<(long FrequencyHz, string Mode)?> ReadTuningAsync()
    {
        var js = Platform == SdrPlatform.KiwiSdr
            ? """
              (function() {
                if (typeof freq_displayed_Hz !== 'number' || typeof cur_mode !== 'string'
                    || typeof muted_until_freq_set === 'undefined' || muted_until_freq_set) return null;
                var offset = (typeof kiwi === 'object' && typeof kiwi.freq_offset_Hz === 'number') ? kiwi.freq_offset_Hz : 0;
                return [freq_displayed_Hz + offset, cur_mode];
              })()
              """
            : """
              (function() {
                if (typeof allloadeddone === 'undefined' || !allloadeddone || typeof nominalfreq !== 'function') return null;
                return [nominalfreq() * 1000, String(mode)];
              })()
              """;
        if (await EvalAsync(js) is { ValueKind: JsonValueKind.Array } result && result.GetArrayLength() == 2
            && result[0].TryGetDouble(out var hz) && hz > 0
            && result[1].ValueKind == JsonValueKind.String)
        {
            return ((long)Math.Round(hz), result[1].GetString()!);
        }
        return null;
    }

    // Download plumbing (WebSdrWindow's DownloadStarting handler)

    /// The page recorder's save: goes to Recordings, named like the app's
    /// own recordings (uniquified if the name is taken), with WebView2's own
    /// download UI suppressed. It's the only download these pages are
    /// expected to make.
    public void OnDownloadStarting(CoreWebView2DownloadStartingEventArgs args)
    {
        var path = Recordings.NewRecordingPath(_segmentLabel, _segmentStart);
        for (var n = 2; File.Exists(path); n++)
        {
            path = Recordings.NewRecordingPath($"{_segmentLabel} {n}", _segmentStart);
        }
        _pendingDestination = path;
        args.ResultFilePath = path;
        args.Handled = true;
        args.DownloadOperation.StateChanged += (operation, _) =>
        {
            switch (operation.State)
            {
                case CoreWebView2DownloadState.Completed:
                    DownloadFinished(success: true);
                    break;
                case CoreWebView2DownloadState.Interrupted:
                    DownloadFinished(success: false);
                    break;
            }
        };
    }

    private void DownloadFinished(bool success)
    {
        var saved = success ? _pendingDestination : null;
        _pendingDestination = null;
        // A stop with no audio captured still saves a bare 44-byte WAV
        // header — not worth keeping.
        if (saved is not null)
        {
            try
            {
                if (new FileInfo(saved).Length <= 44)
                {
                    File.Delete(saved);
                    saved = null;
                }
            }
            catch
            {
                // Unreadable size: keep whatever is there.
            }
        }
        AppLog.Write($"websdr-recording: saved: {(saved is null ? "nothing" : Path.GetFileName(saved))}");
        if (_stopCompletion is { } completion)
        {
            _stopCompletion = null;
            completion.TrySetResult(saved);
        }
        else
        {
            UnexpectedSave?.Invoke(saved);
        }
    }
}
