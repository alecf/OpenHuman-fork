#if DEBUG || OH_DEV_TOOLS
import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import OpenHumanSync

enum FakeGmailLaunch {
    struct Running: Sendable {
        let session: SyncSession
        let gmail: FakeGmail
        let wire: FakeGmailTransport
    }

    static let accessToken = "fake-gmail-access-token"

    // Why: FakeGmail has no quota; 10x Google's 6,000 units/min keeps backfill of the fake corpus from taking minutes
    static let fakeUnitsPerMinute = 60_000

    @MainActor
    static func makeSession(store: MailStore, gmail: FakeGmail, clock: any OHClock = SystemClock(),
                            pollInterval: Duration = .seconds(60), systemEvents: AppSystemEvents? = nil,
                            tokenEvents: AsyncStream<TokenEvent>? = nil, draftsDirectory: URL? = nil,
                            unsubscribeTransport: (any HTTPTransport)? = nil) throws -> Running {
        let wire = FakeGmailTransport(gmail)
        let scopes = OAuthScopes.mailRequest
        let id = try store.accounts().first { $0.email == gmail.accountEmail }?.id
            ?? store.addAccount(email: gmail.accountEmail, displayName: "FakeGmail", scopes: scopes)
        guard let account = try store.accounts().first(where: { $0.id == id }) else {
            throw StoreError.notFound("account \(id.rawValue)")
        }
        let config = GmailClientConfig(unitsPerMinute: fakeUnitsPerMinute, userAgent: "OpenHumanMail/fake-gmail")
        let metrics = SyncMetricsRegistry()
        let factory = DefaultGmailClientFactory(apiTransport: wire, config: config, clock: clock,
                                                metrics: { metrics.collector(for: $0) }) { _ in
            (StaticTokenProvider(token: accessToken), scopes)
        }
        let wiring = SyncSession.Wiring(factory: factory, gmail: config, metrics: metrics, tokenStore: nil, oauthClient: nil,
                                        clock: clock, pollInterval: pollInterval, systemEvents: systemEvents,
                                        tokenEvents: tokenEvents, draftsDirectory: draftsDirectory,
                                        unsubscribeTransport: unsubscribeTransport)
        let session = try SyncSession(account: account, store: store, wiring: wiring, isFake: true)
        return Running(session: session, gmail: gmail, wire: wire)
    }

    static func seed(_ gmail: FakeGmail, corpus: FakeCorpus) async {
        for thread in corpus.threads.reversed() {
            var threadID: String?
            for message in thread.detail.messages {
                let content = thread.bodies[message.id]
                let delivered = await gmail.deliver(
                    from: format(message.from), to: message.to.map(format).joined(separator: ", "),
                    subject: thread.detail.subject, body: content?.text ?? message.snippet, html: content?.html,
                    labels: FixtureStoreSeeder.labels(message, thread: thread).map(\.rawValue), threadID: threadID,
                    date: message.date, attachments: message.attachments.map(syntheticAttachment))
                threadID = threadID ?? delivered.threadID
            }
        }
    }

    static func syntheticAttachment(_ info: AttachmentInfo) -> FakeGmailAttachment {
        let data = info.mimeType.hasPrefix("image/")
            ? FakeGmailAttachment.tinyPNG
            : Data("Synthetic attachment \(info.filename) from the OpenHuman fake corpus.\n".utf8)
        return FakeGmailAttachment(filename: info.filename, mimeType: info.mimeType, data: data,
                                   contentID: info.isInline ? info.contentID : nil)
    }

    @MainActor
    static func launch(corpus: FakeCorpus = .make(threadCount: 80)) throws -> Running {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenHumanMail-FakeGmail-\(UUID().uuidString)", isDirectory: true)
        let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: .app,
                                                    observeExternalChanges: true, appVersion: CompositionRoot.appVersion))
        let gmail = FakeGmail(accountEmail: corpus.account.email)
        let running = try makeSession(store: store, gmail: gmail, systemEvents: AppSystemEvents(),
                                      draftsDirectory: store.location.draftsDirectory)
        Task {
            await seed(gmail, corpus: corpus)
            await running.session.start()
        }
        return running
    }

    private static func format(_ address: EmailAddress?) -> String {
        guard let address else { return "" }
        guard let name = address.name, !name.isEmpty else { return address.email }
        return "\(name) <\(address.email)>"
    }
}
#endif
