import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanLinks
import Testing
@testable import MailFeatures

@MainActor
final class FakeDevFeedbackHost: DevFeedbackHost {
    var appInfo = DevFeedbackSnapshot.AppInfo(version: "0.1.0", build: "1", gitCommit: "abc1234", configuration: "Debug",
                                              dataMode: "fake", devFeedbackEnabledBy: "devTools", os: "macOS 27")
    var screenName = "mail"
    var theme: DevFeedbackSnapshot.ThemeInfo? = .init(themeID: "openhuman.light", appearance: "light", mode: "system", accentID: "blue")
    var extraDenylist: [String] = []
    var screenshot: Data? = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    var shown = 0
    func accountCounters() async -> [DevFeedbackSnapshot.AccountInfo] { [] }
    func captureScreenshot() -> Data? { screenshot }
    func showMainWindow() { shown += 1 }
}

func contentStrings(_ corpus: FakeCorpus) -> [String] {
    var strings: [String] = [corpus.account.email]
    for thread in corpus.threads {
        strings += [thread.row.subject, thread.row.snippet, thread.row.participantsDisplay]
        strings += thread.row.participants.flatMap { [$0.name ?? "", $0.email] }
        for message in thread.detail.messages {
            let people = [message.from].compactMap { $0 } + message.to + message.cc
            strings += people.flatMap { [$0.name ?? "", $0.email] }
            if let text = thread.bodies[message.id]?.text { strings.append(String(text.prefix(40))) }
        }
    }
    return Set(strings).filter { $0.count >= 6 }.sorted()
}

@MainActor
@Suite(.serialized) struct DevFeedbackCenterTests {
    let corpus = FakeCorpus.make(threadCount: 30, now: fixedNow)
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("oh-devfeedback-\(UUID().uuidString)", isDirectory: true)
    let host = FakeDevFeedbackHost()
    let defaults = ScopedDefaults("openhuman.test.devfeedback.center")

    func makeCenter(checklist: [DevChecklistItem] = []) throws -> DevFeedbackCenter {
        let bundled = support.appendingPathComponent("bundled-checklist.json")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let items = checklist.map { item -> [String: Any] in
            ["id": item.id, "area": item.area, "title": item.title, "steps": item.steps, "expected": item.expected,
             "requires": item.requires.rawValue, "deepLink": item.deepLink.map { $0 as Any } ?? NSNull()]
        }
        try JSONSerialization.data(withJSONObject: ["items": items]).write(to: bundled)
        let center = DevFeedbackCenter(availability: .devTools, settings: DevFeedbackSettings(defaults: defaults),
                                       paths: DevFeedbackPaths(support: support), bundledChecklist: bundled,
                                       now: { fixedNow }, timeZone: TimeZone(identifier: "Europe/Berlin") ?? .current)
        center.host = host
        return center
    }

    func openWindow(_ center: DevFeedbackCenter) async -> MailWindowModel {
        let window = MailWindowModel(environment: .fake(corpus: corpus))
        window.start()
        await eventually { window.list?.rows.count == 30 }
        center.window = window
        return window
    }

    func json(_ value: some Encodable) throws -> String {
        String(decoding: try DevFeedbackBundle.encoder.encode(value), as: UTF8.self)
    }

    @Test func snapshotCapturesStateAndIdsButNoContent() async throws {
        defer { try? FileManager.default.removeItem(at: support); defaults.cleanup() }
        let center = try makeCenter()
        let window = await openWindow(center)
        window.perform(.nextThread)
        window.perform(.nextThread)
        window.perform(.openThread)
        let reader = try #require(window.reader)
        await eventually { reader.state == .loaded }
        await eventually { reader.messages.filter(\.isExpanded).allSatisfy { if case .rendered = $0.body { true } else { false } } }
        center.history.record("nav.openThread")
        center.checklist.viewingItemID = "inbox.jk"

        let snapshot = await center.snapshot()
        #expect(snapshot.capturedAtUTC == "2026-10-03T04:00:00Z")
        #expect(snapshot.capturedAtLocal == "2026-10-03T06:00:00+02:00")
        #expect(snapshot.screen == "mail")
        #expect(snapshot.route == "mail/reader/inbox")
        #expect(snapshot.list?.rows == 30)
        #expect(snapshot.list?.cursorIndex == 2)
        #expect(snapshot.reader?.threadID == corpus.threads[2].row.id.gmailThreadID.rawValue)
        #expect(snapshot.reader?.imagePolicy == "blockRemote")
        #expect(snapshot.reader?.mode != "none")
        #expect(snapshot.reader?.focusedMessageID == corpus.threads[2].detail.messages.last?.id.gmailMessageID.rawValue)
        #expect(snapshot.accountCount == 1)
        #expect(snapshot.accounts.first?.idHash == DevFeedbackHash.account(corpus.account.email))
        #expect(snapshot.accounts.first?.idHash.count == 12)
        #expect(snapshot.recentCommands.map(\.id) == ["nav.openThread"])
        #expect(snapshot.checklistViewing == "inbox.jk")
        #expect(snapshot.app.gitCommit == "abc1234")
        #expect(snapshot.theme?.themeID == "openhuman.light")

        let text = try json(snapshot)
        for content in contentStrings(corpus) { #expect(!text.contains(content), "snapshot leaks: \(content)") }
    }

    @Test func sheetDefaultsAttachStateAndLogsButNoContent() async throws {
        defer { try? FileManager.default.removeItem(at: support); defaults.cleanup() }
        let center = try makeCenter()
        let window = await openWindow(center)
        window.perform(.openThread)
        let reader = try #require(window.reader)
        await eventually { reader.state == .loaded }
        let subject = reader.subject
        let sender = try #require(reader.messages.last?.summary.from?.email)
        center.logs.append(.init(at: fixedNow, category: "app", level: "error", message: "opened \(subject) from \(sender) ya29.TOKENabcdef"))

        let model = center.beginFeedback()
        #expect(model.includeSnapshot && model.includeLogs)
        #expect(!model.includeThreadContent && !model.includeScreenshot)
        #expect(model.threadContentAvailable && model.screenshotAvailable)
        #expect(host.shown == 1)
        #expect(center.isFeedbackSheetPresented)

        let (bundle, image) = await model.makeBundle()
        #expect(image == nil)
        #expect(bundle.content == nil)
        #expect(bundle.snapshot != nil)
        #expect(bundle.logs?.count == 1)
        #expect(bundle.attachments == .init(snapshot: true, logs: true, threadSubjectAndSender: false, screenshot: false))
        let text = try json(bundle)
        for content in contentStrings(corpus) + ["TOKENabcdef"] { #expect(!text.contains(content), "bundle leaks: \(content)") }
        #expect(text.contains("<content>"))

        model.includeThreadContent = true
        model.includeScreenshot = true
        let (withContent, withImage) = await model.makeBundle()
        #expect(withContent.content?.subject == subject)
        #expect(withContent.content?.sender.contains(sender) == true)
        #expect(withImage == host.screenshot)
    }

    @Test func noThreadMeansNoContentBox() async throws {
        defer { try? FileManager.default.removeItem(at: support); defaults.cleanup() }
        let center = try makeCenter()
        _ = await openWindow(center)
        host.screenshot = nil
        let model = center.beginFeedback()
        #expect(!model.threadContentAvailable)
        #expect(!model.screenshotAvailable)
        model.includeThreadContent = true
        let (bundle, image) = await model.makeBundle()
        #expect(bundle.content == nil && image == nil)
    }

    @Test func submitWritesOneBundleWithNewAnswersAndTheCommands() async throws {
        defer { try? FileManager.default.removeItem(at: support); defaults.cleanup() }
        let items = [DevChecklistItem(id: "inbox.jk", area: "Inbox", title: "j and k", steps: ["Press j"], expected: "Moves", requires: .fake),
                     DevChecklistItem(id: "status.sync", area: "Status", title: "Sync line", steps: ["Look"], expected: "Shown", requires: .real)]
        let center = try makeCenter(checklist: items)
        center.settings.taildropTarget = "mac-mini"
        _ = await openWindow(center)
        center.checklist.record(.worked, for: "inbox.jk")
        center.checklist.record(.didNotWork, for: "status.sync")
        center.checklist.setNote("No sync line under -UseFakeData", for: "status.sync")

        let model = center.beginFeedback()
        #expect(model.pendingAnswerCount == 2)
        model.category = .bug
        model.text = "The cursor jumped"
        model.includeScreenshot = true
        await model.submit()
        guard case .saved(let saved) = model.state else { Issue.record("not saved: \(model.state)"); return }

        let files = try FileManager.default.contentsOfDirectory(atPath: center.paths.feedbackDirectory.path).sorted()
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.hasPrefix("feedback-20261003T040000Z-") })
        #expect(saved.bundlePath.hasSuffix(".json"))
        #expect(saved.screenshotPath?.hasSuffix(".png") == true)
        #expect(saved.sendCommand == "tailscale file cp '\(saved.bundlePath)' '\(saved.screenshotPath ?? "")' mac-mini:")
        #expect(!saved.needsTarget)
        #expect(saved.receiveCommand.contains("tailscale file get ~/Downloads/OpenHuman-feedback/"))
        #expect(saved.answersIncluded == 2)

        let bundle = try DevFeedbackBundle.decoder.decode(DevFeedbackBundle.self, from: Data(contentsOf: URL(fileURLWithPath: saved.bundlePath)))
        #expect(bundle.format == "openhuman-dev-feedback")
        #expect(bundle.category == .bug)
        #expect(bundle.text == "The cursor jumped")
        #expect(bundle.screenshotFile == URL(fileURLWithPath: saved.screenshotPath ?? "").lastPathComponent)
        #expect(bundle.checklist.answers.map(\.itemID) == ["inbox.jk", "status.sync"])
        #expect(bundle.checklist.answers.map(\.result) == ["worked", "didNotWork"])
        #expect(bundle.checklist.answers[1].note == "No sync line under -UseFakeData")
        let attributes = try FileManager.default.attributesOfItem(atPath: saved.bundlePath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        center.isFeedbackSheetPresented = false
        #expect(center.feedback == nil)
        let next = center.beginFeedback()
        #expect(next.pendingAnswerCount == 0)
        await next.submit()
        guard case .saved(let second) = next.state else { Issue.record("second not saved"); return }
        #expect(second.answersIncluded == 0)
        #expect(second.screenshotPath == nil)
        #expect(second.bundlePath != saved.bundlePath)
    }

    @Test func checklistLinkOpensTheThreadThroughTheWindow() async throws {
        defer { try? FileManager.default.removeItem(at: support); defaults.cleanup() }
        let target = corpus.threads[4].row.id.gmailThreadID.rawValue
        let link = "openhuman://thread/\(corpus.account.email)/\(target)"
        let center = try makeCenter(checklist: [
            DevChecklistItem(id: "link", area: "Inbox", title: "Link", steps: ["Click Open"], deepLink: link, expected: "Opens", requires: .fake),
            DevChecklistItem(id: "other", area: "Inbox", title: "Other account", steps: ["Click Open"],
                             deepLink: "openhuman://thread/someone@example.org/\(target)", expected: "Refused", requires: .fake),
            DevChecklistItem(id: "search", area: "Inbox", title: "Search", steps: ["Click Open"],
                             deepLink: "openhuman://search?q=hello", expected: "Shows results", requires: .fake),
        ])
        #expect(center.checklist.items.count == 3)
        #expect(center.follow(.search(query: "x", account: nil)) == "No mail window is open.")
        let window = await openWindow(center)

        let outcome = center.checklist.open(center.checklist.items[0])
        guard case .followed(_, let message) = outcome else { Issue.record("not followed: \(outcome)"); return }
        #expect(message == "Opened thread \(target).")
        #expect(window.mode == .reader)
        #expect(window.reader?.thread.gmailThreadID.rawValue == target)

        guard case .followed(_, let refused) = center.checklist.open(center.checklist.items[1]) else { Issue.record("no outcome"); return }
        #expect(refused == "No account named “someone@example.org”.")
        guard case .followed(_, let search) = center.checklist.open(center.checklist.items[2]) else { Issue.record("no outcome"); return }
        #expect(search == "Showing search results.")
        #expect(window.location == .search("hello"))
        #expect(window.mode == .list)
        #expect(center.history.commands.map(\.id).contains("link:thread"))
    }

    @Test func pressingGiveFeedbackAgainKeepsTheOpenDraft() async throws {
        defer { try? FileManager.default.removeItem(at: support); defaults.cleanup() }
        let center = try makeCenter()
        let first = center.beginFeedback()
        first.text = "half-written"
        #expect(center.beginFeedback() === first)
        await first.submit()
        #expect(center.beginFeedback() !== first)
    }

    @Test func signInScreenSnapshotUsesTheHost() async throws {
        defer { try? FileManager.default.removeItem(at: support); defaults.cleanup() }
        let center = try makeCenter()
        host.screenName = "signIn/ready"
        let snapshot = await center.snapshot()
        #expect(snapshot.screen == "signIn/ready")
        #expect(snapshot.route == "signIn/ready")
        #expect(snapshot.list == nil && snapshot.reader == nil)
    }
}
