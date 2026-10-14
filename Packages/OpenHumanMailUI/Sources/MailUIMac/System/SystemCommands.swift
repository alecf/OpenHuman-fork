import MailActions
import MailFeatures
import SwiftUI

public struct SystemCommands: Commands {
    let environment: @MainActor () -> AppEnvironment?

    public init(environment: @escaping @MainActor () -> AppEnvironment?) {
        self.environment = environment
    }

    public var body: some Commands {
        let environment = environment()
        CommandGroup(after: .help) {
            Button("Export Diagnostics…") {
                guard let system = environment?.system else { return }
                Task { await system.exportDiagnostics() }
            }
            .disabled(environment?.modules.modules.contains(.diagnostics) != true)
            if environment?.modules.modules.contains(.diagnostics) == true {
                ForEach([ActionID.copyConversationDebug, .saveConversationDebug].compactMap(ActionCatalog.descriptor)) { descriptor in
                    MenuItem(descriptor: descriptor, router: environment?.router)
                }
            }
            if environment?.system.sendFeedback.canBegin == true {
                Button(SendFeedbackCenter.menuTitle) { environment?.system.sendFeedback.begin() }
            }
        }
    }
}
