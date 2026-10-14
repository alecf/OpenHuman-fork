import MailFeatures
import MailTheme
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct GoogleClientGuideView: View {
    let guide: GoogleClientGuide
    let theme: ThemeTokens
    let haveFile: () -> Void
    let skip: () -> Void
    @State private var copiedStep: String?
    @State private var copiedLink: URL?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: theme.space5) {
                    header
                    VStack(alignment: .leading, spacing: theme.space3) {
                        ForEach(Array(GoogleClientGuide.steps.enumerated()), id: \.element.id) { index, step in
                            row(step, number: index + 1)
                        }
                        Text(GoogleClientGuide.multiAccountHint)
                            .font(theme.typeMeta.swiftUIFont)
                            .foregroundStyle(theme.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: GoogleClientGuideMetrics.column, alignment: .leading)
                .padding(.horizontal, theme.space8)
                .padding(.vertical, theme.space7)
                .frame(maxWidth: .infinity)
            }
            Rectangle().fill(theme.borderHairline.color).frame(height: 1).accessibilityHidden(true)
            footer
        }
        .background(theme.bgWindow.color)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            Text(GoogleClientGuide.title)
                .font(theme.typeTitle.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .accessibilityAddTraits(.isHeader)
            Text(GoogleClientGuide.intro)
                .font(theme.typeReader.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: theme.space1) {
                ForEach(GoogleClientGuide.reassurance, id: \.self) { line in
                    Label(line, systemImage: "checkmark")
                        .font(theme.typeMeta.swiftUIFont)
                        .foregroundStyle(theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, theme.space1)
            Text(guide.progressText)
                .font(theme.typeCaption.swiftUIFont)
                .foregroundStyle(theme.textTertiary.color)
                .padding(.top, theme.space2)
        }
    }

    private func row(_ step: GoogleClientGuideStep, number: Int) -> some View {
        let done = guide.isDone(step)
        return HStack(alignment: .top, spacing: theme.space3) {
            Button { guide.toggle(step) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: GoogleClientGuideMetrics.checkSize))
                    .foregroundStyle((done ? theme.textSuccess : theme.textTertiary).color)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(guide.accessibilityLabel(step))
            .accessibilityHint("Ticks the step off. Only for you; nothing is saved.")
            VStack(alignment: .leading, spacing: theme.space1) {
                Text(verbatim: "\(number). \(step.title)")
                    .font(theme.typeBodyStrong.swiftUIFont)
                    .foregroundStyle((done ? theme.textSecondary : theme.textPrimary).color)
                Text(step.action)
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let value = step.copyValue { copyField(value, step: step) }
                Text(step.why)
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(step.links, id: \.url) { link in linkRow(link) }
            }
            Spacer(minLength: 0)
        }
        .padding(theme.space4)
        .background(theme.bgSunken.color, in: RoundedRectangle(cornerRadius: theme.radiusMD))
        .accessibilityElement(children: .contain)
    }

    private func linkRow(_ link: GoogleClientGuideLink) -> some View {
        HStack(spacing: theme.space3) {
            Button(link.label) { GoogleClientGuide.open(link) { openURL($0) } }
                .ohLinkButtonStyle()
                .font(theme.typeBody.swiftUIFont)
                .accessibilityLabel(link.accessibilityLabel)
            Text(verbatim: link.domain)
                .font(theme.typeCaption.swiftUIFont)
                .foregroundStyle(theme.textTertiary.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(copiedLink == link.url ? "Copied" : GoogleClientGuide.copyLinkTitle) {
                GoogleClientGuide.copyAddress(of: link) { TextClipboard.copy($0) }
                copiedLink = link.url
            }
            .controlSize(.small)
            .accessibilityLabel("Copy link to \(link.label)")
        }
        .padding(.top, theme.space1)
    }

    private func copyField(_ value: String, step: GoogleClientGuideStep) -> some View {
        HStack(spacing: theme.space3) {
            Text(verbatim: value)
                .font(theme.typeMeta.swiftUIFont.monospaced())
                .foregroundStyle(theme.textPrimary.color)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if copiedStep == step.id {
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
            }
            Button("Copy") {
                TextClipboard.copy(value)
                copiedStep = step.id
            }
            .accessibilityLabel("Copy the Gmail permission")
        }
        .padding(.horizontal, theme.space3)
        .padding(.vertical, theme.space2)
        .background(theme.bgWindow.color, in: RoundedRectangle(cornerRadius: theme.radiusSM))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            HStack(spacing: theme.space3) {
                Button(GoogleClientGuide.skipTitle) { skip() }
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: theme.space4)
                Button {
                    haveFile()
                } label: {
                    Text(GoogleClientGuide.haveFileTitle).font(theme.typeBodyStrong.swiftUIFont)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Opens a file picker to import the Google client file.")
            }
            Text(GoogleClientGuide.laterNote)
                .font(theme.typeMeta.swiftUIFont)
                .foregroundStyle(theme.textTertiary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: GoogleClientGuideMetrics.column)
        .padding(.horizontal, theme.space8)
        .padding(.vertical, theme.space5)
        .frame(maxWidth: .infinity)
    }
}

enum GoogleClientGuideMetrics {
    static let column: CGFloat = 520
    static let checkSize: CGFloat = 16
}

@MainActor
enum TextClipboard {
    static func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
