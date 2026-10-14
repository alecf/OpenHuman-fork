import AppKit
import WebKit

@MainActor
final class ReaderNavigationPolicy: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let decision = Self.decide(url: action.request.url, isLinkActivation: action.navigationType == .linkActivated,
                                   isMainFrame: action.targetFrame?.isMainFrame == true)
        if let url = decision.activate { (webView as? ReaderWebView)?.linkActivated(url, modifiers: action.modifierFlags) }
        return decision.allow && !action.shouldPerformDownload ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        // A response WebKit cannot show would become a download, so cancel it
        response.canShowMIMEType ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        (webView as? ReaderWebView)?.navigationCommitted(navigation)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        (webView as? ReaderWebView)?.contentProcessTerminated()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.cancel(nil)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.cancel(nil)
    }

    static func decide(url: URL?, isLinkActivation: Bool, isMainFrame: Bool) -> (allow: Bool, activate: URL?) {
        guard let url else { return (false, nil) }
        if isLinkActivation { return (false, url) }
        return (url.absoluteString == "about:blank" && isMainFrame, nil)
    }
}
