import MailFeatures
import SwiftUI

public struct DevChecklistView: View {
    @Bindable var model: DevChecklistModel
    let onGiveFeedback: () -> Void

    public init(model: DevChecklistModel, onGiveFeedback: @escaping () -> Void) {
        self.model = model
        self.onGiveFeedback = onGiveFeedback
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.sections.isEmpty {
                Text(verbatim: model.items.isEmpty ? "No checklist items." : "Everything here has been tested.")
                    .foregroundStyle(.secondary)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List {
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                DevChecklistRow(model: model, item: item)
                            }
                        } header: {
                            Text(verbatim: section.area)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(verbatim: "\(model.testedCount) of \(model.items.count) tested")
                    .font(.headline)
                Spacer()
                Toggle("Only not yet tested", isOn: $model.showOnlyUntested)
                    .devCheckbox()
                Button("Give feedback…", action: onGiveFeedback)
            }
            Text(verbatim: "Answers save as you go. Give feedback (⌃⌥⌘F) sends them with the next bundle.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(model.checklist.issues.prefix(5).enumerated()), id: \.offset) { _, issue in
                Text(verbatim: issue).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            if let error = model.saveError {
                Text(verbatim: error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
    }
}

struct DevChecklistRow: View {
    @Bindable var model: DevChecklistModel
    let item: DevChecklistItem

    private var answer: DevChecklistAnswer? { model.answer(for: item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(symbolColor)
                    .accessibilityLabel(answer?.result?.title ?? "Not tested")
                Text(verbatim: item.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(3)
                Spacer(minLength: 8)
                Text(verbatim: Self.requirementTitle(item.requires))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(item.deepLink == nil ? "Show keys" : "Open") { model.open(item) }
                    .help(item.deepLink.map { "Follows \($0)" } ?? "This item has no link: follow the steps.")
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(item.steps.enumerated()), id: \.offset) { index, step in
                    Text(verbatim: "\(index + 1). \(step)")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: "Expected: \(item.expected)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 24)
            HStack(spacing: 6) {
                ForEach(DevChecklistResult.allCases, id: \.self) { result in
                    resultButton(result)
                }
                if let answer, answer.result != nil {
                    Text(answer.answeredAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "ago").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 24)
            TextField("Notes (optional)", text: Binding(
                get: { model.answer(for: item.id)?.note ?? "" },
                set: { model.setNote($0, for: item.id) }), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .padding(.leading, 24)
            if let outcome = model.openOutcomes[item.id] {
                Text(verbatim: message(outcome))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func resultButton(_ result: DevChecklistResult) -> some View {
        let selected = answer?.result == result
        if selected {
            Button(result.title) { model.record(nil, for: item.id) }
                .buttonStyle(.borderedProminent)
                .help("Click again to clear")
        } else {
            Button(result.title) { model.record(result, for: item.id) }
                .buttonStyle(.bordered)
        }
    }

    private var symbol: String {
        switch answer?.result {
        case .worked: "checkmark.circle.fill"
        case .didNotWork: "xmark.circle.fill"
        case .skipped: "arrow.uturn.right.circle"
        case nil: "circle"
        }
    }

    private var symbolColor: Color {
        switch answer?.result {
        case .worked: .green
        case .didNotWork: .red
        case .skipped: .secondary
        case nil: .secondary
        }
    }

    private func message(_ outcome: DevChecklistModel.OpenOutcome) -> String {
        switch outcome {
        case .followed(_, let message): message
        case .showKeys: "No link for this item: follow the steps above in the mail window."
        case .invalidLink: "The link could not be read."
        }
    }

    static func requirementTitle(_ requirement: DevChecklistItem.Requirement) -> String {
        switch requirement {
        case .fake: "fake data"
        case .real: "real account"
        }
    }
}
