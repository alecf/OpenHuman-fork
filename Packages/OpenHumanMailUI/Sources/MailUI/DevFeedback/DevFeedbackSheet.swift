import MailFeatures
import SwiftUI

public struct DevFeedbackSheet: View {
    @Bindable var model: DevFeedbackModel
    let onClose: () -> Void
    let copy: (String) -> Void
    let onSendToDevice: (() -> Void)?

    public init(model: DevFeedbackModel, onClose: @escaping () -> Void, copy: @escaping (String) -> Void,
                onSendToDevice: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
        self.copy = copy
        self.onSendToDevice = onSendToDevice
    }

    public var body: some View {
        Group {
            if case .saved(let saved) = model.state {
                savedView(saved)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "Give feedback").font(.title2.weight(.semibold))
            Picker("Category", selection: $model.category) {
                ForEach(DevFeedbackCategory.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.text)
                    .font(.body)
                    .frame(minHeight: 120, maxHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    .accessibilityLabel("What happened")
                if model.text.isEmpty {
                    Text(verbatim: "What happened? What did you expect?")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .allowsHitTesting(false)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "Attach").font(.headline)
                Toggle("App state snapshot (ids, counts, sync state; no email content)", isOn: $model.includeSnapshot)
                Toggle("Logs from the last 10 minutes (scrubbed; no email content)", isOn: $model.includeLogs)
                Toggle(isOn: $model.includeThreadContent) {
                    contentLabel("Subject and sender of the open thread",
                                 unavailable: model.threadContentAvailable ? nil : "no thread open")
                }
                .disabled(!model.threadContentAvailable)
                Toggle(isOn: $model.includeScreenshot) {
                    contentLabel("Screenshot of the window",
                                 unavailable: model.screenshotAvailable ? nil : "not available")
                }
                .disabled(!model.screenshotAvailable)
            }
            .devCheckbox()
            Text(verbatim: model.pendingAnswerCount == 1 ? "1 checklist answer will be included."
                 : "\(model.pendingAnswerCount) checklist answers will be included.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if case .failed(let message) = model.state {
                Text(verbatim: message).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if let onSendToDevice { Button("Send to Another Device…", action: onSendToDevice) }
                Spacer()
                Button("Cancel", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Save Feedback") { Task { await model.submit() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.state == .saving)
            }
        }
    }

    private func contentLabel(_ title: String, unavailable: String?) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
            Text(verbatim: "contains email content")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if let unavailable {
                Text(verbatim: "(\(unavailable))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func savedView(_ saved: DevFeedbackModel.Saved) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "Feedback saved").font(.title2.weight(.semibold))
            Text(verbatim: saved.bundlePath)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if saved.answersIncluded > 0 {
                Text(verbatim: "Includes \(saved.answersIncluded) checklist answer\(saved.answersIncluded == 1 ? "" : "s").")
                    .font(.caption).foregroundStyle(.secondary)
            }
            command("On this Mac (send to your other device):", saved.sendCommand)
            if saved.needsTarget {
                Text(verbatim: "Replace \(DevFeedbackCommands.targetPlaceholder) with the other device's Tailscale name, or set it in Settings › Advanced.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            command("On the other device (receive):", saved.receiveCommand)
            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func command(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.headline)
            HStack(alignment: .top) {
                Text(verbatim: text)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") { copy(text) }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
        }
    }
}
