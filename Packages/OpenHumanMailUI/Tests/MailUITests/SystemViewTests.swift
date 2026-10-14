#if os(macOS)
import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI

private let fixedNow = Date(timeIntervalSince1970: 1_791_000_000)

@MainActor
private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 760, height: 560), name: String,
                           theme: ResolvedTheme = .light) throws -> NSHostingView<some View> {
    let hosting = NSHostingView(rootView: view.environment(\.theme, theme).environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
        .background(theme.bgWindow.color))
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    if let dir = ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] {
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    return hosting
}

@MainActor
private func environment(authorization: NotificationAuthorization = .authorized) -> (AppEnvironment, FakeSystemNotifier, FakeLoginItem) {
    let env = AppEnvironment.fake(corpus: .rich(threadCount: 20, now: fixedNow), options: .init(remoteAck: .immediate),
                                  featureFlags: FeatureFlags())
    let notifier = FakeSystemNotifier(authorization: authorization)
    let login = FakeLoginItem(status: .requiresApproval)
    env.installPlatform(SystemPlatform(notifier: notifier, dock: FakeDockBadge(), loginItem: login, urlOpener: FakeURLOpener(),
                                       isAppActive: { false }))
    env.runLaunchTasks()
    return (env, notifier, login)
}

@MainActor
@Test func notificationsSettingsLayOutWithAccountsSwitchesAndThePermissionWarning() async throws {
    let (env, _, _) = environment(authorization: .denied)
    while env.system.notifications == nil { await Task.yield() }
    let model = NotificationsSettingsModel(environment: env)
    model.start()
    while model.accounts.isEmpty || !model.showsPermissionWarning { await Task.yield() }
    #expect(model.accounts.count == 2)
    _ = try host(NotificationsSettingsView(model: model), name: "settings-notifications-denied")
    _ = try host(NotificationsSettingsView(model: model), name: "settings-notifications-dark", theme: .dark)
}

@MainActor
@Test func generalRowsShowTheLoginItemApprovalStateAndTheDockBadgeMenu() async throws {
    let (env, _, login) = environment()
    while env.system.launchAtLogin == nil || env.system.dockBadge == nil { await Task.yield() }
    #expect(env.system.launchAtLogin?.showsSettingsButton == true)
    _ = try host(SystemGeneralSettingsView(environment: env), name: "settings-general-system")
    login.current = .enabled
    env.system.launchAtLogin?.refresh()
    #expect(env.system.launchAtLogin?.detail == nil)
}
#endif
