import AppKit
import MailFeatures
import WebKit

@MainActor
public final class ConversationPrinter: NSObject, ConversationPrinting, WKNavigationDelegate {
    private let window: () -> NSWindow?
    private let webKit: ReaderWebKit
    private(set) var webView: WKWebView?
    private var pending: ConversationPrintDocument?
    var run: (NSPrintOperation, NSWindow?) -> Void = { operation, window in
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    public init(webKit: ReaderWebKit = .shared, window: @escaping () -> NSWindow?) {
        self.webKit = webKit
        self.window = window
    }

    public func print(_ document: ConversationPrintDocument) {
        guard let configuration = webKit.makeConfiguration(.blocked) else {
            NSSound.beep()
            return
        }
        let info = Self.printInfo()
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: max(width, 300), height: 800), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        pending = document
        view.loadHTMLString(document.html, baseURL: URL(string: "about:blank"))
    }

    static func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        return info
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy {
        navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, let document = pending else { return }
        pending = nil
        let operation = webView.printOperation(with: Self.printInfo())
        operation.jobTitle = document.title.isEmpty ? "Mail" : document.title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.view?.frame = webView.bounds
        run(operation, window())
    }
}
