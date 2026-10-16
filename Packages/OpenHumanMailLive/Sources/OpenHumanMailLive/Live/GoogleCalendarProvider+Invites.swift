import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail

extension GoogleCalendarProvider {
    func invitedEvent(_ query: CalendarInviteQuery, wholeSeries: Bool) async throws -> CalendarEvent? {
        let (from, to) = query.window
        do {
            let byUID = (try? await client.inviteCandidates(iCalUID: query.uid, from: from, to: to)) ?? []
            var picked = Self.pick(byUID, query)
            if case .missing = picked {
                picked = Self.pick(try await client.inviteCandidates(iCalUID: nil, from: from, to: to), query)
            }
            switch picked {
            case .found(let candidate):
                let event = Self.event(candidate.event)
                return wholeSeries ? event.seriesReference : event
            case .missing:
                return nil
            case .ambiguous:
                throw CalendarError.refused(CalendarInviteQuery.ambiguousRefusal)
            }
        } catch let error as CalendarError {
            throw error
        } catch {
            throw Self.calendarError(error, doing: "find the invitation")
        }
    }

    static func pick(_ candidates: [GoogleInviteCandidate], _ query: CalendarInviteQuery)
        -> CalendarInviteQuery.Pick<GoogleInviteCandidate> {
        query.pick(candidates, start: \.event.start, uid: \.iCalUID,
                   looksLike: { query.looksLike(title: $0.event.title, organizer: $0.organizerEmail) })
    }
}
