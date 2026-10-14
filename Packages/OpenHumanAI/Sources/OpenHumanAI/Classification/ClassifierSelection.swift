import Foundation

public enum ClassifierPreference: String, Sendable, Hashable, Codable, CaseIterable {
    case automatic
    case appleModel
    case localModel
}

public enum ClassifierSelection {
    public static func ordered(_ classifiers: [any AIClassificationProvider],
                               preference: ClassifierPreference) -> [any AIClassificationProvider] {
        let onDevice = classifiers.filter { $0.dataLocation == .onDevice }
        let local = onDevice.filter { $0.id.isLocalModel }
        let others = onDevice.filter { !$0.id.isLocalModel }
        switch preference {
        case .automatic: return others + local
        case .appleModel: return others
        case .localModel: return local
        }
    }

    public static func allows(_ classifier: any AIClassificationProvider, preference: ClassifierPreference) -> Bool {
        guard classifier.dataLocation == .onDevice else { return true }
        switch preference {
        case .automatic: return true
        case .appleModel: return !classifier.id.isLocalModel
        case .localModel: return classifier.id.isLocalModel
        }
    }
}
