import Foundation

public enum ClassifierPreference: String, Sendable, Hashable, Codable, CaseIterable {
    case appleModel
    case localModel
}

public enum ClassifierSelection {
    public static func ordered(_ classifiers: [any AIClassificationProvider],
                               preference: ClassifierPreference) -> [any AIClassificationProvider] {
        classifiers.filter { $0.dataLocation == .onDevice && allows($0, preference: preference) }
    }

    public static func allows(_ classifier: any AIClassificationProvider, preference: ClassifierPreference) -> Bool {
        guard classifier.dataLocation == .onDevice else { return true }
        switch preference {
        case .appleModel: return !classifier.id.isLocalModel
        case .localModel: return classifier.id.isLocalModel
        }
    }
}
