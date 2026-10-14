import Foundation
import OpenHumanCore

extension AppSettings {
    public static let hideSuperhumanLabels = AppSettingKey(name: "labels.superhuman.hide", defaultValue: true)
    public static let superhumanLabelMapping = AppSettingKey(name: "labels.superhuman.mapping",
                                                             defaultValue: [String: String]())
    public static let superhumanAgreement = AppSettingKey(name: "labels.superhuman.agreement",
                                                          defaultValue: SuperhumanAgreement.empty)
}

public enum SuperhumanLabels {
    public static let root = "[Superhuman]"
    public static let aiPrefix = OHGmailLabels.superhumanAutoLabelPrefix

    public static let confirmedNames = OHGmailLabels.autoLabelCategories

    public static let unconfirmedNames = ["comp", "AutoArchived", "FYI", "Notifications", "Promotions"]

    public static func isSuperhuman(_ name: String) -> Bool {
        let lower = name.lowercased()
        let root = Self.root.lowercased()
        return lower == root || lower.hasPrefix(root + "/")
    }

    public static func aiName(_ labelName: String) -> String? {
        guard labelName.lowercased().hasPrefix(aiPrefix.lowercased()) else { return nil }
        let rest = String(labelName.dropFirst(aiPrefix.count)).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, !rest.contains("/") else { return nil }
        return rest
    }

    public static func isConfirmed(aiName name: String) -> Bool {
        OHGmailLabels.canonicalAutoLabelCategory(name) != nil
    }
}

public struct SuperhumanLabelRules: Sendable, Hashable {
    public var hidesLabels: Bool
    public var mapping: [String: String]

    public init(hidesLabels: Bool = AppSettings.hideSuperhumanLabels.defaultValue, mapping: [String: String] = [:]) {
        self.hidesLabels = hidesLabels
        self.mapping = mapping
    }

    public func hides(_ labelName: String) -> Bool {
        hidesLabels && SuperhumanLabels.isSuperhuman(labelName)
    }

    public func category(forLabelName labelName: String) -> String? {
        guard let name = SuperhumanLabels.aiName(labelName) else { return nil }
        return category(forAIName: name)
    }

    public func category(forAIName name: String) -> String? {
        if let confirmed = OHGmailLabels.canonicalAutoLabelCategory(name) { return confirmed }
        let chosen = mapping.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        return chosen.flatMap(OHGmailLabels.canonicalAutoLabelCategory)
    }

    public func category(inLabelNames labelNames: [String]) -> String? {
        let found = Set(labelNames.compactMap(category(forLabelName:)))
        return OHGmailLabels.autoLabelCategories.first { found.contains($0) }
    }
}

public struct SuperhumanAgreement: Codable, Sendable, Hashable {
    public struct CategoryScore: Codable, Sendable, Hashable, Identifiable {
        public var category: String
        public var superhuman: Int
        public var ours: Int
        public var agreed: Int
        public var precision: Double
        public var recall: Double
        public var f1: Double
        public var id: String { category }

        public init(category: String, superhuman: Int, ours: Int, agreed: Int, precision: Double, recall: Double,
                    f1: Double) {
            self.category = category
            self.superhuman = superhuman
            self.ours = ours
            self.agreed = agreed
            self.precision = precision
            self.recall = recall
            self.f1 = f1
        }
    }

    public struct Pair: Sendable, Hashable {
        public var superhuman: String
        public var ours: String?

        public init(superhuman: String, ours: String?) {
            self.superhuman = superhuman
            self.ours = ours
        }
    }

    public static let noneColumn = "(none)"

    public var generatedAt: Date?
    public var compared: Int
    public var agreed: Int
    public var fromCache: Int
    public var ranOnDevice: Int
    public var failed: Int
    public var perCategory: [CategoryScore]
    public var confusion: [String: [String: Int]]

    public init(generatedAt: Date?, compared: Int, agreed: Int, fromCache: Int, ranOnDevice: Int, failed: Int,
                perCategory: [CategoryScore], confusion: [String: [String: Int]]) {
        self.generatedAt = generatedAt
        self.compared = compared
        self.agreed = agreed
        self.fromCache = fromCache
        self.ranOnDevice = ranOnDevice
        self.failed = failed
        self.perCategory = perCategory
        self.confusion = confusion
    }

    public static let empty = SuperhumanAgreement(generatedAt: nil, compared: 0, agreed: 0, fromCache: 0, ranOnDevice: 0,
                                                  failed: 0, perCategory: [], confusion: [:])

    public var agreement: Double { Self.ratio(agreed, compared) }

    public var columns: [String] {
        let used = Set(confusion.values.flatMap(\.keys))
        return OHGmailLabels.autoLabelCategories.filter { used.contains($0) } + (used.contains(Self.noneColumn) ? [Self.noneColumn] : [])
    }

    public var rows: [String] {
        OHGmailLabels.autoLabelCategories.filter { confusion[$0] != nil }
    }

    public static func score(_ pairs: [Pair], fromCache: Int, ranOnDevice: Int, failed: Int,
                             generatedAt: Date?) -> SuperhumanAgreement {
        var confusion: [String: [String: Int]] = [:]
        var agreed = 0
        for pair in pairs {
            let column = pair.ours ?? noneColumn
            confusion[pair.superhuman, default: [:]][column, default: 0] += 1
            if pair.ours == pair.superhuman { agreed += 1 }
        }
        var scores: [CategoryScore] = []
        for category in OHGmailLabels.autoLabelCategories {
            let superhuman = confusion[category]?.values.reduce(0, +) ?? 0
            let ours = confusion.values.reduce(0) { $0 + ($1[category] ?? 0) }
            guard superhuman > 0 || ours > 0 else { continue }
            let hits = confusion[category]?[category] ?? 0
            let precision = ratio(hits, ours)
            let recall = ratio(hits, superhuman)
            let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
            scores.append(CategoryScore(category: category, superhuman: superhuman, ours: ours, agreed: hits,
                                        precision: precision, recall: recall, f1: f1))
        }
        return SuperhumanAgreement(generatedAt: generatedAt, compared: pairs.count, agreed: agreed, fromCache: fromCache,
                                   ranOnDevice: ranOnDevice, failed: failed, perCategory: scores, confusion: confusion)
    }

    static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }
}
