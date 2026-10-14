import MailFeatures
import MailModel
import SwiftUI

struct AutoLabelsSection: View {
    @State private var model: AutoLabelSettingsModel
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        _model = State(initialValue: AutoLabelSettingsModel(environment: environment))
        self.environment = environment
    }

    var body: some View {
        Group {
            autoLabels
            SuperhumanLabelsSection(environment: environment)
        }
    }

    private var autoLabels: some View {
        SettingsSection("Auto labels", footnote: AutoLabelSettingsModel.placementNote) {
            SettingsRow("Auto labels", detail: AutoLabelSettingsModel.enabledNote, status: model.unavailableText,
                        statusTone: .warning, isOn: binding(model.enabled))
                .disabled(!model.canUseSwitch)
                .accessibilityIdentifier("settings.autoLabels.enabled")
            SettingsRow("Also apply as Gmail labels", detail: AutoLabelSettingsModel.applyNote,
                        isOn: binding(model.applyToGmail))
                .disabled(!model.canUseSwitch || !model.enabled.value)
                .accessibilityIdentifier("settings.autoLabels.applyToGmail")
            SettingsRow("Show auto labels in Gmail", detail: AutoLabelSettingsModel.showNote,
                        isOn: binding(model.showInGmail))
                .disabled(!model.canUseSwitch || !model.enabled.value)
                .accessibilityIdentifier("settings.autoLabels.showInGmail")
            SettingsRow("Recent mail", detail: AutoLabelSettingsModel.classifyNote, status: model.statusText) {
                HStack {
                    Button("Classify recent mail") { Task { await model.classifyRecent() } }
                        .disabled(!model.canAct)
                        .accessibilityIdentifier("settings.autoLabels.classifyRecent")
                    Button("Reset auto labels") { Task { await model.reset() } }
                        .disabled(model.isBusy || model.center == nil)
                        .accessibilityIdentifier("settings.autoLabels.reset")
                }
            }
            SettingsRow("Reset", detail: AutoLabelSettingsModel.resetNote)
            ForEach(AutoLabelSettingsModel.categories, id: \.self) { category in
                SettingsRow(category, selection: placement(category)) {
                    ForEach(AutoLabelSettingsModel.Placement.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!model.canPlace || !model.enabled.value)
            }
            SettingsErrorLine(text: model.errorMessage)
        }
        .task { model.start() }
    }

    private func binding<Value>(_ setting: StoredSetting<Value>) -> Binding<Value> {
        Binding(get: { setting.value }, set: { value in Task { await setting.set(value) } })
    }

    private func placement(_ category: String) -> Binding<AutoLabelSettingsModel.Placement> {
        Binding(get: { model.placement(category) },
                set: { value in Task { await model.setPlacement(value, for: category) } })
    }
}
