import Foundation
import MailActions
import MailFakes
import MailModel
import MailRender
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
final class RecordingPrinter: ConversationPrinting {
    var documents: [ConversationPrintDocument] = []
    func print(_ document: ConversationPrintDocument) { documents.append(document) }
}

@MainActor
@Suite struct SuperhumanCorePass2Tests {
    private static let account = AccountID(1)
    private static let thread = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1"))

    @Test func removeLabelAndDoneTakesTheLabelAndTheInboxInOneUndoEntry() async throws {
        let f = ActionFixture()
        await f.loaded()
        let key = try #require(f.router.list?.cursor)
        _ = try await f.store.createLabel(Self.account, name: "Projects", applyTo: [key])
        var labels: [LabelInfo] = []
        for try await list in f.store.labels(Self.account) {
            labels = list
            break
        }
        let label = try #require(labels.first { $0.name == "Projects" })
        await eventually { f.router.active?.labels.contains { $0.labelID == label.labelID } == true }
        #expect(!f.registry.availability(.removeLabelAndDone, host: f.router).isEnabled, "only inside a label's view")
        f.router.go(to: .label(label.labelID))
        await eventually { f.router.list?.state == .loaded && f.router.list?.row(for: key) != nil }
        var context = f.router.actionContext()
        context.selection = [key]
        context.focusedThread = key
        #expect(await f.run(.removeLabelAndDone, context: context))
        await f.toast("Removed label Projects and marked done")
        await eventually { f.router.list?.row(for: key) == nil }
        let inbox = try await f.store.threadPage(.system(.inbox), account: Self.account, after: nil, limit: 500).rows
        #expect(!inbox.contains { $0.id == key })
        #expect(await f.run(.undo))
        await eventually { f.router.list?.row(for: key) != nil }
    }

    @Test func checkFromHereChecksTheCursorRowAndEveryRowBelow() async throws {
        let f = ActionFixture()
        await f.loaded()
        let rows = f.rows.map(\.id)
        try #require(rows.count >= 4)
        f.router.list?.moveCursor(by: 2)
        #expect(f.router.list?.cursor == rows[2])
        #expect(await f.run(.checkFromHere))
        #expect(f.router.active?.selection.checked == Set(rows[2...]))
    }

    @Test func somedayIsARemindRowThatSetsAReminderWithNoDate() {
        var chosen: TimeChoice?
        let picker = TimePickerModel(kind: .remind, targets: [Self.thread]) { chosen = $0 }
        let row = picker.rows.first { $0.kind == .someday }
        #expect(row?.number == nil && row?.title == "Someday")
        if let row { picker.choose(row) }
        #expect(chosen == .at(ReminderItem.someday, .ifNoReply), "the default 'Only if no reply' applies")
        #expect(TimePickerModel(kind: .snooze, targets: [Self.thread]) { _ in }.rows.allSatisfy { $0.kind != .someday })
        let item = ReminderItem(id: "r", thread: Self.thread, subject: "s", dueAt: ReminderItem.someday, kind: .always)
        #expect(item.isSomeday)
        #expect(!ReminderItem(id: "r", thread: Self.thread, subject: "s", dueAt: fixedNow, kind: .always).isSomeday)
        let current = TimePickerModel(kind: .remind, targets: [Self.thread]) { _ in }
        current.apply(snooze: nil, reminder: item)
        #expect(current.currentLine == "Current: Someday")
    }

    @Test func aSomedayReminderSaysSomedayInItsToastAndInReminders() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await f.loaded()
        let key = try #require(f.router.list?.cursor)
        await f.registry.threadActions?.remind(key, at: ReminderItem.someday, kind: .always, host: f.router)?.value
        await f.toast("Reminder set for someday")
        let row = ThreadRow(id: key, subject: "s", snippet: "", participantsDisplay: "", participants: [], messageCount: 1,
                            unreadCount: 0, draftCount: 0, attachmentCount: 0, isUnread: false, isStarred: false,
                            isImportant: false, userLabelIDs: [], lastMessageAt: fixedNow, sortAt: ReminderItem.someday,
                            reminderAt: ReminderItem.someday)
        let shown = ThreadRowFormatting().dateColumn(row, location: .system(.reminders), now: fixedNow)
        #expect(shown.text == "Someday" && shown.isUpcoming)
    }

    @Test func quickQuoteKeepsTheAttributionAndQuotesOnlyTheSelection() {
        let html = "<div class=\"gmail_quote\" data-oh-quote=\"1\"><div class=\"gmail_attr\">On Tue, Dana wrote:<br></div>"
            + "<blockquote class=\"gmail_quote\">Long original</blockquote></div>"
        let cut = QuickQuote.quote("Just <this>\npart", mode: .reply, html: html, text: "On Tue, Dana wrote:\n> Long original")
        #expect(cut.html.hasPrefix("<div class=\"gmail_quote\" data-oh-quote=\"1\"><div class=\"gmail_attr\">On Tue"))
        #expect(cut.html.contains("Just &lt;this&gt;<br>part") && !cut.html.contains("Long original"))
        #expect(QuoteSplit.quoteBlockCount(cut.html) == 1)
        #expect(cut.text == "On Tue, Dana wrote:\n> Just <this>\n> part")
        let forwardHTML = "<div class=\"gmail_quote\" data-oh-quote=\"1\"><div class=\"gmail_attr\">"
            + "---------- Forwarded message ---------<br>From: Dana<br></div><br><br>Body</div>"
        let forward = QuickQuote.quote("Only this", mode: .forward, html: forwardHTML,
                                       text: "---------- Forwarded message ---------\nFrom: Dana\n\nBody")
        #expect(forward.html.contains("Only this") && !forward.html.contains("Body"))
        #expect(forward.text == "---------- Forwarded message ---------\nFrom: Dana\n\nOnly this")
        #expect(QuoteSelection(message: MessageKey(account: Self.account, rowID: 1, gmailMessageID: GmailMessageID("m")),
                               text: " \n ") == nil)
    }

    @Test func aReplyWithTextSelectedQuotesOnlyThatText() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let key = try #require(f.router.list?.cursor)
        f.router.open(key)
        let reader = try #require(f.router.active?.reader)
        await eventually { reader.state == .loaded && !reader.messages.isEmpty }
        let message = try #require(reader.messages.last?.id)
        reader.setQuoteSelection("  a selected line  ", in: message)
        #expect(reader.quoteSelection?.text == "a selected line")
        #expect(await f.run(.reply))
        let session = try #require(f.compose.sessions.last)
        await session.settle()
        await eventually { !session.quotedHTML.isEmpty }
        #expect(session.quotedHTML.contains("a selected line"))
        #expect(QuoteSplit.quoteBlockCount(session.quotedHTML) == 1)
        #expect(session.replyTo == message)
        await session.settle()
        let draftKey = try #require(session.draftKey)
        let draft = try #require(await f.draftRow(draftKey))
        #expect(draft.fields.bodyHTML.contains("a selected line"))
        reader.setQuoteSelection("", in: message)
        #expect(reader.quoteSelection == nil, "an empty selection in the same message clears it")
    }

    @Test func includeOriginalAttachmentsAddsTheAnsweredMessagesFilesOnce() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let rows = try await f.store.threadPage(.system(.allMail), account: ComposeFixture.work, after: nil, limit: 1_000).rows
        var found: (ThreadKey, [AttachmentInfo])?
        for row in rows where row.attachmentCount > 0 {
            var detail: ConversationDetail?
            for try await value in f.store.threadDetail(row.id) {
                detail = value
                break
            }
            let files = detail?.messages.last?.attachments.filter { !$0.isInline } ?? []
            if !files.isEmpty {
                found = (row.id, files)
                break
            }
        }
        let (key, files) = try #require(found)
        let session = try #require(f.compose.openReply(key, mode: .reply))
        await session.settle()
        #expect(await f.run(.includeOriginalAttachments, in: session))
        #expect(session.attachments.compactMap(\.sourceAttachmentID) == files.map(\.id))
        #expect(await f.run(.includeOriginalAttachments, in: session))
        #expect(session.attachments.count == files.count, "never twice")
        f.compose.close(session)
        let forward = try #require(f.compose.openReply(key, mode: .forward))
        await forward.settle()
        #expect(f.env.actions.availability(.includeOriginalAttachments, host: forward) == .hidden)
    }

    @Test func repliesStartWithoutTheSignatureWhenTheSettingIsOff() async throws {
        let f = ComposeFixture()
        await f.loaded()
        try await f.store.set(AppSettings.signatureOnReplies, false)
        let key = try #require(f.router.list?.cursor)
        let session = try #require(f.compose.openReply(key, mode: .reply))
        await session.settle()
        #expect(!session.includesSignature)
        #expect(!session.hasUserEdits, "not a user edit")
    }

    @Test func snippetPhrasesAreFoundAndABackslashKeepsABrace() {
        #expect(SnippetExpander.phrases(in: "Hi {name}, about {{first_name}} and \\{literal} and {company name}")
            == ["name", "company name"])
        #expect(SnippetExpander.phrases(in: "{}{ }{a\nb}").isEmpty)
        #expect(SnippetExpander.expand("Keep \\{this} as is", context: SnippetContext()).text == "Keep {this} as is")
        #expect(SnippetExpander.expand("Keep \\{{this}} as is", context: SnippetContext()).text == "Keep {{this}} as is")
    }

    @Test func aSnippetsPhraseCountsAsUnfilledUntilReplaced() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let snippet = SnippetInfo(name: "Intro", bodyHTML: "<p>Hello {name}, meet {{first_name}}</p>")
        session.didInsertSnippet(session.insertion(snippet, range: nil), unresolved: [])
        session.updateBody(doc("Hello {name}, meet Sam"))
        #expect(session.unfilledPlaceholders == ["name"])
        session.updateBody(doc("Hello Dana, meet Sam"))
        #expect(session.unfilledPlaceholders.isEmpty)
    }

    @Test func saveMessageAsSnippetStoresTheMessagesOwnText() async throws {
        let f = ActionFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await f.loaded()
        let key = try #require(f.router.list?.cursor)
        f.router.open(key)
        await eventually { f.router.active?.reader?.state == .loaded && f.router.active?.reader?.messages.isEmpty == false }
        #expect(await f.run(.saveMessageAsSnippet))
        await eventually { f.toastMessages.contains { $0.hasPrefix("Saved snippet") } }
        var snippets: [SnippetInfo] = []
        for try await list in f.store.snippets(Self.account) {
            snippets = list
            break
        }
        #expect(snippets.contains { !$0.bodyHTML.isEmpty && $0.account == Self.account })
    }

    @Test func addToSplitOffersSafeRuleFragments() {
        let choices = AddToSplit.choices(sender: "Dana@Example.com", recipient: "sam@example.org",
                                         subject: "Re: Quarterly plan", labels: ["Clients", "bad\"label"])
        #expect(choices.map(\.fragment) == ["from:dana@example.com", "from:@example.com", "to:sam@example.org",
                                            "subject:\"Quarterly plan\"", "label:\"Clients\""])
        #expect(AddToSplit.choices(sender: "not an address", recipient: nil, subject: "", labels: []).isEmpty)
        #expect(AddToSplit.appending("from:@example.com", to: "label:Clients") == "(label:Clients) OR from:@example.com")
        #expect(AddToSplit.appending("from:@example.com", to: "from:@EXAMPLE.com") == "from:@EXAMPLE.com")
        #expect(AddToSplit.appending("from:a@example.com", to: "  ") == "from:a@example.com")
        let splits = [SplitInfo(id: SplitKey("1"), account: Self.account, name: "Important", position: 0, ruleText: "is:important"),
                      SplitInfo(id: SplitKey("2"), account: Self.account, name: "Clients", position: 1, ruleText: "label:Clients")]
        #expect(AddToSplit.targets(splits).map(\.name) == ["Clients"])
    }

    @Test func addToSplitWritesTheRuleAndOneUndoPutsItBack() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 40, now: fixedNow))
        await f.loaded()
        let state = try #require(f.router.active)
        await eventually { !AddToSplit.targets(state.splits).isEmpty }
        let split = try #require(AddToSplit.targets(state.splits).first)
        let handler = try #require(f.registry.superhumanCore)
        let choice = SplitRuleChoice(kind: .domain, value: "example.net")
        #expect(await handler.addToSplit(choice, into: split.id, account: state.id))
        await eventually { state.splits.first { $0.id == split.id }?.ruleText.contains("from:@example.net") == true }
        #expect(await f.run(.undo))
        await eventually { state.splits.first { $0.id == split.id }?.ruleText == split.ruleText }
    }

    @Test func addToSplitOpensThePaletteOnItsChoices() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 40, now: fixedNow))
        await f.loaded()
        await eventually { !(f.router.active?.splits.isEmpty ?? true) }
        #expect(await f.run(.addToSplit))
        let palette = try #require(f.palette)
        #expect(palette.query == AddToSplit.paletteQuery)
        #expect(palette.entries.contains { if case .addToSplit = $0.kind { true } else { false } })
        #expect(!palette.entries.contains { $0.kind == .action(.addToSplit) }, "not listed again inside its own palette")
    }

    @Test func archiveSuggestionsLeaveOutWhatTheAuthorCaresAbout() {
        let rules = ArchiveSuggestionRules(overrides: ["vip@example.com": .never, "@deals.example": .always],
                                           ownDomains: ["example.com", "gmail.com"])
        var promo = ArchiveSuggestionFacts(sender: "offers@shop.example")
        promo.categories = ["promotions"]
        #expect(rules.decide(promo) == .include)
        #expect(rules.decide(ArchiveSuggestionFacts(sender: "sam@example.com")) == .exclude(.ownDomain))
        #expect(rules.decide(ArchiveSuggestionFacts(sender: "friend@gmail.com")) == .include, "a mail provider is not a colleague")
        #expect(rules.decide(ArchiveSuggestionFacts(sender: "vip@example.com")) == .exclude(.neverRule))
        var starredDeal = ArchiveSuggestionFacts(sender: "a@deals.example")
        starredDeal.isStarred = true
        #expect(rules.decide(starredDeal) == .include, "an Always rule beats the exceptions")
        var spamDeal = starredDeal
        spamDeal.isSpam = true
        #expect(rules.decide(spamDeal) == .exclude(.spam), "Gmail spam wins")
        var labeled = promo
        labeled.userLabels = ["Newsletters"]
        #expect(rules.decide(labeled) == .include)
        labeled.userLabels = ["Clients"]
        #expect(rules.decide(labeled) == .exclude(.userLabel))
        var respond = promo
        respond.categories = ["[Superhuman]/AI/Respond"]
        #expect(rules.decide(respond) == .exclude(.needsAttention))
        var wrote = promo
        wrote.authorWroteToSender = true
        #expect(rules.decide(wrote) == .exclude(.wroteToSender))
        for flag in [\ArchiveSuggestionFacts.isSnoozed, \.hasReminder, \.isMuted, \.isImportantByRule] {
            var facts = promo
            facts[keyPath: flag] = true
            #expect(rules.decide(facts) != .include)
        }
    }

    @Test func thePrintDocumentScopesEachMessageAndLoadsNothingRemote() {
        let html = ConversationPrint.html(subject: "Plan <b>", messages: [
            PrintedMessage(from: "Dana <dana@example.com>", to: "Sam <sam@example.com>", date: "Mon",
                           content: MessageContent(html: "<style>p { color: red }</style><p>First</p>", text: nil)),
            PrintedMessage(from: "Sam", to: "Dana", date: "Tue", content: MessageContent(html: nil, text: "Second <line>")),
            PrintedMessage(from: "Lee", to: "Dana", date: "Wed", content: nil),
        ])
        #expect(html.contains("Plan &lt;b&gt;") && html.contains("Dana &lt;dana@example.com&gt;"))
        #expect(html.contains("oh-print-m0") && html.contains("oh-print-m1") && html.contains("oh-print-m2"))
        #expect(html.contains(".oh-print-m0 .oh-body"), "an email's stylesheet stays on its own message")
        #expect(html.contains("img-src ohcid: data:;"), "the CSP allows no remote image")
        #expect(html.contains("Second &lt;line&gt;") && html.contains("isn't downloaded"))
    }

    @Test func printHandsTheConversationToThePrinterInReadOnlyToo() async throws {
        let f = ActionFixture(corpus: .rich(threadCount: 20, now: fixedNow), options: .init(remoteAck: .immediate, safeMode: .readOnly))
        await f.loaded()
        let printer = RecordingPrinter()
        f.registry.superhumanCore?.printer = printer
        let key = try #require(f.router.list?.cursor)
        #expect(!f.registry.availability(.printConversation, host: f.router).isEnabled, "only in a conversation")
        f.router.open(key)
        await eventually { f.router.active?.reader?.state == .loaded }
        #expect(await f.run(.printConversation))
        let document = try #require(printer.documents.first)
        #expect(document.html.contains("oh-print-message"))
        #expect(!f.registry.availability(.addToSplit, host: f.router).isEnabled, "split edits are refused in read-only")
    }

    @Test func theContactPaneIsAboutTheNewestOtherPerson() {
        let me = "me@example.com"
        func message(_ n: Int64, from: String, to: [String]) -> MessageSummary {
            MessageSummary(id: MessageKey(account: Self.account, rowID: n, gmailMessageID: GmailMessageID("m\(n)")),
                           from: EmailAddress(email: from), to: to.map { EmailAddress(email: $0) }, cc: [], bcc: [],
                           date: fixedNow, snippet: "", isUnread: false, attachments: [])
        }
        let detail = ConversationDetail(id: Self.thread, subject: "s",
                                        messages: [message(1, from: "dana@example.com", to: [me]),
                                                   message(2, from: me, to: ["lee@example.com"])])
        #expect(ContextSidebarModel.person(in: detail, isMe: { $0 == me })?.email == "lee@example.com")
        #expect(ContextSidebarModel.Person(name: "Dana Ruiz", email: "d@example.com").initials == "DR")
        #expect(ContextSidebarModel.Person(name: nil, email: "d@example.com").initials == "D")
        #expect(ContextSidebarModel.query(for: "d@example.com")
            == "from:\"d@example.com\" OR to:\"d@example.com\" OR cc:\"d@example.com\"")
    }

    @Test func theContactPaneTogglesAndListsRecentConversations() async throws {
        let f = ActionFixture(corpus: .rich(threadCount: 40, now: fixedNow))
        await f.loaded()
        let model = try #require(f.registry.superhumanCore?.contextSidebar)
        #expect(!model.isVisible)
        #expect(await f.run(.toggleContextSidebar))
        #expect(model.isVisible)
        let key = try #require(f.router.list?.cursor)
        await model.show(thread: key)
        #expect(model.person != nil)
        #expect(model.recent.count <= ContextSidebarModel.recentLimit)
        #expect(!model.recent.contains { $0.id == key }, "the open conversation is not listed")
    }

    @Test func zoomWorksFromThePalette() async throws {
        let f = ActionFixture()
        await f.loaded()
        let handler = try #require(f.registry.superhumanCore)
        handler.zoom = ReaderPreferences(defaults: nil)
        #expect(!f.registry.availability(.zoomReset, host: f.router).isEnabled, "already actual size")
        #expect(await f.run(.zoomIn))
        #expect(handler.zoom.textZoom > 1)
        #expect(await f.run(.zoomReset))
        #expect(handler.zoom.textZoom == 1)
    }
}
