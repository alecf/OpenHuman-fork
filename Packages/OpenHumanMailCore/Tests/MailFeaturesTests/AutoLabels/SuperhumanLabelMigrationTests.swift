import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct SuperhumanLabelMigrationTests {
    typealias F = AutoLabelFixture

    static let meeting = "[Superhuman]/AI/Meeting"
    static let marketing = "[Superhuman]/AI/Marketing"
    static let comp = "[Superhuman]/AI/comp"

    struct Seeded {
        var meeting: [ThreadKey]
        var marketing: [ThreadKey]
        var comp: [ThreadKey]
        var all: [ThreadKey] { meeting + marketing + comp }
    }

    static func seed(_ store: FakeMailStore) async throws -> Seeded {
        let rows = try await store.threadPage(.system(.inbox), account: F.work, after: nil, limit: 1_000).rows
        try #require(rows.count >= 17)
        let keys = rows.map(\.id)
        let seeded = Seeded(meeting: Array(keys[0..<3]), marketing: Array(keys[3..<15]), comp: Array(keys[15..<17]))
        _ = try await store.createLabel(F.work, name: meeting, applyTo: seeded.meeting)
        _ = try await store.createLabel(F.work, name: marketing, applyTo: seeded.marketing)
        _ = try await store.createLabel(F.work, name: comp, applyTo: seeded.comp)
        return seeded
    }

    func importer(_ f: F, writes: Bool? = true) -> SuperhumanLabelImportModel {
        SuperhumanLabelImportModel(environment: f.env, options: .init(writesToGmail: writes))
    }

    @Test func documentedNamesMapAndUnconfirmedOnesOnlyWhenTheUserMapsThem() {
        let rules = SuperhumanLabelRules()
        #expect(rules.category(forLabelName: "[Superhuman]/AI/Meeting") == "Meeting")
        #expect(rules.category(forLabelName: "[superhuman]/ai/marketing") == "Marketing", "any case")
        #expect(rules.category(forLabelName: "[Superhuman]/AI/Travel") == "Travel")
        #expect(rules.category(forLabelName: "[Superhuman]/AI/Waiting") == "Waiting")
        for name in SuperhumanLabels.unconfirmedNames {
            #expect(rules.category(forLabelName: "[Superhuman]/AI/" + name) == nil, "\(name) is skipped by default")
        }
        #expect(rules.category(forLabelName: "[Superhuman]/Muted") == nil, "not an AI category")
        #expect(rules.category(forLabelName: "[Superhuman]/AI/Meeting/Extra") == nil)
        #expect(rules.category(forLabelName: "Meeting") == nil)
        let mapped = SuperhumanLabelRules(mapping: ["COMP": "invoice", "FYI": "Banana"])
        #expect(mapped.category(forLabelName: Self.comp) == "Invoice", "the user's choice, names without regard to case")
        #expect(mapped.category(forLabelName: "[Superhuman]/AI/FYI") == nil, "only our categories")
        #expect(mapped.category(inLabelNames: [Self.marketing, "[Superhuman]/AI/Respond"]) == "Respond",
                "one category per conversation, our order")
        #expect(SuperhumanLabels.isSuperhuman("[Superhuman]") && SuperhumanLabels.isSuperhuman("[Superhuman]/Is Snoozed"))
        #expect(!SuperhumanLabels.isSuperhuman("[Superhuman]x") && !SuperhumanLabels.isSuperhuman("Superhuman"))
        #expect(rules.hides("[Superhuman]/Muted") && !SuperhumanLabelRules(hidesLabels: false).hides("[Superhuman]/Muted"))
        #expect(!rules.hides("Clients"))
    }

    @Test func agreementPrecisionRecallAndTheConfusionMatrix() {
        typealias P = SuperhumanAgreement.Pair
        let pairs = Array(repeating: P(superhuman: "Meeting", ours: "Meeting"), count: 3)
            + [P(superhuman: "Meeting", ours: "Respond")]
            + Array(repeating: P(superhuman: "Marketing", ours: "Marketing"), count: 2)
            + [P(superhuman: "Marketing", ours: nil), P(superhuman: "News", ours: "Marketing")]
        let report = SuperhumanAgreement.score(pairs, fromCache: 5, ranOnDevice: 3, failed: 1, generatedAt: fixedNow)
        #expect(report.compared == 8 && report.agreed == 5 && abs(report.agreement - 0.625) < 1e-9)
        #expect(report.fromCache == 5 && report.ranOnDevice == 3 && report.failed == 1)
        let byName = Dictionary(uniqueKeysWithValues: report.perCategory.map { ($0.category, $0) })
        let meeting = byName["Meeting"]
        #expect(meeting?.superhuman == 4 && meeting?.ours == 3 && meeting?.agreed == 3)
        #expect(meeting?.precision == 1 && meeting?.recall == 0.75)
        let marketing = byName["Marketing"]
        #expect(marketing?.superhuman == 3 && marketing?.ours == 3 && marketing?.agreed == 2)
        #expect(abs((marketing?.precision ?? 0) - 2.0 / 3) < 1e-9 && abs((marketing?.recall ?? 0) - 2.0 / 3) < 1e-9)
        #expect(byName["News"]?.recall == 0 && byName["News"]?.precision == 0)
        #expect(byName["Respond"]?.superhuman == 0 && byName["Respond"]?.ours == 1 && byName["Respond"]?.precision == 0)
        #expect(byName["Pitch"] == nil, "a category nobody used is left out")
        #expect(report.confusion["Marketing"]?[SuperhumanAgreement.noneColumn] == 1)
        #expect(report.confusion["News"]?["Marketing"] == 1)
        #expect(report.rows == ["Meeting", "News", "Marketing"], "Superhuman's categories in our order")
        #expect(report.columns.last == SuperhumanAgreement.noneColumn)
        #expect(SuperhumanAgreement.score([], fromCache: 0, ranOnDevice: 0, failed: 0, generatedAt: nil).agreement == 0)
    }

    @Test func countsPerCategoryAndTenExamplesComeFirstAndWriteNothing() async throws {
        let f = F(writes: true)
        _ = try await Self.seed(f.store)
        let entries = f.env.undo?.stack.count ?? 0
        let model = importer(f)
        await model.count(account: F.work)
        #expect(model.phase == .counted)
        let counts = Dictionary(uniqueKeysWithValues: model.counts.map { ($0.category, $0) })
        #expect(counts["Meeting"]?.toImport == 3 && counts["Meeting"]?.total == 3 && counts["Meeting"]?.sources == ["Meeting"])
        #expect(counts["Marketing"]?.toImport == 12 && counts["Marketing"]?.alreadyOurs == 0)
        #expect(counts.keys.sorted() == ["Marketing", "Meeting"], "comp is not documented: skipped")
        #expect(model.preview.count == 10, "ten examples")
        #expect(model.plan?.total == 15 && model.importTitle == "Import 15 conversations")
        let comp = try #require(model.unconfirmed.first { $0.name == "comp" })
        #expect(comp.isKnown && comp.mappedTo == nil)
        #expect(f.recorder.calls.isEmpty, "counting writes nothing")
        #expect(f.env.undo?.stack.count == entries)
        #expect(f.log.all.isEmpty, "the import never asks the model")
    }

    @Test func mappingAnUnconfirmedLabelAddsItToTheCounts() async throws {
        let f = F(writes: true)
        let seeded = try await Self.seed(f.store)
        let model = importer(f)
        await model.count(account: F.work)
        await model.setMapping("Invoice", for: "comp")
        #expect(try await f.store.get(AppSettings.superhumanLabelMapping) == ["comp": "Invoice"])
        #expect(model.counts.first { $0.category == "Invoice" }?.toImport == seeded.comp.count)
        #expect(model.unconfirmed.first { $0.name == "comp" }?.mappedTo == "Invoice")
        await model.setMapping(nil, for: "comp")
        #expect(model.counts.first { $0.category == "Invoice" } == nil, "Skip takes it out again")
        #expect(f.recorder.calls.isEmpty)
    }

    @Test func importIsOneUndoEntryAndNeverTouchesSuperhumansLabels() async throws {
        let f = F(writes: true)
        let seeded = try await Self.seed(f.store)
        let undo = try #require(f.env.undo)
        let model = importer(f)
        await model.count(account: F.work)
        let plan = try #require(model.plan)
        #expect(plan.addedLabelNames.allSatisfy { $0.hasPrefix(OHGmailLabels.root + "/") })
        let superhumanIDs = Set((await f.labels()).filter { SuperhumanLabels.isSuperhuman($0.name) }.map(\.labelID))
        #expect(plan.steps.allSatisfy { step in step.labelID.map { !superhumanIDs.contains($0) } ?? true },
                "the plan only ever adds our label")
        let entries = undo.stack.count
        #expect(await model.importLabels())
        #expect(undo.stack.count == entries + 1, "one undo entry for the whole import")
        #expect(f.recorder.calls.contains("createLabel"), "our label is created on first use")
        for key in seeded.meeting {
            let names = f.store.labelNames(of: key)
            #expect(names.contains("OpenHuman/Meeting") && names.contains(Self.meeting))
        }
        for key in seeded.marketing {
            let names = f.store.labelNames(of: key)
            #expect(names.contains("OpenHuman/Marketing") && names.contains(Self.marketing))
        }
        for key in seeded.comp {
            let names = f.store.labelNames(of: key)
            #expect(names.contains(Self.comp) && !names.contains { OHGmailLabels.autoLabelCategory(inLabelName: $0) != nil },
                    "an unconfirmed name is skipped")
        }
        #expect(f.log.all.isEmpty, "never the model")
        guard case .done = model.phase else { throw TestFailure("\(model.phase)") }

        await undo.undoLast()
        await eventually {
            seeded.meeting.allSatisfy { !f.store.labelNames(of: $0).contains("OpenHuman/Meeting") }
        }
        #expect(seeded.all.allSatisfy { key in f.store.labelNames(of: key).contains { SuperhumanLabels.aiName($0) != nil } })
        #expect((await f.labels()).contains { $0.name == "OpenHuman/Meeting" }, "the label object stays")
    }

    @Test func aSecondRunWritesNothingAndTheCenterReadsTheImportBackWithoutTheModel() async throws {
        let f = F(writes: true)
        let seeded = try await Self.seed(f.store)
        let model = importer(f)
        await model.count(account: F.work)
        #expect(await model.importLabels())
        let calls = f.recorder.calls.count
        await model.count(account: F.work)
        #expect(model.plan?.total == 0)
        #expect(model.counts.first { $0.category == "Meeting" }?.alreadyOurs == 3)
        #expect(await model.importLabels() == false)
        #expect(model.phase == .done("Nothing left to import."))
        #expect(f.recorder.calls.count == calls, "no label op is repeated")
        await f.center.classifyRecent()
        let entries = try await f.index.entries(account: F.work)
        let byThread = Dictionary(entries.map { ($0.thread, $0) }, uniquingKeysWith: { first, _ in first })
        for key in seeded.meeting + seeded.marketing {
            let entry = try #require(byThread[key.gmailThreadID])
            #expect(entry.source != .model, "an imported conversation is read back (or derived Waiting), never classified")
        }
        #expect(entries.contains { $0.source == .gmailLabel && ($0.category == "Meeting" || $0.category == "Marketing") })
    }

    @Test func oursWinsOnConflict() async throws {
        let f = F(writes: true)
        let seeded = try await Self.seed(f.store)
        let sorted = seeded.meeting[0]
        try await f.index.put([AutoLabelEntry(account: F.work, thread: sorted.gmailThreadID,
                                              latestMessage: GmailMessageID("m-latest"), promptVersion: 1, modelID: "x",
                                              category: "Respond", source: .model, classifiedAt: fixedNow)])
        let labelled = seeded.marketing[0]
        _ = try await f.store.createLabel(F.work, name: "OpenHuman/Pitch", applyTo: [labelled])
        let model = importer(f)
        await model.count(account: F.work)
        #expect(model.counts.first { $0.category == "Meeting" }?.alreadyOurs == 1)
        #expect(model.counts.first { $0.category == "Marketing" }?.alreadyOurs == 1)
        #expect(model.plan?.threads.contains(sorted) == false && model.plan?.threads.contains(labelled) == false)
        #expect(await model.importLabels())
        let names = f.store.labelNames(of: labelled)
        #expect(names.contains("OpenHuman/Pitch") && !names.contains("OpenHuman/Marketing"), "ours wins")
        #expect(f.store.isVisible(sorted) && !f.store.labelNames(of: sorted).contains("OpenHuman/Meeting"))
    }

    @Test func fakeDataAndReadOnlyRefuseBeforeAnyPortCall() async throws {
        let fake = F(writes: true)
        _ = try await Self.seed(fake.store)
        let model = importer(fake, writes: nil)
        await model.count(account: F.work)
        #expect(model.plan?.total == 15)
        #expect(model.writeBlockedReason != nil && !model.canImport && !model.canRemove)
        #expect(await model.importLabels() == false)
        guard case .failed = model.phase else { throw TestFailure("\(model.phase)") }
        #expect(fake.recorder.calls.isEmpty, "fake data: nothing reaches the mail port")

        let store = FakeMailStore(corpus: .rich(threadCount: 60, now: fixedNow),
                                  options: .init(remoteAck: .immediate, heldSends: .manual, safeMode: .normal,
                                                 now: { fixedNow }))
        _ = try await Self.seed(store)
        store.setSafeMode(.readOnly)
        let readOnly = F(safeMode: .readOnly, writes: true, sharing: store)
        let blocked = importer(readOnly)
        await blocked.count(account: F.work)
        #expect(blocked.phase == .counted, "counting works in read-only")
        #expect(blocked.writeBlockedReason?.hasPrefix("Read-only") == true)
        let entries = readOnly.env.undo?.stack.count ?? 0
        #expect(await blocked.importLabels() == false)
        #expect(await blocked.removeSuperhumanLabels() == false)
        #expect(readOnly.recorder.calls.isEmpty)
        #expect(readOnly.env.undo?.stack.count == entries)
    }

    @Test func removeIsExplicitTouchesOnlyMappedAILabelsAndIsUndoable() async throws {
        let f = F(writes: true)
        let seeded = try await Self.seed(f.store)
        _ = try await f.store.createLabel(F.work, name: "[Superhuman]/Muted", applyTo: [seeded.meeting[0]])
        let undo = try #require(f.env.undo)
        let model = importer(f)
        await model.count(account: F.work)
        #expect(model.removable == 0, "nothing carries ours yet")
        #expect(await model.importLabels())
        #expect(model.removable == 15)
        #expect(seeded.all.allSatisfy { key in f.store.labelNames(of: key).contains { SuperhumanLabels.aiName($0) != nil } },
                "the import alone never removes Superhuman's labels")
        let entries = undo.stack.count
        #expect(await model.removeSuperhumanLabels())
        #expect(undo.stack.count == entries + 1)
        for key in seeded.meeting + seeded.marketing {
            let names = f.store.labelNames(of: key)
            #expect(!names.contains(Self.meeting) && !names.contains(Self.marketing))
            #expect(names.contains { OHGmailLabels.autoLabelCategory(inLabelName: $0) != nil }, "ours stays")
        }
        #expect(f.store.labelNames(of: seeded.meeting[0]).contains("[Superhuman]/Muted"), "Muted is never touched")
        #expect(seeded.comp.allSatisfy { f.store.labelNames(of: $0).contains(Self.comp) }, "an unmapped name stays")
        #expect((await f.labels()).contains { $0.name == Self.meeting }, "the label object is never deleted")
        await undo.undoLast()
        await eventually { seeded.meeting.allSatisfy { f.store.labelNames(of: $0).contains(Self.meeting) } }
        #expect(seeded.marketing.allSatisfy { f.store.labelNames(of: $0).contains(Self.marketing) })
    }

    static func label(_ id: Int64, _ name: String, kind: LabelInfo.Kind = .user) -> LabelInfo {
        LabelInfo(id: id, account: F.work, labelID: GmailLabelID("Label_\(id)"), kind: kind, name: name,
                  displayName: String(name.split(separator: "/").last ?? ""), position: Int(id))
    }

    static func row(_ labels: [Int64], categories: [Int64] = []) -> ThreadRow {
        ThreadRow(id: ThreadKey(account: F.work, rowID: 1, gmailThreadID: GmailThreadID("t1")), subject: "Plan", snippet: "",
                  participantsDisplay: "Dana", participants: [], messageCount: 1, unreadCount: 0, draftCount: 0,
                  attachmentCount: 0, isUnread: false, isStarred: false, isImportant: false, userLabelIDs: labels,
                  lastMessageAt: fixedNow, sortAt: fixedNow, categoryLabelIDs: categories)
    }

    @Test func aSuperhumanOnlyConversationShowsAMutedFallbackChipAndHiddenLabels() {
        let labels: [Int64: LabelInfo] = [1: Self.label(1, Self.meeting), 2: Self.label(2, "[Superhuman]/Muted"), 3: Self.label(3, "Clients"),
                      4: Self.label(4, "CATEGORY_PROMOTIONS", kind: .category)]
        let row = Self.row([1, 2, 3], categories: [4])
        let hidden = ThreadRowFormatting.chips(for: row, context: ThreadRowChipContext(location: .system(.inbox), labels: labels))
        #expect(hidden.filter { $0.kind == .category } == [ThreadRowChip(kind: .category, title: "Meeting", isFallback: true)],
                "Superhuman's category, muted, in place of Gmail's")
        #expect(hidden.filter { $0.kind == .label }.map(\.title) == ["Clients"], "Hide Superhuman labels is on by default")
        let shown = ThreadRowFormatting.chips(for: row, context: ThreadRowChipContext(
            location: .system(.inbox), labels: labels, superhuman: SuperhumanLabelRules(hidesLabels: false)))
        #expect(shown.filter { $0.kind == .label }.map(\.title) == ["Muted", "Clients"],
                "switch off: Superhuman's labels show again, its AI label folded into the category chip")
        let ours = ThreadRowFormatting.chips(for: row, context: ThreadRowChipContext(location: .system(.inbox), labels: labels),
                                             autoLabel: "Respond")
        #expect(ours.filter { $0.kind == .category } == [ThreadRowChip(kind: .category, title: "Respond")], "ours wins")
        let format = ThreadRowFormatting(calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US_POSIX"))
        #expect(format.accessibilityLabel(row, chips: hidden, location: .system(.inbox), now: fixedNow)
            .contains("Superhuman category Meeting"))
    }

    @Test func theCenterNeverPassesSuperhumansCategoryOffAsOurs() async throws {
        let f = F(writes: false)
        let seeded = try await Self.seed(f.store)
        await f.center.refreshAvailability()
        #expect(f.center.isOn)
        let labels = await f.labelMap()
        let row = try #require(try await f.inbox().first { $0.id == seeded.meeting[0] })
        #expect(f.center.title(for: row, labels: labels) == nil, "Superhuman's category is the fallback chip, not ours")
        await f.center.classifyRecent()
        let entry = try #require(try await f.index.entry(account: F.work, thread: seeded.meeting[0].gmailThreadID))
        #expect(entry.source != .gmailLabel)
        let after = try #require(try await f.inbox().first { $0.id == seeded.meeting[0] })
        let labelsAfter = await f.labelMap()
        #expect(f.center.title(for: after, labels: labelsAfter) == entry.category)
        #expect(f.recorder.calls.isEmpty, "writes off: nothing reaches the mail port")
    }

    @Test func hideSuperhumanLabelsCoversTheSidebarThePickerAndThePalette() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 30, now: fixedNow))
        await f.loaded()
        let state = try #require(f.router.active)
        let key = try #require(f.router.list?.cursor)
        _ = try await f.store.createLabel(state.id, name: Self.meeting, applyTo: [key])
        _ = try await f.store.createLabel(state.id, name: "[Superhuman]/Muted", applyTo: [key])
        await eventually { state.labels.filter { SuperhumanLabels.isSuperhuman($0.name) }.count >= 2 }
        let ours = Set(state.labels.filter { SuperhumanLabels.isSuperhuman($0.name) }.map(\.labelID))
        func sidebarShows() -> Bool { state.sidebarItems.contains { if case .label(let id) = $0.location { ours.contains(id) } else { false } } }
        #expect(f.env.superhumanLabels.hidesLabels && !sidebarShows(), "hidden by default")

        await f.run(.label)
        let picker = try #require(f.labelPicker)
        #expect(!picker.rows.contains { if case .label(let l) = $0.kind { SuperhumanLabels.isSuperhuman(l.name) } else { false } })
        picker.query = Self.meeting
        #expect(!picker.rows.contains { if case .create = $0.kind { true } else { false } },
                "never a new label in Superhuman's family")
        f.center.dismiss()

        await f.run(.commandPalette)
        let palette = try #require(f.palette)
        palette.query = "meeting"
        #expect(!palette.entries.contains { if case .label(let l) = $0.kind { SuperhumanLabels.isSuperhuman(l.name) } else { false } },
                "no \u{201C}Label: Meeting\u{201D} row for Superhuman's label")
        f.center.dismiss()

        try await f.store.set(AppSettings.hideSuperhumanLabels, false)
        await eventually { !f.env.superhumanLabels.hidesLabels }
        #expect(sidebarShows(), "switch off: the sidebar lists them again")
        await f.run(.label)
        let again = try #require(f.labelPicker)
        #expect(again.rows.contains { if case .label(let l) = $0.kind { l.name == Self.meeting } else { false } })
    }

    @Test func theReportComparesOnDemandStoresNothingAndKeepsCountsOnly() async throws {
        let f = F(writes: true)
        let seeded = try await Self.seed(f.store)
        let report = SuperhumanAgreementModel(environment: f.env)
        report.sampleLimit = 5
        report.now = { fixedNow }
        await report.run(account: F.work)
        #expect(report.phase == .finished)
        let result = report.report
        #expect(result.fromCache == 0 && result.ranOnDevice + result.failed <= 5 && result.compared > 0)
        #expect(result.perCategory.allSatisfy { ["Meeting", "Marketing", "Waiting", "Respond", "Invoice", "Travel", "Pitch",
                                                  "Social", "News"].contains($0.category) })
        #expect(try await f.store.get(AppSettings.superhumanAgreement) == result, "saved on this Mac")
        #expect(try await f.index.entries(account: F.work).isEmpty, "answers made for the report are not stored")
        #expect(f.recorder.calls.isEmpty, "nothing is written to mail")
        #expect(f.log.all.count <= 5, "at most the sample is asked")

        try await f.index.put([AutoLabelEntry(account: F.work, thread: seeded.meeting[0].gmailThreadID,
                                              latestMessage: GmailMessageID("m-latest"), promptVersion: 1, modelID: "x",
                                              category: "Meeting", source: .model, classifiedAt: fixedNow)])
        report.sampleLimit = 0
        await report.run(account: F.work)
        #expect(report.report.fromCache == 1 && report.report.ranOnDevice == 0 && report.report.agreed == 1)
    }

    @Test func theSampleTakesEveryCategoryInTurn() {
        func item(_ n: Int, _ category: String) -> SuperhumanLabelImportModel.ScanItem {
            let row = ThreadRow(id: ThreadKey(account: F.work, rowID: Int64(n), gmailThreadID: GmailThreadID("t\(n)")), subject: "",
                                snippet: "", participantsDisplay: "", participants: [], messageCount: 1, unreadCount: 0,
                                draftCount: 0, attachmentCount: 0, isUnread: false, isStarred: false, isImportant: false,
                                userLabelIDs: [], lastMessageAt: fixedNow.addingTimeInterval(Double(n)),
                                sortAt: fixedNow)
            return SuperhumanLabelImportModel.ScanItem(row: row, category: category, superhumanName: category)
        }
        let items = (0..<10).map { item($0, "Marketing") } + [item(20, "Meeting"), item(21, "News")]
        let sample = SuperhumanAgreementModel.sample(items, limit: 4)
        #expect(sample.map(\.category) == ["Meeting", "News", "Marketing", "Marketing"])
        #expect(sample[2].row.id.gmailThreadID == GmailThreadID("t9"), "newest first within a category")
        #expect(SuperhumanAgreementModel.sample(items, limit: 0).isEmpty)
    }
}
