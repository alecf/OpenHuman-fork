import MailFeatures
import MailModel
import MailRender
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

struct CalendarEventFormView: View {
    @Binding var form: CalendarEventForm
    var rights: CalendarFieldRights
    var timeZone: TimeZone
    var idPrefix: String
    var meetLink: URL?
    var calendarChoices: [(key: String, title: String)] = []
    var titleIsSuggested = false
    var focusesTitle = false
    var asksSendUpdates = false
    var sendUpdates: Binding<CalendarSendUpdates>?
    var calendarName: String = ""

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @FocusState private var titleFocused: Bool
    @State private var guestText = ""
    @State private var guestNote: String?
    @State private var firstNotes: CalendarDescription.Parsed?
    @State private var notesText = ""
    @State private var editingNotes = false

    private var iconColumn: CGFloat { CalendarDraftEditor.iconColumn }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            titleRow
            timeRows
            guestRows
            row(.location, symbol: "mappin.and.ellipse") {
                TextField("Location", text: $form.location).textFieldStyle(.plain)
                    .accessibilityIdentifier("\(idPrefix).location")
            }
            meetRow
            notesRow
            row(.repeats, symbol: "repeat") { repeatPicker }
            row(.reminders, symbol: "bell") { remindersRow }
            row(.busy, symbol: "circle.lefthalf.filled") {
                Picker("Show as", selection: $form.busy) {
                    ForEach(CalendarBusyStatus.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityIdentifier("\(idPrefix).busy")
            }
            row(.visibility, symbol: "eye") {
                Picker("Visibility", selection: $form.visibility) {
                    ForEach(CalendarVisibility.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityIdentifier("\(idPrefix).visibility")
            }
            row(.color, symbol: "paintpalette") { colorRow }
            row(.calendar, symbol: "calendar") { calendarRow }
            if asksSendUpdates, let sendUpdates {
                sendUpdatesRow(sendUpdates)
            }
        }
        .environment(\.timeZone, timeZone)
        .onAppear {
            if firstNotes == nil {
                let parsed = CalendarDescription.parse(form.notes)
                firstNotes = parsed
                notesText = parsed.editableText
            }
            if focusesTitle { titleFocused = true }
        }
    }


    private func row<Content: View>(_ field: CalendarFormField, symbol: String,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        let access = rights.access(field)
        return HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(theme.textTertiary.color)
                .frame(width: iconColumn - theme.space2, alignment: .leading).accessibilityHidden(true)
            content().disabled(access.reason != nil)
        }
        .themeFont(theme.typeMeta)
        .readOnlyReason(access.reason)
    }


    @ViewBuilder
    private var titleRow: some View {
        let access = rights.access(.title)
        VStack(alignment: .leading, spacing: 2) {
            if access.reason == nil {
                TextField("Title", text: $form.title).textFieldStyle(.plain)
                    .themeFont(theme.typeHeadline).foregroundStyle(theme.textPrimary.color)
                    .focused($titleFocused)
                    .padding(.horizontal, theme.space2).padding(.vertical, theme.space1)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill((titleIsSuggested ? theme.accentSubtle : theme.bgWindow).color))
                    .accessibilityIdentifier("\(idPrefix).title")
            } else {
                Text(form.title).themeFont(theme.typeHeadline).foregroundStyle(theme.textPrimary.color)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .readOnlyReason(access.reason)
                    .accessibilityIdentifier("\(idPrefix).title")
            }
        }
    }


    @ViewBuilder
    private var timeRows: some View {
        row(.time, symbol: "clock") {
            VStack(alignment: .leading, spacing: theme.space1) {
                Toggle("All day", isOn: Binding(get: { form.isAllDay }, set: { form.setAllDay($0) }))
                    .toggleStyle(.checkbox).accessibilityIdentifier("\(idPrefix).allDay")
                HStack(spacing: theme.space2) {
                    CalendarDateFieldView(date: form.start, zone: timeZone, idPrefix: "\(idPrefix).startDate") { form.setStart($0) }
                    if !form.isAllDay {
                        DatePicker("Starts", selection: Binding(get: { form.start }, set: { form.setStart($0) }),
                                   displayedComponents: .hourAndMinute).labelsHidden()
                    }
                }
                HStack(spacing: theme.space2) {
                    Text("to").foregroundStyle(theme.textTertiary.color)
                    CalendarDateFieldView(date: form.isAllDay ? form.lastDay : form.end, zone: timeZone,
                                          idPrefix: "\(idPrefix).endDate") { day in
                        if form.isAllDay { form.setLastDay(day) } else { form.setEnd(day) }
                    }
                    if !form.isAllDay {
                        DatePicker("Ends", selection: Binding(get: { form.end }, set: { form.setEnd($0) }),
                                   displayedComponents: .hourAndMinute).labelsHidden()
                    }
                }
            }
        }
        row(.timeZone, symbol: "globe") {
            Picker("Time zone", selection: Binding(get: { form.timeZone }, set: { form.setTimeZone($0) })) {
                ForEach(Self.zoneChoices(including: form.timeZone), id: \.self) { Text(Self.zoneTitle($0)).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            .accessibilityIdentifier("\(idPrefix).timeZone")
        }
    }

    static func zoneChoices(including current: String) -> [String] {
        let all = TimeZone.knownTimeZoneIdentifiers.sorted()
        return all.contains(current) ? all : [current] + all
    }

    static func zoneTitle(_ identifier: String) -> String { identifier.replacingOccurrences(of: "_", with: " ") }


    @ViewBuilder
    private var guestRows: some View {
        let access = rights.access(.guests)
        VStack(alignment: .leading, spacing: theme.space2) {
            row(.guests, symbol: "person.2") {
                TextField("Enter name or email", text: $guestText).textFieldStyle(.plain)
                    .onSubmit { addGuest() }
                    .disabled(access.reason != nil)
                    .accessibilityIdentifier("\(idPrefix).addGuest")
            }
            if let guestNote {
                Text(guestNote).themeFont(theme.typeCaption).foregroundStyle(theme.textWarning.color)
                    .padding(.leading, iconColumn)
            }
            ForEach(form.guests) { guest in
                HStack(spacing: theme.space2) {
                    Text(guest.name.map { "\($0) <\(guest.email)>" } ?? guest.email)
                        .themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1).truncationMode(.middle)
                    if let answer = guest.response, answer != .needsAction {
                        Text(answer.title).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    }
                    Spacer(minLength: 0)
                    Toggle("Optional", isOn: Binding(get: { guest.isOptional }, set: { form.setOptional(guest.email, $0) }))
                        .toggleStyle(.checkbox).themeFont(theme.typeCaption)
                        .disabled(access != .editable)
                        .accessibilityIdentifier("\(idPrefix).optional")
                    if access == .editable {
                        Button { form.removeGuest(guest.email) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(theme.textTertiary.color)
                            .accessibilityLabel("Remove \(guest.name ?? guest.email)")
                    }
                }
                .padding(.leading, iconColumn)
            }
            if !form.guests.isEmpty {
                guestPermissions
            }
        }
    }

    private var guestPermissions: some View {
        let access = rights.access(.guestPermissions)
        return VStack(alignment: .leading, spacing: 2) {
            Toggle("Guests can modify the event", isOn: $form.permissions.canModify)
            Toggle("Guests can invite others", isOn: $form.permissions.canInviteOthers)
            Toggle("Guests can see the guest list", isOn: $form.permissions.canSeeGuestList)
        }
        .toggleStyle(.checkbox).themeFont(theme.typeCaption)
        .disabled(access.reason != nil)
        .readOnlyReason(access.reason)
        .padding(.leading, iconColumn)
        .accessibilityIdentifier("\(idPrefix).guestPermissions")
    }

    private func addGuest() {
        let typed = guestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        guard let address = CalendarDraftEditor.address(typed) else {
            guestNote = String(localized: "Type an email address.")
            return
        }
        guestNote = nil
        guestText = ""
        form.addGuest(address)
    }


    private var meetRow: some View {
        row(.meet, symbol: "video") {
            HStack {
                Toggle("Google Meet", isOn: $form.wantsMeet).toggleStyle(.checkbox)
                    .accessibilityIdentifier("\(idPrefix).meet")
                if form.wantsMeet, let meetLink {
                    Button("Join") { openURL(meetLink) }.buttonStyle(.link)
                        .accessibilityIdentifier("\(idPrefix).joinMeet")
                } else if form.wantsMeet {
                    Text("Link will be added when saved").themeFont(theme.typeCaption)
                        .foregroundStyle(theme.textTertiary.color)
                }
            }
        }
    }


    private var notesRow: some View {
        row(.notes, symbol: "text.alignleft") {
            let parsed = firstNotes ?? CalendarDescription.parse(form.notes)
            if editingNotes {
                TextField("Agenda or notes", text: $notesText, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...8)
                    .onChange(of: notesText) { _, new in
                        form.notes = CalendarDescription.textToWrite(edited: new, from: parsed)
                    }
                    .accessibilityIdentifier("\(idPrefix).notes")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    if CalendarDescription.parse(form.notes).isEmpty {
                        Text("Agenda or notes").foregroundStyle(theme.textTertiary.color)
                    } else {
                        Text(CalendarDescription.attributed(CalendarDescription.parse(form.notes).document))
                            .themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                            .lineLimit(12).textSelection(.enabled)
                            .environment(\.openURL, OpenURLAction { url in
                                guard let safe = CalendarDescription.openableURL(url) else { return .discarded }
                                openURL(safe)
                                return .handled
                            })
                    }
                    Spacer(minLength: 0)
                    Button("Edit") { editingNotes = true }.buttonStyle(.link)
                        .accessibilityIdentifier("\(idPrefix).editNotes")
                }
                .accessibilityIdentifier("\(idPrefix).notes")
            }
        }
    }


    private var repeatPicker: some View {
        let current = CalendarRepeat.preset(of: form.recurrence)
        let choices = CalendarRepeat.Preset.allCases.filter { $0 != .custom || current == .custom }
        return Picker("Repeat", selection: Binding(get: { current }, set: { preset in
            if preset != .custom { form.recurrence = CalendarRepeat.rules(preset) }
        })) {
            ForEach(choices, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
        .accessibilityIdentifier("\(idPrefix).repeat")
    }

    @ViewBuilder
    private var remindersRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch form.reminders {
            case .calendarDefault:
                Text("Calendar default").foregroundStyle(theme.textSecondary.color)
            case .custom(let list):
                if list.isEmpty { Text("No reminders").foregroundStyle(theme.textSecondary.color) }
                ForEach(list) { reminder in
                    HStack {
                        Text("\(reminder.method == .email ? String(localized: "Email") : String(localized: "Pop-up")), \(reminder.text)")
                            .foregroundStyle(theme.textSecondary.color)
                        Button { removeReminder(reminder) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(theme.textTertiary.color)
                            .accessibilityLabel("Remove reminder")
                    }
                }
            }
            HStack {
                Menu("Add reminder") {
                    ForEach(CalendarReminder.presets, id: \.self) { minutes in
                        Button(CalendarReminder(minutesBefore: minutes).text) { addReminder(CalendarReminder(minutesBefore: minutes)) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("\(idPrefix).addReminder")
                Button("Calendar default") { form.reminders = .calendarDefault }.buttonStyle(.link)
                Button("None") { form.reminders = .custom([]) }.buttonStyle(.link)
            }
            .themeFont(theme.typeCaption)
        }
    }

    private func addReminder(_ reminder: CalendarReminder) {
        var list: [CalendarReminder] = []
        if case .custom(let current) = form.reminders { list = current }
        if !list.contains(reminder) { list.append(reminder) }
        form.reminders = .custom(list)
    }

    private func removeReminder(_ reminder: CalendarReminder) {
        guard case .custom(var list) = form.reminders else { return }
        list.removeAll { $0 == reminder }
        form.reminders = .custom(list)
    }

    private var colorRow: some View {
        HStack(spacing: theme.space1) {
            Button { form.colorID = nil } label: {
                Image(systemName: form.colorID == nil ? "circle.inset.filled" : "circle")
            }
            .buttonStyle(.plain).help("The calendar's colour")
            ForEach(1...11, id: \.self) { number in
                let chosen = form.colorID == String(number)
                Button { form.colorID = String(number) } label: {
                    Circle().fill(CalendarDayView.calendarColor(number, theme: theme))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(theme.textPrimary.color, lineWidth: chosen ? 2 : 0))
                }
                .buttonStyle(.plain).help("Colour \(number)")
                .accessibilityLabel("Colour \(number)").accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .accessibilityIdentifier("\(idPrefix).color")
    }

    @ViewBuilder
    private var calendarRow: some View {
        if calendarChoices.count > 1, rights.access(.calendar).reason == nil {
            Picker("Calendar", selection: $form.calendarKey) {
                ForEach(calendarChoices, id: \.key) { Text($0.title).tag($0.key) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            .accessibilityIdentifier("\(idPrefix).calendarPicker")
        } else {
            Text(verbatim: calendarName.isEmpty ? form.calendarKey : calendarName)
                .themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                .lineLimit(1).truncationMode(.middle)
                .accessibilityIdentifier("\(idPrefix).calendar")
        }
    }


    private func sendUpdatesRow(_ choice: Binding<CalendarSendUpdates>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker("Guests", selection: choice) {
                ForEach(CalendarSendUpdatesPolicy.options, id: \.self) { Text(CalendarSendUpdatesPolicy.title($0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityIdentifier("\(idPrefix).sendUpdates")
            Text("Google emails the guests only if you choose so. Undo (⌘Z) stops it for a few seconds.")
                .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
        }
        .padding(.leading, iconColumn)
    }
}

struct CalendarDateFieldView: View {
    var date: Date
    var zone: TimeZone
    var idPrefix: String
    var set: (Date) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool
    private let locale = Locale.current

    var body: some View {
        HStack(spacing: 2) {
            TextField("Date", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 96)
                .focused($focused)
                .onSubmit(commit)
                .onKeyPress(.upArrow) { step(1); return .handled }
                .onKeyPress(.downArrow) { step(-1); return .handled }
                .onChange(of: focused) { _, now in if !now { commit() } }
                .accessibilityIdentifier(idPrefix)
            Stepper("Day", onIncrement: { step(1) }, onDecrement: { step(-1) }).labelsHidden()
        }
        .onAppear { text = shown }
        .onChange(of: date) { _, _ in text = shown }
        .onChange(of: zone) { _, _ in text = shown }
    }

    private var shown: String { CalendarDateField.text(date, zone: zone, locale: locale) }

    private func commit() {
        if let parsed = CalendarDateField.parse(text, keepingTimeOf: date, zone: zone, locale: locale) {
            if parsed != date { set(parsed) }
        }
        text = shown
    }

    private func step(_ days: Int) {
        set(CalendarDateField.stepped(date, byDays: days, zone: zone))
    }
}
