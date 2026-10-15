import MailActions
import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct AISettingsSection: View {
    @State private var model: AISettingsPageModel
    @State private var summarizeEvery: StoredSetting<Bool>?
    private let offersQuickRepliesRow: Bool
    @Environment(\.theme) private var theme

    public init(center: AICenter, environment: AppEnvironment?, listsUnavailableModels: Bool = true) {
        _model = State(initialValue: AISettingsPageModel(center: center, environment: environment,
                                                         listsUnavailableModels: listsUnavailableModels))
        offersQuickRepliesRow = environment?.actions.contains(.aiToggleInstantReply) ?? true
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.space7) {
            providers
            AIFeatureModelsSection(center: model.center)
            choices
            personal
            accounts
            SettingsErrorLine(text: model.error)
        }
        .task { await model.refresh() }
    }

    private var providers: some View {
        SettingsSection(String(localized: "Models"),
                        footnote: String(localized: "The models Mail can use. Each feature's model is chosen below.")) {
            ForEach(model.providers) { row in
                SettingsRow(row.name, detail: row.status, status: row.warning, statusTone: .warning) {
                    AIProviderBadgeView(badge: row.badge)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var choices: some View {
        SettingsSection(String(localized: "Features")) {
            SettingsRow(String(localized: "Use AI"), isOn: $model.useAI)
            SettingsRow(String(localized: "Draft replies"), alignment: .firstTextBaseline, labelsControl: true) {
                Picker("Draft replies", selection: $model.draftReplies) {
                    Text("Yes, draft replies on this Mac").tag(DraftRepliesChoice.onDeviceAuto)
                    Text("Only when I ask (⌘J)").tag(DraftRepliesChoice.onDemand)
                    Text("Not at all").tag(DraftRepliesChoice.off)
                }
                .ohRadioGroupPickerStyle()
                .labelsHidden()
                .fixedSize()
            }
            .disabled(!model.useAI)
            if offersQuickRepliesRow {
                SettingsRow(AISettingsPageModel.instantReplyStripTitle,
                            detail: AISettingsPageModel.instantReplyStripDetail,
                            status: model.instantReplyStripStatus,
                            isOn: $model.instantReplyStrip)
                    .disabled(!model.offersInstantReplyStrip)
                    .accessibilityIdentifier("settings.ai.quickRepliesRow")
            }
            if model.offersAgentQuickReplies {
                SettingsRow(String(localized: "Also write quick replies with Claude Code or Codex"),
                            detail: String(localized: "Each conversation you open is sent to that company."),
                            isOn: $model.agentQuickReplies)
                    .disabled(!model.useAI || model.draftReplies != .onDeviceAuto)
            }
            SettingsRow(String(localized: "Summarize conversations when I open them"),
                        detail: String(localized: "On this Mac, for conversations of 3 messages or more."),
                        isOn: $model.summarizeOnOpen)
                .disabled(!model.useAI)
            SettingsRow(String(localized: "Summarize every conversation"),
                        detail: String(localized: "A one-line summary under each subject, made on this Mac only. With “Prepare replies and summaries in advance” on, your newest Inbox conversations get theirs in the background."),
                        isOn: Binding(get: { summarizeEvery?.value ?? true },
                                      set: { on in
                                          Task {
                                              await summarizeEvery?.set(on)
                                              if !on { model.center.threadLines.cancelBackground() }
                                          }
                                      }))
                .disabled(!model.useAI)
                .task {
                    guard summarizeEvery == nil else { return }
                    let setting = model.center.threadLines.makeEnabledSetting()
                    setting.start()
                    summarizeEvery = setting
                }
            HStack {
                Spacer(minLength: 0)
                Button(String(localized: "Summarize now")) {
                    Task { await model.center.threadLines.summarizeRecent(days: 7) }
                }
                .help(String(localized: "One-line summaries for the Inbox conversations of the last 7 days, on this Mac."))
                .disabled(!model.useAI || summarizeEvery?.value == false)
                .accessibilityIdentifier("settings.ai.summarizeNow")
            }
            SettingsRow(AISettingsPageModel.prepareTitle, detail: AISettingsPageModel.prepareDetail,
                        status: model.prepareStatus, isOn: $model.prepareInAdvance)
                .disabled(model.prepareStatus != nil)
                .accessibilityIdentifier("settings.ai.prepareInAdvance")
            SettingsRow(AISettingsPageModel.autoDraftTitle, detail: AISettingsPageModel.autoDraftDetail,
                        status: model.autoDraftStatus, isOn: $model.autoDraftReplies)
                .disabled(model.autoDraftStatus != nil)
                .accessibilityIdentifier("settings.ai.autoDraftReplies")
            HStack {
                Spacer(minLength: 0)
                Button(String(localized: "Clear prepared replies")) {
                    Task { await model.clearPrepared() }
                }
                .help(String(localized: "Drops the replies and summaries prepared in advance. New mail is prepared again as it comes."))
                .disabled(!model.useAI)
                .accessibilityIdentifier("settings.ai.clearPrepared")
            }
            SettingsRow(String(localized: "Allow Apple Writing Tools in the composer"),
                        detail: AISettingsPageModel.writingToolsNote,
                        isOn: $model.allowWritingTools)
                .disabled(!model.useAI)
        }
    }

    private var personal: some View {
        SettingsSection(String(localized: "Personal writing instructions"), footnote: AISettingsPageModel.personalNote) {
            personalRow(AISettingsPageModel.aboutMeTitle, prompt: AISettingsPageModel.aboutMePrompt, text: $model.aboutMe,
                        identifier: "settings.ai.aboutMe")
            personalRow(AISettingsPageModel.writingInstructionsTitle, prompt: AISettingsPageModel.writingInstructionsPrompt,
                        text: $model.writingInstructions, identifier: "settings.ai.howIWrite")
        }
        .disabled(!model.useAI)
    }

    private func personalRow(_ title: String, prompt: String, text: Binding<String>, identifier: String) -> some View {
        SettingsRow(title, alignment: .firstTextBaseline, labelsControl: true) {
            TextField(title, text: text, prompt: Text(prompt), axis: .vertical)
                .lineLimit(2...5)
                .labelsHidden()
                .settingsTextField()
                .frame(maxWidth: 320)
                .accessibilityIdentifier(identifier)
        }
    }

    @ViewBuilder private var accounts: some View {
        SettingsSection(String(localized: "On-device AI only"),
                        footnote: String(localized: "Mail never sends this account's mail to a provider off this Mac, even one you allowed.")) {
            ForEach(model.accounts) { account in
                SettingsRow(account.title, isOn: Binding(get: { account.onDeviceOnly },
                                                         set: { model.setOnDeviceOnly($0, account: account.id) }))
            }
        }
    }
}
