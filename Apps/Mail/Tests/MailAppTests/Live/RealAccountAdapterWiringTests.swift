import Foundation
import MailFakes
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import OpenHumanSync
import Testing
@testable import OpenHumanMail

@MainActor
@Suite(.serialized)
struct RealAccountAdapterWiringTests {
    private func start(gmail: FakeGmail,
                       unsubscribe: (any HTTPTransport)? = nil) async throws -> (FakeGmailLaunch.Running, MailStore, AppModel) {
        let store = try MailStore.openInMemoryForTesting()
        let running = try FakeGmailLaunch.makeSession(store: store, gmail: gmail, unsubscribeTransport: unsubscribe)
        let app = AppModel(screen: .mail(running.session.environment), session: running.session)
        await running.session.start()
        let account = running.session.account
        await eventually("the inbox", timeout: .seconds(60)) {
            ((try? store.label(account: account, key: "INBOX"))?.totalThreads ?? 0) > 0
        }
        return (running, store, app)
    }

    @Test(.timeLimit(.minutes(2))) func aReminderSchedulesItsNotificationAndAMissedOneIsNeutralWithoutPreviews() async throws {
        let corpus = FakeCorpus.make(threadCount: 3, now: Date())
        let gmail = FakeGmail(accountEmail: corpus.account.email)
        await FakeGmailLaunch.seed(gmail, corpus: corpus)
        let (running, store, app) = try await start(gmail: gmail)
        let session = running.session
        defer { Task { await session.stop() } }
        let environment = session.environment
        let notifier = try #require(environment.system.platform.notifier as? FakeSystemNotifier)
        await eventually("the reminder mirror", timeout: .seconds(30)) { environment.system.reminderMirror != nil }

        let item = try #require(try store.threadPage(view: .system(session.account, .inbox), after: nil, limit: 1).items.first)
        let thread = MailStoreAdapter.threadKey(item.ref)
        let due = Date().addingTimeInterval(3_600)
        _ = try await #require(environment.commands).apply(.setReminder(thread, dueAt: due, kind: .always))
        await eventually("the reminder's local notification", timeout: .seconds(30)) {
            notifier.pending.contains { $0.identifier.hasPrefix(ReminderNotificationMirror.prefix) }
        }
        let scheduled = try #require(notifier.pending.first { $0.identifier.hasPrefix(ReminderNotificationMirror.prefix) })
        #expect(scheduled.title == "Reminder: \(item.subject)")
        #expect(abs((scheduled.deliverAt ?? .distantPast).timeIntervalSince(due)) < 1, "delivered by the system at its due time")

        environment.system.preferences.hidePreviews = true
        await eventually("the neutral title", timeout: .seconds(30)) {
            notifier.pending.first { $0.identifier == scheduled.identifier }?.title == "Reminder"
        }
        await environment.system.handle(.reminderFired(thread, overdue: 600))
        await eventually("the missed reminder", timeout: .seconds(30)) {
            notifier.delivered.contains { $0.identifier.hasPrefix("reminder.missed.") }
        }
        let missed = try #require(notifier.delivered.first { $0.identifier.hasPrefix("reminder.missed.") })
        #expect(missed.title.hasPrefix("Missed reminder (due ") && !missed.title.contains(item.subject))
        _ = app
    }

    @Test(.timeLimit(.minutes(2))) func trashSpamAndDraftsFillFromGmailWhenTheyOpenWithReadsOnly() async throws {
        let corpus = FakeCorpus.make(threadCount: 3, now: Date())
        let gmail = FakeGmail(accountEmail: corpus.account.email)
        await FakeGmailLaunch.seed(gmail, corpus: corpus)
        let trashed = await gmail.deliver(subject: "Synthetic trashed", labels: ["TRASH"])
        let spam = await gmail.deliver(subject: "Synthetic spam", labels: ["SPAM"])
        let draft = await gmail.deliver(subject: "Synthetic draft", labels: ["DRAFT"])
        let (running, store, app) = try await start(gmail: gmail)
        let session = running.session
        defer { Task { await session.stop() } }
        let account = session.account
        #expect(try store.thread(account: account, gmailThreadID: GmailThreadID(trashed.threadID)) == nil,
                "the backfill lists without Trash")
        for (folder, expected) in [(SystemFolder.trash, trashed.threadID), (.spam, spam.threadID), (.drafts, draft.threadID)] {
            let window = try await firstValue(session.environment.data.threadWindow(.system(folder), account: account,
                                                                                    limit: 50)) {
                $0.rows.contains { $0.id.gmailThreadID.rawValue == expected }
            }
            #expect(window.rows.count == 1, "\(folder)")
        }
        #expect(running.wire.requests.allSatisfy(isReadOnTheWire))
        _ = app
    }

    @Test(.timeLimit(.minutes(2))) func theSearchFallbackReachesGmailWithReadsOnly() async throws {
        let corpus = FakeCorpus.make(threadCount: 3, now: Date())
        let gmail = FakeGmail(accountEmail: corpus.account.email)
        await FakeGmailLaunch.seed(gmail, corpus: corpus)
        let starred = await gmail.deliver(subject: "Synthetic starred", labels: ["STARRED"])
        let (running, _, app) = try await start(gmail: gmail)
        let session = running.session
        defer { Task { await session.stop() } }
        let adapter = try #require(session.environment.data as? MailStoreAdapter)
        let fallback = try #require(adapter.searchFallback, "the session wires the engine's remote search")
        let refs = try #require(await fallback.threads(matching: "is:starred", account: session.account))
        #expect(refs.contains { $0.gmailThreadID.rawValue == starred.threadID })
        #expect(adapter.viewLoader != nil, "and the view loads")
        #expect(try await adapter.searchGmail("is:starred", account: session.account) >= 1)
        #expect(running.wire.requests.allSatisfy(isReadOnTheWire))
        _ = app
    }

    @Test(.timeLimit(.minutes(3))) func unsubscribeReadsSyncedHeadersAndPostsToTheListOnly() async throws {
        let corpus = FakeCorpus.make(threadCount: 2, now: Date())
        let gmail = FakeGmail(accountEmail: corpus.account.email)
        await FakeGmailLaunch.seed(gmail, corpus: corpus)
        let news = await gmail.deliver(from: "Synthetic List <news@list.example>", subject: "Synthetic digest",
                                       extraHeaders: [
                                           GmailHeader(name: "List-Unsubscribe", value: "<https://list.example/u/synthetic-token>"),
                                           GmailHeader(name: "List-Unsubscribe-Post", value: "List-Unsubscribe=One-Click"),
                                       ])
        let lists = FakeHTTPTransport()
        lists.on("POST", "/u/") { _ in HTTPResponse(status: 200, headers: [:], body: Data()) }
        let (running, store, app) = try await start(gmail: gmail, unsubscribe: lists)
        let session = running.session
        let account = session.account
        await eventually("the newsletter", timeout: .seconds(60)) {
            (try? store.message(account: account, gmailMessageID: GmailMessageID(news.messageID))) != nil
        }
        let row = try #require(try store.message(account: account, gmailMessageID: GmailMessageID(news.messageID)))
        let key = MessageKey(account: account, rowID: row.id.rawValue, gmailMessageID: GmailMessageID(news.messageID))
        #expect(try await session.environment.data.unsubscribeInfo(key) == .oneClick(host: "list.example"))
        let commands = try #require(session.environment.commands)
        try await commands.unsubscribe(key)
        #expect(lists.requests.map(\.url.absoluteString) == ["https://list.example/u/synthetic-token"])
        #expect(lists.requests.allSatisfy { $0.method == "POST" })
        #expect(running.wire.requests.allSatisfy(isReadOnTheWire), "the unsubscribe never touches Gmail")
        await session.stop()
        _ = app
    }
}
