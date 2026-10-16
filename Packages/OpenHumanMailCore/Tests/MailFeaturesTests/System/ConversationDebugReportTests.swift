import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct ConversationDebugReportTests {
    static let account = AccountID(1)
    static let thread = ThreadKey(account: account, rowID: 7, gmailThreadID: GmailThreadID("18c0ffee00112233"))
    static let now = Date(timeIntervalSince1970: 1_791_000_000)
    static let subject = "Invite ya29.A0ARrdaMsecretTOKEN for refresh_token=1//0gSECRET quarterly review"
    static let senderName = "Zelda Quimby ya29.NAMEtoken"
    static let senderAddress = "zelda.quimby@invites.example.org"
    static let ownAddress = "me.myself@home.example.net"
    static let otherAddress = "bob.builder@other.example.com"
    static let snippet = "snippet words about the secret merger"
    static let fileName = "Quarterly-Numbers-Final.xlsx"

    static func message(_ n: Int, from: EmailAddress, invite: Bool, attachments: [AttachmentInfo] = []) -> MessageSummary {
        MessageSummary(id: MessageKey(account: account, rowID: Int64(n), gmailMessageID: GmailMessageID("m\(n)")),
                       from: from, to: [EmailAddress(name: "Bob Builder", email: otherAddress)], cc: [],
                       bcc: [], date: now.addingTimeInterval(Double(n) * 60), snippet: snippet, isUnread: n == 2,
                       attachments: attachments, hasCalendarInvite: invite)
    }

    static func input(options: ConversationDebugOptions = ConversationDebugOptions(), invite: Bool = false,
                      logLines: [String]? = nil) -> ConversationDebugInput {
        let attachment = AttachmentInfo(id: 1, filename: fileName, mimeType: "application/vnd.ms-excel", size: 2048,
                                        contentID: nil, isInline: false)
        let messages = [
            message(1, from: EmailAddress(name: senderName, email: senderAddress), invite: invite, attachments: [attachment]),
            message(2, from: EmailAddress(name: "Me", email: ownAddress), invite: false),
        ]
        let detail = ConversationDetail(id: thread, subject: subject, messages: messages, userLabelIDs: [11], isStarred: true)
        let labels = [
            LabelInfo(id: 11, account: account, labelID: GmailLabelID("Label_11"), kind: .user, name: "Clients/Acme",
                      displayName: "Acme", colorBackground: "#fb4c2f", colorText: "#ffffff", position: 1),
            LabelInfo(id: 12, account: account, labelID: GmailLabelID("INBOX"), kind: .system, name: "INBOX",
                      displayName: "Inbox", position: 0),
            LabelInfo(id: 13, account: account, labelID: GmailLabelID("CATEGORY_PROMOTIONS"), kind: .category,
                      name: "Promotions", displayName: "Promotions", position: 2),
        ]
        let splits = [
            SplitInfo(id: SplitKey("s-events"), account: account, name: "Events", position: 1, ruleText: "has:invite"),
            SplitInfo(id: SplitKey("s-clients"), account: account, name: "Clients", position: 2,
                      ruleText: "from:(@invites.example.org) OR label:Clients/Acme"),
            SplitInfo(id: SplitKey("s-private"), account: account, name: "Private", position: 3,
                      ruleText: "from:zelda.quimby@invites.example.org -is:unread"),
        ]
        let store = ConversationDebugStoreFacts(messages: [
            ConversationDebugStoreMessage(message: messages[0].id, labelIDs: ["INBOX", "Label_11"], bodyState: "metadata",
                                          sizeBytes: 4096, headerNames: ["From", "To", "Subject", "Date"],
                                          mimeParts: [ConversationDebugMimePart(contentType: "text/plain", size: 100),
                                                      ConversationDebugMimePart(contentType: "application/vnd.ms-excel", size: 2048,
                                                                                fileExtension: "xlsx")],
                                          aiCache: ["summary": "3"]),
            ConversationDebugStoreMessage(message: messages[1].id, labelIDs: ["SENT"], bodyState: "full"),
        ])
        let log = logLines ?? [
            "sync ok thread=18c0ffee00112233 from \(senderAddress) subject \(subject)",
            "unrelated line",
            "fetch thread=18c0ffee00112233 token=ya29.LOGTOKEN \(snippet) name \(senderName)",
        ]
        return ConversationDebugInput(
            app: DiagnosticsAppInfo(version: "1.2", build: "34", gitCommit: "abc1234", os: "Version 27.0", dataMode: "live"),
            now: now.addingTimeInterval(600), accountIndex: 1, isLiveAccount: false,
            sync: DiagnosticsSnapshot.AccountEntry(index: 1, health: "active", connectivity: "online", lastSyncAt: now,
                                                   threadCount: 40, messageCount: 90, draftCount: 0, pendingOperations: 0,
                                                   failedOperations: 0),
            detail: detail, labels: labels, splits: splits,
            importance: ImportanceExplanation(isImportant: false, placement: "Other",
                                              reason: "Never important from \(senderAddress)", ruleID: "r1"),
            ownAddresses: [ownAddress], store: store, logLines: log, options: options)
    }

    static func decode(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? [String: Any])
    }

    @Test func isParsableJSONWithTheFormatTag() throws {
        let json = try Self.decode(ConversationDebugReport.build(Self.input()))
        #expect(json["format"] as? String == ConversationDebugReport.format)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["position"] as? Int == 1)
        #expect(messages[0]["fromDomain"] as? String == "invites.example.org")
        #expect(messages[0]["fromIsOwn"] as? Bool == false)
        #expect(messages[1]["fromIsOwn"] as? Bool == true)
        #expect(messages[0]["bodyDownloaded"] as? String == "no (format metadata only)")
        #expect(messages[1]["bodyDownloaded"] as? String == "yes (full)")
        #expect((messages[0]["mimeParts"] as? [String])?.last == "application/vnd.ms-excel 2048B .xlsx")
        #expect(messages[0]["aiCache"] as? String == "summary=yes(v3) replies=no classification=no")
    }

    @Test func nothingPrivateLeaksWithDefaultSettings() {
        let text = ConversationDebugReport.build(Self.input())
        for forbidden in [Self.subject, "ya29", "refresh_token", "1//0gSECRET", "quarterly review", Self.senderName, "Zelda",
                          "Quimby", Self.senderAddress, Self.ownAddress, Self.otherAddress, "zelda.quimby", "bob.builder",
                          "Bob Builder", Self.snippet, "secret merger", Self.fileName, "Quarterly-Numbers", "LOGTOKEN",
                          "@home.example.net", "@other.example.com"] {
            #expect(!text.localizedCaseInsensitiveContains(forbidden), "leaked: \(forbidden)")
        }
        #expect(text.contains("invites.example.org"))
    }

    @Test func optInAddsSubjectAndSenderNameButStillScrubsTokensAndAddresses() throws {
        let text = ConversationDebugReport.build(Self.input(options: ConversationDebugOptions(includeSubjectAndSender: true)))
        let json = try Self.decode(text)
        let thread = try #require(json["thread"] as? [String: Any])
        #expect((thread["subject"] as? String)?.isEmpty == false)
        #expect(text.contains("Zelda"))
        for forbidden in ["ya29", "refresh_token=1", Self.senderAddress, Self.ownAddress, Self.otherAddress, Self.snippet,
                          Self.fileName, "LOGTOKEN"] {
            #expect(!text.contains(forbidden), "leaked even with opt-in: \(forbidden)")
        }
    }

    @Test func splitVerdictsNameTheTermAndWhy() throws {
        let off = try Self.decode(ConversationDebugReport.build(Self.input(invite: false)))
        let splits = try #require(off["splits"] as? [[String: Any]])
        let events = try #require(splits.first { $0["name"] as? String == "Events" })
        #expect(events["wouldMatch"] as? Bool == false)
        #expect(events["terms"] as? [String] == ["has_calendar_invite=false"])
        let on = try Self.decode(ConversationDebugReport.build(Self.input(invite: true)))
        let eventsOn = try #require((on["splits"] as? [[String: Any]])?.first { $0["name"] as? String == "Events" })
        #expect(eventsOn["wouldMatch"] as? Bool == true)
        #expect(eventsOn["terms"] as? [String] == ["has_calendar_invite=true"])
        let clients = try #require(splits.first { $0["name"] as? String == "Clients" })
        #expect(clients["wouldMatch"] as? Bool == true)
        #expect(clients["terms"] as? [String] == ["from:@invites.example.org=true", "label:Clients/Acme=true"])
    }

    @Test func splitRuleValuesThatAreAddressesAreNotPrinted() throws {
        let json = try Self.decode(ConversationDebugReport.build(Self.input()))
        let splits = try #require(json["splits"] as? [[String: Any]])
        let privateSplit = try #require(splits.first { $0["name"] as? String == "Private" })
        #expect(privateSplit["terms"] as? [String] == ["from:<value>=true", "is_unread=true"])
        #expect(!((privateSplit["rule"] as? String) ?? "").contains("@invites"))
    }

    @Test func filedInComesFromTheImportancePlacementAndRuleSpecificity() throws {
        let json = try Self.decode(ConversationDebugReport.build(Self.input()))
        let importance = try #require(json["importance"] as? [String: Any])
        #expect(importance["placement"] as? String == "Other")
        #expect(importance["ruleSpecificity"] as? String == "sender")
        #expect(!(importance["reason"] as? String ?? "").contains(Self.senderAddress))
    }

    @Test func threadFlagsLabelsAndAccountState() throws {
        let json = try Self.decode(ConversationDebugReport.build(Self.input()))
        let thread = try #require(json["thread"] as? [String: Any])
        #expect(thread["starred"] as? Bool == true)
        #expect(thread["messageCount"] as? Int == 2)
        let labels = try #require(thread["labels"] as? [[String: String]])
        #expect(labels.contains { $0["name"] == "Clients/Acme" && $0["kind"] == "user" })
        #expect(!ConversationDebugReport.build(Self.input()).contains("#fb4c2f"))
        let account = try #require(json["account"] as? [String: Any])
        #expect(account["index"] as? Int == 1)
        #expect(account["lastSyncAgeSeconds"] as? Int == 600)
        #expect(account["liveAccount"] as? Bool == false)
    }

    @Test func theReportSaysWhetherTheSessionIsALiveAccount() async throws {
        let corpus = FakeCorpus.make(threadCount: 3, now: Self.now)
        let thread = try #require(corpus.mailboxes.first?.threads.first?.row.id)
        let live = AppEnvironment(data: FakeMailStore(corpus: corpus), isFake: true, isLiveAccount: true)
        let fake = AppEnvironment.fake(corpus: corpus)
        let options = ConversationDebugOptions()
        let liveInput = try #require(await ConversationDebugCollector(environment: live).collect(thread, options: options))
        let fakeInput = try #require(await ConversationDebugCollector(environment: fake).collect(thread, options: options))
        #expect(liveInput.isLiveAccount && !fakeInput.isLiveAccount)
        let liveAccount = try #require(try Self.decode(ConversationDebugReport.build(liveInput))["account"] as? [String: Any])
        let fakeAccount = try #require(try Self.decode(ConversationDebugReport.build(fakeInput))["account"] as? [String: Any])
        #expect(liveAccount["liveAccount"] as? Bool == true)
        #expect(fakeAccount["liveAccount"] as? Bool == false)
        #expect(ConversationDebugReport.build(liveInput) != ConversationDebugReport.build(fakeInput))
    }

    @Test func logKeepsOnlyScrubbedLinesForThisThreadAtMostTwenty() throws {
        let many = (0..<30).map { "line \($0) thread=18c0ffee00112233 from \(Self.senderAddress)" } + ["other thread=zzz"]
        let json = try Self.decode(ConversationDebugReport.build(Self.input(logLines: many)))
        let log = try #require(json["log"] as? [String])
        #expect(log.count == 20)
        #expect(log.last?.contains("line 29") == true)
        #expect(log.allSatisfy { !$0.contains(Self.senderAddress) })
    }

    @Test func withoutStoreFactsTheReportSaysUnknown() throws {
        var input = Self.input()
        input.store = nil
        let json = try Self.decode(ConversationDebugReport.build(input))
        let message = try #require((json["messages"] as? [[String: Any]])?.first)
        #expect(message["bodyDownloaded"] as? String == "unknown")
        #expect(message["bodyHorizon"] as? String == "unknown")
        #expect(message["aiCache"] as? String == "unknown")
        #expect((message["mimeParts"] as? [String]) == ["application/vnd.ms-excel 2048B .xlsx"])
    }

    @Test func unparsableRuleIsReportedNotGuessed() {
        let outcome = SplitRuleEvaluator.evaluate("from:(unclosed", facts: SplitFacts(messages: [], labels: []))
        #expect(outcome.matches == nil)
    }

    @Test func catalogEntriesHaveNoKeyAndChangeNoMail() throws {
        for id in [ActionID.copyConversationDebug, .saveConversationDebug] {
            let descriptor = try #require(ActionCatalog.descriptor(id))
            #expect(descriptor.defaultBindings.isEmpty)
            #expect(descriptor.module == .diagnostics)
            #expect(descriptor.appearsInPalette)
            #expect(descriptor.changesMail == false)
        }
        #expect(ActionCatalog.descriptor(.copyConversationDebug)?.title == "Copy debug info for this conversation")
    }

    @Test func theActionsShowOnlyWhileTheDebuggingToolsAreShown() {
        let environment = AppEnvironment.fake(corpus: FakeCorpus.make(threadCount: 1, now: Self.now))
        let handler = ConversationDebugActionHandler(environment: environment)
        let context = ActionContext(scope: .reader)
        for id in ConversationDebugActionHandler.ids {
            #expect(handler.availability(of: id, in: context, host: nil) == .hidden, "off unless a dev-tools build turns it on")
        }
        var shown = true
        environment.system.showsDebuggingTools = { shown }
        for id in ConversationDebugActionHandler.ids {
            #expect(handler.availability(of: id, in: context, host: nil) == .enabled)
        }
        shown = false
        for id in ConversationDebugActionHandler.ids {
            #expect(handler.availability(of: id, in: context, host: nil) == .hidden)
        }
    }

    @Test func suggestedFileNameIsUTC() {
        #expect(ConversationDebugActionHandler.suggestedFileName(now: Date(timeIntervalSince1970: 1_791_000_000))
                == "Mail-Conversation-Debug-20261003-040000.json")
    }
}
