import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
private let newYork = TimeZone(identifier: "America/New_York")!

private func now() -> Date {
    CalendarDateMentions.calendar(losAngeles).date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 15))!
}

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, _ zone: TimeZone = losAngeles) -> Date {
    CalendarDateMentions.calendar(zone).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private let invitation = """
Garden Club Supper

Friday, December 4
6:00PM PST
Add to calendar

Lantern Hall Rooftop
12 Example Ave
Sampletown, CA 94000

View map
Guest List
View guest list
"""

@Suite struct EmailEventExtractorTests {
    @Test func explicitDateBeatsTheWeekdayWord() throws {
        let facts = try #require(EmailEventExtractor.extract(texts: ["Party", invitation], htmls: [], timeZone: losAngeles, now: now()))
        #expect(facts.start == at(2026, 12, 4, 18))
    }

    @Test func weekdayPicksTheYearOnlyWithinThisYearAndNext() throws {
        let facts = try #require(EmailEventExtractor.extract(texts: ["Fri, Dec 4 at 7pm"], htmls: [], timeZone: losAngeles,
                                                             now: at(2026, 12, 5, 9)))
        #expect(facts.start == at(2027, 12, 4, 19))
        #expect(facts.provenance.contains("2027"))
        #expect(facts.provenance.contains("weekday"))
    }

    @Test func writtenYearAndNumericAndIsoDatesAreRead() throws {
        let a = try #require(EmailEventExtractor.extract(texts: ["Dec 4, 2027 at 2pm"], htmls: [], timeZone: losAngeles, now: now()))
        #expect(a.start == at(2027, 12, 4, 14))
        let b = try #require(EmailEventExtractor.extract(texts: ["on 12/4/2026 from 2pm to 4pm"], htmls: [], timeZone: losAngeles, now: now()))
        #expect(b.start == at(2026, 12, 4, 14) && b.end == at(2026, 12, 4, 16))
        let c = try #require(EmailEventExtractor.extract(texts: ["2026-11-02 09:30"], htmls: [], timeZone: losAngeles, now: now()))
        #expect(c.start == at(2026, 11, 2, 9, 30))
    }

    @Test func namedZoneIsHonouredAndConvertedToTheCalendarZone() throws {
        let facts = try #require(EmailEventExtractor.extract(texts: ["Friday, December 4\n6:00PM PST"], htmls: [],
                                                             timeZone: newYork, now: now()))
        #expect(facts.zoneAbbreviation == "PST")
        #expect(facts.start == at(2026, 12, 4, 21, 0, newYork))
        #expect(facts.provenance.contains("PST"))
        #expect(facts.provenance.contains("From the email:"))
        #expect(facts.provenance.contains("Dec 4"))
        let regional = try #require(EmailEventExtractor.extract(texts: ["Dec 4 at 3pm ET"], htmls: [], timeZone: losAngeles, now: now()))
        #expect(regional.start == at(2026, 12, 4, 12))
    }

    @Test func venueAndAddressBlockBecomesTheLocation() throws {
        let facts = try #require(EmailEventExtractor.extract(texts: [invitation], htmls: [], timeZone: losAngeles, now: now()))
        #expect(facts.location == "Lantern Hall Rooftop, 12 Example Ave, Sampletown, CA 94000")
        let labelled = try #require(EmailEventExtractor.extract(
            texts: ["Dec 4 at 3pm\nLocation: The Test Room, 5 Sample Rd"], htmls: [], timeZone: losAngeles, now: now()))
        #expect(labelled.location == "The Test Room, 5 Sample Rd")
    }

    @Test func addToCalendarMarksAnAnnouncementAndPlainMailIsNot() throws {
        #expect(try #require(EmailEventExtractor.extract(texts: [invitation], htmls: [], timeZone: losAngeles, now: now())).strongSignal)
        let plain = try #require(EmailEventExtractor.extract(texts: ["Lunch on Dec 4 at 1pm?"], htmls: [], timeZone: losAngeles, now: now()))
        #expect(!plain.strongSignal)
    }

    @Test func eventMarkupIsReadFirstAndBeatsFreeText() throws {
        let html = """
        <html><script type="application/ld+json">
        {"@context":"https://schema.org","@type":"SocialEvent","name":"Supper","startDate":"2026-12-04T18:00:00-08:00",
         "endDate":"2026-12-04T20:00:00-08:00",
         "location":{"@type":"Place","name":"Lantern Hall","address":{"streetAddress":"12 Example Ave",
         "addressLocality":"Sampletown","addressRegion":"CA","postalCode":"94000"}}}
        </script></html>
        """
        let facts = try #require(EmailEventExtractor.extract(texts: ["Saturday, January 9\n1pm"], htmls: [html],
                                                             timeZone: losAngeles, now: now()))
        #expect(facts.start == at(2026, 12, 4, 18) && facts.end == at(2026, 12, 4, 20))
        #expect(facts.location == "Lantern Hall, 12 Example Ave, Sampletown, CA 94000")
        #expect(facts.strongSignal)
    }

    @Test func inlineIcsIsReadBeforeWords() throws {
        let ics = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:20261204T020000Z\nDTEND:20261204T040000Z\nLOCATION:Hall\\, 1 Test St\nEND:VEVENT\nEND:VCALENDAR"
        let facts = try #require(EmailEventExtractor.extract(texts: [ics, "Monday, Nov 2 at 9am"], htmls: [],
                                                             timeZone: losAngeles, now: now()))
        #expect(facts.start == at(2026, 12, 3, 18))
        #expect(facts.location == "Hall, 1 Test St")
    }

    @Test func noDateWithATimeMeansNoFacts() {
        #expect(EmailEventExtractor.extract(texts: ["See you Friday", "Order placed Oct 2"], htmls: [], timeZone: losAngeles, now: now()) == nil)
    }
}

@Suite struct EmailEventExtractorReviewTests {
    private func facts(_ texts: [String], now when: Date = now()) throws -> EmailEventFacts {
        try #require(EmailEventExtractor.extract(texts: texts, htmls: [], timeZone: losAngeles, now: when))
    }

    @Test func aDateThenADashAndATimeIsThatTimeNotARange() throws {
        let saturday = try facts(["Saturday, December 4 – 6:00 PM"])
        #expect(saturday.start == at(2027, 12, 4, 18) && saturday.end == nil)
        #expect(saturday.provenance.contains("6:00") && !saturday.provenance.contains("4:00"))
        let short = try facts(["Dec 4 - 10am"])
        #expect(short.start == at(2026, 12, 4, 10) && short.end == nil)
        let midnight = try facts(["Nov 12 - 9am"])
        #expect(midnight.start == at(2026, 11, 12, 9) && midnight.end == nil)
    }

    @Test func aRealRangeAfterTheDateStillWorks() throws {
        let range = try facts(["Dec 4, 6–8pm"])
        #expect(range.start == at(2026, 12, 4, 18) && range.end == at(2026, 12, 4, 20))
    }

    @Test func theNewestMessageWinsOverAQuotedAttributionInAnOlderOne() throws {
        let thread = [
            "Re: Dinner",
            "Sounds good! On Mon, Oct 12, 2026 at 3:00 PM Sample Person <sample@example.test> wrote: > see you then",
            "Moved it: Friday, December 4 at 6pm",
        ]
        #expect(try facts(thread).start == at(2026, 12, 4, 18))
    }

    @Test func aRescheduleInTheNewestMessageWins() throws {
        let thread = ["Re: Sync", "Can we do Dec 4 at 2pm?", "Actually Dec 5 at 3pm works better"]
        #expect(try facts(thread).start == at(2026, 12, 5, 15))
    }

    @Test func anAttributionLineIsNotReadEvenWhenItHasNoYear() throws {
        let thread = [
            "Re: Plan",
            "Lunch on Dec 4 at 1pm?",
            "Yes! On Thu, Sep 3 at 9:15 AM, Sample Person <sample@example.test> wrote: > hello",
        ]
        #expect(try facts(thread).start == at(2026, 12, 4, 13))
    }

    @Test func aPastDateInTheNewestMessageGivesWayToAFutureOne() throws {
        let thread = ["Re: Sync", "Dec 4 at 2pm then?", "Notes from Oct 12, 2026 at 3pm attached"]
        #expect(try facts(thread).start == at(2026, 12, 4, 14))
        #expect(try facts(["Re: Sync", "Notes from Oct 12, 2026 at 3pm attached"]).start == at(2026, 10, 12, 15))
    }

    @Test func theDraftPrefersAFutureMentionOverAPastStatedDate() {
        let thread = CalendarThreadText(subject: "Re: Sync", texts: ["Re: Sync", "Notes from Oct 12, 2026 at 3pm attached"],
                                        participants: [])
        let future = CalendarDateMention(date: at(2026, 12, 4, 14), hasTime: true)
        let draft = CalendarEventDraftBuilder.draft(from: thread, mentions: [future], myAddresses: [], timeZone: losAngeles,
                                                    now: now())
        #expect(draft.start == at(2026, 12, 4, 14))
        #expect(draft.provenance.isEmpty)
    }

    @Test func aWeekdayThatMatchesNeitherYearTakesTheNextDateAndSaysSo() throws {
        let facts = try facts(["Monday, March 3 at 10am"])
        #expect(facts.start == at(2027, 3, 3, 10))
        #expect(facts.provenance.contains("2027"))
        #expect(facts.provenance.contains("weekday"))
    }

    @Test func aMatchingWeekdayNeedsNoNoteAndThisYearShowsNoYear() throws {
        let facts = try facts(["Friday, December 4 at 6pm"])
        #expect(facts.start == at(2026, 12, 4, 18))
        #expect(!facts.provenance.contains("2026") && !facts.provenance.contains("weekday"))
    }
}

@Suite struct EmailEventDraftTests {
    private func person(_ email: String, _ name: String? = nil) -> EmailAddress { EmailAddress(name: name, email: email) }

    @Test func theDraftTakesDateZoneLocationAndNoSenderAsGuest() throws {
        let sender = person("announce@mail.example.test", "Garden Club")
        let me = person("me@example.test")
        let thread = CalendarThreadText(subject: "Garden Club Supper", texts: ["Garden Club Supper", invitation],
                                        participants: [sender, me], senders: [sender.email])
        let draft = CalendarEventDraftBuilder.draft(from: thread, mentions: [], myAddresses: [me.email], timeZone: losAngeles,
                                                    now: now())
        #expect(draft.start == at(2026, 12, 4, 18))
        #expect(draft.end == draft.start.addingTimeInterval(30 * 60))
        #expect(draft.location.hasPrefix("Lantern Hall Rooftop"))
        #expect(draft.attendees.isEmpty)
        #expect(draft.provenance.contains("PST"))
    }

    @Test func automatedSendersAreNeverGuestsAndPeopleAddressedAre() {
        let robot = person("no-reply@example.test")
        let friend = person("pat@example.test", "Pat")
        let me = person("me@example.test")
        let thread = CalendarThreadText(subject: "Lunch", texts: ["Lunch", "Lunch on Dec 4 at 1pm?"],
                                        participants: [robot, friend, me], senders: [robot.email, friend.email])
        let draft = CalendarEventDraftBuilder.draft(from: thread, mentions: [], myAddresses: [me.email], timeZone: losAngeles,
                                                    now: now())
        #expect(draft.attendees.map(\.email) == [friend.email])
    }

    @Test func addressedPeopleOfAnAnnouncementStayButItsSenderGoes() {
        let sender = person("host@example.test")
        let guest = person("kim@example.test")
        let me = person("me@example.test")
        let thread = CalendarThreadText(subject: "Supper", texts: ["Supper", invitation], participants: [sender, me, guest],
                                        senders: [sender.email])
        let draft = CalendarEventDraftBuilder.draft(from: thread, mentions: [], myAddresses: [me.email], timeZone: losAngeles,
                                                    now: now())
        #expect(draft.attendees.map(\.email) == [guest.email])
    }
}
