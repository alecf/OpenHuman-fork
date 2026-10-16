import Foundation
import OpenHumanAI

@MainActor
public enum PromptServices {
    public static var current: PromptRegistry?
    private static var persistentURL: URL?

    static func install(persistent: Bool, directory: URL?) {
        let url = persistent ? directory?.appendingPathComponent(SQLitePromptStore.fileName) : nil
        if current != nil, url == persistentURL { return }
        let provider = PromptLibraryProvider.shared
        if let url, let store = try? SQLitePromptStore(url: url) {
            provider.setOverrides(store.activeAtOpen.filter { provider.bundled.templates[$0.key] != nil }
                .mapValues(\.override))
            current = PromptRegistry(provider: provider, store: store)
        } else {
            provider.setOverrides([:])
            current = PromptRegistry(provider: provider, store: InMemoryPromptOverrideStore())
        }
        persistentURL = url
    }
}
