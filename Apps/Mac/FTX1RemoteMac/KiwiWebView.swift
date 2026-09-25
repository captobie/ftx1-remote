import SwiftUI
import WebKit

/// `WKWebView` host for the WebSDR window, KiwiSDR or classic WebSDR page.
/// Loads whenever `request` changes — for a Kiwi, retuning is a plain
/// `load()` of a new `?f=` URL (a full page reload/reconnect), skipped when
/// the page is already there (see `WebSDRFollowModel`'s click-to-tune). A
/// classic WebSDR is only loaded once per connection and then retuned in
/// place (`SDRPageBridge.retuneInPlace`), so `request` doesn't change.
struct KiwiWebView: NSViewRepresentable {
    let request: WebSDRFollowModel.PageRequest?
    /// Receives the page's own recorder's WAV saves (see
    /// `SDRPageBridge`) and gets this web view to run its commands.
    let pageBridge: SDRPageBridge
    var onLoadFailure: (String) -> Void = { _ in }
    /// A receiver page (not about:blank) finished loading — where a recording
    /// that spans a retune picks up again.
    var onPageLoaded: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(pageBridge: pageBridge) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Kiwis gate audio behind a "click to start" overlay for browser
        // autoplay policy; lifting WebKit's user-gesture requirement is what
        // lets a reload after a retune keep playing. The default (persistent)
        // data store keeps the Kiwi's own localStorage — its saved
        // name/callsign, `last_mode`, `last_zoom`, volume — across reloads.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        pageBridge.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLoadFailure = onLoadFailure
        context.coordinator.onPageLoaded = onPageLoaded
        guard request != context.coordinator.loaded else { return }
        context.coordinator.loaded = request
        if let request {
            webView.load(URLRequest(url: request.url))
        } else {
            Self.unloadKiwi(webView)
        }
    }

    /// Backstop for window close: even if SwiftUI (or WebKit's own process
    /// model) kept this web view alive a moment longer, the Kiwi page is
    /// unloaded now and can't keep a session or audio running.
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        unloadKiwi(webView)
    }

    /// Navigating away is what makes the Kiwi page close its WebSocket —
    /// `stopLoading()` alone doesn't touch an already-loaded page.
    private static func unloadKiwi(_ webView: WKWebView) {
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        var loaded: WebSDRFollowModel.PageRequest?
        var onLoadFailure: (String) -> Void = { _ in }
        var onPageLoaded: () -> Void = {}
        let pageBridge: SDRPageBridge

        init(pageBridge: SDRPageBridge) {
            self.pageBridge = pageBridge
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView.url?.scheme != "about" else { return }
            onPageLoaded()
        }

        // MARK: The page recorder's save

        /// The page saves a recording through an `<a download>` pointing at
        /// a blob (the Kiwi clicks its hidden one itself; a WebSDR's "save"
        /// link is clicked by `SDRPageBridge.stop`) — WebKit flags that as a
        /// download, which is the only download these pages are expected to
        /// make.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String) async -> URL? {
            pageBridge.destinationURL()
        }

        func downloadDidFinish(_ download: WKDownload) {
            pageBridge.downloadFinished(success: true)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            pageBridge.downloadFinished(success: false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        /// A retune superseding a still-loading page cancels it — that's
        /// expected, not a failure worth surfacing.
        private func report(_ error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            onLoadFailure(error.localizedDescription)
        }
    }
}
