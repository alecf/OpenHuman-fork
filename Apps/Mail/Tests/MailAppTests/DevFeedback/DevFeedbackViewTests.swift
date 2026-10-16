import AppKit
import MailFakes
import MailFeatures
import MailUI
import OpenHumanCore
import OpenHumanLinks
import SwiftUI
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

@MainActor
@Suite(.serialized) struct DevFeedbackViewTests {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("oh-devfeedback-views-\(UUID().uuidString)", isDirectory: true)
    let defaults = ScopedDefaults("openhuman.test.devfeedback.views")

    func render(_ view: some View, size: NSSize, name: String) throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        #expect(png.count > 1_000)
        if let dir = ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        window.orderOut(nil)
    }

    func makeCenter(bundled: URL?) throws -> DevFeedbackCenter {
        let center = DevFeedbackCenter(availability: .devTools, settings: DevFeedbackSettings(defaults: defaults),
                                       paths: DevFeedbackPaths(support: support), bundledChecklist: bundled)
        return center
    }

    @Test func bundledChecklistIsValid() throws {
        let url = try #require(Bundle.main.url(forResource: "dev-test-checklist", withExtension: "json"))
        let checklist = DevChecklistLoader.load(bundled: url, override: nil)
        #expect(checklist.source == .bundled)
        #expect(checklist.issues.isEmpty, "\(checklist.issues)")
        #expect(checklist.items.count >= 12)
        #expect(Set(checklist.items.map(\.id)).count == checklist.items.count)
        for item in checklist.items {
            #expect(!item.steps.isEmpty && item.steps.count <= 4, "\(item.id): keep it under a minute")
            if let link = item.deepLink { #expect((try? MailLinkParser.parse(string: link).get()) != nil) }
        }
        #expect(checklist.items.contains { $0.requires == .fake } && checklist.items.contains { $0.requires == .real })
        for area in ["Sign-in", "Inbox", "Reader", "Block", "Sync", "Appearance"] {
            #expect(checklist.items.contains { $0.area == area }, "no \(area) items")
        }
    }

    @Test func themeInfoIsIdsOnly() {
        let info = AppThemes.themeInfo
        #expect(info.themeID.hasPrefix("openhuman.") || info.themeID.contains("."))
        #expect(["light", "dark"].contains(info.appearance))
        #expect(["light", "dark", "system"].contains(info.mode))
    }

    @Test func checklistPanelRenders() throws {
        defer { try? FileManager.default.removeItem(at: support); defaults.cleanup() }
        let center = try makeCenter(bundled: Bundle.main.url(forResource: "dev-test-checklist", withExtension: "json"))
        center.checklist.record(.worked, for: "inbox.jk")
        center.checklist.record(.didNotWork, for: "block.sender-cleanup-undo")
        center.checklist.setNote("Undo left one conversation in Trash", for: "block.sender-cleanup-undo")
        center.checklist.open(center.checklist.items[0])
        try render(DevChecklistView(model: center.checklist, onGiveFeedback: {}), size: NSSize(width: 680, height: 900),
                   name: "dev-checklist-panel")
        center.checklist.showOnlyUntested = true
        #expect(!center.checklist.sections.flatMap(\.items).contains { $0.id == "inbox.jk" })
    }

    @Test func hostileChecklistRendersAsPlainText() throws {
        defer { try? FileManager.default.removeItem(at: support); defaults.cleanup() }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let file = support.appendingPathComponent("hostile.json")
        let hostile: [String: Any] = ["items": [
            ["id": "h1", "area": "**Area** [x](https://evil.example)", "title": "<script>alert(1)</script> $(rm -rf ~) \u{202E}gnp.exe",
             "steps": [String(repeating: "Very long step ", count: 40), "Press `e`; then \"quoted\""],
             "expected": "[Click me](javascript:alert(1)) ![img](https://tracker.example/p.gif)", "requires": "fake",
             "deepLink": "javascript:alert(1)"],
            ["id": "h2", "area": "Fine", "title": String(repeating: "W", count: 1_000), "steps": ["x"], "expected": "y", "requires": "fake"],
        ]]
        try JSONSerialization.data(withJSONObject: hostile).write(to: file)
        let center = try makeCenter(bundled: file)
        #expect(center.checklist.items.count == 2)
        #expect(center.checklist.items[0].deepLink == nil)
        #expect(center.checklist.open(center.checklist.items[0]) == .showKeys(center.checklist.items[0].steps))
        try render(DevChecklistView(model: center.checklist, onGiveFeedback: {}), size: NSSize(width: 680, height: 700),
                   name: "dev-checklist-hostile")
    }

    @Test func feedbackSheetRendersBeforeAndAfterSaving() async throws {
        defer { try? FileManager.default.removeItem(at: support); defaults.cleanup() }
        let center = try makeCenter(bundled: Bundle.main.url(forResource: "dev-test-checklist", withExtension: "json"))
        let app = AppModel(screen: .mail(.fake(corpus: .make(threadCount: 10))))
        let host = AppDevFeedbackHost(availability: .devTools, arguments: ["-UseFakeData"], environment: [:],
                                      app: { app }, theme: { nil })
        center.host = host
        center.checklist.record(.worked, for: "inbox.jk")
        let model = center.beginFeedback()
        model.text = "The list jumped after pressing j twice."
        try render(DevFeedbackSheet(model: model, onClose: {}, copy: { _ in }), size: NSSize(width: 560, height: 560),
                   name: "dev-feedback-sheet")
        await model.submit()
        guard case .saved(let saved) = model.state else { Issue.record("not saved: \(model.state)"); return }
        #expect(saved.needsTarget)
        #expect(saved.sendCommand.hasSuffix(" <device-name>:"))
        try render(DevFeedbackSheet(model: model, onClose: {}, copy: { _ in }), size: NSSize(width: 560, height: 420),
                   name: "dev-feedback-sheet-saved")
        try render(DevFeedbackSettingsView(settings: center.settings, availability: .devTools,
                                           feedbackFolder: center.paths.feedbackDirectory.path),
                   size: NSSize(width: 640, height: 320), name: "dev-feedback-settings")
    }

    @Test func unavailableDeveloperFeedbackShowsNothingInSettings() throws {
        defer { try? FileManager.default.removeItem(at: support); defaults.cleanup() }
        let center = try makeCenter(bundled: nil)
        func height(_ availability: DevFeedbackAvailability) -> CGFloat {
            let view = DevFeedbackSettingsView(settings: center.settings, availability: availability,
                                               feedbackFolder: center.paths.feedbackDirectory.path)
            let hosting = NSHostingView(rootView: view.frame(width: 640))
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.height
        }
        #expect(height(.off) < 1, "nothing at all")
        #expect(height(.devTools) > 40, "the developer rows")
        let optionsDefaults = ScopedDefaults("openhuman.test.developer-options")
        defer { optionsDefaults.cleanup() }
        func options(_ availability: DevFeedbackAvailability) -> DeveloperOptions {
            DeveloperOptions(devFeedback: availability, defaults: optionsDefaults)
        }
        #expect(SettingsRoot.showsDeveloperItems(options(.off)) == false)
        #expect(SettingsRoot.showsDeveloperItems(options(.devTools)) == false, "off by default in a dev-tools build too")
        let devTools = options(.devTools)
        #expect(devTools.isAvailable)
        devTools.isOn = true
        #expect(SettingsRoot.showsDeveloperItems(devTools))
        #expect(SettingsRoot.showsDeveloperItems(options(.devTools)), "remembered where the switch is offered")
        #expect(SettingsRoot.showsDeveloperItems(options(.off)) == false, "never in a public build")
        #expect(!options(.off).isAvailable, "and no switch there")
    }
}
