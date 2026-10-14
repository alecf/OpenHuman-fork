import MailFeatures
import SwiftUI

public struct WelcomeGuideCommands: Commands {
    let environment: @MainActor () -> AppEnvironment?

    public init(environment: @escaping @MainActor () -> AppEnvironment?) {
        self.environment = environment
    }

    public var body: some Commands {
        let environment = environment()
        CommandGroup(before: .help) {
            Button("Show Welcome Guide") { environment?.welcomeGuide.present() }
                .disabled(environment == nil)
        }
    }
}
