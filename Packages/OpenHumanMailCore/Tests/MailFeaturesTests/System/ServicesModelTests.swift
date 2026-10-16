import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanLinks
import Synchronization
import Testing
@testable import MailFeatures

@MainActor
final class ServicesFixture {
    let env: AppEnvironment
    let store: FakeMailStore
    let recorder: RecordingCommands
    let services = FakeServicesRegistrar()
    let active = ActiveFlag()

    init(flags: FeatureFlags = FeatureFlags()) {
        store = FakeMailStore(corpus: .make(threadCount: 10, now: fixedNow), options: .init(remoteAck: .immediate))
        recorder = RecordingCommands(store)
        env = AppEnvironment(data: store, commands: recorder, accounts: store, settings: store, isFake: true,
                             featureFlags: flags)
        let flag = active
        env.installPlatform(SystemPlatform(notifier: FakeSystemNotifier(authorization: .authorized), dock: FakeDockBadge(),
                                           loginItem: FakeLoginItem(), urlOpener: FakeURLOpener(), services: services,
                                           isAppActive: { false }, activateApp: { flag.activations += 1 },
                                           showMainWindow: { flag.windowShows += 1 }))
    }

    func ready() async {
        env.router.start()
        env.system.startServices()
        await eventually(timeout: .seconds(15)) { self.env.router.accountsLoaded && self.env.router.list?.state == .loaded }
    }

    var session: ComposeSession? { env.composeIfStarted?.windowSession }
    var draftWrites: [String] { recorder.calls.filter { ["createDraft", "updateDraft", "flushDraft"].contains($0) } }
    var toasts: [String] { env.notices.toasts.map(\.message) }

    func files(_ names: [String]) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("services-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try names.map { name in
            let url = folder.appendingPathComponent(name)
            try Data("synthetic \(name)".utf8).write(to: url)
            return url
        }
    }
}

@MainActor
@Suite(.serialized)
struct ServicesModelTests {
    @Test func textOpensOneComposerWithTheBodyOnlyAndSavesNothingUntilAnEdit() async throws {
        let f = ServicesFixture()
        await f.ready()
        #expect(f.services.deliver(.newMessage("Hello\r\nfrom Notes\u{7}")))
        let session = try #require(f.session)
        #expect(session.mode == .new && f.env.compose.sessions.count == 1)
        #expect(session.to.tokens.isEmpty && session.cc.tokens.isEmpty && session.bcc.tokens.isEmpty)
        #expect(session.subject.isEmpty && session.linkRecipients == nil && !session.linkTriedBcc)
        #expect(session.plainText.contains("Hello\nfrom Notes") && !session.plainText.contains("\u{7}"))
        #expect(f.active.windowShows == 1, "Mail comes forward")
        await f.env.compose.settle()
        #expect(f.draftWrites.isEmpty, "nothing is saved until the user edits")
        let link = ServicesModel.newMessageLink("Hello")
        #expect(MailLinkParser.parse(MailLinkBuilder.url(for: link)) == .success(.compose(ComposePrefill(body: "Hello"))))
        session.updateBody(doc("Hello from Notes, edited"))
        #expect(await session.save())
        #expect(f.recorder.calls.contains("createDraft"))
        #expect(f.recorder.calls.allSatisfy { !["send", "scheduleSend", "apply"].contains($0) })
    }

    @Test func aLongSelectionIsCutAndSaysSo() async throws {
        let f = ServicesFixture()
        await f.ready()
        f.services.deliver(.newMessage(String(repeating: "word ", count: 10_000)))
        let session = try #require(f.session)
        #expect(session.plainText.utf8.count <= ServiceInput.maxBodyBytes + 1)
        #expect(f.toasts.contains(ServicesModel.cutText))
    }

    @Test func emptyTextOpensNothing() async {
        let f = ServicesFixture()
        await f.ready()
        f.services.deliver(.newMessage(" \n\u{0}\t "))
        #expect(f.session == nil)
        #expect(f.toasts.contains(ServicesModel.noTextText))
    }

    @Test func filesAreStagedWithoutADraftAndFoldersAreSkipped() async throws {
        let f = ServicesFixture()
        await f.ready()
        var urls = try f.files(["a.pdf", "b.txt"])
        let folder = urls[0].deletingLastPathComponent().appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        urls.append(folder)
        #expect(f.services.deliver(.attachFiles(urls)))
        let session = try #require(f.session)
        #expect(session.attachments.count == 2)
        #expect(f.toasts.contains(ServicesModel.foldersText))
        await f.env.compose.settle()
        #expect(f.draftWrites.isEmpty, "staged files are not the user's edit")
        session.subject = "Files"
        #expect(await session.save())
        #expect(f.recorder.calls.contains("createDraft"))
        #expect(session.assembledFields().attachments.count == 2, "the draft carries the files once it is saved")
    }

    @Test func moreThanTwentyFilesAreRefusedAndNothingOpens() async throws {
        let f = ServicesFixture()
        await f.ready()
        f.services.deliver(.attachFiles(try f.files((0...ServiceInput.maxFiles).map { "f\($0).txt" })))
        #expect(f.session == nil)
        #expect(f.toasts.contains(ServicesModel.tooManyFilesText))
        f.services.deliver(.attachFiles([]))
        #expect(f.session == nil)
    }

    @Test func searchShowsResultsOnTheActiveAccount() async throws {
        let f = ServicesFixture()
        await f.ready()
        let account = f.env.router.activeAccountID
        f.services.deliver(.search("  budget\nreview "))
        #expect(f.env.router.location == .search("budget review"))
        #expect(f.env.router.activeAccountID == account && f.env.router.mode == .list)
        #expect(f.env.composeIfStarted?.sessions.isEmpty != false)
    }

    @Test func theSixthRequestInTenSecondsIsDroppedWithOneNotice() async {
        let f = ServicesFixture()
        f.env.router.start()
        await eventually(timeout: .seconds(15)) { f.env.router.accountsLoaded }
        var clock = fixedNow
        let model = ServicesModel(environment: f.env, registrar: f.services, preferences: f.env.system.preferences,
                                  showMainWindow: {}, now: { clock })
        model.start()
        for i in 0..<7 { f.services.deliver(.search("q\(i)")) }
        #expect(f.env.router.location == .search("q4"), "five are handled")
        #expect(f.toasts.filter { $0 == ServicesModel.rateLimitedText }.count == 1)
        clock = fixedNow.addingTimeInterval(10.5)
        f.services.deliver(.search("later"))
        #expect(f.env.router.location == .search("later"))
    }

    @Test func requestsBeforeTheAccountsLoadAreHeldAndHandledInOrder() async {
        let f = ServicesFixture()
        f.env.system.startServices()
        f.services.deliver(.search("first"))
        f.services.deliver(.search("second"))
        let model = f.env.system.services
        #expect(model?.queuedCount == 2)
        f.env.router.start()
        await eventually(timeout: .seconds(15)) { model?.queuedCount == 0 }
        #expect(f.env.router.location == .search("second"), "handled in arrival order")
    }

    @Test func switchedOffMailComesForwardAndOnlySaysSo() async throws {
        let f = ServicesFixture()
        await f.ready()
        f.env.system.setServices(enabled: false)
        #expect(f.services.isRegistered, "the provider stays registered")
        f.services.deliver(.newMessage("Hello"))
        #expect(f.session == nil)
        #expect(f.toasts.contains(ServicesModel.offText) && f.active.windowShows == 1)
        #expect(!FeatureFlags.load(from: f.env.system.preferences.defaults).isEnabled(.services, default: true))
        f.env.system.setServices(enabled: true)
        f.services.deliver(.newMessage("Hello"))
        #expect(f.session != nil)
    }

    @Test func theModuleIsOnByDefaultAndOffLeavesNoProvider() async {
        let on = ServicesFixture()
        on.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { on.env.system.services != nil }
        #expect(on.services.isRegistered && on.env.modules.modules.contains(.services))
        let off = ServicesFixture(flags: FeatureFlags().with(.services, false))
        off.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { off.env.system.notifications != nil }
        #expect(off.env.system.services == nil && !off.services.isRegistered)
        #expect(!off.services.deliver(.newMessage("x")))
    }

    @Test func theSettingsSwitchAndItsStatus() {
        let f = ServicesFixture()
        let settings = ServicesSettingsModel(system: f.env.system)
        #expect(settings.isOn && settings.status.hasPrefix("On."))
        settings.setOn(false)
        #expect(!settings.isOn && settings.status.hasPrefix("Off."))
        #expect(ServicesSettingsModel.entryTitles.count == 3)
        #expect(FeaturesSettingsModel.info(.services).title == "Services menu")
    }

    @Test func logsNeverCarryTheTextTheQueryOrFileNames() async throws {
        let seed = UUID().uuidString
        let lines = Mutex<[String]>([])
        Log.setMirror { record in lines.withLock { $0.append(record.message) } }
        defer { Log.setMirror(nil) }
        let f = ServicesFixture()
        await f.ready()
        f.services.deliver(.newMessage("body-\(seed)"))
        f.services.deliver(.search("query-\(seed)"))
        f.services.deliver(.attachFiles(try f.files(["file-\(seed).txt"])))
        f.services.deliver(.newMessage("  "))
        let captured = lines.withLock { $0 }
        #expect(captured.contains { $0.contains("services:") })
        #expect(!captured.contains { $0.contains(seed) })
    }
}
