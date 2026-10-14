import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

struct CalendarEventCardView: View {
    @Bindable var model: CalendarWindowModel
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let card = model.card, card.form != nil {
            formBody(card)
        } else if let card = model.card {
            VStack(alignment: .leading, spacing: theme.space3) {
                title(card)
                timeRow(card)
                attendees(card)
                if let link = card.event.meetLink {
                    fieldRow(symbol: "video") {
                        Button("Join Google Meet") { openURL(link) }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("calendar.card.meet")
                    }
                }
                place(card)
                notes(card)
                fieldRow(symbol: "calendar") {
                    HStack(spacing: theme.space2) {
                        Circle().fill(CalendarDayView.calendarColor(model.colorIndex(for: card.event), theme: theme))
                            .frame(width: 8, height: 8)
                        Text(verbatim: card.calendarKey.isEmpty ? model.sidebar.providerName : card.calendarKey)
                            .themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .accessibilityIdentifier("calendar.card.calendar")
                if card.event.canRespond { answers(card) }
                notesAndReasons(card)
                actions(card)
            }
            .padding(theme.space4)
            .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgWindow.color))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
                .strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
            .onExitCommand { model.closeCard() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(card.event.title)
            .accessibilityIdentifier("calendar.card")
        }
    }

    @ViewBuilder
    private func title(_ card: CalendarEventCard) -> some View {
        if card.canEditDetails {
            TextField("Title", text: binding(\.title, card))
                .textFieldStyle(.plain)
                .themeFont(theme.typeHeadline).foregroundStyle(theme.textPrimary.color)
                .accessibilityIdentifier("calendar.card.title")
        } else {
            Text(card.event.title).themeFont(theme.typeHeadline).foregroundStyle(theme.textPrimary.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .readOnlyReason(card.reason)
                .accessibilityIdentifier("calendar.card.title")
        }
    }

    private func timeRow(_ card: CalendarEventCard) -> some View {
        fieldRow(symbol: "clock") {
            if card.canMove {
                VStack(alignment: .leading, spacing: theme.space1) {
                    DatePicker("Day", selection: startBinding(card), displayedComponents: .date).labelsHidden()
                    HStack(spacing: theme.space2) {
                        DatePicker("Starts", selection: startBinding(card), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        Text(verbatim: "–").foregroundStyle(theme.textTertiary.color)
                        DatePicker("Ends", selection: binding(\.end, card), in: card.start...,
                                   displayedComponents: .hourAndMinute).labelsHidden()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.event.start.formatted(Date.FormatStyle(timeZone: model.timeZone)
                        .weekday(.wide).month(.wide).day()))
                        .themeFont(theme.typeMeta).foregroundStyle(theme.textPrimary.color)
                    Text(model.timeText(card.event)).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                }
                .readOnlyReason(card.reason)
            }
        }
        .accessibilityIdentifier("calendar.card.time")
    }

    @ViewBuilder
    private func attendees(_ card: CalendarEventCard) -> some View {
        if !card.event.attendees.isEmpty {
            fieldRow(symbol: "person.2") {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(card.event.attendees, id: \.email) { person in
                        Text(person.name.map { "\($0) <\(person.email)>" } ?? person.email)
                            .themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .accessibilityIdentifier("calendar.card.attendees")
        }
    }

    @ViewBuilder
    private func place(_ card: CalendarEventCard) -> some View {
        if card.canEditDetails {
            fieldRow(symbol: "mappin.and.ellipse") {
                TextField("Location", text: binding(\.location, card)).textFieldStyle(.plain)
                    .accessibilityIdentifier("calendar.card.location")
            }
        } else if let location = card.event.location {
            fieldRow(symbol: "mappin.and.ellipse") {
                Text(location).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func notes(_ card: CalendarEventCard) -> some View {
        if card.canEditDetails {
            fieldRow(symbol: "text.alignleft") {
                TextField("Agenda or notes", text: binding(\.notes, card), axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...6)
                    .accessibilityIdentifier("calendar.card.notes")
            }
        } else if let notes = card.event.notes {
            fieldRow(symbol: "text.alignleft") {
                Text(notes).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                    .lineLimit(8).textSelection(.enabled)
            }
        }
    }

    private func answers(_ card: CalendarEventCard) -> some View {
        HStack(spacing: theme.space2) {
            Text("Going?").themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
            ForEach(CalendarResponse.choices, id: \.self) { choice in
                let chosen = card.response == choice
                Button { Task { await model.respond(choice) } } label: {
                    Text(choice.title).themeFont(theme.typeMeta)
                        .foregroundStyle((chosen ? theme.accentOnFill : theme.textPrimary).color)
                        .padding(.horizontal, theme.space3).padding(.vertical, 3)
                        .background(Capsule().fill((chosen ? theme.accentFill : theme.bgSunken).color))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!card.canRespond)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityIdentifier("calendar.card.rsvp.\(choice.rawValue)")
            }
        }
        .help(card.canRespond ? String(localized: "Google tells the organizer after a few seconds (Undo ⌘Z stops it).")
                              : (card.reason ?? ""))
    }

    @ViewBuilder
    private func notesAndReasons(_ card: CalendarEventCard) -> some View {
        if card.reason == nil, card.hasChanges, card.emailsPeople {
            Text("Saved after a few seconds, so Undo (⌘Z) can stop it. Google emails the attendees.")
                .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
        }
        if let note = card.note, note != card.reason {
            Text(note).themeFont(theme.typeMeta).foregroundStyle(theme.textDanger.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actions(_ card: CalendarEventCard) -> some View {
        HStack(spacing: theme.space3) {
            if card.canMove || card.canEditDetails {
                Button("Save") { Task { await model.saveCard() } }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accentFill.color)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!card.hasChanges)
                    .help("Save the changes  ⌘↵")
                    .accessibilityIdentifier("calendar.card.save")
            }
            Button(card.canMove || card.canEditDetails ? "Cancel" : "Close") { model.closeCard() }
                .help("Esc")
                .accessibilityIdentifier("calendar.card.cancel")
            Spacer(minLength: 0)
            if card.canRemove {
                Button(role: .destructive) { model.askToRemoveCardEvent() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.textDanger.color)
                .help("Delete the event (asks first; Undo ⌘Z for a few seconds)")
                .accessibilityLabel("Delete event")
                .accessibilityIdentifier("calendar.card.delete")
            }
        }
    }


    private func formBody(_ card: CalendarEventCard) -> some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            if let move = card.pendingMove { pendingHeader(move, card) }
            CalendarEventFormView(
                form: Binding(get: { model.card?.form ?? card.form! }, set: { model.card?.form = $0 }),
                rights: card.rights, timeZone: model.cardTimeZone, idPrefix: "calendar.card",
                meetLink: card.event.meetLink,
                calendarChoices: model.sources.map { (key: $0.key, title: $0.title) },
                asksSendUpdates: model.asksSendUpdates(for: card),
                sendUpdates: Binding(get: { model.sendUpdates(for: model.card ?? card) },
                                     set: { model.chooseSendUpdates($0) }),
                calendarName: card.calendarKey.isEmpty ? model.sidebar.providerName : card.calendarKey)
                .id(card.event.id)
            if card.event.canRespond { answers(card) }
            if let note = card.note, note != card.rights.summary {
                Text(note).themeFont(theme.typeMeta).foregroundStyle(theme.textDanger.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("calendar.card.note")
            }
            formActions(card)
        }
        .padding(theme.space4)
        .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgWindow.color))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
            .strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
        .onExitCommand { model.closeCard() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.event.title)
        .accessibilityIdentifier("calendar.card")
    }

    private func pendingHeader(_ move: CalendarPendingMove, _ card: CalendarEventCard) -> some View {
        let shown = card.form
        return VStack(alignment: .leading, spacing: 2) {
            Text(move.kind == .resized ? "Change the length?" : "Move this event?")
                .themeFont(theme.typeHeadline).foregroundStyle(theme.textPrimary.color)
            Text("From  \(CalendarPendingMove.line(move.originalStart, move.originalEnd, zone: model.cardTimeZone))")
                .themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
            Text("To  \(CalendarPendingMove.line(shown?.start ?? move.proposedStart, shown?.end ?? move.proposedEnd, zone: model.cardTimeZone))")
                .themeFont(theme.typeMeta).foregroundStyle(theme.textPrimary.color)
            Text("Nothing changes and nobody is told until you accept. Change the length or anything else below first.")
                .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
        }
        .accessibilityIdentifier("calendar.card.pendingMove")
    }

    private func formActions(_ card: CalendarEventCard) -> some View {
        let editable = card.rights.hasAnyEditable
        let accepting = card.pendingMove != nil
        return HStack(spacing: theme.space3) {
            if editable {
                Button(accepting ? "Accept" : "Save") { Task { await model.saveCard() } }
                    .buttonStyle(.borderedProminent).tint(theme.accentFill.color)
                    .keyboardShortcut(accepting ? .defaultAction : KeyboardShortcut(.return, modifiers: .command))
                    .disabled(!card.hasChanges)
                    .help(accepting ? "Accept the change  ↵" : "Save the changes  ⌘↵")
                    .accessibilityIdentifier(accepting ? "calendar.card.accept" : "calendar.card.save")
            }
            Button(editable ? "Cancel" : "Close") { model.closeCard() }
                .help("Esc").accessibilityIdentifier("calendar.card.cancel")
            Spacer(minLength: 0)
            if card.event.id.isEmpty == false, card.rights.hasAnyEditable {
                Button { Task { await model.duplicateCardEvent() } } label: { Image(systemName: "plus.square.on.square") }
                    .buttonStyle(.borderless).help("Duplicate this event")
                    .accessibilityLabel("Duplicate event").accessibilityIdentifier("calendar.card.duplicate")
            }
            switch card.rights.delete {
            case .delete:
                Button(role: .destructive) { model.askToRemoveCardEvent() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(theme.textDanger.color)
                    .help("Delete the event (asks first; Undo ⌘Z for a few seconds)")
                    .accessibilityLabel("Delete event").accessibilityIdentifier("calendar.card.delete")
            case .declineInstead(let why):
                Button("Decline") { Task { await model.declineInsteadOfDelete() } }
                    .help(why).accessibilityIdentifier("calendar.card.decline")
            case .unavailable(let why):
                Image(systemName: "trash").foregroundStyle(theme.textTertiary.color).help(why)
                    .accessibilityLabel("Delete unavailable: \(why)").accessibilityIdentifier("calendar.card.deleteDisabled")
            }
        }
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

    private func binding<Value>(_ path: WritableKeyPath<CalendarEventCard, Value>,
                                _ shown: CalendarEventCard) -> Binding<Value> {
        Binding(get: { (model.card ?? shown)[keyPath: path] }, set: { model.card?[keyPath: path] = $0 })
    }

    private func startBinding(_ shown: CalendarEventCard) -> Binding<Date> {
        Binding(get: { (model.card ?? shown).start }, set: { start in
            guard var card = model.card else { return }
            let length = max(card.end.timeIntervalSince(card.start), CalendarDragMath.step)
            card.start = start
            card.end = start.addingTimeInterval(length)
            model.card = card
        })
    }
}

extension View {
    @ViewBuilder
    func readOnlyReason(_ reason: String?) -> some View {
        if let reason, !reason.isEmpty {
            self.help(reason).accessibilityHint(reason)
        } else {
            self
        }
    }
}
