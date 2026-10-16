import MailRender
import SwiftUI
import UIKit
import WebKit

@MainActor
final class PhoneReaderWebKit {
    static let shared = PhoneReaderWebKit()

    static let ruleListIdentifier = "dev.openhuman.mail.ios.block-all-remote.v1"
    static let blockAllRemoteRules = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},\
    {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]
    """
    static let heightHandler = "ohHeight"
    static let measureScript = """
    (function () {
      function post() {
        var root = document.getElementById('oh-root');
        if (!root) { return; }
        window.webkit.messageHandlers.\(heightHandler).postMessage(Math.ceil(root.getBoundingClientRect().height));
      }
      document.addEventListener('DOMContentLoaded', function () {
        post();
        var root = document.getElementById('oh-root');
        if (window.ResizeObserver && root) { new ResizeObserver(post).observe(root); }
      });
      window.addEventListener('load', post);
    })();
    """
    static let viewport = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"

    private(set) var ruleList: WKContentRuleList?
    private(set) var isPrepared = false
    private var preparing: Task<Void, Never>?

    func prepare() async {
        if isPrepared { return }
        if let preparing { return await preparing.value }
        let task = Task { @MainActor in
            self.ruleList = try? await Self.compile()
            self.isPrepared = true
        }
        preparing = task
        await task.value
    }

    private static func compile() async throws -> WKContentRuleList? {
        guard let store = WKContentRuleListStore.default() else { return nil }
        if let cached = try? await store.contentRuleList(forIdentifier: ruleListIdentifier) { return cached }
        return try await store.compileContentRuleList(forIdentifier: ruleListIdentifier,
                                                      encodedContentRuleList: blockAllRemoteRules)
    }

    // Why: nil when the rule list did not compile, so the caller shows text instead of unblocked HTML
    func configuration(handler: any WKScriptMessageHandler) -> WKWebViewConfiguration? {
        guard let ruleList else { return nil }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.dataDetectorTypes = []
        config.allowsInlineMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        let content = config.userContentController
        content.add(ruleList)
        content.addUserScript(WKUserScript(source: Self.measureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(WeakScriptHandler(handler), name: Self.heightHandler)
        return config
    }

    // Why: page zoom keeps the layout width and clips lines; text-size-adjust scales the text and lets it wrap
    static func document(_ html: String, textScale: Int) -> String {
        let insert = viewport + "<style>html{-webkit-text-size-adjust:\(textScale)%;}</style>"
        let head = "<head>"
        guard let range = html.range(of: head) else { return insert + html }
        return html.replacingCharacters(in: range, with: head + insert)
    }
}

@MainActor
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

struct MessageWebBody: View {
    let rendered: RenderedMessage
    let readerTextSize: Double
    let follow: (URL) -> Void
    @State private var height: CGFloat = 1
    @State private var ready = PhoneReaderWebKit.shared.isPrepared
    @Environment(\.touch) private var theme

    var body: some View {
        Group {
            if !ready {
                ProgressView().tint(theme.textSecondary).frame(maxWidth: .infinity, minHeight: 44)
            } else if PhoneReaderWebKit.shared.ruleList == nil {
                Text(PlainTextExtractor.text(fromHTML: rendered.html))
                    .font(theme.body)
                    .foregroundStyle(theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MessageWebView(rendered: rendered, textScale: textScale, height: $height, follow: follow)
                    .frame(height: max(height, 1))
            }
        }
        .task {
            await PhoneReaderWebKit.shared.prepare()
            ready = true
        }
    }

    private var textScale: Int {
        let body = UIFont.preferredFont(forTextStyle: .body).pointSize
        return Int((max(1, body / CGFloat(max(readerTextSize, 1))) * 100).rounded())
    }
}

struct MessageWebView: UIViewRepresentable {
    let rendered: RenderedMessage
    let textScale: Int
    @Binding var height: CGFloat
    let follow: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let config = PhoneReaderWebKit.shared.configuration(handler: coordinator) ?? WKWebViewConfiguration()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 1), configuration: config)
        view.navigationDelegate = coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.follow = follow
        let height = $height
        coordinator.onHeight = { value in
            Task { @MainActor in if abs(height.wrappedValue - value) > 0.5 { height.wrappedValue = value } }
        }
        let document = PhoneReaderWebKit.document(rendered.html, textScale: textScale)
        guard coordinator.loaded != document else { return }
        coordinator.loaded = document
        view.loadHTMLString(document, baseURL: nil)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: PhoneReaderWebKit.heightHandler)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var follow: (URL) -> Void = { _ in }
        var onHeight: (CGFloat) -> Void = { _ in }
        var loaded: String?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? NSNumber else { return }
            onHeight(ceil(CGFloat(truncating: value)))
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if action.navigationType == .linkActivated {
                follow(url)
                return .cancel
            }
            let initial = url.absoluteString == "about:blank" && action.targetFrame?.isMainFrame == true
            return initial && !action.shouldPerformDownload ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            response.canShowMIMEType ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.cancel(nil)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let loaded else { return }
            webView.loadHTMLString(loaded, baseURL: nil)
        }
    }
}
