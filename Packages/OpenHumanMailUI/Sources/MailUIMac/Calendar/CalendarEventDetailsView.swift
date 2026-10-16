import AppKit
import MailFeatures
import MailModel
import MailRender
import MailTheme
import MailUI
import SwiftUI

struct CalendarEventDetailsOverlay: View {
    let model: CalendarSidebarModel
    let router: AppRouter
    @Environment(\.theme) private var theme

    var body: some View {
        if let details = model.openedDetails {
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    CalendarEventDetailsView(details: details,
                                             onClose: { byKeyboard in model.closeEvent(keepsFocus: byKeyboard) },
                                             onEdit: details.canOpenEditor ? { edit(details) } : nil)
                }
                .frame(maxHeight: max(proxy.size.height - 2 * theme.space4, 160))
                .fixedSize(horizontal: false, vertical: true)
                .padding(theme.space4)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func edit(_ details: CalendarEventDetails) {
        guard let window = router.environment.calendarWindow else { return }
        model.closeEvent()
        Task { await window.openEditor(for: details.event, calendarKey: details.calendarKey) }
    }
}

struct CalendarEventDetailsView: View {
    let details: CalendarEventDetails
    var onClose: (_ byKeyboard: Bool) -> Void = { _ in }
    var onEdit: (() -> Void)?
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            header
            when
            if let place = details.location {
                row(symbol: "mappin.and.ellipse") {
                    Text(verbatim: place).foregroundStyle(theme.textSecondary.color)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location: \(place)")
                .accessibilityIdentifier("calendar.details.location")
            }
            if let link = details.joinLink { join(link) }
            guests
            notes
            calendarRow
            if let answer = details.answerText {
                row(symbol: "checkmark.circle") {
                    Text(verbatim: answer).foregroundStyle(theme.textSecondary.color)
                }
                .accessibilityIdentifier("calendar.details.answer")
            }
            if let organizer = details.organizerText {
                Text(verbatim: organizer).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, CalendarDraftEditor.iconColumn)
                    .accessibilityIdentifier("calendar.details.organizer")
            }
            if let onEdit {
                Button("Edit in Calendar", action: onEdit)
                    .help("Opens this event in Calendar to change it")
                    .accessibilityIdentifier("calendar.details.edit")
            }
        }
        .padding(theme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgWindow.color))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
            .strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
        .onExitCommand { onClose(true) }
        .onAppear { titleFocused = true }
        .onChange(of: details.event.id) { titleFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details of \(details.title)")
        .accessibilityIdentifier("calendar.details")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
            Text(verbatim: details.title).themeFont(theme.typeHeadline).foregroundStyle(theme.textPrimary.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
                .accessibilityIdentifier("calendar.details.title")
            Spacer(minLength: 0)
            Button { onClose(false) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary.color)
            .help("Close  Esc")
            .accessibilityLabel("Close event details")
            .accessibilityIdentifier("calendar.details.close")
        }
    }

    private var when: some View {
        row(symbol: "clock") {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: details.dayText).foregroundStyle(theme.textPrimary.color)
                if let time = details.timeText {
                    Text(verbatim: time).foregroundStyle(theme.textSecondary.color)
                }
                ForEach([details.zoneText, details.eventZoneText, details.repeatText].compactMap { $0 }, id: \.self) { line in
                    Text(verbatim: line).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([details.spokenTime, details.repeatText].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("calendar.details.time")
    }

    private func join(_ link: URL) -> some View {
        row(symbol: "video") {
            VStack(alignment: .leading, spacing: 1) {
                Button("Join Google Meet") { openURL(link) }
                    .buttonStyle(.link)
                    .help(link.absoluteString)
                    .accessibilityIdentifier("calendar.details.join")
                Text(verbatim: Self.shortLink(link)).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityHidden(true)
            }
        }
    }

    static func shortLink(_ url: URL) -> String {
        let text = url.absoluteString
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            return String(text.dropFirst(scheme.count))
        }
        return text
    }

    @ViewBuilder
    private var guests: some View {
        if let summary = details.guestSummary {
            row(symbol: "person.2") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: summary).foregroundStyle(theme.textPrimary.color)
                    ForEach(details.guests) { guest in
                        HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
                            Text(verbatim: guest.line).foregroundStyle(theme.textSecondary.color)
                                .lineLimit(1).truncationMode(.middle)
                            if guest.isOptional {
                                Text("Optional").themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                            }
                            Spacer(minLength: 0)
                            if let answer = guest.responseText {
                                Text(verbatim: answer).themeFont(theme.typeCaption)
                                    .foregroundStyle(answerColor(guest.response).color)
                            }
                        }
                        .help(guest.email)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(guest.spokenText)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(summary)
            .accessibilityIdentifier("calendar.details.guests")
        }
    }

    private func answerColor(_ response: CalendarResponse?) -> ThemeColor {
        switch response ?? .needsAction {
        case .accepted: theme.textSuccess
        case .declined: theme.textDanger
        case .tentative: theme.textWarning
        case .needsAction: theme.textTertiary
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let parsed = details.notes {
            row(symbol: "text.alignleft") {
                Text(CalendarDescription.attributed(parsed.document))
                    .foregroundStyle(theme.textSecondary.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let safe = CalendarDescription.openableURL(url) else { return .discarded }
                        openURL(safe)
                        return .handled
                    })
            }
            .accessibilityIdentifier("calendar.details.notes")
        }
    }

    private var calendarRow: some View {
        row(symbol: "calendar") {
            HStack(spacing: theme.space2) {
                Circle().fill(CalendarDayView.calendarColor(details.colorIndex, theme: theme))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(verbatim: details.calendarName).foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calendar: \(details.calendarName)")
        .accessibilityIdentifier("calendar.details.calendar")
    }

    private func row<Content: View>(symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(theme.textTertiary.color)
                .frame(width: CalendarDraftEditor.iconColumn - theme.space2, alignment: .leading)
                .accessibilityHidden(true)
            content()
        }
        .themeFont(theme.typeMeta)
    }
}
