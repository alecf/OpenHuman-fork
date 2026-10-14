import AppKit
import MailModel
import MailRender
import Network
import Testing
import WebKit
@testable import MailUIMac

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ReaderWebKitTests {
    init() async {
        await ReaderWebKit.shared.prepare()
    }

    @Test func ruleListsCompileAndConfigurationsAreLockedDown() throws {
        #expect(ReaderWebKit.shared.compileError == nil)
        #expect(ReaderWebKit.shared.imagesCompileError == nil)
        #expect(ReaderWebKit.shared.ruleList != nil)
        #expect(ReaderWebKit.shared.imagesRuleList != nil)
        for mode in [ReaderWebKit.Mode.blocked, .imagesAllowed] {
            let config = try #require(ReaderWebKit.shared.makeConfiguration(mode))
            #expect(!config.defaultWebpagePreferences.allowsContentJavaScript)
            #expect(!config.preferences.javaScriptCanOpenWindowsAutomatically)
            #expect(!config.websiteDataStore.isPersistent)
            #expect(config.suppressesIncrementalRendering)
            #expect(config.urlSchemeHandler(forURLScheme: "ohcid") != nil)
            #expect(config.userContentController.userScripts.count == 4)
            #expect(config.userContentController.userScripts.allSatisfy { $0.isForMainFrameOnly })
        }
        #expect(ReaderWebKit.shared.makeConfiguration(.blocked)?.userContentController
            !== ReaderWebKit.shared.makeConfiguration(.imagesAllowed)?.userContentController, "each mode has its own rules")
    }

    // DNS prefetching would tell a DNS server the mail was opened; WebKit has it off by default and this pins that
    @Test func dnsPrefetchingIsOff() throws {
        for mode in [ReaderWebKit.Mode.blocked, .imagesAllowed] {
            let preferences = try #require(ReaderWebKit.shared.makeConfiguration(mode)).preferences
            guard preferences.responds(to: NSSelectorFromString("_dnsPrefetchingEnabled")) else { continue }
            #expect((preferences.value(forKey: "_dnsPrefetchingEnabled") as? Bool) == false)
        }
    }

    @Test func imagesOnlyRulesBlockEverythingButImagesAndTrackers() throws {
        let data = Data(ReaderWebKit.imagesOnlyRules.utf8)
        let rules = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: [String: Any]]])
        let first = try #require(rules.first)
        let types = try #require(first["trigger"]?["resource-type"] as? [String])
        #expect(!types.contains("image"))
        for type in ["document", "style-sheet", "script", "font", "media", "fetch", "ping", "raw", "websocket", "other"] {
            #expect(types.contains(type), "\(type)")
        }
        #expect(rules.count == 2 + TrackerList.hosts.count)
        #expect(ReaderWebKit.imagesRuleListIdentifier.contains("t\(TrackerList.version)"))
    }

    @Test func aBrokenRuleListFailsClosed() async throws {
        let broken = ReaderWebKit(blockRules: "[{\"trigger\":{}}]", blockIdentifier: "dev.openhuman.mail.tests.broken.\(UUID().uuidString)",
                                  imagesRules: "not json", imagesIdentifier: "dev.openhuman.mail.tests.broken-i.\(UUID().uuidString)")
        await broken.prepare()
        #expect(broken.isPrepared)
        #expect(broken.compileError != nil)
        #expect(broken.makeConfiguration(.blocked) == nil)
        #expect(broken.makeConfiguration(.imagesAllowed) == nil)
        guard case .html(let rendered) = MessageRenderer().render(MessageContent(html: "<p>x</p>", text: nil)) else {
            Issue.record("expected html"); return
        }
        #expect(ReaderWebView.make(for: rendered, width: 600, webKit: broken) == nil)
        #expect(ReaderWebView.make(for: rendered, width: 600, webKit: broken, imagesAllowed: true) == nil)
    }

    @Test func appWorldScriptRunsWithContentJavaScriptOff() async throws {
        let html = "<p style='margin:40px 0'>first</p><p style='margin:40px 0'>last</p>"
        guard case .html(let rendered) = MessageRenderer().render(MessageContent(html: html, text: nil)) else {
            Issue.record("expected html"); return
        }
        let view = try #require(ReaderWebView.make(for: rendered, width: 600))
        defer { ReaderWebKit.shared.pool.recycle(view) }
        #expect(view.alphaValue == 0, "attached invisible until its height is final")
        await Reports.heights(of: view).wait { view.isShown }
        let height = try #require(view.measuredHeight)
        #expect(height > 140 && height < 200, "height \(height)")
        #expect(view.alphaValue == 1)
    }

    @Test func heightTracksContentNotTheViewport() async throws {
        guard case .html(let rendered) = MessageRenderer().render(MessageContent(html: "<p>short</p>", text: nil)) else {
            Issue.record("expected html"); return
        }
        let view = try #require(ReaderWebView.make(for: rendered, width: 600))
        defer { ReaderWebKit.shared.pool.recycle(view) }
        view.setFrameSize(NSSize(width: 600, height: 900))
        await Reports.heights(of: view).wait { view.isShown }
        #expect((view.measuredHeight ?? 0) < 60, "documentElement.scrollHeight would report 900")
    }

    @Test func thePageLaysOutAtTheViewsFullWidthWithoutAScrollbar() async throws {
        let html = String(repeating: "<p>A paragraph that makes the page taller than the view it starts in.</p>", count: 8)
        guard case .html(let rendered) = MessageRenderer().render(MessageContent(html: html, text: nil)) else {
            Issue.record("expected html"); return
        }
        let view = try #require(ReaderWebView.make(for: rendered, width: 600))
        defer { ReaderWebKit.shared.pool.recycle(view) }
        view.setFrameSize(NSSize(width: 600, height: 40))
        await Reports.heights(of: view).wait { view.measuredHeight != nil }
        let width = try await view.evaluateJavaScript("""
            document.head.insertAdjacentHTML('beforeend', '<style>::-webkit-scrollbar { width: 17px; }</style>');
            var page = document.documentElement;
            page.style.overflowY = 'hidden';
            page.clientWidth;
            page.style.overflowY = '';
            page.clientWidth
            """, in: nil, contentWorld: .defaultClient) as? Int
        #expect(width == 600, "page width \(String(describing: width))")
    }

    @Test func contentScriptsDoNotRun() async throws {
        let config = try #require(ReaderWebKit.shared.makeConfiguration())
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let delegate = LoadDelegate()
        view.navigationDelegate = delegate
        view.loadHTMLString("""
            <html><head><script>document.title = 'pwned'</script></head>
            <body><img src="x" onerror="document.title = 'pwned2'"><div id="oh-root">x</div></body></html>
            """, baseURL: URL(string: "about:blank"))
        try await until { delegate.finished }
        let title = try await view.evaluateJavaScript("document.title", in: nil, contentWorld: .defaultClient) as? String
        #expect(title == "")
    }

    @Test func remoteLoadsAreBlockedByTheRuleList() async throws {
        let controlServer = try await HitServer.start()
        defer { controlServer.stop() }
        let open = WKWebViewConfiguration()
        open.websiteDataStore = .nonPersistent()
        open.defaultWebpagePreferences.allowsContentJavaScript = false
        let control = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: open)
        let controlDelegate = LoadDelegate()
        control.navigationDelegate = controlDelegate
        control.loadHTMLString(HitServer.hostileDocument(port: controlServer.port), baseURL: URL(string: "about:blank"))
        try await until(timeout: .seconds(60)) { controlServer.hits.count >= 3 }

        for (mode, document) in [(ReaderWebKit.Mode.blocked, HitServer.hostileDocument), (.imagesAllowed, HitServer.nonImageDocument)] {
            let server = try await HitServer.start()
            defer { server.stop() }
            let config = try #require(ReaderWebKit.shared.makeConfiguration(mode))
            let reader = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
            let delegate = LoadDelegate()
            reader.navigationDelegate = delegate
            reader.loadHTMLString(document(server.port), baseURL: URL(string: "about:blank"))
            try await until { delegate.finished }
            try await server.fence()
            #expect(server.hits.isEmpty, "\(mode): requests leaked: \(server.hits)")
        }
    }

    @Test func sanitizedHostileMessageMakesNoRequests() async throws {
        let server = try await HitServer.start()
        defer { server.stop() }
        guard case .html(let rendered) = MessageRenderer().render(
            MessageContent(html: HitServer.hostileDocument(port: server.port), text: nil)) else {
            Issue.record("expected html"); return
        }
        #expect(rendered.hasRemoteContent)
        let view = try #require(ReaderWebView.make(for: rendered, width: 600))
        defer { ReaderWebKit.shared.pool.recycle(view) }
        await Reports.heights(of: view).wait { view.isShown }
        try await until { (try? await view.evaluateJavaScript("document.readyState", in: nil, contentWorld: .defaultClient) as? String) == "complete" }
        try await server.fence()
        #expect(server.hits.isEmpty, "requests leaked: \(server.hits)")
    }

    @Test func navigationPolicyAllowsOnlyTheInitialLoadAndHandsLinksToTheReader() {
        let decide = ReaderNavigationPolicy.decide
        let https = URL(string: "https://example.com/a")!
        #expect(decide(https, true, true) == (false, https))
        let mailto = URL(string: "mailto:a@example.com")!
        #expect(decide(mailto, true, true) == (false, mailto))
        let script = URL(string: "javascript:alert(1)")!
        #expect(decide(script, true, true) == (false, script), "the reader resolves it to 'not supported'")
        #expect(decide(URL(string: "https://evil.example/"), false, true) == (false, nil))
        #expect(decide(URL(string: "about:blank"), false, false) == (false, nil))
        #expect(decide(URL(string: "about:blank"), false, true) == (true, nil))
        #expect(decide(nil, false, true) == (false, nil))
    }

    @Test func poolReusesViewsAndResetsThem() async throws {
        let webKit = ReaderWebKit()
        await webKit.prepare()
        guard case .html(let one) = MessageRenderer().render(MessageContent(html: "<p>one</p>", text: nil)),
              case .html(let two) = MessageRenderer().render(MessageContent(html: "<p>two</p><p>two</p>", text: nil)) else {
            Issue.record("expected html"); return
        }
        let first = try #require(ReaderWebView.make(for: one, width: 600, webKit: webKit))
        await Reports.heights(of: first).wait { first.isShown }
        webKit.pool.recycle(first)
        #expect(first.rendered == nil && first.alphaValue == 0 && first.owner == nil)
        let again = try #require(ReaderWebView.make(for: two, width: 600, webKit: webKit))
        #expect(again === first, "the idle view is reused")
        #expect(again.alphaValue == 0)
        await Reports.heights(of: again).wait { again.isShown }
        #expect(again.rendered?.contentHash == two.contentHash)
        let images = try #require(ReaderWebView.make(for: two, width: 600, webKit: webKit, imagesAllowed: true))
        #expect(images.mode == .imagesAllowed && images !== again)
        #expect(webKit.pool.created == 2)
        for _ in 0..<10 {
            webKit.pool.recycle(try #require(ReaderWebView.make(for: one, width: 600, webKit: webKit)))
        }
        webKit.pool.recycle(again)
        webKit.pool.recycle(images)
        #expect(webKit.pool.idle.count <= ReaderWebViewPool.capacity)
    }

    @Test func linkHoverIsReportedFromTheAppWorld() async throws {
        let html = """
        <p><a href="https://login.evil.example/x">https://bank.example/</a> and <a href="https://example.com/doc">the doc</a></p>
        """
        guard case .html(let rendered) = MessageRenderer().render(MessageContent(html: html, text: nil)) else {
            Issue.record("expected html"); return
        }
        let view = try #require(ReaderWebView.make(for: rendered, width: 600))
        defer { ReaderWebKit.shared.pool.recycle(view) }
        let owner = RecordingOwner()
        view.owner = owner
        let hovers = Reports()
        owner.onEvent = hovers.arrived
        await Reports.heights(of: view).wait { view.isShown }
        let hover = "document.querySelectorAll('a')[%d].dispatchEvent(new MouseEvent('mouseover', {bubbles: true})); 0"
        _ = try await view.evaluateJavaScript(String(format: hover, 0), in: nil, contentWorld: .defaultClient)
        await hovers.wait { owner.hovered.last??.url.host == "login.evil.example" }
        let link = try #require(owner.hovered.last ?? nil)
        #expect(link.rect.map { $0.width > 0 && $0.height > 0 } == true)
        #expect(rendered.suspiciousLink(for: link.url)?.displayedDestination == "bank.example")
        _ = try await view.evaluateJavaScript(String(format: hover, 1), in: nil, contentWorld: .defaultClient)
        await hovers.wait { owner.hovered.last??.url.host == "example.com" }
        #expect(rendered.suspiciousLink(for: URL(string: "https://example.com/doc")!) == nil)
        _ = try await view.evaluateJavaScript("document.body.dispatchEvent(new MouseEvent('mouseover', {bubbles: true})); 0",
                                              in: nil, contentWorld: .defaultClient)
        await hovers.wait { owner.hovered.last.map { $0 == nil } == true }
    }

    @Test func heightMessagesAreValidated() {
        #expect(HeightMessageRouter.parse([NSNumber(value: 120), NSNumber(value: 1)]).map { [$0.0] } == [120])
        #expect(HeightMessageRouter.parse([NSNumber(value: 120), NSNumber(value: 1)])?.1 == true)
        #expect(HeightMessageRouter.parse([NSNumber(value: 120), NSNumber(value: 0)])?.1 == false)
        #expect(HeightMessageRouter.parse(NSNumber(value: 80))?.1 == false)
        #expect(HeightMessageRouter.parse([NSNumber(value: Double.nan), NSNumber(value: 1)]) == nil)
        #expect(HeightMessageRouter.parse([NSNumber(value: 2_000_000)]) == nil)
        #expect(HeightMessageRouter.parse([NSNumber(value: -1)]) == nil)
        #expect(HeightMessageRouter.parse("120") == nil)
        #expect(HeightMessageRouter.parse([NSNumber(value: 120), NSNumber(value: 1), NSNumber(value: 640)])?.2 == 640)
        #expect(HeightMessageRouter.parse([NSNumber(value: 120), NSNumber(value: 1)])?.2 == nil)
        #expect(HeightMessageRouter.parse([NSNumber(value: 120), NSNumber(value: 1), NSNumber(value: Double.nan)]) == nil)
        #expect(HeightMessageRouter.parse([NSNumber(value: 120), NSNumber(value: 1), NSNumber(value: -1)]) == nil)
        #expect(HeightMessageRouter.parse([NSNumber(value: 1), NSNumber(value: 1), NSNumber(value: 1), NSNumber(value: 1)]) == nil)
    }

    @Test func aHeightMeasuredAtAnotherWidthIsNeitherShownNorRemembered() async throws {
        let webKit = TestWebKit.noNetwork
        await webKit.prepare()
        guard case .html(let rendered) = MessageRenderer().render(
            MessageContent(html: "<p>Reminder: the reading group meets Thursday at 7 pm in room 12.</p>", text: nil)) else {
            Issue.record("not rendered as HTML")
            return
        }
        let view = try #require(ReaderWebView.make(for: rendered, width: 700, webKit: webKit))
        view.stopLoading()
        view.navigationCommitted(view.currentNavigation)
        let width = view.bounds.width
        var reports: [CGFloat] = []
        view.onHeightChange = { reports.append($0) }

        view.contentHeightDidChange(128, loaded: true, width: 300)
        #expect(!view.isShown && view.alphaValue == 0, "not shown at a height it will not keep")
        #expect(ReaderWebView.cachedHeight(hash: rendered.contentHash, width: width) == nil, "not remembered either")

        view.contentHeightDidChange(106, loaded: true, width: width)
        #expect(view.isShown && view.alphaValue == 1)
        #expect(view.measuredHeight == 106)
        #expect(ReaderWebView.cachedHeight(hash: rendered.contentHash, width: width) == 106)
        #expect(reports == [128, 106])
        webKit.pool.recycle(view)
    }

    @Test func aHeightReportedBeforeTheBodysLayoutWaitsForIt() async throws {
        let webKit = TestWebKit.noNetwork
        await webKit.prepare()
        guard case .html(let rendered) = MessageRenderer().render(
            MessageContent(html: "<p>This week: chapters 4 and 5, and the reading list for next month.</p>", text: nil)) else {
            Issue.record("not rendered as HTML")
            return
        }
        let view = try #require(ReaderWebView.make(for: rendered, width: 300, webKit: webKit))
        view.awaitsLayoutWidth = true
        view.stopLoading()
        view.navigationCommitted(view.currentNavigation)

        view.contentHeightDidChange(150, loaded: true, width: 300)
        #expect(!view.isShown, "waits for the body's layout")
        view.setFrameSize(NSSize(width: 700, height: view.frame.height))
        view.layoutWidthSettled()
        #expect(!view.isShown, "measured at the guess, not at the width it keeps")
        view.contentHeightDidChange(106, loaded: true, width: 700)
        #expect(view.isShown && view.measuredHeight == 106)

        let again = try #require(ReaderWebView.make(for: rendered, width: 640, webKit: webKit))
        again.awaitsLayoutWidth = true
        again.stopLoading()
        again.navigationCommitted(again.currentNavigation)
        again.contentHeightDidChange(110, loaded: true, width: 640)
        #expect(!again.isShown)
        again.layoutWidthSettled()
        #expect(again.isShown && again.measuredHeight == 110)
        webKit.pool.recycle(view)
        webKit.pool.recycle(again)
    }

    @Test func hoverMessagesAreValidated() {
        #expect(LinkMessageRouter.parse(["href": "javascript:alert(1)", "x": 1, "y": 1, "w": 1, "h": 1]) == nil)
        #expect(LinkMessageRouter.parse(["href": "https://example.com", "x": Double.infinity, "y": 1, "w": 1, "h": 1])?.rect == nil)
        #expect(LinkMessageRouter.parse(["href": String(repeating: "a", count: 9_000)]) == nil)
        #expect(LinkMessageRouter.parse("not a dictionary") == nil)
        #expect(LinkMessageRouter.parse(["href": "mailto:a@example.com", "x": 1, "y": 2, "w": 3, "h": 4])?.rect
            == CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    @Test func contextMenuKeepsOnlyReadingItems() {
        let menu = NSMenu()
        for id in ["WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierCopyLink",
                   "WKMenuItemIdentifierReload", "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierCopy",
                   "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierShareMenu"] {
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: "Unknown", action: nil, keyEquivalent: ""))
        ReaderWebView.filterContextMenu(menu)
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            == ["WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp"])
        #expect(menu.items.first?.isSeparatorItem == false && menu.items.last?.isSeparatorItem == false)
        #expect(!zip(menu.items, menu.items.dropFirst()).contains { $0.isSeparatorItem && $1.isSeparatorItem })
    }

    @Test func cidImagesAreServedFromTheMessagesOwnPartsOnly() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reader-cid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("chart.png")
        try TestImages.png(width: 30, height: 20).write(to: png)
        let fake = folder.appendingPathComponent("fake.png")
        try Data("<svg onload=alert(1)>".utf8).write(to: fake)
        let html = """
        <p><img id="a" src="cid:chart-1@fake.example"><img id="b" src="cid:other@fake.example"><img id="c" src="cid:svg@fake.example"></p>
        """
        guard case .html(let rendered) = MessageRenderer().render(MessageContent(html: html, text: nil)) else {
            Issue.record("expected html"); return
        }
        #expect(rendered.inlineContentIDs.contains("chart-1@fake.example"))
        let parts = [
            AttachmentInfo(id: 1, filename: "chart.png", mimeType: "image/png", size: 100, contentID: "<chart-1@fake.example>", isInline: true),
            AttachmentInfo(id: 3, filename: "x.png", mimeType: "image/png", size: 10, contentID: "svg@fake.example", isInline: true),
        ]
        let view = try #require(ReaderWebView.make(for: rendered, width: 600))
        defer { ReaderWebKit.shared.pool.recycle(view) }
        view.inlineParts = InlinePartSource(attachments: parts) { attachment in attachment.id == 1 ? png : fake }
        await Reports.heights(of: view).wait { view.isShown }
        func width(_ id: String) async -> Int {
            (try? await view.evaluateJavaScript("document.getElementById('\(id)').naturalWidth", in: nil,
                                                contentWorld: .defaultClient) as? Int) ?? -1
        }
        #expect(await width("a") == 30)
        #expect(await width("b") == 0, "another message's part is not served")
        #expect(await width("c") == 0, "only real raster images are served")
        #expect(CIDSchemeHandler.imageType(of: Data("GIF89a....".utf8)) == "image/gif")
        #expect(CIDSchemeHandler.imageType(of: Data("<svg".utf8)) == nil)
    }

    @Test func textZoomScalesTheMeasuredHeight() async throws {
        let html = String(repeating: "<p>A line of text that fits the column at the default size but wraps once it is zoomed in by half again.</p>", count: 8)
        guard case .html(let rendered) = MessageRenderer().render(MessageContent(html: html, text: nil)) else {
            Issue.record("expected html"); return
        }
        let view = try #require(ReaderWebView.make(for: rendered, width: 600))
        defer { ReaderWebKit.shared.pool.recycle(view) }
        let window = TestWindows.window(view, size: NSSize(width: 600, height: 400))
        defer { window.close() }
        view.widthAnchor.constraint(equalToConstant: 600).isActive = true
        let heights = Reports.heights(of: view)
        await heights.wait { view.isShown }
        let base = try #require(view.measuredHeight)
        view.setZoom(1.5)
        await heights.wait { (view.measuredHeight ?? 0) > base * 1.3 }
        view.setZoom(1)
        await heights.wait { abs((view.measuredHeight ?? 0) - base) <= 2 }
        guard case .html(let short) = MessageRenderer().render(MessageContent(html: "<p>Short.</p>", text: nil)) else { return }
        let small = try #require(ReaderWebView.make(for: short, width: 600))
        defer { ReaderWebKit.shared.pool.recycle(small) }
        await Reports.heights(of: small).wait { small.isShown }
        let smallBase = try #require(small.measuredHeight)
        small.setZoom(2)
        #expect(small.measuredHeight == (smallBase * 2).rounded(.up))
    }

    @Test func quotesToggleFromTheAppWorld() async throws {
        let html = """
        <div>Reply text.</div><div class="gmail_quote"><div>On Tue, Sam wrote:</div>
        <blockquote class="gmail_quote">\(String(repeating: "<p>Quoted line of an older message.</p>", count: 10))</blockquote></div>
        """
        guard case .html(let rendered) = MessageRenderer().render(MessageContent(html: html, text: nil)) else {
            Issue.record("expected html"); return
        }
        #expect(rendered.hasQuotedText)
        let view = try #require(ReaderWebView.make(for: rendered, width: 600))
        defer { ReaderWebKit.shared.pool.recycle(view) }
        let heights = Reports.heights(of: view)
        await heights.wait { view.isShown }
        let folded = try #require(view.measuredHeight)
        await view.setQuotesExpanded(true)
        await heights.wait { (view.measuredHeight ?? 0) > folded + 100 }
        await view.setQuotesExpanded(false)
        await heights.wait { view.measuredHeight == folded }
    }

    @Test func aMessageWithASignatureAndQuotedTextHasOneFoldControl() async throws {
        let html = """
        <div dir="ltr">Reply text.</div><br clear="all"><div><br></div>-- <br>\
        <div dir="ltr" class="gmail_signature"><div>Ana Costa</div><div>Community events</div></div>
        <div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Tue, Sam wrote:<br></div>
        <blockquote class="gmail_quote">\(String(repeating: "<p>Quoted line of an older message.</p>", count: 6))</blockquote></div>
        """
        guard case .html(let rendered) = MessageRenderer().render(MessageContent(html: html, text: nil)) else {
            Issue.record("expected html"); return
        }
        #expect(rendered.html.components(separatedBy: "<details class=\"oh-quoted").count - 1 == 2, "two folds")
        let view = try #require(ReaderWebView.make(for: rendered, width: 600))
        defer { ReaderWebKit.shared.pool.recycle(view) }
        var toggles = 0
        let clicks = Reports()
        view.onToggleQuotes = { toggles += 1; clicks.arrived() }
        await Reports.heights(of: view).wait { view.isShown }
        func js(_ script: String) async -> Any? { try? await view.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) }
        let summaries = "document.querySelectorAll('details.oh-quoted > summary')"
        #expect(await js("\(summaries).length") as? Int == 2)
        #expect(await js("Array.prototype.filter.call(\(summaries), function (s) { return s.offsetHeight > 0; }).length") as? Int == 1,
                "one control")
        #expect(await js("\(summaries)[0].title") as? String == "Show quoted text  .")
        _ = await js("\(summaries)[0].click(); 0")
        await clicks.wait { toggles == 1 }
        let anyOpen = "Array.prototype.some.call(document.querySelectorAll('details.oh-quoted'), function (d) { return d.open; })"
        #expect(await js(anyOpen) as? Bool == false)
        await view.setQuotesExpanded(true)
        #expect(await js("Array.prototype.every.call(document.querySelectorAll('details.oh-quoted'), function (d) { return d.open; })") as? Bool == true)
        #expect(await js("\(summaries)[0].title") as? String == "Hide quoted text  .")
        await view.setQuotesExpanded(false)
        #expect(await js(anyOpen) as? Bool == false)
    }

    @Test func findSelectsMatchesInOrder() async throws {
        let html = "<p>alpha needle</p><p>beta</p><p>gamma needle</p>"
        guard case .html(let rendered) = MessageRenderer().render(MessageContent(html: html, text: nil)) else {
            Issue.record("expected html"); return
        }
        let view = try #require(ReaderWebView.make(for: rendered, width: 600))
        defer { ReaderWebKit.shared.pool.recycle(view) }
        let window = TestWindows.window(view, size: NSSize(width: 600, height: 400))
        defer { window.close() }
        view.widthAnchor.constraint(equalToConstant: 600).isActive = true
        await Reports.heights(of: view).wait { view.isShown }
        try await until {
            let width = try? await view.evaluateJavaScript("window.innerWidth", in: nil, contentWorld: .defaultClient) as? NSNumber
            return width?.intValue == 600
        }
        #expect(await view.findNext("needle", backwards: false))
        let first = try #require(await stableSelectionRect(view))
        #expect(await view.findNext("needle", backwards: false))
        let second = try #require(await stableSelectionRect(view))
        #expect(second.minY > first.minY)
        #expect(await view.findNext("needle", backwards: false) == false, "no wrapping inside one message")
        await view.clearSelection()
        #expect(await view.findNext("NEEDLE", backwards: false), "case-insensitive")
        #expect(await view.findNext("absent", backwards: false) == false)
    }
}

@MainActor
func stableSelectionRect(_ view: ReaderWebView, timeout: Duration = .seconds(60)) async throws -> CGRect? {
    var last: CGRect?
    var result: CGRect?
    try await until(timeout: timeout) {
        guard let rect = await view.selectionRect() else { last = nil; return false }
        defer { last = rect }
        if rect == last { result = rect; return true }
        return false
    }
    return result
}

@MainActor
func until(timeout: Duration = .seconds(60), _ condition: @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !(await condition()) {
        if clock.now > deadline { throw TimeoutError() }
        try await Task.sleep(for: .milliseconds(20))
    }
}

struct TimeoutError: Error {}

@MainActor
final class Reports {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrived() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    func wait(until condition: () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    static func heights(of view: ReaderWebView) -> Reports {
        let reports = Reports()
        let previous = view.onHeightChange
        view.onHeightChange = { height in
            previous?(height)
            reports.arrived()
        }
        return reports
    }
}

@MainActor
final class LoadDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}

@MainActor
final class RecordingOwner: ReaderWebViewOwner {
    var hovered: [ReaderWebView.HoveredLink?] = []
    var activated: [URL] = []
    var keys: [String] = []
    var onEvent: (() -> Void)?

    func readerWebView(_ view: ReaderWebView, hovered link: ReaderWebView.HoveredLink?) {
        hovered.append(link)
        onEvent?()
    }
    func readerWebView(_ view: ReaderWebView, activated url: URL, modifiers: NSEvent.ModifierFlags) {
        activated.append(url)
        onEvent?()
    }
    func readerWebView(_ view: ReaderWebView, keyDown event: NSEvent) -> Bool {
        keys.append(event.charactersIgnoringModifiers ?? "")
        return true
    }
    func readerWebViewFind(_ view: ReaderWebView) {}
}

@MainActor
enum TestWindows {
    static func window(_ view: NSView, size: NSSize = NSSize(width: 1000, height: 700)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        container.addSubview(view)
        if !view.translatesAutoresizingMaskIntoConstraints {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
            ])
        }
        window.orderFrontRegardless()
        return window
    }
}

enum TestImages {
    static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<width { for y in 0..<height { rep.setColor(.systemBlue, atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])!
    }
}

final class HitServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var recorded: [String] = []
    private var fences = 0

    var hits: [String] { lock.withLock { recorded.filter { !$0.contains("/__fence") } } }
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> HitServer {
        let server = try HitServer()
        server.listener.newConnectionHandler = { [server] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? "?"
                server.record(line)
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = AsyncStream<Void> { continuation in
            server.listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.yield(); continuation.finish() }
            }
        }
        server.listener.start(queue: .global())
        for await _ in ready { break }
        return server
    }

    func record(_ line: String) { lock.withLock { recorded.append(line) } }
    func stop() { listener.cancel() }

    @MainActor
    func fence() async throws {
        let n = lock.withLock { fences += 1; return fences }
        let path = "/__fence\(n)"
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 10
        _ = try? await URLSession(configuration: .ephemeral).data(for: request)
        try await until { self.lock.withLock { self.recorded.contains { $0.contains(path) } } }
    }

    static func hostileDocument(port: UInt16) -> String {
        let base = "http://127.0.0.1:\(port)"
        return """
        <!doctype html><html><head>
        <meta http-equiv="refresh" content="0;url=\(base)/meta-refresh">
        <link rel="stylesheet" href="\(base)/link.css"><link rel="prefetch" href="\(base)/prefetch">
        <style>@import url("\(base)/import.css"); body { background-image: url("\(base)/bg.png"); }
        @font-face { font-family: X; src: url("\(base)/font.woff"); } p { font-family: X; }</style>
        <script src="\(base)/script.js"></script>
        </head><body><div id="oh-root">
        <img src="\(base)/img.png" width="40" height="40"><img src="\(base)/pixel.gif" width="1" height="1">
        <picture><source srcset="\(base)/srcset.png"><img src="\(base)/picture.png"></picture>
        <iframe src="\(base)/iframe"></iframe><object data="\(base)/object"></object><embed src="\(base)/embed">
        <video src="\(base)/video.mp4" autoplay></video><audio src="\(base)/audio.mp3" autoplay></audio>
        <table background="\(base)/table.png"><tr><td>cell</td></tr></table>
        <p>text</p></div></body></html>
        """
    }

    static func nonImageDocument(port: UInt16) -> String {
        let base = "http://127.0.0.1:\(port)"
        return """
        <!doctype html><html><head>
        <meta http-equiv="refresh" content="0;url=\(base)/meta-refresh">
        <link rel="stylesheet" href="\(base)/link.css"><link rel="prefetch" href="\(base)/prefetch">
        <style>@import url("\(base)/import.css");
        @font-face { font-family: X; src: url("\(base)/font.woff"); } p { font-family: X; }</style>
        <script src="\(base)/script.js"></script>
        </head><body><div id="oh-root">
        <iframe src="\(base)/iframe"></iframe><object data="\(base)/object"></object><embed src="\(base)/embed">
        <video src="\(base)/video.mp4" autoplay></video><audio src="\(base)/audio.mp3" autoplay></audio>
        <p>text</p></div></body></html>
        """
    }
}
