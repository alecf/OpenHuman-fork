import Foundation
import Testing
import OpenHumanCore

@Suite struct EventMailSignalsTests {
    @Test func googleCalendarMailIsAnEventWhateverTheSubject() {
        let google = "calendar-notification@google.com"
        for subject in ["Invitation: Planning @ Mon Oct 12, 2026 10am - 11am (UTC) (sam@example.com)",
                        "Updated invitation: Planning @ Tue Oct 13, 2026", "Canceled event: Planning",
                        "Accepted: Planning @ Mon Oct 12, 2026", "Declined: Planning", "Reminder: Planning"] {
            #expect(EventMailSignals.headersSuggestEvent(fromEmail: google, subject: subject), "\(subject)")
            #expect(EventMailSignals.shouldCheckForInvite(fromEmail: google, subject: subject), "\(subject)")
        }
        #expect(EventMailSignals.headersSuggestEvent(fromEmail: "Calendar-Notification@Google.com", subject: "x"))
    }

    @Test func invitationPrefixesCountFromAnySender() {
        for subject in ["Invitation: design review", "UPDATED INVITATION: design review", "Canceled event: standup",
                        "Fwd: Invitation: design review", "Re: invitation: lunch", "  Fw: Canceled event: retro"] {
            #expect(EventMailSignals.headersSuggestEvent(fromEmail: "alex@example.org", subject: subject), "\(subject)")
            #expect(EventMailSignals.shouldCheckForInvite(fromEmail: "alex@example.org", subject: subject), "\(subject)")
        }
    }

    @Test func rsvpAnswersCountOnlyFromTheCalendarSender() {
        #expect(!EventMailSignals.headersSuggestEvent(fromEmail: "jobs@example.org", subject: "Accepted: your application"))
        #expect(!EventMailSignals.headersSuggestEvent(fromEmail: "bank@example.org", subject: "Reminder: payment due"))
    }

    @Test func eventPlatformsMatchTheirDomainAndSubdomains() {
        for from in ["hello@lu.ma", "notify@luma-mail.com", "noreply@eventbrite.com", "orders@mail.eventbrite.com",
                     "info@meetup.com", "hi@partiful.com"] {
            #expect(EventMailSignals.headersSuggestEvent(fromEmail: from, subject: "Your ticket"), "\(from)")
            #expect(!EventMailSignals.shouldCheckForInvite(fromEmail: from, subject: "Your ticket"), "\(from)")
        }
        #expect(!EventMailSignals.headersSuggestEvent(fromEmail: "x@notmeetup.com", subject: "Weekly digest"))
        #expect(!EventMailSignals.headersSuggestEvent(fromEmail: "x@meetup.com.example.net", subject: "Weekly digest"))
    }

    @Test func eventPhrasesInTheSubject() {
        for subject in ["You are invited to the launch party", "You\u{2019}re invited: demo night", "RSVP by Friday",
                        "Join us for a fireside chat", "Webinar: shipping faster"] {
            #expect(EventMailSignals.headersSuggestEvent(fromEmail: "team@example.com", subject: subject), "\(subject)")
            #expect(!EventMailSignals.shouldCheckForInvite(fromEmail: "team@example.com", subject: subject), "\(subject)")
        }
    }

    @Test func ordinaryMailIsNotAnEvent() {
        for (from, subject) in [("pat@example.com", "Quarterly numbers"), ("billing@example.com", "Your invoice"),
                                ("news@example.com", "This week in review"), ("pat@example.com", "Invitations are out")] {
            #expect(!EventMailSignals.headersSuggestEvent(fromEmail: from, subject: subject), "\(subject)")
            #expect(!EventMailSignals.shouldCheckForInvite(fromEmail: from, subject: subject), "\(subject)")
        }
        #expect(!EventMailSignals.headersSuggestEvent(fromEmail: nil, subject: nil))
    }

    @Test func theMeetingAutoLabelIsTheEventLabel() {
        #expect(EventMailSignals.labelNames == ["OpenHuman/Meeting", "[Superhuman]/AI/Meeting"])
        #expect(EventMailSignals.isEventLabelName("openhuman/meeting"))
        #expect(EventMailSignals.isEventLabelName("[superhuman]/ai/MEETING"))
        #expect(!EventMailSignals.isEventLabelName("OpenHuman/Travel"))
        #expect(OHGmailLabels.canonicalAutoLabelCategory(EventMailSignals.autoLabelCategory) == "Meeting")
    }
}
