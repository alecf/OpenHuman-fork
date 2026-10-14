import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor
@Observable
public final class SuperhumanAgreementModel {
    public enum Phase: Hashable, Sendable {
        case idle
        case running(done: Int, total: Int)
        case finished
        case failed(String)
    }

    public static let defaultSampleLimit = 300

    public private(set) var phase: Phase = .idle
    public private(set) var report: SuperhumanAgreement = .empty
    public private(set) var note: String?
    @ObservationIgnored public var sampleLimit = SuperhumanAgreementModel.defaultSampleLimit
    @ObservationIgnored public var now: @Sendable () -> Date = { Date() }
    @ObservationIgnored private weak var environment: AppEnvironment?

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public static let explanation = String(localized: """
        Compares Superhuman's categories with Mail's own for the same conversations: answers Mail already has, plus up \
        to 300 more sorted now by Apple's on-device model. Counts only; nothing leaves this Mac.
        """)

    public var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    public var summary: String? {
        guard report.compared > 0 else { return nil }
        let percent = (report.agreement * 100).rounded()
        return String(localized: "Mail agrees with Superhuman on \(Int(percent))% of \(report.compared.formatted()) conversations.")
    }

    public func load() async {
        guard let settings = environment?.settings,
              let saved = try? await settings.get(AppSettings.superhumanAgreement) else { return }
        report = saved
    }

    public func run(account requested: AccountID? = nil) async {
        guard let environment, !isRunning else { return }
        guard let center = environment.autoLabels else {
            phase = .failed(String(localized: "The comparison needs Apple's on-device model, which isn't set up in this copy of Mail."))
            return
        }
        phase = .running(done: 0, total: 0)
        note = nil
        await center.prepareForReport()
        let accounts = await AIThreadLoader.first(environment.data.accounts()) ?? []
        let account = requested.flatMap { id in accounts.first { $0.id == id } }
            ?? environment.router.active?.account ?? accounts.first
        guard let account else {
            phase = .failed(String(localized: "Sign in first."))
            return
        }
        let settings = environment.settings
        let mapping = (try? await settings?.get(AppSettings.superhumanLabelMapping)) ?? [:]
        let rules = SuperhumanLabelRules(hidesLabels: true, mapping: mapping)
        let scan: SuperhumanLabelImportModel.Scan
        do {
            scan = try await SuperhumanLabelImportModel.scan(account: account.id, data: environment.data, rules: rules,
                                                             maxPerLabel: 10_000)
        } catch {
            phase = .failed(String(localized: "Couldn't read this account's labels."))
            return
        }
        let cached = await center.cachedOwnAnswers(account: account.id)
        var pairs: [SuperhumanAgreement.Pair] = []
        var uncached: [SuperhumanLabelImportModel.ScanItem] = []
        for item in scan.items {
            if let own = cached[item.row.id.gmailThreadID] {
                pairs.append(SuperhumanAgreement.Pair(superhuman: item.category, ours: own))
            } else {
                uncached.append(item)
            }
        }
        let fromCache = pairs.count
        let sample = Self.sample(uncached, limit: sampleLimit)
        var ran = 0, failed = 0
        phase = .running(done: 0, total: sample.count)
        sampling: for (index, item) in sample.enumerated() {
            guard !Task.isCancelled else { break }
            switch await center.ownAnswer(for: item.row) {
            case .answer(let category):
                pairs.append(SuperhumanAgreement.Pair(superhuman: item.category, ours: category))
                ran += 1
            case .failed:
                failed += 1
            case .unavailable:
                note = String(localized: "Apple's on-device model isn't available, so only answers Mail already had were compared.")
                break sampling
            }
            phase = .running(done: index + 1, total: sample.count)
        }
        report = SuperhumanAgreement.score(pairs, fromCache: fromCache, ranOnDevice: ran, failed: failed,
                                           generatedAt: now())
        try? await settings?.set(AppSettings.superhumanAgreement, report)
        if scan.items.isEmpty {
            note = String(localized: "No conversations with a Superhuman category on this account.")
        }
        phase = .finished
    }

    nonisolated static func sample(_ items: [SuperhumanLabelImportModel.ScanItem],
                                   limit: Int) -> [SuperhumanLabelImportModel.ScanItem] {
        guard limit > 0 else { return [] }
        var queues = Dictionary(grouping: items, by: \.category)
            .mapValues { $0.sorted { $0.row.lastMessageAt > $1.row.lastMessageAt } }
        let order = OHGmailLabels.autoLabelCategories.filter { queues[$0] != nil }
        var out: [SuperhumanLabelImportModel.ScanItem] = []
        var index = 0
        while out.count < limit, queues.values.contains(where: { !$0.isEmpty }) {
            let category = order[index % order.count]
            if var queue = queues[category], !queue.isEmpty {
                out.append(queue.removeFirst())
                queues[category] = queue
            }
            index += 1
        }
        return out
    }
}
