import MailFeatures
import MailModel
import MailRender
import SwiftUI

struct MessageCard: View {
    let phone: PhoneMail
    let reader: ReaderModel
    let message: ReaderModel.Message
    let me: Set<String>
    @Environment(\.touch) private var theme

    private var summary: MessageSummary { message.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.tokens.space2) {
            Button { reader.toggle(message.id) } label: { header }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(message.isExpanded ? "Folds the message" : "Opens the message")
            if message.isExpanded {
                MessageBody(phone: phone, message: message)
                    .padding(.top, theme.tokens.space1)
                let files = summary.attachments.filter { !$0.isInline }
                if !files.isEmpty { AttachmentList(files: files) }
            }
        }
        .padding(theme.tokens.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.tokens.space1) {
            HStack(alignment: .firstTextBaseline, spacing: theme.tokens.space2) {
                Text(sender)
                    .font(theme.senderUnread)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if summary.isUnread {
                    Circle().fill(theme.unreadDot).frame(width: 8, height: 8)
                        .accessibilityLabel("Unread")
                }
                Spacer(minLength: theme.tokens.space2)
                Text(phone.formatting.listDate(summary.date, now: Date()))
                    .font(theme.date)
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize()
            }
            if message.isExpanded {
                Text(phone.formatting.recipientsLine(summary, me: me))
                    .font(theme.caption)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
            } else {
                Text(summary.snippet)
                    .font(theme.snippet)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var sender: String {
        guard let from = summary.from else { return "(no sender)" }
        if me.contains(from.email.lowercased()) { return "Me" }
        return from.name.flatMap { $0.isEmpty ? nil : $0 } ?? from.email
    }
}

struct MessageBody: View {
    let phone: PhoneMail
    let message: ReaderModel.Message
    @Environment(\.touch) private var theme

    var body: some View {
        switch message.body {
        case .notLoaded, .fetching:
            ProgressView()
                .tint(theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel("Loading the message")
        case .failed(let reason):
            Text("Couldn't load this message. \(reason)")
                .font(theme.body)
                .foregroundStyle(theme.textWarning)
        case .rendered(.empty):
            Text(message.summary.snippet.isEmpty ? "This message has no text." : message.summary.snippet)
                .font(theme.body)
                .foregroundStyle(theme.textSecondary)
        case .rendered(.plain(let document)):
            PlainMessageText(layout: PlainTextLayout(document))
        case .rendered(.html(let rendered)):
            MessageWebBody(rendered: rendered, readerTextSize: theme.tokens.typeReader.size) { url in
                phone.follow(url, in: rendered)
            }
        }
    }
}

struct PlainMessageText: View {
    let layout: PlainTextLayout
    @State private var showsFolded = false
    @Environment(\.touch) private var theme

    var body: some View {
        let end = showsFolded ? layout.lines.count : (layout.foldStart ?? layout.lines.count)
        VStack(alignment: .leading, spacing: theme.tokens.space2) {
            Text(text(layout.lines[0..<end]))
                .font(theme.body)
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if layout.foldStart != nil, !showsFolded {
                Button { showsFolded = true } label: {
                    Image(systemName: "ellipsis")
                        .font(theme.smallIcon)
                        .foregroundStyle(theme.textSecondary)
                        .frame(minWidth: 44, minHeight: 32)
                        .background(Capsule().fill(theme.sunken))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show quoted text")
            }
        }
    }

    private func text(_ lines: ArraySlice<PlainTextLayout.Line>) -> AttributedString {
        var out = AttributedString()
        for (index, line) in lines.enumerated() {
            var piece = AttributedString((index == 0 ? "" : "\n") + line.text)
            switch line.role {
            case .body: break
            case .quote: piece.foregroundColor = theme.textSecondary
            case .signature: piece.foregroundColor = theme.textTertiary
            }
            out += piece
        }
        return out
    }
}

struct AttachmentList: View {
    let files: [AttachmentInfo]
    @Environment(\.touch) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.tokens.space2) {
            ForEach(files) { file in
                HStack(spacing: theme.tokens.space2) {
                    Image(systemName: "paperclip").accessibilityHidden(true)
                    Text(file.filename).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                        .foregroundStyle(theme.textTertiary)
                }
                .font(theme.snippet)
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, theme.tokens.space3)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: theme.tokens.radiusMD).fill(theme.sunken))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, theme.tokens.space1)
    }
}
