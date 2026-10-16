import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct OnboardingFixture {
    let f: SettingsFixture
    let progress: InMemoryOnboardingProgress
    let ai: FakeAIOnboarding
    let notifier: FakeSystemNotifier
    let login: FakeLoginItem
    let model: OnboardingModel

    init(progress initial: OnboardingProgress = OnboardingProgress(), ai: FakeAIOnboarding = FakeAIOnboarding(),
         notifier: FakeSystemNotifier = FakeSystemNotifier(grantOnRequest: true)) {
        f = SettingsFixture()
        progress = InMemoryOnboardingProgress(initial)
        self.ai = ai
        self.notifier = notifier
        login = FakeLoginItem()
        model = OnboardingModel(store: progress, ports: OnboardingModel.Ports(
            data: f.store, accounts: f.store, ai: ai, notifier: notifier, loginItem: login))
    }
}

@MainActor
struct OnboardingFlowTests {
    @Test func aFirstRunStartsAtWelcomeAndEveryStepIsSavedAsItIsReached() async {
        let o = OnboardingFixture()
        #expect(o.model.step == .welcome && o.model.isFirst && !o.model.canSkip)
        await o.model.next()
        #expect(o.model.step == .calendar && o.progress.load().step == .calendar)
        await o.model.next()
        #expect(o.progress.load().step == .inboxes)
        await o.model.next()
        #expect(o.progress.load().step == .permissions)
    }

    @Test func quittingMidwayResumesOnTheStepTheUserQuitOn() async {
        let first = OnboardingFixture()
        await first.model.go(to: .keys)
        first.model.close()
        #expect(!first.progress.load().completed && first.progress.load().step == .keys)
        let again = OnboardingModel(store: first.progress, ports: OnboardingModel.Ports(
            data: first.f.store, accounts: first.f.store, ai: first.ai, notifier: first.notifier, loginItem: first.login))
        #expect(again.step == .keys)
        #expect(OnboardingModel.shouldAutoPresent(first.progress), "an unfinished guide shows itself again")
    }

    @Test func aFinishedGuideReplaysFromTheTopAndNoLongerShowsItself() async {
        let o = OnboardingFixture()
        await o.model.go(to: .ready)
        o.model.finish()
        #expect(o.progress.load().completed && o.model.isFinished)
        #expect(!OnboardingModel.shouldAutoPresent(o.progress))
        let replay = OnboardingModel(store: o.progress, ports: OnboardingModel.Ports(
            data: o.f.store, accounts: o.f.store, ai: o.ai, notifier: o.notifier, loginItem: o.login))
        #expect(replay.step == .welcome && !replay.isFinished)
    }

    @Test func everyOptionalStepIsSkippableAndSaysWhereToChangeItLater() async {
        let o = OnboardingFixture()
        let fixed: Set<OnboardingStep> = [.welcome, .ready, .inboxes, .connectEmail]
        for step in OnboardingStep.allCases {
            #expect(step.isSkippable == !fixed.contains(step))
            #expect((step.laterNote != nil) == step.isSkippable)
            if let note = step.laterNote { #expect(note.contains("Settings") || note.contains("System Settings") || note.contains("press ?")) }
        }
        await o.model.next()
        await o.model.skip()
        #expect(o.model.step == .inboxes && !o.model.canSkip)
        await o.model.next()
        while o.model.canSkip { await o.model.skip() }
        #expect(o.model.step == .ready)
        #expect(o.progress.load().skipped == [.calendar, .permissions, .look, .keys, .ai])
        await o.model.skip()
        #expect(o.model.step == .ready, "the last step can't be skipped")
        #expect(o.ai.log.filter { $0.hasPrefix("setDraftReplies") }.isEmpty, "skipping the AI step writes nothing")
    }

    @Test func goingBackWorksAndAnotherAccountUsesTheSignInPort() async throws {
        let o = OnboardingFixture()
        await o.model.go(to: .inboxes)
        await o.model.back()
        #expect(o.model.step == .calendar)
        await o.model.next()
        #expect(o.model.step == .inboxes && o.model.canAddAccount)
        o.f.store.enqueueSignIn(.succeed(email: "second.work@example.org", displayName: nil))
        await o.model.addAnotherInbox()
        let signIn = try #require(o.model.emailSignIn)
        await eventually { signIn.canSignIn }
        signIn.signIn()
        await eventually { o.model.step == .calendar }
        #expect(try await o.f.accounts().contains { $0.email == "second.work@example.org" })
        #expect(o.model.title == "Connect calendar for second.work@example.org")
        await o.model.back()
        #expect(o.model.step == .inboxes, "a later inbox's calendar goes back to the list")

        await o.model.addAnotherInbox()
        let again = try #require(o.model.emailSignIn)
        await eventually { again.canSignIn }
        o.f.store.enqueueSignIn(.fail)
        again.signIn()
        await eventually { again.errorMessage != nil }
        #expect(o.model.step == .connectEmail && again.errorMessage == "Sign-in failed. Try again.")
        o.f.store.enqueueSignIn(.cancel)
        again.signIn()
        await eventually { again.errorMessage == "Sign-in was cancelled." }
        #expect(o.model.step == .connectEmail)
        await o.model.back()
        #expect(o.model.step == .inboxes && o.model.emailSignIn == nil)
    }

    private func inboxIDs(_ o: OnboardingFixture) async throws -> [ThreadKey] {
        for try await window in o.f.store.threadWindow(.system(.inbox), account: o.f.work, limit: 50) { return window.rows.map(\.id) }
        return []
    }

    @Test func theGuideEndsInTheInboxWithoutChangingMail() async throws {
        let o = OnboardingFixture()
        let before = try await inboxIDs(o)
        while !o.model.isLast { await o.model.next() }
        o.model.finish()
        #expect(o.model.isFinished)
        #expect(try await inboxIDs(o) == before, "the guide touched no mail")
        #expect(o.f.store.pendingOperationCount == 0)
    }
}

@MainActor
struct PermissionsTests {
    @Test func everyPermissionHasAWhatBreaksLineThatSaysTheRestStillWorks() {
        #expect(Set(PermissionInfo.all.map(\.id)) == Set(PermissionID.allCases))
        for info in PermissionInfo.all {
            #expect(!info.whatBreaksIfDenied.isEmpty && !info.why.isEmpty && !info.actionTitle.isEmpty)
            let line = info.whatBreaksIfDenied.lowercased()
            #expect(line.hasPrefix("without"), "\(info.id) names what is lost")
        }
        #expect(PermissionInfo.info(.gmail).whatBreaksIfDenied
            == "Without Gmail access no mail can load, but you can still change settings and look around.")
    }

    @Test func deniedNotificationsDisableOneCapabilityAndNeverBlockTheGuide() async {
        let o = OnboardingFixture(notifier: FakeSystemNotifier(grantOnRequest: false))
        await o.model.go(to: .permissions)
        #expect(o.model.permissions.rows.first { $0.id == .notifications }?.state == .notAsked, "nothing is asked on its own")
        await o.model.permissions.requestNotifications()
        #expect(o.model.permissions.rows.first { $0.id == .notifications }?.state == .denied)
        #expect(!o.model.permissions.blocksContinuing)
        await o.model.next()
        #expect(o.model.step == .look, "the guide goes on after a denial")
        #expect(o.notifier.authorizationRequests == 1)
    }

    @Test func theLoginItemSwitchUsesTheFakeAndReportsApproval() async {
        let o = OnboardingFixture()
        o.login.statusAfterRegister = .requiresApproval
        await o.model.go(to: .permissions)
        o.model.permissions.setOpenAtLogin(true)
        #expect(o.login.registerCalls == 1)
        #expect(o.model.permissions.rows.first { $0.id == .openAtLogin }?.state == .needsApproval)
        o.login.statusAfterRegister = .enabled
        o.login.failure = CocoaError(.fileWriteUnknown)
        o.model.permissions.setOpenAtLogin(true)
        #expect(o.model.permissions.rows.first { $0.id == .openAtLogin }?.state == .denied)
    }

    @Test func onDeviceAIUnavailableShowsTheReasonNotAnError() async {
        let o = OnboardingFixture(ai: FakeAIOnboarding(status: .unavailable(hint: "Turn on Apple Intelligence in System Settings")))
        await o.model.go(to: .permissions)
        #expect(o.model.permissions.rows.first { $0.id == .onDeviceAI }?.state.text == "Turn on Apple Intelligence in System Settings")
    }
}

@MainActor
struct KeysTutorialTests {
    @Test func promptsCompleteInOrderOnTheirKeysOnAMadeUpList() {
        let keys = KeysTutorial()
        #expect(keys.current?.text == "Press J to move down")
        keys.press("e")
        #expect(keys.completed.isEmpty, "only the current prompt's key counts")
        keys.press("j")
        #expect(keys.cursor == 1 && keys.current?.text == "Press E to mark done")
        keys.press("e")
        #expect(keys.rows.count == KeysTutorial.sampleRows.count - 1)
        #expect(keys.current?.text == "Press Z to undo")
        keys.press("z")
        #expect(keys.rows == KeysTutorial.sampleRows && keys.cursor == 1)
        #expect(keys.current?.text == "Press Tab for the next split" && keys.split == 0)
        keys.press("tab")
        #expect(keys.split == 1 && KeysTutorial.sampleSplits[keys.split] == "Other")
        keys.press("cmd-k")
        keys.press("/")
        #expect(keys.isFinished && keys.current == nil)
        keys.press("tab")
        #expect(keys.split == 0, "the practice tabs wrap")
        keys.reset()
        #expect(keys.completed.isEmpty && keys.rows == KeysTutorial.sampleRows && keys.split == 0)
    }

    @Test func zWithNothingDoneChangesNothing() {
        let keys = KeysTutorial()
        keys.press("z")
        #expect(keys.rows == KeysTutorial.sampleRows && keys.completed.isEmpty)
        #expect(KeysTutorial.prompts.map(\.key) == ["j", "e", "z", "tab", "cmd-k", "/"])
    }
}

@MainActor
struct WelcomeGuideCenterTests {
    @Test func helpShowWelcomeGuideResumesAndFakeDataNeverAutoPresents() async {
        let f = SettingsFixture()
        f.env.welcomeGuide.presentIfFirstRun()
        #expect(!f.env.welcomeGuide.isPresented, "fake data never opens it by itself")
        f.env.onboardingProgress.save(OnboardingProgress(step: .look))
        f.env.welcomeGuide.present()
        #expect(f.env.welcomeGuide.isPresented && f.env.welcomeGuide.model?.step == .look)
        f.env.welcomeGuide.dismiss()
        #expect(!f.env.welcomeGuide.isPresented)
        #expect(f.env.onboardingProgress.load().step == .look && !f.env.onboardingProgress.load().completed)
    }

    @Test func theGuideOpensByItselfOnceOnRealDataAndNotAgainAfterItWasClosed() async {
        let progress = InMemoryOnboardingProgress()
        let store = FakeMailStore(corpus: .small)
        let env = AppEnvironment(data: store, commands: store, accounts: store, settings: store, isFake: false,
                                 aiOnboarding: FakeAIOnboarding(), onboardingProgress: progress)
        env.welcomeGuide.presentIfFirstRun()
        #expect(env.welcomeGuide.isPresented && progress.load().shown)
        env.welcomeGuide.dismiss()
        env.welcomeGuide.presentIfFirstRun()
        #expect(!env.welcomeGuide.isPresented, "closing it early does not bring it back at every launch")
        env.welcomeGuide.present()
        #expect(env.welcomeGuide.isPresented, "Help > Show Welcome Guide always works")
    }

    @Test func withoutAnAIAdapterTheAIStepSaysSoAndOffersOnlyAskingFirst() async {
        let status = await UnavailableAIOnboarding().onDeviceStatus()
        #expect(!status.isAvailable)
        let step = AIStepModel(port: UnavailableAIOnboarding())
        await step.load()
        #expect(step.selected == .onDemand)
    }

    @Test func progressIsStoredAsOneJSONValueInAGivenSuite() {
        let (_, name) = scratchDefaults()
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let store = UserDefaultsOnboardingProgress(suite: name)
        #expect(store.load() == OnboardingProgress())
        store.save(OnboardingProgress(step: .ai, completed: false, skipped: [.keys], aiAnswered: true, shown: true))
        #expect(UserDefaultsOnboardingProgress(suite: name).load() == OnboardingProgress(step: .ai, skipped: [.keys], aiAnswered: true, shown: true))
    }
}
