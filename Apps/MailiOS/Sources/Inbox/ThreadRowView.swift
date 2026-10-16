import MailFeatures
import MailModel
import SwiftUI

struct ThreadRowView: View {
    let row: ThreadRow
    let chips: [ThreadRowChip]
    let location: MailLocation
    let formatting: ThreadRowFormatting
    @ScaledMetric(relativeTo: .body) private var dotSize: CGFloat = 9
    @Environment(\.touch) private var theme

    var body: some View {
        let now = Date()
        let date = formatting.dateColumn(row, location: location, now: now)
        let subject = formatting.subject(row)
        HStack(alignment: .top, spacing: 0) {
            Circle()
                .fill(row.isUnread ? theme.unreadDot : .clear)
                .frame(width: dotSize, height: dotSize)
                .frame(width: theme.gutter + theme.tokens.space1)
                .padding(.top, theme.tokens.space3)
            VStack(alignment: .leading, spacing: theme.tokens.space1) {
                HStack(alignment: .firstTextBaseline, spacing: theme.tokens.space2) {
                    senderLine
                        .lineLimit(1)
                    Spacer(minLength: theme.tokens.space2)
                    Text(date.text)
                        .font(theme.date)
                        .foregroundStyle(date.isUpcoming ? theme.textWarning
                                         : (row.isUnread ? theme.tokens.component.row.dateUnread.color
                                            : theme.tokens.component.row.date.color))
                        .fixedSize()
                }
                Text(subject ?? "(no subject)")
                    .font(row.isUnread ? theme.subject.weight(.medium) : theme.subject)
                    .foregroundStyle(subject == nil ? theme.textTertiary : theme.tokens.component.row.subject.color)
                    .lineLimit(1)
                Text(formatting.snippet(row))
                    .font(theme.snippet)
                    .foregroundStyle(theme.tokens.component.row.snippet.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !chips.isEmpty {
                    ChipRow(chips: chips)
                        .padding(.top, theme.tokens.space1)
                }
            }
        }
        .padding(.trailing, theme.gutter)
        .padding(.vertical, theme.tokens.space3)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: theme.tokens.borderWidthHairline)
                .padding(.leading, theme.gutter + theme.tokens.space1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(formatting.accessibilityLabel(row, chips: chips, location: location, now: now))
    }

    private var senderLine: Text {
        let sender = formatting.sender(row)
        let name = Text(sender.name.isEmpty ? "(no sender)" : sender.name)
            .font(row.isUnread ? theme.senderUnread : theme.sender)
            .foregroundStyle(theme.tokens.component.row.sender.color)
        let count = Text(sender.count.map { " \($0)" } ?? "")
            .font(theme.snippet)
            .foregroundStyle(theme.textTertiary)
        let draft = Text(formatting.showsDraftPrefix(row, location: location) ? ", Draft" : "")
            .font(theme.sender)
            .foregroundStyle(theme.tokens.component.row.draft.color)
        return Text("\(name)\(count)\(draft)")
    }
}

struct ChipRow: View {
    let chips: [ThreadRowChip]
    @Environment(\.touch) private var theme

    var body: some View {
        HStack(spacing: theme.tokens.space2) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                let tint = tint(chip)
                Text(chip.title)
                    .font(theme.chip)
                    .foregroundStyle(tint ?? theme.tokens.component.row.chipText.color)
                    .lineLimit(1)
                    .padding(.horizontal, theme.tokens.space2)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: theme.tokens.component.row.chipRadius)
                        .fill(tint.map { $0.opacity(0.18) } ?? theme.tokens.component.row.chipBg.color))
                    .opacity(chip.isQuiet ? 0.75 : 1)
            }
        }
    }

    private func tint(_ chip: ThreadRowChip) -> Color? {
        switch chip.kind {
        case .important: theme.textWarning
        case .vip: theme.textAI
        case .label: theme.labelColor(chip.color)
        case .returned: theme.textLink
        case .gmailImportant, .category, .overflow: nil
        }
    }
}
