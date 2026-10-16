import AppKit
import MailActions
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

public struct CalendarSidebarView: View {
    static let followDelay: Duration = .milliseconds(300)
    static let composerDelay: Duration = .milliseconds(500)

    struct ComposerFollow: Equatable {
        let session: UUID
        let revision: Int
    }

    @Bindable var model: CalendarSidebarModel
    let router: AppRouter
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var dayKeys = CalendarDayKeyFocus()

    public init(model: CalendarSidebarModel, router: AppRouter) {
        self.model = model
        self.router = router
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: theme.space5) {
                    if model.draft != nil { CalendarDraftEditor(model: model, takeKeys: { dayKeys.take() }) }
                    summary
                    if model.draft == nil, let day = model.dayViewDay {
                        CalendarDayView(model: model, day: day, takeKeys: { dayKeys.take() })
                        otherDays(besides: day)
                        freeTimes(day)
                    }
                }
                .padding(theme.space5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .top) { CalendarEventDetailsOverlay(model: model, router: router) }
            CalendarSidebarBottomBar(model: model, router: router)
        }
        .frame(width: theme.component.sidebar.width)
        .frame(maxHeight: .infinity)
        .background(CalendarDayKeys(model: model, focus: dayKeys))
        .background(theme.component.sidebar.bg.color)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.borderHairline.color).frame(width: theme.borderWidthHairline)
        }
        .task(id: router.reader?.thread) {
            model.activeAccount = { [weak router = self.router] in router?.activeAccountID }
            try? await Task.sleep(for: Self.followDelay)
            guard !Task.isCancelled else { return }
            await model.show(thread: router.reader?.thread)
        }
        .task(id: composerFollow) {
            guard let follow = composerFollow else { return }
            try? await Task.sleep(for: Self.composerDelay)
            guard !Task.isCancelled, let session = router.environment.composeIfStarted?.session(id: follow.session) else {
                return
            }
            await model.follow(typed: session.plainText)
        }
        .onChange(of: router.environment.pendingEvents.returnRequest) {
            dayKeys.view?.window?.makeFirstResponder(nil)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: model.refreshInterval)
                guard !Task.isCancelled else { return }
                await model.tick()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                await model.appBecameActive()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar")
        .accessibilityIdentifier("calendar.sidebar")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
                let contact = router.environment.actions.superhumanCore?.contextSidebar
                if let contact {
                    let title = router.reader == nil ? ListSidePanelView.panel(for: router).title : "Contact"
                    Button(title) { contact.setVisible(true) }
                        .buttonStyle(.borderless)
                        .themeFont(theme.typeHeadline).foregroundStyle(theme.textSecondary.color)
                        .shortcutTip(.toggleContextSidebar, title: "Show \(title.lowercased())")
                }
                Text("Calendar").themeFont(theme.typeHeadline).foregroundStyle(theme.textPrimary.color)
                    .overlay(alignment: .bottom) {
                        if contact != nil {
                            Rectangle().fill(theme.component.row.cursorBar.color)
                                .frame(height: theme.component.row.cursorBarWidth)
                                .offset(y: theme.space2)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityAddTraits(contact != nil ? [.isHeader, .isSelected] : .isHeader)
                if model.isSample {
                    Text("Sample").themeFont(theme.typeCaption).foregroundStyle(theme.textSecondary.color)
                        .padding(.horizontal, theme.space2)
                        .background(Capsule().fill(theme.bgSunken.color))
                        .overlay(Capsule().strokeBorder(theme.borderControl.color, lineWidth: theme.borderWidthHairline))
                }
                Spacer(minLength: 0)
                if model.state == .loading { ProgressView().controlSize(.small) }
                CalendarHeaderGlyph(symbol: "arrow.clockwise", help: "Refresh", label: "Refresh calendar") {
                    Task { await model.refresh() }
                }
                CalendarHeaderGlyph(symbol: "xmark", help: "Hide calendar", label: "Hide calendar",
                                    shortcut: .calendarToggleSidebar) {
                    model.setVisible(false)
                }
            }
            Text(model.zonesText).themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
            dayNavigation
            if model.routesByAccount {
                Toggle("Show all calendars", isOn: Binding(get: { model.showAllSetting.value },
                                                           set: { on in Task { await model.setShowAll(on) } }))
                    .toggleStyle(.checkbox)
                    .themeFont(theme.typeMeta)
                    .accessibilityIdentifier("calendar.showAll")
            }
        }
        .padding(.horizontal, theme.space5)
        .padding(.vertical, theme.space4)
    }

    @ViewBuilder
    private var dayNavigation: some View {
        if model.dayViewDay == nil {
            dayNavigationRow
        }
    }

    private var dayNavigationRow: some View {
        HStack(spacing: theme.space2) {
            Button { dayKeys.take(); model.moveDayInstantly(by: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).dayKeyTip(.previousDay)
                .accessibilityLabel("Previous day")
            Button("Today") { dayKeys.take(); model.goToTodayInstantly() }
                .buttonStyle(.borderless).dayKeyTip(.today)
            Button { dayKeys.take(); model.moveDayInstantly(by: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).dayKeyTip(.nextDay)
                .accessibilityLabel("Next day")
            Spacer(minLength: 0)
        }
        .themeFont(theme.typeMeta)
        .accessibilityIdentifier("calendar.dayNavigation")
    }

    private var summaryLine: String? {
        if model.followsDraft { return String(localized: "Days your draft mentions:") }
        if model.isBrowsing || model.thread == nil { return nil }
        return model.mentionCount == 0 ? String(localized: "This conversation mentions no dates. Today:")
                                       : String(localized: "Days this conversation mentions:")
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            if let line = summaryLine {
                Text(line).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
            }
            if let note = model.calendarNote {
                Text(note).themeFont(theme.typeMeta)
                    .foregroundStyle(model.connectIsReconnect ? theme.textWarning.color : theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("calendar.notConnected")
            }
            if let title = model.connectTitle {
                HStack(spacing: theme.space2) {
                    Button(title) { Task { await model.connectShownCalendar() } }
                        .disabled(model.isConnecting)
                        .accessibilityIdentifier("calendar.connect")
                    if model.isConnecting { ProgressView().controlSize(.small) }
                }
            }
            if let error = model.connectError {
                Text(error).themeFont(theme.typeMeta).foregroundStyle(theme.textDanger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.thread != nil, model.draft == nil {
                Button("Create event from email…") { Task { await model.beginDraft(for: nil) } }
                    .accessibilityIdentifier("calendar.createDraft")
            }
            Button("Suggest times") { Task { await model.suggestTimes() } }
                .disabled(model.isSuggesting)
                .help("Up to 3 free 30-minute times in the next five working days, as text. Nothing is added to your calendar.")
                .accessibilityIdentifier("calendar.suggestTimes")
        }
        if let suggestion = model.suggestion {
            suggestionBox(suggestion)
        } else if let note = model.suggestionNote {
            Text(note).themeFont(theme.typeMeta).foregroundStyle(theme.textWarning.color)
        }
        if case .failed(let message) = model.state {
            Text(message).themeFont(theme.typeMeta).foregroundStyle(theme.textDanger.color)
        }
    }

    private func suggestionBox(_ suggestion: CalendarAvailability) -> some View {
        let text = model.suggestionText(suggestion) ?? ""
        let composer = router.environment.composeIfStarted?.windowSession
        return VStack(alignment: .leading, spacing: theme.space2) {
            Text("Suggested times").themeFont(theme.typeLabel).foregroundStyle(theme.textTertiary.color)
            Text(text).themeFont(theme.typeMeta).foregroundStyle(theme.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Toggle("Ignore conflicts", isOn: Binding(
                get: { model.ignoreConflictsSetting.value },
                set: { on in Task { await model.ignoreConflictsSetting.set(on); await model.suggestTimes() } }))
                .accessibilityIdentifier("calendar.ignoreConflicts")
            if let note = model.suggestionNote {
                Text(note).themeFont(theme.typeCaption).foregroundStyle(theme.textWarning.color)
            }
            HStack(spacing: theme.space3) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                if let composer, composer.isOpen {
                    Button("Insert in draft") { Task { await model.insertAvailability(into: composer) } }
                        .help("Puts the times in the open draft  ⇧⌘A")
                        .accessibilityIdentifier("calendar.insertAvailability")
                }
            }
            Text("Text only: nothing is added to your calendar.")
                .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
        }
        .padding(theme.space4)
        .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgWindow.color))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
            .strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.suggestion")
    }

    private var composerFollow: ComposerFollow? {
        guard let session = router.environment.composeIfStarted?.keySession else { return nil }
        return ComposerFollow(session: session.id, revision: session.documentRevision)
    }

    @ViewBuilder
    private func otherDays(besides shown: CalendarSidebarModel.Day) -> some View {
        let others = model.days.filter { $0.start != shown.start }
        if !others.isEmpty {
            HStack(spacing: theme.space2) {
                Text("Also mentioned:").themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                ForEach(others) { day in
                    Button(model.dayHeader(day)) { dayKeys.take(); Task { await model.show(day: day.start) } }
                        .buttonStyle(.link)
                        .themeFont(theme.typeCaption)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("calendar.otherDays")
        }
    }

    @ViewBuilder
    private func freeTimes(_ day: CalendarSidebarModel.Day) -> some View {
        if !day.free.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Free (\(model.workdayText(day)))")
                    .themeFont(theme.typeLabel).foregroundStyle(theme.textTertiary.color)
                ForEach(day.free, id: \.start) { gap in
                    timeLines(gap.start, gap.end, allDay: false, style: theme.typeMeta, color: theme.textSuccess)
                }
            }
            .accessibilityElement(children: .combine)
        } else if !day.busy.isEmpty {
            Text("No free time \(model.workdayText(day))")
                .themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
        }
    }

    @ViewBuilder
    private func timeLines(_ start: Date, _ end: Date, allDay: Bool, style: TypeStyle, color: ThemeColor) -> some View {
        Text(model.timeText(start, end, allDay: allDay)).themeFont(style).foregroundStyle(color.color)
        if let second = model.secondTimeText(start, end, allDay: allDay) {
            Text(second).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
        }
    }
}

struct CalendarDraftEditor: View {
    @Bindable var model: CalendarSidebarModel
    var showsDay = true
    var onCancel: (() -> Void)?
    var takeKeys: () -> Void = {}
    @Environment(\.theme) private var theme
    @State private var feedback: PendingEventStore.Feedback?

    var body: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: theme.space3) {
                CalendarEventFormView(
                    form: Binding(get: { CalendarEventForm(draft: model.draft ?? draft) },
                                  set: { model.draft = $0.applying(to: model.draft ?? draft) }),
                    rights: CalendarFieldRights.forNewEvent(refusal: model.createRefusal),
                    timeZone: model.timeZone, idPrefix: "calendar.draft", meetLink: nil,
                    titleIsSuggested: model.titleIsSuggested, focusesTitle: model.titleIsSuggested,
                    calendarName: model.calendarLine)
                if !draft.provenance.isEmpty {
                    Text(draft.provenance).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                        .padding(.leading, CalendarDraftEditor.iconColumn)
                        .accessibilityIdentifier("calendar.draft.provenance")
                }
                if let second = model.secondTimeText(draft.start, draft.end) {
                    Text(second).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                        .padding(.leading, CalendarDraftEditor.iconColumn)
                }
                if showsDay, let day = model.dayViewDay {
                    CalendarDayView(model: model, day: day, strikesConflicts: true, takeKeys: takeKeys, compact: true)
                    conflicts(model.timeline(for: day))
                }
                status(draft)
                actions
            }
            .environment(\.timeZone, model.timeZone)
            .onExitCommand { cancel() }
            .padding(theme.space4)
            .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgWindow.color))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
                .strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("New event")
            .accessibilityIdentifier("calendar.draft")
        }
    }

    @ViewBuilder
    private func conflicts(_ timeline: CalendarDayTimeline) -> some View {
        let found = timeline.conflicts
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(found) { event in
                    Label {
                        Text("Conflicts with \(event.title) · \(model.timeText(event.start, event.end))")
                    } icon: { Image(systemName: "exclamationmark.triangle") }
                    .themeFont(theme.typeCaption).foregroundStyle(theme.textDanger.color)
                }
            }
            .accessibilityIdentifier("calendar.draft.conflicts")
        }
    }

    @ViewBuilder
    private func status(_ draft: CalendarEventDraft) -> some View {
        Text(draft.mayEmailAttendees
             ? "Saved after a few seconds, so Undo (⌘Z) can stop it. Google may email attendees even when invitations are off."
             : "No attendees: nobody is emailed.")
            .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
        if model.createRefusal == nil, let problem = draft.problem {
            Text(problem).themeFont(theme.typeMeta).foregroundStyle(theme.textWarning.color)
        }
        if let note = model.draftNote, note != model.createRefusal {
            Text(note).themeFont(theme.typeMeta).foregroundStyle(theme.textDanger.color)
        }
    }

    private var actions: some View {
        HStack(spacing: theme.space3) {
            Button("Save") { Task { await model.createEvent() } }
                .buttonStyle(.borderedProminent)
                .tint(theme.accentFill.color)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canCreate)
                .help(model.createRefusal ?? String(localized: "Save the event  ⌘↵"))
                .accessibilityHint(model.createRefusal ?? "")
                .accessibilityIdentifier("calendar.draft.create")
            Button("Cancel") { cancel() }
                .help(onCancel == nil ? "Cancel and go back to the email  Esc" : "Cancel  Esc")
                .accessibilityIdentifier("calendar.draft.cancel")
            Spacer(minLength: 0)
            thumb(.up, symbol: "hand.thumbsup", label: "Good suggestion")
            thumb(.down, symbol: "hand.thumbsdown", label: "Bad suggestion")
        }
    }

    private func cancel() {
        if let onCancel { onCancel() } else { model.cancelDraft() }
    }

    private func thumb(_ value: PendingEventStore.Feedback, symbol: String, label: String) -> some View {
        Button {
            guard feedback == nil else { return }
            feedback = value
            model.recordFeedback(value)
        } label: {
            Image(systemName: feedback == value ? symbol + ".fill" : symbol)
        }
        .buttonStyle(.plain)
        .foregroundStyle((feedback == value ? theme.textPrimary : theme.textTertiary).color)
        .help("\(label) (kept on this Mac only)")
        .accessibilityLabel(label)
    }

    private func fieldRow<Content: View>(symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(theme.textTertiary.color)
                .frame(width: CalendarDraftEditor.iconColumn - theme.space2, alignment: .leading)
                .accessibilityHidden(true)
            content()
        }
        .themeFont(theme.typeMeta)
    }

    static let iconColumn: CGFloat = 24

    static func address(_ text: String) -> EmailAddress? {
        var name: String?
        var email = text
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            email = String(text[text.index(after: open)..<close])
            let before = text[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            name = before.isEmpty ? nil : before
        }
        email = email.trimmingCharacters(in: .whitespaces)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !email.contains(" ") else { return nil }
        return EmailAddress(name: name, email: email)
    }
}

struct CalendarDayKeys: NSViewRepresentable {
    let model: CalendarSidebarModel
    let focus: CalendarDayKeyFocus

    func makeNSView(context: Context) -> CalendarDayKeyView {
        let view = CalendarDayKeyView()
        view.model = model
        focus.view = view
        return view
    }

    func updateNSView(_ view: CalendarDayKeyView, context: Context) {
        view.model = model
        focus.view = view
    }
}

@MainActor
final class CalendarDayKeyFocus {
    weak var view: CalendarDayKeyView?

    func take() {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }
}

final class CalendarDayKeyView: NSView, TextInputHost {
    weak var model: CalendarSidebarModel?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 53 {
            if let model, model.openedEvent != nil {
                model.closeEvent(keepsFocus: true)
            } else {
                window?.makeFirstResponder(nil)
            }
            return true
        }
        guard let model else { return false }
        switch event.keyCode {
        case 36, 76: return model.openFocusedEvent()
        case 125: return model.moveEventFocus(by: 1)
        case 126: return model.moveEventFocus(by: -1)
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "-": model.moveDayInstantly(by: -1)
        case "=", "+": model.moveDayInstantly(by: 1)
        case "t", "T": model.goToTodayInstantly()
        default: return false
        }
        return true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        String(localized: "Calendar days. Minus for the day before, equals for the day after, T for today. Up and down arrows choose an event, Return shows its details, Escape closes them.")
    }
}

private struct CalendarHeaderGlyph: View {
    let symbol: String
    let help: String
    let label: String
    var shortcut: ActionID?
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle((hovered ? theme.textPrimary : theme.textSecondary).color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .shortcutTip(shortcut, title: help, orHelp: help)
        .accessibilityLabel(label)
    }
}

enum CalendarDayKey {
    case previousDay, today, nextDay

    var tip: ShortcutTip {
        switch self {
        case .previousDay: ShortcutTip(title: String(localized: "Previous day"), keycaps: ["−"])
        case .today: ShortcutTip(title: String(localized: "Today"), keycaps: ["T"])
        case .nextDay: ShortcutTip(title: String(localized: "Next day"), keycaps: ["="])
        }
    }
}

extension View {
    func dayKeyTip(_ key: CalendarDayKey) -> some View {
        let tip = key.tip
        return shortcutTip(tip).accessibilityHint(tip.spokenDetail)
    }
}
