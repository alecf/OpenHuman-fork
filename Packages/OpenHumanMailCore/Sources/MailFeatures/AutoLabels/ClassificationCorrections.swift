import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanAI
import OpenHumanCore

extension AutoLabelCenter {
    @discardableResult
    public func setLabel(_ category: String, thread: ThreadKey, row: ThreadRow?, labels: [Int64: LabelInfo]) async throws
        -> String? {
        guard let category = OHGmailLabels.canonicalAutoLabelCategory(category) else { return nil }
        let account = thread.account
        let existing = entries[account]?[thread.gmailThreadID]
        let current = row.flatMap { title(for: $0, labels: labels) } ?? existing?.category
        var latestID = existing?.latestMessage
        var sender: String?
        if let data = environment?.data, let detail = await AIThreadLoader.first(data.threadDetail(thread)) ?? nil,
           let latest = detail.messages.last {
            latestID = latest.id.gmailMessageID
            sender = latest.from?.email.lowercased()
        }
        guard let latestID else { return nil }
        let base = AutoLabelEntry(account: account, thread: thread.gmailThreadID, latestMessage: latestID,
                                  promptVersion: existing?.promptVersion ?? options.promptVersion,
                                  modelID: existing?.modelID ?? "user", category: current, source: .user,
                                  classifiedAt: options.now(), rejected: existing?.rejected ?? [])
        lastCorrected = (thread, row)
        takeCorrection(base, nowOnGmail: category, sender: sender ?? "", written: false)
        if let row { decidedAt[thread] = row.lastMessageAt }
        guard writesToGmail, let environment, let commands = environment.commands else { return category }
        let ours = ourLabels(account)
        let onRow = Set(row?.userLabelIDs ?? [])
        let remove = ours.filter { $0.key != category && (row == nil || onRow.contains($0.value.id)) }.map(\.value.labelID)
            .sorted { $0.rawValue < $1.rawValue }
        let present = ours[category].map { onRow.contains($0.id) } ?? false
        guard !present || !remove.isEmpty else { return category }
        inFlight.insert(thread)
        defer { finishWriting([thread]) }
        let work: @Sendable () async throws -> UndoToken
        if let label = ours[category] {
            work = { try await commands.apply(.modifyLabels([thread], add: present ? [] : [label.labelID], remove: remove)) }
        } else if let name = OHGmailLabels.autoLabel(category) {
            work = {
                var tokens = [try await commands.createLabel(account, name: name, applyTo: [thread])]
                if !remove.isEmpty {
                    do { tokens.append(try await commands.apply(.modifyLabels([thread], add: [], remove: remove))) } catch {
                        for token in tokens.reversed() { _ = try? await commands.undo(token) }
                        throw error
                    }
                }
                return try UndoSequence.token(tokens)
            }
        } else {
            return category
        }
        let sequenced = ours[category] == nil
        if let undo = environment.undo {
            try await undo.perform("Labelled \(category)", threads: [thread],
                                   via: sequenced ? UndoSequence(port: commands) : commands) { try await work() }
        } else {
            _ = try await work()
        }
        return category
    }
}

struct ImportanceAndFlagUndo: MailUndoing {
    struct Steps: Codable { var importance: Data; var flag: Data? }

    let importance: any MailUndoing
    let commands: any MailUndoing

    static func token(importance: UndoToken, flag: UndoToken?) throws -> UndoToken {
        UndoToken(payload: try JSONEncoder().encode(Steps(importance: importance.payload, flag: flag?.payload)))
    }

    func undo(_ token: UndoToken) async throws -> UndoToken? {
        let steps = try JSONDecoder().decode(Steps.self, from: token.payload)
        var flagBack: UndoToken?
        if let flag = steps.flag { flagBack = try await commands.undo(UndoToken(payload: flag)) }
        guard let back = try await importance.undo(UndoToken(payload: steps.importance)) else { return nil }
        return try Self.token(importance: back, flag: flagBack)
    }
}

@MainActor @Observable
public final class ClassificationCorrectionHandler: ActionHandler {
    public static let ids: [ActionID] = [.classificationNotImportant, .classificationMarkImportant,
                                         .classificationRuleFromThread]
        + ActionID.classificationLabelCategories.map(ActionID.classificationSetLabel)

    nonisolated static let gmailImportant = GmailLabelID("IMPORTANT")
    nonisolated static let readOnlyNote = "Recorded for testing. Mail can't change importance while read-only."

    @ObservationIgnored private weak var environment: AppEnvironment?
    @ObservationIgnored private let feedback: ActionFeedback

    init(environment: AppEnvironment, feedback: ActionFeedback) {
        self.environment = environment
        self.feedback = feedback
    }

    public func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        guard let environment else { return .hidden }
        switch id {
        case .classificationNotImportant, .classificationMarkImportant:
            return environment.importance == nil ? .hidden : .enabled
        case .classificationRuleFromThread:
            return environment.settingsNavigator.canOpen ? .enabled : .hidden
        default:
            return environment.autoLabels?.isOn == true ? .enabled : .hidden
        }
    }

    public func perform(_ request: ActionRequest) -> ActionPerformance {
        guard let environment, let thread = request.context.focusedThread else { return .notHandled }
        let (row, labels) = AutoLabelActionHandler.row(of: thread, router: request.router)
        let context = request.context
        switch request.id {
        case .classificationNotImportant, .classificationMarkImportant:
            guard let port = environment.importance else { return .notHandled }
            let important = request.id == .classificationMarkImportant
            return .started(Task { [weak self] in
                await self?.correctImportance(important, thread: thread, row: row, port: port, sender: context.sender,
                                              domain: context.senderDomain, id: request.id)
            })
        case .classificationRuleFromThread:
            return .started(Task { [weak self] in
                await self?.ruleFromThread(thread, row: row, labels: labels, sender: context.sender)
            })
        default:
            guard let category = request.id.classificationSetLabelCategory, let center = environment.autoLabels else {
                return .notHandled
            }
            let id = request.id
            return .started(Task { [weak self] in
                guard let self else { return }
                do {
                    guard let title = try await center.setLabel(category, thread: thread, row: row, labels: labels) else {
                        self.feedback.failed("Couldn't label this conversation")
                        return
                    }
                    if !center.writesToGmail { environment.notices.post("Labelled \(title) on this Mac", style: .info) }
                    await self.offerLabelRule(title, thread: thread, sender: context.sender, domain: context.senderDomain)
                } catch MailPortError.blockedBySafeMode {
                    self.feedback.refuse(id, .safeMode)
                } catch {
                    self.feedback.failed("Couldn't label this conversation")
                }
            })
        }
    }


    private func correctImportance(_ important: Bool, thread: ThreadKey, row: ThreadRow?, port: any ImportanceRulesPort,
                                   sender: String?, domain: String?, id: ActionID) async {
        guard let environment else { return }
        var row = row
        if row == nil { row = (try? await environment.data.localThread(thread.account, gmailThreadID: thread.gmailThreadID)) ?? nil }
        let change = ImportanceChange(kind: important ? .alwaysThread : .neverThread, account: thread.account,
                                      value: thread.gmailThreadID.rawValue, thread: thread)
        let flagSetting = (try? await environment.settings?.get(AppSettings.classificationNotImportantRemovesGmailFlag))
            ?? AppSettings.classificationNotImportantRemovesGmailFlag.defaultValue
        let removesFlag = !important && flagSetting && (row?.isImportant ?? true)
            && environment.status.safeMode.allowsMailChanges
        let commands = removesFlag ? environment.commands : nil
        let title: LocalizedStringResource = important ? "Marked important" : "Marked not important"
        do {
            let work: () async throws -> UndoToken = {
                let rule = try await port.apply(change)
                guard let commands else { return rule }
                do {
                    let flag = try await commands.apply(.modifyLabels([thread], add: [], remove: [Self.gmailImportant]))
                    return try ImportanceAndFlagUndo.token(importance: rule, flag: flag)
                } catch {
                    _ = try? await port.undo(rule)
                    throw error
                }
            }
            let undoer: any MailUndoing = commands.map { ImportanceAndFlagUndo(importance: port, commands: $0) } ?? port
            if let undo = environment.undo {
                try await undo.perform(title, threads: [thread], via: undoer, work)
            } else {
                _ = try await work()
            }
            await recordImportance(important, thread: thread, row: row)
            await offerImportanceRule(important, thread: thread, port: port, sender: sender, domain: domain)
        } catch MailPortError.blockedBySafeMode {
            await recordImportance(important, thread: thread, row: row)
            environment.notices.post(Self.readOnlyNote, style: .info)
        } catch {
            feedback.failed("Couldn't change the importance rule")
        }
    }

    private func recordImportance(_ important: Bool, thread: ThreadKey, row: ThreadRow?) async {
        guard let environment else { return }
        let ruleSet = environment.classification
        let expected = important ? "important" : "not_important"
        let was = row.map { $0.isImportant ? "important" : "not_important" }
        if let center = environment.autoLabels {
            center.lastCorrected = (thread, row)
            await center.recordExample(account: thread.account, thread: thread.gmailThreadID, key: thread,
                                       feature: "importance", expected: expected, was: was, ruleSet: ruleSet)
        } else {
            await ruleSet.record(LabelledExample(account: thread.account, thread: thread.gmailThreadID,
                                                 createdAt: ruleSet.now(), feature: "importance", expected: expected,
                                                 was: was))
        }
    }


    private func suggestsRules() async -> Bool {
        (try? await environment?.settings?.get(AppSettings.classificationSuggestRules))
            ?? AppSettings.classificationSuggestRules.defaultValue
    }

    private func offerImportanceRule(_ important: Bool, thread: ThreadKey, port: any ImportanceRulesPort, sender: String?,
                                     domain: String?) async {
        guard let environment, await suggestsRules(), let sender, let domain else { return }
        let undo = environment.undo
        func choice(_ title: String, _ kind: ImportanceRuleKind, _ value: String, _ done: LocalizedStringResource)
            -> NoticeCenter.Choice {
            NoticeCenter.Choice(title) { [weak self] in
                let change = ImportanceChange(kind: kind, account: thread.account, value: value, thread: thread)
                do {
                    if let undo { try await undo.perform(done, threads: [thread], via: port) { try await port.apply(change) } }
                    else { _ = try await port.apply(change) }
                } catch MailPortError.blockedBySafeMode {
                    self?.feedback.refuse(.classificationNotImportant, .safeMode)
                } catch {
                    self?.feedback.failed("Couldn't change the importance rule")
                }
            }
        }
        let prefix = important ? "Always important" : "Never important"
        environment.notices.postChoice(
            "\(prefix) for:",
            choice("This sender", important ? .alwaysSender : .neverSender, sender, "\(prefix) from \(sender)"),
            choice("This domain", important ? .alwaysDomain : .neverDomain, domain, "\(prefix) from \(domain)"))
    }

    private func offerLabelRule(_ category: String, thread: ThreadKey, sender: String?, domain: String?) async {
        guard let environment, await suggestsRules(), let label = AutoLabelCategory(title: category) else { return }
        var listID: String?
        if let detail = await AIThreadLoader.first(environment.data.threadDetail(thread)) ?? nil,
           let latest = detail.messages.last {
            listID = (try? await environment.data.listID(latest.id)) ?? nil
        }
        let options = Self.labelRuleOptions(label, sender: sender, domain: domain, listID: listID)
        guard options.count >= 2 else { return }
        let ruleSet = environment.classification
        func choice(_ option: (String, ClassificationRule)) -> NoticeCenter.Choice {
            NoticeCenter.Choice(option.0) { _ = await ruleSet.add(option.1) }
        }
        environment.notices.postChoice("Always label \(category) for:", choice(options[0]), choice(options[1]))
    }

    nonisolated static func labelRuleOptions(_ label: AutoLabelCategory, sender: String?, domain: String?,
                                             listID: String?) -> [(String, ClassificationRule)] {
        var out: [(String, ClassificationRule)] = []
        func rule(_ title: String, _ when: RuleCondition) -> ClassificationRule {
            ClassificationRule(id: ClassificationRule.newUserID(), origin: .user, title: title, when: when,
                               then: .setLabel(label))
        }
        if let listID, !listID.isEmpty {
            out.append(("This list", rule("Mail from the list \(listID) is \(label.title)",
                                          .fact(.listID, "equals", .text(listID)))))
        }
        if let sender, !sender.isEmpty {
            out.append(("This sender", rule("Mail from \(sender) is \(label.title)", .fact(.sender, "equals", .text(sender)))))
        }
        if listID == nil, let domain, !domain.isEmpty {
            out.append(("This domain", rule("Mail from \(domain) is \(label.title)", .fact(.sender, "domain", .text(domain)))))
        }
        return Array(out.prefix(2))
    }


    private func ruleFromThread(_ thread: ThreadKey, row: ThreadRow?, labels: [Int64: LabelInfo], sender: String?) async {
        guard let environment else { return }
        var listID: String?
        if let detail = await AIThreadLoader.first(environment.data.threadDetail(thread)) ?? nil,
           let latest = detail.messages.last {
            listID = (try? await environment.data.listID(latest.id)) ?? nil
        }
        let current = row.flatMap { environment.autoLabels?.title(for: $0, labels: labels) }
            .flatMap(AutoLabelCategory.init(title:))
        environment.classification.pendingDraft = Self.draft(sender: sender, listID: listID, label: current)
        environment.settingsNavigator.open(ImportanceSettingsModel.pageID)
    }

    nonisolated static func draft(sender: String?, listID: String?, label: AutoLabelCategory?) -> ClassificationRule {
        let when: RuleCondition
        let about: String
        if let listID, !listID.isEmpty {
            when = .all([.fact(.listID, "equals", .text(listID))])
            about = "the list \(listID)"
        } else {
            when = .all([.fact(.sender, "equals", .text(sender ?? ""))])
            about = sender ?? "this sender"
        }
        let category = label ?? .news
        return ClassificationRule(id: ClassificationRule.newUserID(), origin: .user,
                                  title: "Mail from \(about) is \(category.title)", when: when, then: .setLabel(category))
    }
}
