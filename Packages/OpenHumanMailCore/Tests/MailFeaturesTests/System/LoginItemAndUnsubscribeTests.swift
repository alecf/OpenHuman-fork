import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized)
struct LaunchAtLoginTests {
    @Test func switchRegistersAndShowsTheApprovalState() {
        let login = FakeLoginItem()
        login.statusAfterRegister = .requiresApproval
        let model = LaunchAtLoginModel(control: login)
        #expect(!model.isOn && model.detail == nil)
        model.setEnabled(true)
        #expect(login.registerCalls == 1)
        #expect(model.isOn && model.status == .requiresApproval)
        #expect(model.detail?.contains("Login Items") == true)
        #expect(model.showsSettingsButton)
        model.openSystemSettings()
        #expect(login.openedSettings == 1)
        login.current = .enabled
        model.refresh()
        #expect(model.isOn && model.detail == nil && !model.showsSettingsButton)
        model.setEnabled(false)
        #expect(login.unregisterCalls == 1 && !model.isOn)
    }

    @Test func aRefusedRegistrationSaysSoAndStaysOff() {
        let login = FakeLoginItem()
        login.failure = NSError(domain: "test", code: 1)
        let model = LaunchAtLoginModel(control: login)
        model.setEnabled(true)
        #expect(!model.isOn)
        #expect(model.errorMessage == "Couldn't turn on Open at login.")
    }

    @Test func defaultsOffAndModuleOffRemovesTheModel() {
        let f = SystemFixture()
        f.env.runLaunchTasks()
        #expect(f.login.registerCalls == 0, "nothing registers on its own")
        let off = SystemFixture(flags: FeatureFlags().with(.launchAtLogin, false))
        off.env.runLaunchTasks()
        #expect(off.env.system.launchAtLogin == nil)
    }
}

@MainActor
@Suite(.serialized)
struct UnsubscribeModelTests {
    private func listThread(_ f: SystemFixture) async throws -> (ThreadRow, MessageSummary, UnsubscribeInfo) {
        let rows = try #require(await first(f.store.threadWindow(.system(.inbox), account: f.account, limit: 200))).rows
        for row in rows {
            guard let detail = try await first(f.store.threadDetail(row.id)) ?? nil, let message = detail.messages.last else { continue }
            if let info = try await f.store.unsubscribeInfo(message.id) { return (row, message, info) }
        }
        throw TestFailure("no thread with List-Unsubscribe in the fake corpus")
    }

    private func started() -> SystemFixture {
        let f = SystemFixture(corpus: .small)
        f.env.runLaunchTasks()
        return f
    }

    @Test func theHeaderLineAppearsOnlyForAMessageThatOffersUnsubscribe() async throws {
        let f = started()
        await eventually(timeout: .seconds(15)) { f.env.system.unsubscribe != nil }
        let model = try #require(f.env.system.unsubscribe)
        let (row, message, _) = try await listThread(f)
        let item = await model.item(for: message, in: row.id)
        #expect(item?.title == "Unsubscribe")
        let plain = try #require(await first(f.store.threadWindow(.system(.inbox), account: f.account, limit: 200))?.rows.first {
            $0.id != row.id
        })
        let plainDetail = try #require(try await first(f.store.threadDetail(plain.id)) ?? nil)
        if let last = plainDetail.messages.last, try await f.store.unsubscribeInfo(last.id) == nil {
            #expect(await model.item(for: last, in: plain.id) == nil)
        }
    }

    @Test func clickingTheLineGoesAheadWithUndoInsteadOfACard() async throws {
        let f = started()
        await eventually(timeout: .seconds(15)) { f.env.system.unsubscribe != nil }
        let model = try #require(f.env.system.unsubscribe)
        let handler = try #require(f.env.actions.threadActions)
        let window = TestGate()
        handler.sleep = { _ in await window.wait() }
        let compose = f.env.compose
        let (row, message, info) = try await listThread(f)
        guard let item = await model.item(for: message, in: row.id) else { throw TestFailure("no item") }
        f.env.router.start()
        model.activate(item, for: message, in: row.id)
        switch info {
        case .oneClick:
            await eventually(timeout: .seconds(15)) { handler.heldUnsubscribeCount == 1 }
            #expect(f.store.unsubscribeRequests.isEmpty, "nothing goes out inside the undo window")
            #expect(f.env.notices.toasts.contains { $0.message.hasPrefix("Unsubscribing from") && $0.actionTitle == "Undo" })
            window.release()
            await eventually(timeout: .seconds(15)) { f.store.unsubscribeRequests == [message.id] }
            await eventually(timeout: .seconds(15)) {
                f.env.notices.toasts.contains {
                    $0.message.hasPrefix("Unsubscribe request sent") && $0.actionTitle?.hasPrefix("Archive all") == true
                        && $0.secondaryActionTitle?.hasSuffix("to Trash") == true
                }
            }
        case .mailto(let address, _):
            await eventually(timeout: .seconds(15)) {
                compose.sessions.contains { $0.to.tokens.contains { $0.email == address.email } }
            }
            #expect(f.store.sentMessages.isEmpty && f.store.unsubscribeRequests.isEmpty)
        case .link(let url):
            await eventually(timeout: .seconds(15)) { f.opener.opened == [url] }
            #expect(f.store.unsubscribeRequests.isEmpty)
        }
    }

    @Test func readOnlyModeRefusesTheActionAndNothingIsHeldOrSent() async throws {
        let f = SystemFixture(corpus: .small,
                              options: .init(remoteAck: .immediate, safeMode: .readOnly))
        f.env.runLaunchTasks()
        await eventually(timeout: .seconds(15)) { f.env.system.unsubscribe != nil }
        let model = try #require(f.env.system.unsubscribe)
        let (row, message, _) = try await listThread(f)
        let item = try #require(await model.item(for: message, in: row.id))
        f.env.router.start()
        model.activate(item, for: message, in: row.id)
        await eventually(timeout: .seconds(15)) { f.env.notices.toasts.contains { $0.message == StatusModel.blockedText } }
        #expect(f.env.actions.threadActions?.heldUnsubscribeCount == 0 && f.opener.opened.isEmpty)
        #expect(f.store.unsubscribeRequests.isEmpty)
        let ctx = ActionContext(scope: .reader, account: f.account, focusedThread: row.id, focusedMessage: message.id,
                                safeMode: .readOnly)
        #expect(f.env.actions.availability(.unsubscribe, host: f.env.router, context: ctx) != .enabled)
    }

    @Test func httpsLinksOpenInTheBrowserAndNothingElseDoes() {
        let f = started()
        let model = SystemFixture.unsubscribeModel(f)
        model.present(.openURL(URL(string: "https://list.example.com/unsub?id=1")!))
        model.present(.openURL(URL(string: "http://list.example.com/unsub")!))
        model.present(.openURL(URL(string: "file:///etc/passwd")!))
        model.present(.openURL(URL(string: "mailto:a@b.example")!))
        #expect(f.opener.opened == [URL(string: "https://list.example.com/unsub?id=1")!])
        #expect(f.env.notices.toasts.count == 2, "refusals are said once (the third replaces nothing: max two shown)")
    }

    @Test func installAndUninstallHookTheOverlayChainAndTheReaderSlot() {
        let f = SystemFixture()
        let slot = ReaderHeaderAccessoryStore()
        let model = UnsubscribeModel(environment: f.env, urlOpener: f.opener, accessorySlot: slot)
        model.install()
        #expect(f.env.overlays.fallback === model && slot.current === model)
        model.uninstall()
        #expect(f.env.overlays.fallback == nil && slot.current !== model)
    }

    @Test func presenterChainKeepsComposeAndOtherKinds() {
        let f = started()
        let model = SystemFixture.unsubscribeModel(f)
        let other = RecordingPresenter()
        other.kinds = [.compose, .palette]
        model.next = other
        #expect(model.canPresent(.openURL))
        #expect(model.canPresent(.compose) && model.canPresent(.palette))
        #expect(!model.canPresent(.snoozePicker))
        model.present(.compose(.new))
        #expect(other.lastKind == .compose)
    }

    @Test func moduleOffRemovesTheLineAndTheAction() {
        let f = SystemFixture(flags: FeatureFlags().with(.unsubscribe, false))
        f.env.runLaunchTasks()
        #expect(f.env.system.unsubscribe == nil)
        #expect(!f.env.actions.contains(.unsubscribe))
        #expect(f.env.overlays.fallback == nil)
    }
}

extension SystemFixture {
    static func unsubscribeModel(_ f: SystemFixture) -> UnsubscribeModel {
        UnsubscribeModel(environment: f.env, urlOpener: f.opener)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
