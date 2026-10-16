import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.timeLimit(.minutes(2))) struct LabelPickerTests {
    private func fixture() async throws -> (OverlayFixture, ThreadKey, LabelInfo) {
        let f = OverlayFixture(corpus: .rich(threadCount: 60, now: fixedNow))
        await f.loaded()
        let state = try #require(f.router.active)
        await untilObserved { state.labels.contains { $0.displayName == "Clients" } }
        let key = try #require(f.router.list?.cursor)
        let clients = try #require(state.labels.first { $0.displayName == "Clients" })
        return (f, key, clients)
    }

    private func isInInbox(_ names: Set<String>) -> Bool {
        names.contains { $0.uppercased() == "INBOX" }
    }

    @Test func lOpensThePickerWithUserLabelsOnly() async throws {
        let (f, key, _) = try await fixture()
        #expect(await f.run(.label))
        let picker = try #require(f.labelPicker)
        #expect(picker.mode == .label && picker.targets == [key] && picker.title == "Label as…")
        let names: [String] = picker.rows.compactMap { if case .label(let l) = $0.kind { l.name } else { nil } }
        #expect(!names.isEmpty && !names.contains("INBOX") && !names.contains { $0.hasPrefix("OpenHuman/") })
        #expect(picker.rows.allSatisfy { $0.check != nil }, "label mode shows checkboxes")
    }

    @Test func spaceToggleAndEnterApplyWithUndo() async throws {
        let (f, key, clients) = try await fixture()
        let before = f.store.labelNames(of: key)
        #expect(isInInbox(before) && !before.contains("Clients"))
        await f.run(.label)
        let picker = try #require(f.labelPicker)
        picker.query = "clients"
        let row = try #require(picker.rows.first { $0.title == "Clients" })
        #expect(row.check == .off)
        picker.moveCursor(by: picker.rows.firstIndex(of: row)!)
        picker.toggleCursor()
        #expect(picker.rows.first { $0.title == "Clients" }?.check == .on)
        #expect(picker.changes.add.map(\.id) == [clients.id])
        picker.confirm()
        #expect(f.center.overlay.isNone)
        await f.settled()
        #expect(f.hasToast("Labeled Clients"))
        #expect(f.store.labelNames(of: key) == before.union(["Clients"]))
        #expect(await f.run(.undo))
        #expect(f.store.labelNames(of: key) == before)
    }

    @Test func enterAppliesTheCursorRowWhenNothingWasToggled() async throws {
        let (f, key, _) = try await fixture()
        let before = f.store.labelNames(of: key)
        #expect(isInInbox(before) && !before.contains("Clients"))
        await f.run(.label)
        let picker = try #require(f.labelPicker)
        picker.query = "clients"
        picker.confirm()
        await f.settled()
        #expect(f.hasToast("Labeled Clients"))
        #expect(f.store.labelNames(of: key) == before.union(["Clients"]))
    }

    @Test func aSetOfThreadsShowsTheMixedState() async throws {
        let (f, _, clients) = try await fixture()
        let rows = f.rows
        let withLabel = rows.filter { $0.userLabelIDs.contains(clients.id) }.map(\.id)
        let without = rows.filter { !$0.userLabelIDs.contains(clients.id) }.map(\.id)
        let a = try #require(withLabel.first), b = try #require(without.first)
        let picker = LabelPickerModel(mode: .label, targets: [a, b], account: a.account, labels: f.router.active?.labels ?? [],
                                      targetRows: rows, actions: LabelPickerActions(setLabels: { _, _ in }, move: { _ in },
                                                                                    create: { _ in }, navigate: { _ in }))
        #expect(picker.check(of: clients) == .mixed)
        picker.query = "clients"
        picker.toggleCursor()
        #expect(picker.check(of: clients) == .on, "a mixed row turns on first")
        picker.toggleCursor()
        #expect(picker.check(of: clients) == .off)
    }

    @Test func moveIsSingleSelectAndRemovesInbox() async throws {
        let (f, key, _) = try await fixture()
        #expect(await f.run(.move))
        let picker = try #require(f.labelPicker)
        #expect(picker.mode == .move && picker.title == "Move to…" && picker.rows.allSatisfy { $0.check == nil })
        picker.query = "clients"
        picker.confirm()
        await f.settled()
        #expect(f.hasToast("Moved to Clients"))
        #expect(!f.rows.contains { $0.id == key })
        let names = f.store.labelNames(of: key)
        #expect(names.contains("Clients") && !isInInbox(names))
    }

    @Test func goToLabelNavigates() async throws {
        let (f, _, clients) = try await fixture()
        #expect(await f.run(.goLabel))
        let picker = try #require(f.labelPicker)
        #expect(picker.mode == .navigate && picker.targets.isEmpty)
        picker.query = "clients"
        #expect(!picker.rows.contains { if case .create = $0.kind { true } else { false } }, "navigating never creates")
        picker.confirm()
        #expect(f.router.active?.location == .label(clients.labelID))
    }

    @Test func createLabelCreatesAndAppliesInOneUndoableStep() async throws {
        let (f, key, _) = try await fixture()
        let before = f.store.labelNames(of: key)
        #expect(isInInbox(before))
        await f.run(.label)
        let picker = try #require(f.labelPicker)
        picker.query = "Brand New"
        let create = try #require(picker.rows.last)
        #expect(create.title == "Create label “Brand New”")
        picker.moveCursor(by: picker.rows.count - 1)
        picker.confirm()
        await f.settled()
        #expect(f.hasToast("Created label Brand New"))
        #expect(f.store.labelNames(of: key) == before.union(["Brand New"]))
        #expect(f.env.undo?.stack.count == 1, "one entry")
        #expect(await f.run(.undo))
        #expect(f.store.labelNames(of: key) == before)
    }

    @Test func createLabelWorksOffline() async throws {
        var options = FakeMailStore.Options(remoteAck: .manual)
        options.liveConnectivity = true
        let f = OverlayFixture(corpus: .rich(threadCount: 60, now: fixedNow), options: options)
        await f.loaded()
        let key = try #require(f.router.list?.cursor)
        let before = f.store.labelNames(of: key)
        #expect(isInInbox(before))
        f.store.setOffline(true)
        let pending = f.store.pendingOperationCount
        f.center.present(.labelPicker(targets: [key], mode: .label))
        let picker = try #require(f.labelPicker)
        picker.query = "Offline Label"
        picker.moveCursor(by: picker.rows.count - 1)
        picker.confirm()
        await f.settled()
        #expect(f.hasToast("Created label Offline Label"))
        #expect(f.store.labelNames(of: key) == before.union(["Offline Label"]))
        #expect(f.store.pendingOperationCount > pending, "queued for when the connection returns")
    }

    @Test func theCreateRowIsHiddenForAnExactNameAndThePickerNeedsAWritePort() async throws {
        let (f, _, _) = try await fixture()
        await f.run(.label)
        let picker = try #require(f.labelPicker)
        picker.query = "clients"
        #expect(!picker.rows.contains { if case .create = $0.kind { true } else { false } })
        picker.query = "Cli"
        #expect(picker.rows.last.map { if case .create = $0.kind { true } else { false } } == true)

        let noPort = OverlayFixture(corpus: .rich(threadCount: 60, now: fixedNow), writePort: false)
        await noPort.loaded()
        #expect(await noPort.run(.label), "refused out loud, not opened")
        #expect(noPort.center.overlay.isNone)
        let key = try #require(noPort.router.list?.cursor)
        #expect(noPort.registry.threadActions?.createLabel(named: "X", account: key.account, applyTo: [key], host: noPort.router) == nil)
    }
}

@MainActor
@Suite struct ShortcutSheetAndPresenterTests {
    @Test func questionMarkListsEveryBoundActionIncludingOverrides() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        f.registry.applyKeymap(KeymapOverrides(bindings: ["thread.done": ["y"]]))
        #expect(await f.run(.shortcutHelp))
        guard case .shortcuts(let sheet) = f.center.overlay else {
            Issue.record("no sheet")
            return
        }
        #expect(sheet.sections.map(\.title) == ["Navigate", "Act", "Write"])
        let bound = f.registry.descriptors.filter { !$0.defaultBindings.isEmpty }.map(\.id)
        #expect(Set(sheet.allLines.map(\.action)) == Set(bound), "every bound action of the effective catalog")
        #expect(sheet.allLines.first { $0.action == .markDone }?.keys == ["Y"], "the user's override, not E")
        sheet.filter = "snooze"
        #expect(sheet.sections.flatMap(\.lines).contains { $0.action == .snooze })
        #expect(!sheet.sections.flatMap(\.lines).contains { $0.action == .markDone })
        sheet.filter = ""
        #expect(sheet.sections.count == 3)
    }

    @Test func thePresenterShowsOneOverlayAtATimeAndEscDismisses() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        await f.run(.shortcutHelp)
        #expect(f.center.isShowing)
        await f.run(.commandPalette)
        #expect(f.palette != nil, "the palette replaced the sheet")
        f.center.dismiss()
        #expect(!f.center.isShowing && !f.registry.palette.isOpen)
    }

    @Test func kindsOtherWorkPackagesDrawGoToTheFallback() async throws {
        let f = OverlayFixture()
        await f.loaded(10)
        #expect(!f.center.canPresent(.compose) && !f.center.canPresent(.openURL))
        #expect(f.center.canPresent(.palette) && f.center.canPresent(.search) && f.center.canPresent(.labelPicker))
        let other = RecordingPresenter()
        f.center.fallback = other
        #expect(f.center.canPresent(.compose))
        f.center.present(.compose(.new))
        #expect(other.lastKind == .compose)
        #expect(f.registry.availability(.compose, host: f.router) == .enabled)
    }

    @Test func theCenterIsTheRegistrysPresenterOnlyOnceTheWindowAsksForIt() async throws {
        let env = AppEnvironment.fake()
        #expect(env.actions.presenter == nil)
        let center = env.overlays
        #expect(env.actions.presenter === center)
    }
}
