import Foundation
import MailFeatures

extension CompositionRoot {
    static func attachClassification(_ environment: AppEnvironment, isFake: Bool) {
        guard !isFake, let directory = AIServices.cacheDirectory,
              let store = try? SQLiteRulesStore(url: directory.appendingPathComponent(SQLiteRulesStore.fileName)) else { return }
        environment.classification.use(store: store)
    }
}
