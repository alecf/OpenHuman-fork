import MailActions
import MailFeatures
import MailModel
import SwiftUI

struct InboxAutomationSection: View {
    @State private var model: InboxAutomationSettingsModel
    let modules: [FeatureModuleID]
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        _model = State(initialValue: InboxAutomationSettingsModel(environment: environment))
        modules = environment.modules.modules
        self.environment = environment
    }

    var body: some View {
        Group {
            if modules.contains(.hygiene) {
                SettingsSection("Inbox") {
                    SettingsRow("Suggest cleaning up the inbox", detail: InboxAutomationSettingsModel.cleanupNote,
                                isOn: binding(model.suggestCleanup))
                        .disabled(!model.availability.canEditSettings)
                    SettingsRow("Ask when the inbox holds more than", selection: binding(model.cleanupThreshold)) {
                        ForEach(InboxAutomationSettingsModel.thresholdChoices, id: \.self) {
                            Text(InboxAutomationSettingsModel.thresholdTitle($0)).tag($0)
                        }
                    }
                    .disabled(!model.availability.canEditSettings || !model.suggestCleanup.value)
                    SettingsRow("Suggest conversations older than", selection: binding(model.cleanupAgeDays)) {
                        ForEach(InboxAutomationSettingsModel.ageChoices, id: \.self) {
                            Text(InboxAutomationSettingsModel.ageTitle($0)).tag($0)
                        }
                    }
                    .disabled(!model.availability.canEditSettings || !model.suggestCleanup.value)
                }
            }
            if modules.contains(.hygiene) {
                CleanupRulesSection(model: model.cleanupRules, canEdit: model.availability.canEditSettings)
            }
            if modules.contains(.reminders) {
                SettingsSection("Follow-up reminders") {
                    SettingsRow("Remind me when nobody replies", detail: model.scopeNote, status: model.scopeStatus,
                                statusTone: .warning, selection: scopeBinding) {
                        ForEach(model.scopeChoices, id: \.self) {
                            Text(InboxAutomationSettingsModel.scopeTitle($0)).tag($0)
                        }
                    }
                    .disabled(!model.availability.canEditSettings)
                    if model.scope == .needsFollowUp, model.followUpModelReady == true {
                        SettingsRow("Check sent mail from the last 7 days",
                                    detail: InboxAutomationSettingsModel.catchUpNote, status: model.catchUpMessage) {
                            Button("Check Now") { Task { await model.catchUp() } }
                                .disabled(model.isCatchingUp)
                        }
                        .disabled(!model.availability.hasCommands)
                    }
                    SettingsRow("Wait", selection: binding(model.autoRemindDays)) {
                        ForEach(InboxAutomationSettingsModel.dayChoices, id: \.self) {
                            Text(InboxAutomationSettingsModel.ageTitle($0)).tag($0)
                        }
                    }
                    .disabled(!model.availability.canEditSettings || !model.autoRemind.value)
                    SettingsRow("Remind me at", selection: binding(model.autoRemindHour)) {
                        ForEach(InboxAutomationSettingsModel.hourChoices, id: \.self) {
                            Text(InboxAutomationSettingsModel.hourTitle($0)).tag($0)
                        }
                    }
                    .disabled(!model.availability.canEditSettings || !model.autoRemind.value)
                    SettingsRow("Count weekdays only", isOn: binding(model.autoRemindWeekdaysOnly))
                        .disabled(!model.availability.canEditSettings || !model.autoRemind.value)
                }
                SuperhumanRemindersSection(environment: environment)
            }
            AutoLabelsSection(environment: environment)
            SettingsErrorLine(text: model.errorMessage)
        }
        .task { model.start() }
    }

    private var scopeBinding: Binding<InboxAutomationSettingsModel.Scope> {
        Binding(get: { model.scope }, set: { scope in Task { await model.setScope(scope) } })
    }

    private func binding<Value>(_ setting: StoredSetting<Value>) -> Binding<Value> {
        Binding(get: { setting.value }, set: { value in Task { await setting.set(value) } })
    }
}
