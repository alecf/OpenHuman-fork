import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct SuperhumanReminderImportTests {
    private struct Fixture {
        let store: FakeMailStore
        let account: AccountID
        let threads: [ThreadKey]

        init() {
            let corpus = FakeCorpus.make(threadCount: 6, now: fixedNow)
            store = FakeMailStore(corpus: corpus, options: .init(remoteAck: .immediate, now: { fixedNow }))
            account = corpus.account.id
            threads = corpus.threads.map(\.row.id)
        }

        func email(_ n: Int, in thread: ThreadKey, match: SuperhumanReminderEmail.Match, inInbox: Bool = true,
                   hidden: Bool = false, targetInInbox: Bool = false, minutesAgo: Int = 10) -> SuperhumanReminderEmail {
            SuperhumanReminderEmail(id: MessageKey(account: account, rowID: Int64(9000 + n), gmailMessageID: GmailMessageID("r\(n)")),
                                    thread: thread, date: fixedNow.addingTimeInterval(Double(-minutesAgo * 60)),
                                    isInInbox: inInbox, isHidden: hidden, match: match, subject: "Plan \(n)",
                                    targetInInbox: targetInInbox)
        }

        func importer(commands: Bool = true) -> SuperhumanReminderImport {
            SuperhumanReminderImport(settings: store, commands: commands ? store : nil, scan: { _ in [] })
        }

        func inbox() async throws -> Set<ThreadKey> {
            for try await window in store.threadWindow(.system(.inbox), account: account, limit: 100) {
                return Set(window.rows.map(\.id))
            }
            return []
        }
    }

    @Test func thePreviewSortsAndCountsWithoutWritingAnything() async throws {
        let f = Fixture()
        let a = f.threads[0], b = f.threads[1], own = f.threads[2], lone = f.threads[3]
        let emails = [
            f.email(1, in: a, match: .sameConversation),
            f.email(2, in: a, match: .sameConversation),
            f.email(3, in: own, match: .replyHeaders(b)),
            f.email(4, in: lone, match: .unmatched),
            f.email(5, in: a, match: .sameConversation, hidden: true),
        ]
        let importer = SuperhumanReminderImport(settings: f.store, commands: f.store, scan: { _ in emails })
        let preview = try await importer.preview(accounts: [f.account])
        #expect(preview.inConversation.count == 2 && preview.matched.count == 1 && preview.unmatched.count == 1)
        #expect(preview.alreadyHandled == 1 && preview.found == 5 && preview.changeCount == 3)
        #expect(preview.conversationCount == 2, "two emails, one conversation")
        #expect(preview.conversationsToBringBack == [b] && preview.conversationsToArchive == [own])
        #expect(SuperhumanRemindersSettingsModel.summary(preview).hasPrefix("5 reminder emails found."))
        #expect(try await f.store.get(AppSettings.superhumanRemindersBacklogImported) == false)
        #expect(try await f.store.get(AppSettings.superhumanRemindersConverted(f.account)).isEmpty)
    }

    @Test func applyIsOneUndoableStep() async throws {
        let f = Fixture()
        let a = f.threads[0], b = f.threads[1], own = f.threads[2]
        _ = try await f.store.apply(.moveToInbox([a, own]))
        _ = try await f.store.apply(.markDone([b]))
        #expect(try await f.inbox().contains(b) == false)
        let preview = SuperhumanReminderImportPreview.make([
            f.email(1, in: a, match: .sameConversation),
            f.email(3, in: own, match: .replyHeaders(b), minutesAgo: 30),
        ])
        let (token, skipped) = try await f.importer().apply(preview, archiveInGmail: true)
        #expect(skipped == 0 && !token.changesNothing)
        #expect(try await f.store.get(AppSettings.superhumanRemindersBacklogImported))
        #expect(try await f.store.get(AppSettings.superhumanRemindersConverted(f.account)) == ["r3"])
        let returned = try await f.store.get(AppSettings.superhumanRemindersReturned(f.account))
        #expect(returned[b.gmailThreadID.rawValue] == Int64((fixedNow.timeIntervalSince1970 - 1800) * 1000))
        var inbox = try await f.inbox()
        #expect(inbox.contains(b), "the matched conversation is back in the inbox")
        #expect(!inbox.contains(own), "Also archive them in Gmail: the reminder email's own conversation")

        let undone = try await SuperhumanReminderImportUndoer(settings: f.store, commands: f.store).undo(token)
        #expect(undone == nil)
        #expect(try await f.store.get(AppSettings.superhumanRemindersBacklogImported) == false)
        #expect(try await f.store.get(AppSettings.superhumanRemindersConverted(f.account)).isEmpty)
        #expect(try await f.store.get(AppSettings.superhumanRemindersReturned(f.account)).isEmpty)
        inbox = try await f.inbox()
        #expect(!inbox.contains(b) && inbox.contains(own))
    }

    @Test func archivingStaysOffByDefaultAndUnmatchedEmailsAreLeftAlone() async throws {
        let f = Fixture()
        let b = f.threads[1], own = f.threads[2], lone = f.threads[3]
        #expect(AppSettings.superhumanRemindersArchiveInGmail.defaultValue == false)
        _ = try await f.store.apply(.moveToInbox([b, own, lone]))
        let preview = SuperhumanReminderImportPreview.make([
            f.email(3, in: own, match: .replyHeaders(b), targetInInbox: true),
            f.email(4, in: lone, match: .unmatched),
        ])
        let (token, _) = try await f.importer().apply(preview, archiveInGmail: false)
        let inbox = try await f.inbox()
        #expect(inbox.contains(own) && inbox.contains(lone) && inbox.contains(b))
        #expect(try await f.store.get(AppSettings.superhumanRemindersConverted(f.account)) == ["r3"])
        #expect(!token.changesNothing)
    }

    @Test func readOnlySkipsTheGmailHalfButStillHandlesTheBacklog() async throws {
        let f = Fixture()
        let a = f.threads[0], b = f.threads[1], own = f.threads[2]
        let preview = SuperhumanReminderImportPreview.make([
            f.email(1, in: a, match: .sameConversation),
            f.email(3, in: own, match: .replyHeaders(b)),
        ])
        let (_, skipped) = try await f.importer(commands: false).apply(preview, archiveInGmail: true)
        #expect(skipped == 1)
        #expect(try await f.store.get(AppSettings.superhumanRemindersBacklogImported))
        #expect(try await f.store.get(AppSettings.superhumanRemindersConverted(f.account)).isEmpty,
                "a matched email whose conversation could not come back stays visible")
    }

    @Test func runningItAgainChangesNothingMore() async throws {
        let f = Fixture()
        let a = f.threads[0], b = f.threads[1], own = f.threads[2]
        let emails = [f.email(1, in: a, match: .sameConversation),
                      f.email(3, in: own, match: .replyHeaders(b), targetInInbox: true)]
        _ = try await f.importer().apply(.make(emails), archiveInGmail: false)
        let (again, _) = try await f.importer().apply(.make(emails), archiveInGmail: false)
        #expect(again.changesNothing, "no second undo entry, nothing duplicated")
        #expect(try await f.store.get(AppSettings.superhumanRemindersConverted(f.account)) == ["r3"])
    }

    @Test func theRuleStartIsWrittenOnceAndNeverMoves() async throws {
        let f = Fixture()
        await SuperhumanReminderImport.markRuleStart(settings: f.store, now: fixedNow)
        await SuperhumanReminderImport.markRuleStart(settings: f.store, now: fixedNow.addingTimeInterval(3600))
        #expect(try await f.store.get(AppSettings.superhumanRemindersSince) == Int64(fixedNow.timeIntervalSince1970 * 1000))
    }

    @Test func theSenderFieldTakesAddressesOnly() {
        #expect(AppSettings.superhumanReminderSenders.defaultValue == [SuperhumanReminderEmail.documentedSender])
        #expect(SuperhumanRemindersSettingsModel.parseSenders(" Reminder@Vendor.example, other@vendor.example ")
                == ["reminder@vendor.example", "other@vendor.example"])
        #expect(SuperhumanRemindersSettingsModel.parseSenders("a@b.example;a@b.example") == ["a@b.example"])
        #expect(SuperhumanRemindersSettingsModel.parseSenders("") == nil)
        #expect(SuperhumanRemindersSettingsModel.parseSenders("not an address") == nil)
        #expect(SuperhumanRemindersSettingsModel.parseSenders("@vendor.example") == nil)
    }

    @Test func couldNotMatchNotesStayDismissed() async throws {
        let f = Fixture()
        let lone = f.email(4, in: f.threads[3], match: .unmatched)
        let account = f.account
        let model = SuperhumanRemindersSettingsModel(
            settings: f.store, commands: f.store, undo: nil,
            availability: SettingsAvailability(safeMode: .normal, hasCommands: true, hasSettings: true, hasAccounts: true),
            accounts: { [account] }, scan: { _ in [lone] })
        await model.refreshUnmatched()
        #expect(model.unmatched.map(\.id) == [lone.id])
        await model.dismiss(lone)
        await model.refreshUnmatched()
        #expect(model.unmatched.isEmpty)
    }
}
