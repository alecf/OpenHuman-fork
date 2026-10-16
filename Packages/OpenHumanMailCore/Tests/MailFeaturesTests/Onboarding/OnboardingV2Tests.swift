import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct GoogleClientGuideTests {
    private var screenTexts: [String] {
        [GoogleClientGuide.title, GoogleClientGuide.intro, GoogleClientGuide.laterNote,
         GoogleClientGuide.haveFileTitle, GoogleClientGuide.skipTitle, GoogleClientGuide.multiAccountHint]
            + GoogleClientGuide.steps.flatMap { $0.links.map(\.label) }
            + GoogleClientGuide.reassurance
            + GoogleClientGuide.steps.flatMap { [$0.title, $0.action, $0.why] }
    }

    @Test func theStepsUsePlainWordsWithAnActionAndAReasonEach() {
        #expect(GoogleClientGuide.steps.count == 7)
        for text in screenTexts {
            for jargon in ["oauth", "token", "scope", "redirect", "client id", "client_id", "json…"] {
                #expect(!text.lowercased().contains(jargon), "\"\(jargon)\" in: \(text)")
            }
        }
        for step in GoogleClientGuide.steps {
            #expect(!step.title.isEmpty && !step.action.isEmpty && !step.why.isEmpty)
            #expect(!step.why.contains("\n") && !step.action.contains("\n"), "one line each")
        }
    }

    @Test func everyStepOpensItsOwnExactPage() {
        let byStep = Dictionary(uniqueKeysWithValues: GoogleClientGuide.steps.map { ($0.id, $0.links.map(\.url)) })
        #expect(byStep["project"] == [GoogleConsoleLinks.projects])
        #expect(byStep["gmail"] == [GoogleConsoleLinks.enableGmail, GoogleConsoleLinks.enableCalendar])
        #expect(byStep["branding"] == [GoogleConsoleLinks.authOverview])
        #expect(byStep["audience"] == [GoogleConsoleLinks.authAudience])
        #expect(byStep["access"] == [GoogleConsoleLinks.authOverview])
        #expect(byStep["client"] == [GoogleConsoleLinks.authClients])
        #expect(byStep["download"] == [GoogleConsoleLinks.secretHelp])
        #expect(Set(GoogleClientGuide.steps.flatMap(\.links).map(\.url)).isSubset(of: Set(GoogleConsoleLinks.all)))
        #expect(GoogleClientGuide.steps.compactMap(\.copyValue) == ["https://www.googleapis.com/auth/gmail.modify"])
        #expect(GoogleClientGuide.steps.map(\.id) == ["project", "gmail", "branding", "audience", "access", "client",
                                                      "download"])
        #expect(GoogleClientGuide.steps[3].action.contains("External") && GoogleClientGuide.steps[3].why.contains("In production"))
        #expect(GoogleClientGuide.steps[4].action.contains("Data Access"))
        #expect(GoogleClientGuide.steps[5].action.contains("Desktop app"))
        #expect(GoogleClientGuide.steps[6].action.contains("will not show the secret again"))
        for step in GoogleClientGuide.steps {
            for link in step.links { #expect(!link.label.isEmpty && link.accessibilityLabel.contains(link.domain)) }
        }
    }

    @Test func linksOpenAndCopyThroughInjectedClosuresOnly() {
        var opened: [URL] = []
        var copied: [String] = []
        let link = GoogleClientGuide.steps[5].links[0]
        #expect(GoogleClientGuide.open(link) { opened.append($0) })
        #expect(GoogleClientGuide.copyAddress(of: link) { copied.append($0) })
        #expect(opened == [GoogleConsoleLinks.authClients] && copied == ["https://console.developers.google.com/auth/clients"])
        let rogue = GoogleClientGuideLink(label: "x", url: URL(string: "https://example.com/phish")!)
        #expect(!GoogleClientGuide.open(rogue) { opened.append($0) })
        #expect(!GoogleClientGuide.copyAddress(of: rogue) { copied.append($0) })
        #expect(opened.count == 1 && copied.count == 1)
    }

    @Test func theReassuranceSaysMailStaysHereAndNothingGoesToUs() {
        let all = GoogleClientGuide.reassurance.joined(separator: " ")
        #expect(all.contains("this Mac") && all.contains("Nothing goes through our servers"))
        #expect(all.contains("don't touch your mail"))
    }

    @Test func tickingIsForTheUserOnlyAndReadsWellToVoiceOver() {
        let guide = GoogleClientGuide()
        let branding = GoogleClientGuide.steps[2]
        #expect(guide.progressText == "0 of 7 done")
        #expect(guide.accessibilityLabel(branding) == "Step 3, Name your app, not done")
        guide.toggle(branding)
        #expect(guide.isDone(branding) && guide.progressText == "1 of 7 done")
        #expect(guide.accessibilityLabel(branding) == "Step 3, Name your app, done")
        guide.toggle(branding)
        #expect(!guide.isDone(branding))
        #expect(GoogleClientGuide().done.isEmpty, "nothing is saved between screens")
    }

    @Test func thePlainTextHasEveryStepTheValueAndTheImport() {
        let text = GoogleClientGuide.plainText
        for (index, step) in GoogleClientGuide.steps.enumerated() {
            #expect(text.contains("\(index + 1). \(step.title). \(step.action)"))
        }
        #expect(text.contains(GoogleClientGuide.gmailPermission))
        #expect(text.contains("8. Import it."))
        for url in GoogleConsoleLinks.all { #expect(text.contains("Page: \(url.absoluteString)")) }
        #expect(text.hasSuffix(GoogleClientGuide.multiAccountHint))
    }
}

@MainActor
struct SignInV2Tests {
    private static let syntheticClient = Data(#"{"installed":{"client_id":"synthetic-id","client_secret":"synthetic-value"}}"#.utf8)

    private func model(_ status: OAuthClientStatus, hint: String = "", notice: String? = nil)
        -> (SignInModel, FakeMailStore, Task<Void, Never>) {
        let store = FakeMailStore(corpus: .make(threadCount: 1), options: .init(remoteAck: .immediate, oauthClient: status))
        let model = SignInModel(accounts: store, loginHint: hint, notice: notice)
        let runner = Task { await model.run() }
        return (model, store, runner)
    }

    @Test func withoutAClientTheStepsOpenAndImportingTheFileClosesThem() async {
        let (model, _, runner) = model(.missing)
        defer { runner.cancel() }
        await eventually { model.phase == .needsClient }
        #expect(!model.showsClientGuide)
        model.openClientGuide()
        #expect(model.showsClientGuide)
        await model.importClient(json: Self.syntheticClient)
        #expect(!model.showsClientGuide, "the file is in: back to signing in")
        await eventually { model.phase == .ready && model.canSignIn }
    }

    @Test func skippingGoesBackToTheCardAndChangesNothing() async {
        let (model, store, runner) = model(.missing)
        defer { runner.cancel() }
        await eventually { model.phase == .needsClient }
        model.openClientGuide()
        model.closeClientGuide()
        #expect(!model.showsClientGuide && model.phase == .needsClient && !model.canSignIn)
        #expect(store.threadCount == 1)
    }

    @Test func aFileThatIsNotAClientKeepsTheStepsOpenWithTheReason() async {
        let (model, _, runner) = model(.missing)
        defer { runner.cancel() }
        await eventually { model.phase == .needsClient }
        model.openClientGuide()
        await model.importClient(json: Data("{}".utf8))
        #expect(model.showsClientGuide && model.errorMessage != nil)
    }

    @Test func theAccountFieldWaitsUnlessTheAddressIsKnown() {
        let fresh = SignInModel(accounts: FakeMailStore(corpus: .make(threadCount: 1), options: .init()))
        #expect(!fresh.showsAccountField)
        let again = SignInModel(accounts: FakeMailStore(corpus: .make(threadCount: 1), options: .init()),
                                loginHint: "robin@example.com")
        #expect(again.showsAccountField)
    }

    @Test func ownClientIsOfferedOnlyWhereAnImportCanReplaceIt() async {
        for (status, offered) in [(OAuthClientStatus.configured(source: .file), true),
                                  (.configured(source: .file), true),
                                  (.configured(source: .environment), false),
                                  (.missing, false),
                                  (.configuredWithoutSecret(source: .file), false)] {
            let (model, _, runner) = model(status)
            await eventually { model.phase != .checking }
            #expect(model.offersOwnClient == offered, "\(status)")
            runner.cancel()
        }
        let (again, _, runner) = model(.configured(source: .file), hint: "robin@example.com",
                                       notice: "Google signed this account out.")
        defer { runner.cancel() }
        await eventually { again.phase == .ready }
        #expect(!again.offersOwnClient)
    }
}

@MainActor
struct WelcomeGuideV2Tests {
    @Test func everyStepHasOneTitleAndACount() async {
        let o = OnboardingFixture()
        #expect(Set(OnboardingStep.allCases.map(\.title)).count == OnboardingStep.allCases.count)
        #expect(OnboardingStep.welcome.title == "Welcome to OpenHuman Mail")
        #expect(OnboardingStep.ready.title == "All set")
        #expect(o.model.stepCountText == "Step 1 of 8")
        await o.model.next()
        #expect(o.model.stepCountText == "Step 2 of 8")
    }

    @Test func thePermissionsStepLeavesOutGmailAndTheWithoutLineOnceOn() async {
        let o = OnboardingFixture()
        await o.model.go(to: .permissions)
        #expect(!o.model.permissions.guideRows.contains { $0.id == .gmail })
        #expect(o.model.permissions.guideRows.count == PermissionID.allCases.count - 1)
        let notifications = o.model.permissions.guideRows.first { $0.id == .notifications }
        #expect(notifications?.showsWhatBreaks == true, "not asked yet: say what is lost")
        await o.model.permissions.requestNotifications()
        #expect(o.model.permissions.guideRows.first { $0.id == .notifications }?.showsWhatBreaks == false)
    }

    @Test func theLastStepSaysReadingCanStartOnceTheInboxHasMail() async {
        let o = OnboardingFixture()
        #expect(o.model.readingLine == OnboardingModel.waitingForFirstMailText)
        await o.model.go(to: .ready)
        await eventually { o.model.firstMailArrived }
        #expect(o.model.readingLine == OnboardingModel.canStartReadingText)
    }

    @Test func anEmptyInboxKeepsTheWaitingLine() async throws {
        let o = OnboardingFixture()
        let accounts = try await o.f.accounts()
        for account in accounts {
            for try await window in o.f.store.threadWindow(.system(.inbox), account: account.id, limit: 5000) {
                o.f.store.removeThreads(Set(window.rows.map(\.id)))
                break
            }
        }
        await o.model.go(to: .ready)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!o.model.firstMailArrived && o.model.readingLine == OnboardingModel.waitingForFirstMailText)
    }

    @Test func runAgainStartsFromTheFirstStep() async throws {
        let f = SettingsFixture()
        let center = f.env.welcomeGuide
        center.present()
        let first = try #require(center.model)
        await first.go(to: .keys)
        center.dismiss()
        #expect(f.env.onboardingProgress.load().step == .keys)
        center.presentFromStart()
        #expect(center.model?.step == .welcome)
        await center.model?.go(to: .look)
        center.presentFromStart()
        await eventually { center.model?.step == .welcome }
        center.dismiss()
    }

    @Test func theKeysStepSaysWhichLayoutTheKeysAre() {
        #expect(KeysTutorial.layoutNote.contains("Superhuman-style keys"))
    }
}

@MainActor
struct FakeSyncProgressTests {
    @Test func theFakeReportsTheFirstSyncLineOnlyWithLiveConnectivity() async throws {
        let live = FakeMailStore(corpus: .make(threadCount: 1), options: .init(liveConnectivity: true))
        let account = try #require(try await { () async throws -> AccountID? in
            for try await list in live.accounts() { return list.first?.id }
            return nil
        }())
        live.setSyncProgress("Syncing 1,240 of 4,707", for: account)
        var iterator = live.syncProgress().makeAsyncIterator()
        #expect(await iterator.next() == [account: "Syncing 1,240 of 4,707"])

        let quiet = FakeMailStore(corpus: .make(threadCount: 1), options: .init())
        quiet.setSyncProgress("Syncing 1 of 2", for: account)
        var none = quiet.syncProgress().makeAsyncIterator()
        #expect(await none.next() == nil, "without live connectivity the stream finishes at once, as before")
    }
}

struct GoogleConsoleLinksTests {
    @Test func everyAddressIsHttpsOnAnAllowedHostWithNoQuery() {
        #expect(!GoogleConsoleLinks.all.isEmpty)
        for url in GoogleConsoleLinks.all {
            #expect(url.scheme == "https", "\(url)")
            #expect(["console.cloud.google.com", "console.developers.google.com", "support.google.com"].contains(url.host ?? ""))
            #expect(url.query == nil && url.fragment == nil && url.user == nil, "no query or secrets: \(url)")
            #expect(GoogleConsoleLinks.isAllowed(url))
        }
        #expect(!GoogleConsoleLinks.isAllowed(URL(string: "http://console.cloud.google.com/")!))
        #expect(!GoogleConsoleLinks.isAllowed(URL(string: "https://console.cloud.google.com/?token=abc")!))
        #expect(!GoogleConsoleLinks.isAllowed(URL(string: "https://evil.example.com/")!))
    }

    @Test func unconfirmedAddressesAreNotInTheTable() {
        let all = GoogleConsoleLinks.all.map(\.absoluteString).joined(separator: " ")
        for banned in ["projectcreate", "/auth/branding", "/auth/scopes", "authuser", "?project="] { #expect(!all.contains(banned)) }
    }
}
