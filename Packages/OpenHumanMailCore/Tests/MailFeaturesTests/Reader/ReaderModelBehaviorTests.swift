import Foundation
import MailActions
import MailFakes
import MailModel
import MailRender
import MailTheme
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized)
struct ReaderModelBehaviorTests {
    typealias F = ReaderFixtures

    private func model(_ details: [ConversationDetail], bodies: [MessageKey: MessageContent], open thread: ThreadKey,
                       settings: (any SettingsPort)? = FakeMailStore(corpus: .make(threadCount: 1, now: fixedNow)),
                       files: [Int64: URL] = [:], safeMode: SafeModeInfo = .normal,
                       accessorySlot: ReaderHeaderAccessoryStore = ReaderHeaderAccessoryStore()) -> (ReaderModel, RenderQueue, ReaderTestSource) {
        let source = ReaderTestSource(details: details, bodies: bodies, files: files, safeMode: safeMode)
        let queue = RenderQueue(settings: settings)
        let model = ReaderModel(thread: thread, data: source, renderQueue: queue, accessorySlot: accessorySlot)
        model.start()
        return (model, queue, source)
    }

    private func html(_ model: ReaderModel, _ key: MessageKey) -> RenderedMessage? {
        if case .rendered(.html(let rendered)) = model.message(key)?.body { return rendered }
        return nil
    }

    @Test func theModelCarriesTheStarredState() async throws {
        let base = F.conversation(30, count: 1, from: F.dana)
        let starred = ConversationDetail(id: base.id, subject: base.subject, messages: base.messages, isStarred: true)
        let (model, _, _) = model([starred], bodies: [:], open: starred.id)
        await eventually { model.state == .loaded }
        #expect(model.isStarred)
        let on = ReaderActions.context(host: nil, thread: starred.id, lastMessage: nil, safeMode: .normal, isStarred: true)
        let off = ReaderActions.context(host: nil, thread: starred.id, lastMessage: nil, safeMode: .normal)
        let toggle = try #require(ActionCatalog.all.first { $0.id == .toggleStar })
        #expect(ReaderActions.availability(toggle, registry: nil, host: nil, context: on).help.hasPrefix("Unstar"))
        #expect(ReaderActions.availability(toggle, registry: nil, host: nil, context: off).help.hasPrefix("Star"))
        #expect(ReaderActions.activeSymbol(for: .toggleStar) == "star.fill")
        #expect(ReaderActions.activeSymbol(for: .markDone) == nil)
        #expect(base.isStarred == false, "additive: the default is not starred")
    }

    @Test func focusStartsOnTheNewestAndNPMoveIt() async throws {
        let detail = F.conversation(1, count: 4, from: F.dana, unread: [1, 2])
        let bodies = Dictionary(uniqueKeysWithValues: detail.messages.map { ($0.id, MessageContent(html: nil, text: "Body \($0.id.rowID)")) })
        let (model, _, _) = model([detail], bodies: bodies, open: detail.id)
        await eventually { model.state == .loaded }
        let keys = detail.messages.map(\.id)
        #expect(model.messages.map(\.isExpanded) == [false, true, true, true])
        #expect(model.focusedMessage == keys[3] && model.replyTarget == keys[3] && !model.focusChosen)
        #expect(!model.canFocusNext && model.canFocusPrevious)
        #expect(!model.focusNext(), "nothing newer: the key is not handled (↓ then scrolls)")
        #expect(!model.focusChosen && model.focusScrollRequest == 0, "a key that moved nothing pins nothing")
        #expect(model.focusPrevious())
        #expect(model.focusedMessage == keys[2] && model.replyTarget == keys[2] && model.focusChosen)
        #expect(model.focusScrollRequest == 1, "a move asks the view to scroll the message into view")
        #expect(model.focusNext())
        #expect(model.focusedMessage == keys[3], "stops at the newest")
        model.focusPrevious()
        model.focusPrevious()
        model.focusPrevious()
        #expect(!model.focusPrevious())
        #expect(model.focusedMessage == keys[0] && !model.canFocusPrevious && model.canFocusNext)
        #expect(model.focusScrollRequest == 5)
        model.toggleFocused()
        #expect(model.messages[0].isExpanded, "o expands the focused collapsed message")
        await eventually { if case .rendered(.plain) = model.messages[0].body { return true }; return false }
        model.toggleFocused()
        #expect(!model.messages[0].isExpanded)
        model.expandAll()
        #expect(model.messages.allSatisfy { $0.isExpanded })
    }

    @Test func longCollapsedRunsFoldIntoThePill() async throws {
        let detail = F.conversation(2, count: 12, from: F.dana)
        let bodies = Dictionary(uniqueKeysWithValues: detail.messages.map { ($0.id, MessageContent(html: nil, text: "Body")) })
        let (model, _, source) = model([detail], bodies: bodies, open: detail.id)
        await eventually { model.state == .loaded }
        let keys = detail.messages.map(\.id)
        #expect(model.items == [.message(keys[0]), .olderMessages(Array(keys[1...9])), .message(keys[10]), .message(keys[11])])
        #expect(model.focusedMessage == keys[11])
        await eventually { if case .rendered = model.messages[11].body { return true }; return false }
        #expect(source.requestedBodies == [keys[11]], "only the expanded body is read")
        model.focusPrevious()
        #expect(!model.showsAllMessages)
        model.focusPrevious()
        #expect(model.focusedMessage == keys[9])
        #expect(model.showsAllMessages)
        #expect(model.items == keys.map { .message($0) })
    }

    @Test func focusFollowsNewMessagesUntilTheUserMovesIt() async throws {
        let detail = F.conversation(9, count: 3, from: F.dana)
        let bodies = Dictionary(uniqueKeysWithValues: detail.messages.map { ($0.id, MessageContent(html: nil, text: "Body")) })
        let (model, _, _) = model([detail], bodies: bodies, open: detail.id)
        await eventually { model.state == .loaded }
        let keys = detail.messages.map(\.id)
        #expect(model.focusedMessage == keys[2])
        let arrived = F.summary(9 * 100 + 3, from: F.gmailUser, unread: true, minutesAgo: 1)
        model.apply(ConversationDetail(id: detail.id, subject: detail.subject, messages: detail.messages + [arrived]))
        #expect(model.focusedMessage == arrived.id && model.replyTarget == arrived.id, "a new message takes the focus")

        model.focus(keys[0])
        #expect(model.focusedMessage == keys[0] && model.focusChosen && model.replyTarget == keys[0])
        #expect(model.focusScrollRequest == 0, "a click does not scroll: the message is where the pointer is")
        let later = F.summary(9 * 100 + 4, from: F.gmailUser, unread: true, minutesAgo: 0)
        model.apply(ConversationDetail(id: detail.id, subject: detail.subject, messages: detail.messages + [arrived, later]))
        #expect(model.focusedMessage == keys[0], "the user's choice stays when mail arrives")
        #expect(model.pendingMessages == [later.id], "the user is reading: it waits behind the new-messages pill")

        model.apply(ConversationDetail(id: detail.id, subject: detail.subject, messages: Array(detail.messages[1...]) + [arrived, later]))
        #expect(model.focusedMessage == arrived.id && !model.focusChosen && model.replyTarget == arrived.id)
        model.showNewMessages()
        #expect(model.focusedMessage == later.id && model.replyTarget == later.id)
    }

    @Test func pillOpensOnClickAndShortRunsDoNotFold() async throws {
        let detail = F.conversation(3, count: 4, from: F.dana)
        let bodies = Dictionary(uniqueKeysWithValues: detail.messages.map { ($0.id, MessageContent(html: nil, text: "Body")) })
        let (model, _, _) = model([detail], bodies: bodies, open: detail.id)
        await eventually { model.state == .loaded }
        #expect(model.items.allSatisfy { if case .message = $0 { return true }; return false }, "3 collapsed stay rows")
        let long = F.conversation(4, count: 6, from: F.dana)
        let longBodies = Dictionary(uniqueKeysWithValues: long.messages.map { ($0.id, MessageContent(html: nil, text: "Body")) })
        let (other, _, _) = self.model([long], bodies: longBodies, open: long.id)
        await eventually { other.state == .loaded }
        #expect(other.items.contains { if case .olderMessages(let keys) = $0 { return keys.count == 3 }; return false })
        other.showAllMessages()
        #expect(other.items.count == 6)
    }

    @Test func quotedTextToggleFlipsTheFocusedMessage() async throws {
        let detail = F.conversation(5, count: 1, from: F.dana)
        let key = detail.messages[0].id
        let (model, _, _) = model([detail], bodies: [key: MessageContent(html: F.plainHTML, text: nil)], open: detail.id)
        await eventually { model.state == .loaded }
        #expect(model.message(key)?.quotesExpanded == false)
        model.toggleQuotedText()
        #expect(model.message(key)?.quotesExpanded == true)
        model.toggleQuotedText(key)
        #expect(model.message(key)?.quotesExpanded == false)
    }

    @Test func imagesAreBlockedByDefaultAndLoadOnceIsNotStored() async throws {
        let detail = F.conversation(6, count: 1, from: F.dana)
        let key = detail.messages[0].id
        let store = FakeMailStore(corpus: .make(threadCount: 1, now: fixedNow))
        let (model, _, _) = model([detail], bodies: [key: MessageContent(html: F.newsletterHTML, text: nil)], open: detail.id,
                                  settings: store)
        await eventually { html(model, key) != nil }
        let blocked = try #require(html(model, key))
        #expect(blocked.hasRemoteContent)
        #expect(blocked.blockedCount >= 1)
        #expect(blocked.trackerCount == 1)
        #expect(!blocked.html.contains("https://images.news.example"))
        #expect(model.message(key)?.imagesShown == nil)
        #expect(model.canShowImages, "`I` (and View › Show remote images) has something to load")

        model.loadImagesOnce(key)
        #expect(model.message(key)?.imagesShown == .once)
        #expect(!model.canShowImages)
        await eventually { html(model, key)?.html.contains("https://images.news.example/chart.png") == true }
        let loaded = try #require(html(model, key))
        #expect(loaded.html.contains("img-src ohcid: data: https: http:"), "the CSP allows remote images now")
        #expect(!loaded.html.contains("open.news.example"), "the tracker pixel stays out")
        #expect(try await store.get(AppSettings.remoteImageSenders(F.account)).isEmpty, "Load once is not stored")

        model.hideImages(key)
        #expect(model.message(key)?.imagesShown == nil)
        await eventually { html(model, key)?.html.contains("https://images.news.example") == false }
    }

    @Test func alwaysForTheSenderIsStoredAndAppliesToTheirNextMessageOnly() async throws {
        let first = F.conversation(7, count: 1, from: F.dana)
        let second = F.conversation(8, count: 1, from: F.dana, firstMessageRow: 900)
        let other = F.conversation(19, count: 1, from: EmailAddress(name: "Desk", email: "desk@news.example.com"),
                                   firstMessageRow: 950)
        let bodies = [first.messages[0].id: MessageContent(html: F.newsletterHTML, text: nil),
                      second.messages[0].id: MessageContent(html: F.newsletterHTML, text: nil),
                      other.messages[0].id: MessageContent(html: F.newsletterHTML, text: nil)]
        let store = FakeMailStore(corpus: .make(threadCount: 1, now: fixedNow))
        let (model, queue, source) = model([first, second, other], bodies: bodies, open: first.id, settings: store)
        let key = first.messages[0].id
        await eventually { html(model, key) != nil }
        #expect(model.alwaysEntry(for: key) == "dana@news.example.com")
        #expect(model.remembersChoices)
        await model.alwaysLoadImages(key)
        #expect(try await store.get(AppSettings.remoteImageSenders(F.account)) == ["dana@news.example.com"])
        #expect(model.message(key)?.imagesShown == .allowlist("dana@news.example.com"))
        await eventually { html(model, key)?.html.contains("https://images.news.example/chart.png") == true }

        let next = ReaderModel(thread: second.id, data: source, renderQueue: queue)
        next.start()
        let nextKey = second.messages[0].id
        await eventually { html(next, nextKey) != nil }
        #expect(next.message(nextKey)?.imagesShown == .allowlist("dana@news.example.com"))
        #expect(html(next, nextKey)?.html.contains("https://images.news.example/chart.png") == true)

        let elsewhere = ReaderModel(thread: other.id, data: source, renderQueue: queue)
        elsewhere.start()
        let elsewhereKey = other.messages[0].id
        await eventually { html(elsewhere, elsewhereKey) != nil }
        #expect(elsewhere.message(elsewhereKey)?.imagesShown == nil)
        #expect(html(elsewhere, elsewhereKey)?.html.contains("https://images.news.example/chart.png") == false)

        await model.stopAlwaysLoadingImages(key)
        #expect(try await store.get(AppSettings.remoteImageSenders(F.account)).isEmpty)
        await eventually { model.message(key)?.imagesShown == nil }
        await eventually { next.message(nextKey)?.imagesShown == nil }
    }

    @Test func sharedMailboxSendersAreAllowedByAddressNotDomain() async throws {
        let detail = F.conversation(9, count: 1, from: F.gmailUser)
        let key = detail.messages[0].id
        let store = FakeMailStore(corpus: .make(threadCount: 1, now: fixedNow))
        let (model, _, _) = model([detail], bodies: [key: MessageContent(html: F.newsletterHTML, text: nil)], open: detail.id,
                                  settings: store)
        await eventually { html(model, key) != nil }
        #expect(model.alwaysEntry(for: key) == "sam.lee@gmail.com")
        await model.alwaysLoadImages(key)
        #expect(try await store.get(AppSettings.remoteImageSenders(F.account)) == ["sam.lee@gmail.com"])
    }

    @Test func thePrivacyPolicyLoadAllowsEveryMessage() async throws {
        let detail = F.conversation(10, count: 1, from: F.dana)
        let key = detail.messages[0].id
        let store = FakeMailStore(corpus: .make(threadCount: 1, now: fixedNow))
        try await store.set(AppSettings.remoteImages(F.account), .allow)
        let (model, queue, _) = model([detail], bodies: [key: MessageContent(html: F.newsletterHTML, text: nil)], open: detail.id,
                                      settings: store)
        await eventually { html(model, key) != nil }
        #expect(model.message(key)?.imagesShown == .policy)
        #expect(html(model, key)?.html.contains("https://images.news.example/chart.png") == true)
        #expect(await queue.renderCount == 1, "settings arrive before the first render: no blocked render first")
    }

    @Test func withoutASettingsPortChoicesLastForTheSession() async throws {
        let detail = F.conversation(11, count: 1, from: F.dana)
        let key = detail.messages[0].id
        let (model, _, _) = model([detail], bodies: [key: MessageContent(html: F.newsletterHTML, text: nil)], open: detail.id,
                                  settings: nil)
        await eventually { html(model, key) != nil }
        #expect(!model.remembersChoices)
        await model.alwaysLoadImages(key)
        #expect(model.allowedSenders == ["dana@news.example.com"])
        await eventually { html(model, key)?.html.contains("https://images.news.example/chart.png") == true }
    }

    @Test func colorChoiceIsRememberedPerSender() async throws {
        let detail = F.conversation(12, count: 1, from: F.dana)
        let key = detail.messages[0].id
        let store = FakeMailStore(corpus: .make(threadCount: 1, now: fixedNow))
        let (model, _, _) = model([detail], bodies: [key: MessageContent(html: F.designedHTML, text: nil)], open: detail.id,
                                  settings: store)
        await eventually { html(model, key) != nil }
        model.useRenderer(MessageRenderer(theme: .dark, appearance: .dark))
        await eventually { html(model, key)?.colorTreatment == .original }
        await model.setColorOverride(.darkColors, for: key)
        #expect(try await store.get(ReaderSettings.colorOverrides(F.account)) == ["dana@news.example.com": "darkColors"])
        #expect(model.message(key)?.colorOverride == .darkColors)
        await eventually { html(model, key)?.colorTreatment == .remapped }
        await model.setColorOverride(.originalColors, for: key)
        await eventually { html(model, key)?.colorTreatment == .original }
        await model.setColorOverride(nil, for: key)
        #expect(try await store.get(ReaderSettings.colorOverrides(F.account)).isEmpty)
    }

    @Test func aNewThemeReRendersShownBodies() async throws {
        let detail = F.conversation(13, count: 1, from: F.dana)
        let key = detail.messages[0].id
        let (model, queue, _) = model([detail], bodies: [key: MessageContent(html: F.plainHTML, text: nil)], open: detail.id)
        await eventually { html(model, key) != nil }
        #expect(html(model, key)?.colorScheme == .light)
        model.useRenderer(MessageRenderer(theme: .dark, appearance: .dark))
        await eventually { html(model, key)?.colorScheme == .dark }
        #expect(queue.renderer.appearance == .dark, "later conversations render dark at once")
        let before = await queue.renderCount
        model.useRenderer(MessageRenderer(theme: .dark, appearance: .dark))
        #expect(await queue.renderCount == before, "the same theme does not re-render")
    }

    @Test func prefetchRendersTheNextConversationsIntoTheCache() async throws {
        let open = F.conversation(14, count: 1, from: F.dana)
        let next = F.conversation(15, count: 2, from: F.dana, unread: [0], firstMessageRow: 1_500)
        var bodies: [MessageKey: MessageContent] = [open.messages[0].id: MessageContent(html: F.plainHTML, text: nil)]
        for m in next.messages { bodies[m.id] = MessageContent(html: F.plainHTML + "\(m.id.rowID)", text: nil) }
        let (model, queue, _) = model([open, next], bodies: bodies, open: open.id)
        await eventually { model.state == .loaded }
        await eventually { html(model, open.messages[0].id) != nil }
        model.prefetch([open.id, next.id])
        let renderer = queue.renderer
        for m in next.messages {
            let content = try #require(bodies[m.id])
            await eventuallyAsync { await queue.isCached(content, for: m.id, context: RenderContext(), renderer: renderer) }
        }
    }

    @Test func headerSlotAsksOncePerExpandedMessage() async throws {
        let accessory = RecordingAccessory()
        let slot = ReaderHeaderAccessoryStore(current: accessory)
        let detail = F.conversation(16, count: 3, from: F.dana, unread: [2])
        let bodies = Dictionary(uniqueKeysWithValues: detail.messages.map { ($0.id, MessageContent(html: nil, text: "Body")) })
        let (model, _, _) = model([detail], bodies: bodies, open: detail.id, accessorySlot: slot)
        let last = detail.messages[2].id
        await eventually { model.message(last)?.accessory?.title == "Unsubscribe" }
        #expect(accessory.asked == [last])
        model.activateAccessory(last)
        #expect(accessory.activated == [last])
    }

    @Test func safeModeIsTheDataSources() async throws {
        let detail = F.conversation(17, count: 1, from: F.dana)
        let (model, _, _) = model([detail], bodies: [:], open: detail.id, safeMode: .readOnly)
        #expect(model.safeMode == .readOnly)
        let done = try #require(ActionCatalog.descriptor(.markDone))
        let readOnly = ActionRules.availability(done, in: ReaderActions.context(host: nil, thread: detail.id, lastMessage: nil, safeMode: model.safeMode))
        let availability = ReaderActions.availability(done, decided: readOnly)
        #expect(!availability.isEnabled)
        #expect(availability.help == DisabledReason.safeMode.description)
        let normal = ActionRules.availability(done, in: ReaderActions.context(host: nil, thread: detail.id, lastMessage: nil, safeMode: .normal))
        #expect(ReaderActions.availability(done, decided: normal) == .init(isEnabled: true, help: "Mark done  E"))
        #expect(ReaderActions.threadActions.map(\.id).contains(.markDone))
    }

    @Test func aFlowedTextPartJoinsItsSoftLineBreaks() async throws {
        let detail = F.conversation(19, count: 1, from: F.dana)
        let key = detail.messages[0].id
        let text = "This line is soft \nwrapped by the sender.\n\nSecond paragraph."
        let (model, _, _) = model([detail], bodies: [key: MessageContent(html: nil, text: text, textFormat: .flowed(delSp: false))],
                                  open: detail.id)
        await eventually { if case .rendered(.plain) = model.message(key)?.body { return true }; return false }
        #expect(model.renderContext(key).textFormat == .flowed(delSp: false))
        guard case .rendered(.plain(let document))? = model.message(key)?.body else { return }
        #expect(document.blocks.first?.text.contains("soft wrapped by the sender.") == true)
        #expect(ReaderModel.plainTextFormat(.fixed) == .fixed)
        #expect(ReaderModel.plainTextFormat(.flowed(delSp: true)) == .flowed(delSp: true))
    }

    @Test func savedAttachmentsAreQuarantined() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reader-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.pdf")
        try Data("%PDF-1.4 synthetic".utf8).write(to: source)
        #expect(AttachmentFiles.quarantine(of: source) == nil)
        let info = AttachmentInfo(id: 77, filename: "../Q4\u{202E}fdp.command", mimeType: "application/pdf", size: 18,
                                  contentID: nil, isInline: false)
        let detail = ConversationDetail(id: F.thread(18), subject: "Files",
                                        messages: [F.summary(1_800, from: F.dana, attachments: [info])])
        let (model, _, _) = model([detail], bodies: [:], open: detail.id, files: [77: source])
        let key = detail.messages[0].id

        let opened = try await model.attachmentFile(info, of: key)
        #expect(AttachmentFiles.quarantine(of: opened)?.hasPrefix(FileQuarantine.flags + ";") == true)
        #expect(AttachmentFiles.quarantine(of: opened)?.contains(";\(FileQuarantine.agent);") == true)

        let out = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let saved = try await model.saveAttachment(info, of: key, to: out)
        #expect(saved.lastPathComponent == "-Q4fdp.command", "no path, no direction override")
        #expect(saved.deletingLastPathComponent().standardizedFileURL == out.standardizedFileURL)
        #expect(AttachmentFiles.quarantine(of: saved) == AttachmentFiles.quarantine(of: opened), "the copy keeps the flag")
        let again = try await model.saveAttachment(info, of: key, to: out)
        #expect(again.lastPathComponent == "-Q4fdp 2.command")
        let explicit = out.appendingPathComponent("chosen.pdf")
        let chosen = try await model.saveAttachment(info, of: key, to: explicit)
        #expect(chosen == explicit)
        #expect(AttachmentFiles.quarantine(of: chosen) != nil)

        let missing = AttachmentInfo(id: 78, filename: "x.pdf", mimeType: "application/pdf", size: 1, contentID: nil, isInline: false)
        await #expect(throws: MailPortError.notFound("attachment")) { try await model.attachmentFile(missing, of: key) }
    }
}

@MainActor
final class RecordingAccessory: ReaderHeaderAccessory {
    var asked: [MessageKey] = []
    var activated: [MessageKey] = []

    func item(for message: MessageSummary, in thread: ThreadKey) async -> ReaderHeaderAccessoryItem? {
        asked.append(message.id)
        return ReaderHeaderAccessoryItem(title: "Unsubscribe", accessibilityLabel: "Unsubscribe from the list")
    }

    func activate(_ item: ReaderHeaderAccessoryItem, for message: MessageSummary, in thread: ThreadKey) {
        activated.append(message.id)
    }
}

@MainActor
func eventuallyAsync(timeout: Duration = minimumWaitCeiling, _ condition: @MainActor () async -> Bool,
                     sourceLocation: SourceLocation = #_sourceLocation) async {
    let clock = ContinuousClock()
    let ceiling = max(timeout, minimumWaitCeiling)
    let deadline = clock.now + ceiling
    while !(await condition()) {
        if clock.now > deadline {
            Issue.record("condition not met within \(ceiling)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
