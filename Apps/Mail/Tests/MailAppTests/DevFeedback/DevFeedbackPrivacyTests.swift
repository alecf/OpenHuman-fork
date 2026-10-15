import Foundation
import MailFakes
import MailFeatures
import MailModel
import OpenHumanCore
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanMail

private enum Hostile {
    static let subject = "MARKER-SUBJ-7f3a <script>alert(1)</script> \"quoted\" $(rm -rf ~) `id`"
    static let senderName = "Mallory Marker7f3a"
    static let senderEmail = "mallory.marker7f3a@hostile.example"
    static let toEmail = "victim.marker7f3a@work.example"
    static let body = "MARKER-BODY-7f3a secret plans"
    static let html = "<p>MARKER-HTML-7f3a</p><img src=\"https://tracker.hostile.example/p.gif?u=marker7f3a\"><script>alert(2)</script>"
    static let accessToken = "ya29.MARKERTOKEN7f3aAbCdEf"
    static let refreshToken = "1//MARKERREFRESH7f3aXyZ"
    static let clientID = "MARKER7f3a-client.apps.googleusercontent.com"
    static let clientSecret = "GOCSPX-MARKER7f3aSecretValue"
    static var clientJSON: String {
        #"{"installed":{"client_id":"\#(clientID)","client_secret":"\#(clientSecret)","token_uri":"https://oauth2.example.invalid/token"}}"#
    }
    static let pasted = "http://127.0.0.1:53682/?state=MARKERSTATE7f3a&code=4/MARKERCODE7f3a&scope=https://www.googleapis.com/auth/gmail.modify"
    static let loginHint = "marker.hint7f3a@work.example"

    static let markers = ["MARKER-SUBJ", "Marker7f3a", "marker7f3a", "MARKER-BODY", "MARKER-HTML", "MARKERTOKEN",
                          "MARKERREFRESH", "MARKER7f3a-client", "GOCSPX", "MARKERSTATE", "MARKERCODE", "hint7f3a",
                          "secret plans", "rm -rf", "<script>"]
}

@MainActor
@Suite(.serialized) struct DevFeedbackPrivacyTests {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("oh-devfeedback-app-\(UUID().uuidString)", isDirectory: true)

    func center(for app: AppModel) throws -> (DevFeedbackCenter, AppDevFeedbackHost) {
        let suite = "dev.openhuman.tests.devfeedback.privacy"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let center = DevFeedbackCenter(availability: .debugBuild, settings: DevFeedbackSettings(defaults: defaults),
                                       paths: DevFeedbackPaths(support: support),
                                       bundledChecklist: Bundle.main.url(forResource: "dev-test-checklist", withExtension: "json"))
        let host = AppDevFeedbackHost(availability: .debugBuild, arguments: ["-UseFakeGmail"], environment: [:],
                                      app: { app }, theme: { nil })
        center.host = host
        return (center, host)
    }

    func logCarelessly(_ center: DevFeedbackCenter, _ lines: [String]) {
        Log.setMirror(center.logs.sink)
        for line in lines { Log(.app).error(line) }
        Log.setMirror(MailApp.devFeedback.availability.isAvailable ? MailApp.devFeedback.logs.sink : nil)
    }

    func assertNoMarkers(_ text: String, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for marker in Hostile.markers {
            #expect(!text.contains(marker), "\(what) leaks \(marker)", sourceLocation: sourceLocation)
        }
    }

    @Test func mailScreenBundleWithDefaultsHasNoHostileContent() async throws {
        defer { try? FileManager.default.removeItem(at: support) }
        let corpus = FakeCorpus.make(threadCount: 10)
        let gmail = FakeGmail(accountEmail: corpus.account.email)
        await FakeGmailLaunch.seed(gmail, corpus: corpus)
        _ = await gmail.deliver(from: "\(Hostile.senderName) <\(Hostile.senderEmail)>", to: Hostile.toEmail,
                                subject: Hostile.subject, body: Hostile.body, html: Hostile.html, date: Date())
        let running = try FakeGmailLaunch.makeSession(store: try MailStore.openInMemoryForTesting(), gmail: gmail)
        await running.session.start()
        let environment = running.session.environment
        let app = AppModel(screen: .mail(environment), session: running.session)
        let (center, _) = try center(for: app)

        let window = MailWindowModel(environment: environment)
        window.start()
        center.window = window
        await eventually("hostile row") { window.list?.rows.contains { $0.subject.contains("MARKER-SUBJ-7f3a") } == true }
        let row = try #require(window.list?.rows.first { $0.subject.contains("MARKER-SUBJ-7f3a") })
        window.open(row.id)
        let reader = try #require(window.reader)
        await eventually("hostile body") {
            reader.messages.last.map { if case .rendered = $0.body { true } else { false } } ?? false
        }
        center.history.record("nav.openThread")

        logCarelessly(center, [
            "opened thread subject=\(Hostile.subject) from=\(Hostile.senderEmail)",
            "sender \(Hostile.senderName) wrote to \(Hostile.toEmail)",
            "body: \(Hostile.body)",
            "token \(Hostile.accessToken) refresh \(Hostile.refreshToken)",
            "client file: \(Hostile.clientJSON)",
            "client id \(Hostile.clientID) secret \(Hostile.clientSecret)",
            "pasted \(Hostile.pasted)",
            "hint \(Hostile.loginHint)",
        ])

        let model = center.beginFeedback()
        #expect(model.threadContentAvailable)
        #expect(!model.includeThreadContent && !model.includeScreenshot)
        model.text = "Synthetic note from the test"
        await model.submit()
        guard case .saved(let saved) = model.state else { Issue.record("not saved: \(model.state)"); return }
        let written = String(decoding: try Data(contentsOf: URL(fileURLWithPath: saved.bundlePath)), as: UTF8.self)
        assertNoMarkers(written, "default bundle")
        #expect(saved.screenshotPath == nil)

        let bundle = try DevFeedbackBundle.decoder.decode(DevFeedbackBundle.self, from: Data(written.utf8))
        let snapshot = try #require(bundle.snapshot)
        #expect(snapshot.route == "mail/reader/inbox")
        #expect(snapshot.reader?.threadID == row.id.gmailThreadID.rawValue)
        #expect(snapshot.app.dataMode == "fakeGmail")
        #expect((snapshot.accounts.first?.threadCount ?? 0) > 0)
        #expect((snapshot.accounts.first?.inboxThreads ?? 0) > 0)
        #expect(snapshot.accounts.first?.idHash == DevFeedbackHash.account(corpus.account.email))
        #expect((bundle.logs?.count ?? 0) >= 8)
        #expect(snapshot.recentErrors.count >= 8)

        let withContent = center.beginFeedback()
        withContent.includeThreadContent = true
        let (contentBundle, _) = await withContent.makeBundle()
        #expect(contentBundle.content?.subject.contains("MARKER-SUBJ-7f3a") == true)
        #expect(contentBundle.content?.warning == "contains email content")
        await running.session.stop()
    }

    @Test func signInScreenBundleHasNoHintOrPastedAddress() async throws {
        defer { try? FileManager.default.removeItem(at: support) }
        let store = FakeMailStore(corpus: .make(threadCount: 2))
        let signIn = SignInModel(accounts: store, loginHint: Hostile.loginHint)
        signIn.pastedAddress = Hostile.pasted
        let app = AppModel(screen: .signIn(signIn))
        let (center, host) = try center(for: app)
        #expect(host.screenName.hasPrefix("signIn/"))
        logCarelessly(center, ["remote sign-in pasted \(Hostile.pasted) for \(Hostile.loginHint)",
                               "exchange failed: code=4/MARKERCODE7f3a state=MARKERSTATE7f3a"])
        let model = center.beginFeedback()
        let (bundle, _) = await model.makeBundle()
        let text = String(decoding: try DevFeedbackBundle.encoder.encode(bundle), as: UTF8.self)
        assertNoMarkers(text, "sign-in bundle")
        #expect(bundle.snapshot?.screen.hasPrefix("signIn/") == true)
        #expect(bundle.content == nil)
    }

    @Test func fakeDataRunReportsCountsFromTheFakeStore() async throws {
        defer { try? FileManager.default.removeItem(at: support) }
        let app = CompositionRoot.makeApp(arguments: ["-UseFakeData"], environment: [:])
        let (center, host) = try center(for: app)
        let counters = await host.accountCounters()
        #expect(counters.count == 2, "-UseFakeData runs the two-account rich corpus")
        #expect((counters.first?.threadCount ?? 0) > 0)
        #expect((counters.first?.messageCount ?? 0) >= (counters.first?.threadCount ?? 0))
        #expect(counters.first?.idHash.count == 12)
        guard case .mail(let environment) = app.screen else { Issue.record("not the mail screen"); return }
        let window = MailWindowModel(environment: environment)
        window.start()
        center.window = window
        await eventually("rows") { (window.list?.rows.count ?? 0) > 0 }
        let snapshot = await center.snapshot()
        #expect(snapshot.route == "mail/list/inbox")
        #expect(snapshot.accountCount == 2)
    }
}
