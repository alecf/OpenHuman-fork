import MailFeatures
import MailUI
import OpenHumanAI
import SwiftUI

@MainActor
enum AISettingsPageContent {
    static func view(center: AICenter, environment: AppEnvironment, showsDeveloperItems: Bool,
                     prompts: PromptRegistry? = PromptServices.current,
                     classifier: (any LocalClassifierModelPort)? = ClassifierServices.current,
                     semantic: SemanticServices? = SemanticServices.current,
                     initialTab: AISettingsTab = .overview) -> AnyView {
        let smartSearch = environment.modules.modules.contains(.smartSearch) ? semantic : nil
        return AnyView(AISettingsTabs(prompts: prompts.map {
            PromptsSettingsModel(registry: $0, tester: SettingsRoot.promptTester(center))
        }, activity: AIActivityModel(center: center), navigator: environment.settingsNavigator, initialTab: initialTab) {
            SettingsSectionStack {
                AISettingsSection(center: center, environment: environment, listsUnavailableModels: showsDeveloperItems)
                ClassifierSettingsSection(center: center, port: classifier, environment: environment)
                if let smartSearch {
                    SmartSearchIndexSettingsView(services: smartSearch)
                }
            }
        })
    }
}
