import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

private let now = Date(timeIntervalSince1970: 1_791_000_000)

@MainActor
@Suite(.serialized)
struct CalendarSidebarViewTests {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1300, height: 760), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)

    init() { window.isReleasedWhenClosed = false }

    func environment(calendar: Bool, safeMode: SafeModeInfo = .normal) -> AppEnvironment {
        AppEnvironment.fake(corpus: .rich(threadCount: 20, now: now), options: .init(remoteAck: .immediate, safeMode: safeMode),
                            featureFlags: FeatureFlags(), calendar: calendar ? FakeCalendar.sample(now: now) : nil)
    }

    func controlCommandC() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command], timestamp: 100,
                         windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c",
                         isARepeat: false, keyCode: 8)!
    }

    @Test func controlCommandCTogglesOnlyWhenTheModuleRegistered() {
        for configured in [true, false] {
            let env = environment(calendar: configured)
            let router = KeyRouter()
            router.load(KeyTable.build(env.actions.descriptors))
            let target = window
            router.isMailWindow = { $0 === target }
            router.activeScopes = { [.list, .global] }
            var performed: [ActionID] = []
            router.perform = { action, _ in performed.append(action); return true }
            let passedOn = router.route(controlCommandC()) != nil
            #expect(passedOn != configured, "configured: \(configured)")
            #expect(performed == (configured ? [.calendarToggleSidebar] : []))
        }
    }

    @Test func theSidebarAndItsDraftLayOutAtTheSidebarWidth() async throws {
        for safeMode in [SafeModeInfo.normal, .readOnly] {
            let env = environment(calendar: true, safeMode: safeMode)
            let model = try #require(env.calendarSidebar)
            model.now = { now }
            model.setVisible(true)
            await model.show(thread: nil)
            #expect(model.days.count == 1 && !(model.days.first?.events.isEmpty ?? true))
            await model.beginDraft(for: nil)
            #expect(model.draft != nil)
            for theme in [ResolvedTheme.light, .dark] {
                let hosting = NSHostingView(rootView: CalendarSidebarView(model: model, router: env.router)
                    .environment(\.theme, theme).frame(height: 700))
                hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
                hosting.layoutSubtreeIfNeeded()
                #expect(hosting.fittingSize.width == CGFloat(theme.component.sidebar.width))
                snapshot(hosting, name: "calendar-sidebar-\(safeMode)-\(theme.appearance)")
            }
            #expect(model.canCreate == (safeMode == .normal))
        }
    }

    @Test func theWindowRootHostsTheSidebarAndItFollowsTheOpenConversation() async throws {
        let env = environment(calendar: true)
        let themes = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light)))
        var attached: MainContentViewController?
        let hosting = NSHostingView(rootView: MainWindowRoot(environment: env, themes: themes) { attached = $0 })
        let frame = NSRect(x: -6000, y: -6000, width: 1300, height: 760)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        #expect(window.setFrameAutosaveName("dev.openhuman.tests.calendar-sidebar"))
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.setFrameAutosaveName("")
            window.close()
        }
        await calendarEventually { attached != nil && env.router.list?.state == .loaded }
        let model = try #require(env.calendarSidebar)
        #expect(!model.isVisible && model.state == .idle)
        #expect(env.actions.perform(.calendarToggleSidebar, source: .menu, host: env.router))
        #expect(model.isVisible)
        await calendarEventually { model.state == .loaded && model.thread == nil && model.days.count == 1 }
        let open = try #require(env.router.list?.rows.first?.id)
        env.router.open(open)
        await calendarEventually { model.thread == open && model.state == .loaded }
        snapshot(hosting, name: "calendar-window")
        #expect(env.actions.perform(.calendarToggleSidebar, source: .menu, host: env.router))
        #expect(!model.isVisible)
    }

    @Test func theSidebarsKeyViewMovesTheDayAndTheRouterLeavesItsKeysAlone() async throws {
        let env = environment(calendar: true)
        let model = try #require(env.calendarSidebar)
        model.now = { now }
        let view = CalendarDayKeyView()
        view.model = model
        #expect(KeyRouter.isTextInput(view), "plain keys are the sidebar's while it has the keyboard")
        func key(_ character: String, code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 100,
                             windowNumber: window.windowNumber, context: nil, characters: character,
                             charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
        }
        let calendar = CalendarDateMentions.calendar(model.timeZone)
        let today = calendar.startOfDay(for: now)
        #expect(view.handle(key("=", code: 24)))
        await calendarEventually { model.days.first?.start == calendar.date(byAdding: .day, value: 1, to: today) }
        #expect(view.handle(key("-", code: 27)))
        await calendarEventually { model.days.first?.start == today }
        #expect(view.handle(key("-", code: 27)))
        await calendarEventually { model.days.first?.start == calendar.date(byAdding: .day, value: -1, to: today) }
        #expect(view.handle(key("t", code: 17)))
        await calendarEventually { model.days.first?.start == today && model.isBrowsing }
        #expect(!view.handle(key("j", code: 38)), "other keys are not the sidebar's")
        #expect(view.handle(key("\u{1b}", code: 53)), "Esc gives the keys back")
    }

    private func snapshot(_ view: NSView, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"],
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}

@MainActor
private func calendarEventually(timeout: Duration = .seconds(60), _ condition: @MainActor () -> Bool,
                             sourceLocation: SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now > deadline {
            Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
