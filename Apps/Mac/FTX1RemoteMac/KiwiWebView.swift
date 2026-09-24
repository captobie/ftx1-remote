import SwiftUI
import WebKit

/// `WKWebView` host for the WebSDR window. Loads whenever `request` changes
/// — retuning is a plain `load()` of a new `?f=` URL (a full Kiwi page
/// reload/reconnect). v1.1: retuning in place via JS injection into the
/// Kiwi page would avoid the reconnect gap, but is out of scope for v1.
struct KiwiWebView: NSViewRepresentable {
    let request: WebSDRFollowModel.PageRequest?
    var onLoadFailure: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLoadFailure = onLoadFailure
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

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: WebSDRFollowModel.PageRequest?
        var onLoadFailure: (String) -> Void = { _ in }

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
