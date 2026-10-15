import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct SuperhumanImportTests {
    private func labelID(_ f: OverlayFixture, _ name: String) async throws -> GmailLabelID {
        let account = try #require(f.router.active?.id)
        let labels = try await SuperhumanImportModel.labels(account: account, data: f.store)
        return try #require(SuperhumanImportModel.label(named: name, in: labels)).labelID
    }

    @Test func countsFirstThenMutesAsOneUndoEntryAndLeavesSuperhumansLabels() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 30, now: fixedNow))
        await f.loaded()
        let account = try #require(f.router.active?.id)
        let keys = Array(f.rows.prefix(4).map(\.id))
        try #require(keys.count == 4)
        _ = try await f.store.createLabel(account, name: SuperhumanImportModel.mutedLabelName, applyTo: Array(keys.prefix(3)))
        _ = try await f.store.createLabel(account, name: SuperhumanImportModel.snoozedLabelName, applyTo: [keys[3]])
        let entries = f.env.undo?.stack.count ?? 0

        let model = SuperhumanImportModel(environment: f.env)
        await model.count()
        #expect(model.phase == .counted)
        #expect(model.hasMutedLabel && model.hasSnoozedLabel)
        #expect(model.mutedTotal == 3 && Set(model.toMute) == Set(keys.prefix(3)))
        #expect(model.snoozed.map(\.thread) == [keys[3]])
        #expect(f.env.undo?.stack.count == entries, "counting changes nothing")

        #expect(await model.importMuted())
        #expect(f.env.undo?.stack.count == entries + 1, "one undo entry for the whole import")
        guard case .done = model.phase else { throw TestFailure("\(model.phase)") }

        let superhumanMuted = try await labelID(f, SuperhumanImportModel.mutedLabelName)
        let still = try await f.store.threadPage(.label(superhumanMuted), account: account, after: nil, limit: 100)
        #expect(Set(still.rows.map(\.id)) == Set(keys.prefix(3)))
        await eventuallyAsync {
            await model.count()
            return model.toMute.isEmpty && model.mutedTotal == 3
        }
    }

    @Test func showInMailOpensTheSnoozedLabelsView() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await f.loaded()
        let account = try #require(f.router.active?.id)
        let key = try #require(f.rows.first?.id)
        _ = try await f.store.createLabel(account, name: SuperhumanImportModel.snoozedLabelName, applyTo: [key])
        let model = SuperhumanImportModel(environment: f.env)
        await model.count()
        #expect(!model.hasMutedLabel && model.toMute.isEmpty)
        model.showSnoozedInMail()
        let snoozed = try await labelID(f, SuperhumanImportModel.snoozedLabelName)
        #expect(f.router.location == .label(snoozed))
    }

    @Test func labelNamesMatchExactlyFirstThenIgnoringCase() {
        func label(_ id: Int64, _ name: String) -> LabelInfo {
            LabelInfo(id: id, account: AccountID(1), labelID: GmailLabelID("Label_\(id)"), kind: .user, name: name,
                      displayName: name, position: Int(id))
        }
        let labels = [label(1, "[superhuman]/muted"), label(2, "[Superhuman]/Muted")]
        #expect(SuperhumanImportModel.label(named: SuperhumanImportModel.mutedLabelName, in: labels)?.id == 2)
        #expect(SuperhumanImportModel.label(named: SuperhumanImportModel.mutedLabelName, in: [labels[0]])?.id == 1)
        #expect(SuperhumanImportModel.label(named: SuperhumanImportModel.snoozedLabelName, in: labels) == nil)
    }
}
