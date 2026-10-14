import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import Testing
import WebKit
@testable import MailUIMac

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] != nil))
struct SnapshotRenderTests {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] ?? "/tmp")

    @Test func renderListAndReaders() async throws {
        let corpus = FakeCorpus.make(threadCount: 200)
        let environment = AppEnvironment.fake(corpus: corpus)
        let content = MainContentViewController(router: AppRouter(environment: environment))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1360, height: 860),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.setFrame(NSRect(x: -5000, y: -5000, width: 1360, height: 860), display: true)
        window.orderFrontRegardless()
        content.keyRouter.isMailWindow = { $0 === window }
        try await until { content.windowModel.list?.rows.count == 100 }
        for _ in 0..<2 { content.windowModel.perform(.nextThread) }
        try await Task.sleep(for: .milliseconds(200))
        try snapshot(window, name: "list")

        for (name, kind) in [("reader-newsletter", FakeBodyKind.newsletter), ("reader-plain", .plainReply),
                             ("reader-gmail-reply", .gmailReply), ("reader-hostile", .hostile)] {
            guard let thread = corpus.threads.first(where: { $0.bodyKinds.values.contains(kind) && $0.detail.messages.count <= 3 })
                ?? corpus.threads.first(where: { $0.bodyKinds.values.contains(kind) }) else { continue }
            content.windowModel.perform(.backToList)
            content.windowModel.open(thread.row.id)
            let reader = try #require(content.windowModel.reader)
            try await until { reader.messages.filter(\.isExpanded).allSatisfy { if case .rendered = $0.body { return true }; return false } }
            try await until(timeout: .seconds(60)) {
                Self.webViews(in: window.contentView!).allSatisfy { $0.measuredHeight != nil }
            }
            try await Task.sleep(for: .milliseconds(300))
            try snapshot(window, name: name)
        }
        window.close()
    }

    static func webViews(in view: NSView) -> [ReaderWebView] {
        (view as? ReaderWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }

    func snapshot(_ window: NSWindow, name: String) throws {
        let root = window.contentView!
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let image = NSImage(size: root.bounds.size)
        image.addRepresentation(rep)
        let composed = NSImage(size: root.bounds.size)
        composed.lockFocus()
        image.draw(in: root.bounds)
        let group = DispatchGroup()
        var shots: [(NSRect, NSImage)] = []
        for web in Self.webViews(in: root) where !web.isHiddenOrHasHiddenAncestor && web.alphaValue > 0 {
            let frame = web.convert(web.bounds, to: root)
            group.enter()
            web.takeSnapshot(with: nil) { image, _ in
                if let image { shots.append((frame, image)) }
                group.leave()
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while group.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        for (frame, shot) in shots {
            let flipped = root.isFlipped ? NSRect(x: frame.minX, y: root.bounds.height - frame.maxY, width: frame.width,
                                                  height: frame.height) : frame
            shot.draw(in: flipped)
        }
        composed.unlockFocus()
        let tiff = try #require(composed.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
