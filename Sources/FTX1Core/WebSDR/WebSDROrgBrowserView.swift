#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import WebKit

/// The Stations sheet's WebSDR tab: websdr.org itself, in a web view.
///
/// **Why the site rather than a native table** (user decision,
/// 2026-09-25): websdr.org's station list comes from a JSON endpoint whose
/// response opens with a notice that the data "may not be re-used in
/// another website or automated system without prior permission" of its
/// maintainer (PA3FWM). So the app never fetches or parses that list — it
/// shows the site, which fetches it for the user like any browser would,
/// with its own map, table and band/region filters.
///
/// Picking: the site sends a station click to the station's URL as a
/// top-level navigation (its table cells set `top.location`, its links use
/// `target="_top"`). Any such navigation off the directory pages is
/// cancelled and handed to `onPick` instead — it only fills the host field
/// (`WebSDRFollowModel.selectWebSDR`), never connects. Links meant for a
/// new window, and mailto:, go to the default browser (`openExternally`).
@MainActor
public struct WebSDROrgBrowserView {
    public init(reloadID: Int, onPick: @escaping (URL) -> Void, onLoadFailure: @escaping (String?) -> Void = { _ in }) {
        self.reloadID = reloadID
        self.onPick = onPick
        self.onLoadFailure = onLoadFailure
    }

    public static let homeURL = URL(string: "http://websdr.org/")!

    /// Bumped to reload the site (the sheet's Reload button).
    public let reloadID: Int
    public let onPick: (URL) -> Void
    public var onLoadFailure: (String?) -> Void = { _ in }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.onPick = onPick
        coordinator.onLoadFailure = onLoadFailure
        coordinator.loadedReloadID = reloadID
        webView.load(URLRequest(url: Self.homeURL))
        return webView
    }

    func updateWebView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.onPick = onPick
        coordinator.onLoadFailure = onLoadFailure
        guard reloadID != coordinator.loadedReloadID else { return }
        coordinator.loadedReloadID = reloadID
        webView.load(URLRequest(url: Self.homeURL))
    }

    static func dismantleWebView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }

    /// websdr.org is a frameset around websdr.ewi.utwente.nl/org/ (port 80;
    /// the Twente receiver itself is on :8901, which is a station pick).
    public static func isDirectoryPage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        if host == "websdr.org" || host == "www.websdr.org" { return true }
        return host == "websdr.ewi.utwente.nl" && (url.port == nil || url.port == 80)
    }

    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onPick: (URL) -> Void = { _ in }
        var onLoadFailure: (String?) -> Void = { _ in }
        var loadedReloadID = 0

        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "mailto" {
                openExternally(url)
                return decisionHandler(.cancel)
            }
            // Frames (the site's own inner page, map tiles' iframes if any)
            // load normally; only a top-level navigation can be a pick.
            guard navigationAction.targetFrame?.isMainFrame ?? true,
                  scheme == "http" || scheme == "https",
                  !WebSDROrgBrowserView.isDirectoryPage(url)
            else { return decisionHandler(.allow) }
            if navigationAction.targetFrame == nil {
                openExternally(url)
            } else {
                onPick(url)
            }
            decisionHandler(.cancel)
        }

        /// `target="_blank"` links: open in the default browser, not here.
        public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { openExternally(url) }
            return nil
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadFailure(nil)
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            let code = (error as NSError).code
            // A cancelled pick (or a reload superseding a load) isn't a failure.
            if code == NSURLErrorCancelled || code == 102 /* WebKit: frame load interrupted */ { return }
            onLoadFailure(error.localizedDescription)
        }
    }
}

#if os(macOS)
extension WebSDROrgBrowserView: NSViewRepresentable {
    public func makeNSView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    public func updateNSView(_ webView: WKWebView, context: Context) {
        updateWebView(webView, coordinator: context.coordinator)
    }
    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        dismantleWebView(webView, coordinator: coordinator)
    }
}
#else
extension WebSDROrgBrowserView: UIViewRepresentable {
    public func makeUIView(context: Context) -> WKWebView { makeWebView(coordinator: context.coordinator) }
    public func updateUIView(_ webView: WKWebView, context: Context) {
        updateWebView(webView, coordinator: context.coordinator)
    }
    public static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        dismantleWebView(webView, coordinator: coordinator)
    }
}
#endif

/// A link meant for the default browser (Safari on the iPad).
@MainActor
func openExternally(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}
