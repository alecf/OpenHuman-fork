import AppKit
import MailFakes
import MailFeatures
import MailModel
import OpenHumanCore
import Testing
@testable import MailUIMac

private let now = Date(timeIntervalSince1970: 1_791_000_000)

@MainActor
@Suite(.serialized)
struct RestorationWindowTests {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1000, height: 400), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)

    init() { window.isReleasedWhenClosed = false }

    @Test func theScrollAnchorIsSavedWhileScrollingAndLandsAgainInANewWindow() async throws {
        let store = InMemoryNavigationStore()
        let corpus = FakeCorpus.rich(threadCount: 400, now: now)
        var rows: [ThreadKey] = []
        var rowHeight: CGFloat = 0
        do {
            let router = AppRouter(environment: AppEnvironment.fake(corpus: corpus), location: nil, restoring: store,
                                   persistDelay: .milliseconds(5))
            let content = MainContentViewController(router: router)
            window.contentView = content.view
            window.orderFrontRegardless()
            try await until { router.accounts.count == 2 && router.list?.state == .loaded }
            router.go(to: .system(.allMail))
            try await until { (router.list?.rows.count ?? 0) >= 100 && content.tableView.numberOfRows >= 100 }
            rows = try #require(router.list?.rows.map(\.id))
            rowHeight = content.tableView.rowHeight
            let scroll = try #require(content.tableView.enclosingScrollView)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 40 * rowHeight + 11))
            scroll.reflectScrolledClipView(scroll.contentView)
            let account = try #require(router.activeAccountID)
            try await until { store.load()?.place(for: account)?.scrollTop == rows[40] }
            #expect(store.load()?.place(for: account)?.scrollOffset == 11)
            window.contentView = nil
        }
        let router = AppRouter(environment: AppEnvironment.fake(corpus: corpus), location: nil, restoring: store)
        let content = MainContentViewController(router: router)
        window.contentView = content.view
        defer { window.orderOut(nil) }
        try await until { content.tableView.numberOfRows >= 100 && content.topVisibleKey == rows[40] }
        let clip = try #require(content.tableView.enclosingScrollView?.contentView)
        #expect(clip.bounds.origin.y == 40 * rowHeight + 11)
    }

    @Test(.enabled(if: !NSScreen.screens.isEmpty)) func aSavedFrameOnNoScreenIsBroughtBackAndMovesAreReported() async throws {
        let off = WindowPlace(frame: CGRect(x: -9000, y: -9000, width: 900, height: 600), displayID: 12345)
        let store = InMemoryNavigationStore(NavigationSnapshot(activeAccount: nil, window: off))
        let router = AppRouter(environment: AppEnvironment.fake(corpus: .make(threadCount: 3, now: now)), location: nil,
                               restoring: store)
        let tracker = WindowPlaceTracker(window: window, router: router)
        let screens = WindowPlaceTracker.visibleFrames()
        #expect(screens.contains { $0.contains(window.frame) }, "the window is on an attached screen")
        window.setFrame(CGRect(x: window.frame.origin.x + 20, y: window.frame.origin.y, width: 910, height: 610), display: false)
        tracker.capture()
        #expect(router.windowPlace?.frame == window.frame)
        #expect(router.windowPlace?.isFullScreen == false)
    }
}
