import Foundation
import MailActions
import MailModel

extension CalendarWindowModel {
    public var cardTimeZone: TimeZone { timeZone }


    func saveFormCard(_ current: CalendarEventCard) async {
        var current = current
        let patch = current.formPatch
        if let why = current.rights.firstViolation(of: patch) {
            current.note = why
            card = current
            return
        }
        if let problem = current.form?.problem {
            current.note = problem
            card = current
            return
        }
        let scopes = CalendarRecurrenceScope.options(for: current.event, patch: patch)
        if !scopes.isEmpty {
            var question = CalendarScopeQuestion(eventID: current.event.id, action: .save)
            question.scopes = scopes
            scopeQuestion = question
            return
        }
        await commitPatch(current, patch, scope: .thisEvent)
    }

    public func answerRecurrenceScope(_ scope: CalendarRecurrenceScope) async {
        guard let question = scopeQuestion, question.action == .save, let current = card, current.form != nil else {
            scopeQuestion = nil
            return
        }
        scopeQuestion = nil
        await commitPatch(current, current.formPatch, scope: scope)
    }

    public func chooseSendUpdates(_ choice: CalendarSendUpdates) {
        card?.sendUpdatesChoice = choice
    }

    public func sendUpdates(for card: CalendarEventCard) -> CalendarSendUpdates {
        let patch = card.formPatch
        return CalendarSendUpdatesPolicy.effective(chosen: card.sendUpdatesChoice,
                                                   hasOtherGuests: !card.event.attendees.isEmpty || !patch.guestsAdded.isEmpty,
                                                   patch: patch)
    }

    public func asksSendUpdates(for card: CalendarEventCard) -> Bool {
        let patch = card.formPatch
        return CalendarSendUpdatesPolicy.needsChoice(hasOtherGuests: !card.event.attendees.isEmpty || !patch.guestsAdded.isEmpty,
                                                     patch: patch)
    }

    func commitPatch(_ current: CalendarEventCard, _ patch: CalendarEventPatch, scope: CalendarRecurrenceScope) async {
        guard let target = provider(for: current.event).provider else { return }
        let event = current.event
        let key = current.calendarKey
        let zone = timeZone.identifier
        let others = !event.attendees.isEmpty || !patch.guestsAdded.isEmpty
        let updates = CalendarSendUpdatesPolicy.effective(chosen: current.sendUpdatesChoice, hasOtherGuests: others, patch: patch)
        let id = UUID()
        if let time = patch.time { overlays[id] = .times(id: event.id, start: time.start, end: time.end) }
        closeCard()
        if others, patch.touchesGuests {
            let line = updates == .all ? String(localized: "Saving \(event.title)… Google emails the guests.")
                                       : String(localized: "Saving \(event.title)…")
            hold(id, title: line) { [weak self] in
                do {
                    let latest = try await target.patchEvent(event, with: patch, scope: scope, sendUpdates: updates)
                    self?.store(latest, replacing: event)
                } catch {
                    self?.failed(String(localized: "Couldn't save \(event.title). \(CalendarSidebarModel.message(error))"), id)
                    return
                }
                await self?.changed(id, line: updates == .all
                                    ? String(localized: "Saved \(event.title). Google emailed the guests.")
                                    : String(localized: "Saved \(event.title)."))
            }
            return
        }
        let latest: CalendarEvent
        do {
            latest = try await target.patchEvent(event, with: patch, scope: scope, sendUpdates: .none)
            store(latest, replacing: event)
        } catch {
            failed(String(localized: "Couldn't save \(event.title). \(CalendarSidebarModel.message(error))"), id)
            return
        }
        let back = CalendarEventForm(event: event, calendarKey: key, defaultZone: zone)
            .diff(against: CalendarEventForm(event: latest, calendarKey: key, defaultZone: zone))
        offerUndo(String(localized: "Saved \(event.title).")) { [weak self] in
            let restored = try await target.patchEvent(latest, with: back, scope: scope, sendUpdates: .none)
            self?.store(restored, replacing: event)
        }
        await changed(id, line: nil)
    }


    public func declineInsteadOfDelete() async {
        guard case .declineInstead = card?.rights.delete else { return }
        await respond(.declined)
    }

    public func duplicateCardEvent() async {
        guard let current = card, let form = current.form else { return }
        let copy = form.duplicateDraft()
        closeCard()
        await newEvent(start: copy.start, end: copy.end)
        guard let made = sidebar.draft else { return }
        var merged = copy
        merged.sendUpdates = made.sendUpdates
        sidebar.draft = merged
    }


    var confirmsMoves: Bool {
        get async {
            if let confirmsMovesOverride { return confirmsMovesOverride }
            return await read(AppSettings.calendarConfirmMoves)
        }
    }

    func beginPendingMove(_ event: CalendarEvent, start: Date, end: Date) {
        openEvent(event)
        guard var opened = card else { return }
        opened.pendingMove = CalendarPendingMove(event: event, proposedStart: start, proposedEnd: end)
        opened.start = start
        opened.end = opened.pendingMove?.proposedEnd ?? end
        if opened.form != nil {
            opened.form?.start = opened.start
            opened.form?.end = opened.end
        }
        card = opened
    }

    public func acceptPendingMove() async { await saveCard() }

    public func cancelPendingMove() { closeCard() }
}
