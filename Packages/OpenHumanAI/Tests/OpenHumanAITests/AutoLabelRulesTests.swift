import Foundation
import Testing
@testable import OpenHumanAI

@Suite struct AutoLabelRulesTests {
    typealias M = AutoLabelConversation.Message

    static let me: Set<String> = ["sam@studio.example", "hello@studio.example", "sam rivera"]

    static func conversation(_ subject: String, _ messages: [M]) -> AutoLabelConversation {
        AutoLabelConversation(subject: subject, messages: messages, userIdentities: me)
    }

    static func label(_ c: AutoLabelConversation, model: AutoLabelCategory?) -> AutoLabelCategory? {
        switch AutoLabelRules.evaluate(c) {
        case .decided(let category, _): return category
        case .askModel(let forbidden, _): return AutoLabelRules.resolve(model, forbidden: forbidden)
        }
    }

    @Test func aThankYouToTheUsersOwnAnnouncementIsNeverAPitch() {
        let reply = M(fromUser: false, text: "Thank you so much! On Mon, Oct 12, 2026 at 9:00 AM Sam Rivera "
            + "<hello@studio.example> wrote: Announcing the winners of our spring poster contest")
        let onlyTheReply = Self.conversation("Re: Announcing the winners of our spring poster contest", [reply])
        #expect(AutoLabelRules.evaluate(onlyTheReply) == .decided(nil, .acknowledgement))
        #expect(Self.label(onlyTheReply, model: .pitch) == nil)
        let announcement = M(fromUser: true, text: "Announcing the winners of our spring poster contest")
        let both = Self.conversation("Re: Announcing the winners", [announcement, reply])
        #expect(Self.label(both, model: .pitch) == nil)
        #expect(Self.label(both, model: .marketing) == nil)
        let answered = Self.conversation("Re: Announcing the winners", [announcement, reply,
                                                                         M(fromUser: true, text: "Glad you liked it")])
        #expect(AutoLabelRules.evaluate(answered) == .decided(.waiting, .userWroteLast))
    }

    @Test func aLongerReplyToTheUsersMessageIsNotACategoryForBulkMail() {
        let reply = M(fromUser: false, text: "This is great, my team will try the new templates next month and send "
            + "feedback. On Mon, Oct 12, 2026 at 9:00 AM Sam Rivera <sam@studio.example> wrote: Announcing")
        let c = Self.conversation("Re: Announcing the winners", [reply])
        guard case .askModel(let forbidden, let reasons) = AutoLabelRules.evaluate(c) else {
            Issue.record("a reply with content goes to the model")
            return
        }
        #expect(reasons == [.quotesUser])
        #expect(forbidden == AutoLabelRules.notForConversationsWithTheUser)
        #expect(Self.label(c, model: .pitch) == nil)
        #expect(Self.label(c, model: .news) == nil)
        #expect(Self.label(c, model: .respond) == .respond)
    }

    @Test func aGenuineColdSalesEmailStaysAPitch() {
        let cold = Self.conversation("Grow your pipeline 10x this quarter", [
            M(fromUser: false, text: "Hi Sam, I noticed your studio is hiring. Our platform books qualified meetings "
                + "on autopilot. Do you have 15 minutes this week?"),
        ])
        #expect(AutoLabelRules.evaluate(cold) == .decided(.pitch, .coldOutreach))
        #expect(Self.label(cold, model: .respond) == .pitch)
        let plain = Self.conversation("Hello from a recruiter", [
            M(fromUser: false, text: "Hi Sam, I have a senior design role that might interest you."),
        ])
        #expect(AutoLabelRules.evaluate(plain) == .askModel(forbidden: [], reasons: []))
        #expect(Self.label(plain, model: .pitch) == .pitch)
        let bump = Self.conversation("Re: Grow your pipeline 10x", [
            M(fromUser: false, text: "Just bumping this to the top of your inbox. On Fri, Oct 9, 2026 Alex Seller "
                + "<alex@pipeline.example> wrote: Hi Sam, I noticed your studio is hiring"),
        ])
        #expect(AutoLabelRules.evaluate(bump) == .askModel(forbidden: [], reasons: []))
        #expect(Self.label(bump, model: .pitch) == .pitch)
    }

    @Test func aNewsletterIsTheModelsCall() {
        let newsletter = Self.conversation("This week in type design: five new tools", [
            M(fromUser: false, text: "Welcome to issue 42. This week: variable fonts on the web, a new kerning tool"),
        ])
        #expect(AutoLabelRules.evaluate(newsletter).forbidden.isEmpty)
        #expect(Self.label(newsletter, model: .news) == .news)
    }

    @Test func aVendorReplyTheUserAskedForIsNotAPitch() {
        let c = Self.conversation("Re: Pricing for 20 seats", [
            M(fromUser: true, text: "Hi, could you send pricing for 20 seats?"),
            M(fromUser: false, text: "Here is our pricing for 20 seats, with a 10% discount for annual plans. Happy "
                + "to set up a call to walk you through it."),
        ])
        guard case .askModel(let forbidden, let reasons) = AutoLabelRules.evaluate(c) else {
            Issue.record("the vendor's answer goes to the model")
            return
        }
        #expect(reasons.contains(.userStartedConversation) && reasons.contains(.replyToUser))
        #expect(forbidden.contains(.pitch) && forbidden.contains(.marketing))
        #expect(Self.label(c, model: .pitch) == nil)
        #expect(Self.label(c, model: .respond) == .respond)
        #expect(Self.label(c, model: .invoice) == .invoice)
    }

    @Test func aConversationMostlyFromTheUserIsNeverBulk() {
        let c = Self.conversation("Logo files", [
            M(fromUser: true, text: "Here are the logo files"),
            M(fromUser: true, text: "And the dark version"),
            M(fromUser: false, text: "Looks good, I will forward these to our marketing lead for the launch next week"),
        ])
        let verdict = AutoLabelRules.evaluate(c)
        #expect(verdict.forbidden == AutoLabelRules.notForConversationsWithTheUser)
        guard case .askModel(_, let reasons) = verdict else { return }
        #expect(reasons.contains(.mostlyFromUser) && reasons.contains(.userStartedConversation))
    }

    @Test func acknowledgementsAreShortThanksWithoutAnAsk() {
        for text in ["Thanks!", "thank you so much", "Perfect, thanks!", "Got it, will do.", "Congrats to the winners!",
                     "Merci beaucoup", "Thanks Sam! On Tue, Oct 13, 2026 Sam Rivera <sam@studio.example> wrote: hi"] {
            #expect(AutoLabelRules.isAcknowledgement(text), "\(text)")
        }
        for text in ["Thanks, could you send the invoice?", "Thanks for reaching out, let's schedule a call next week",
                     "Thank you! Please review the attached contract and sign it by Friday",
                     "Great to meet you yesterday at the conference, I wanted to follow up on our chat about hiring",
                     "Hi Sam, quick question about your studio", ""] {
            #expect(!AutoLabelRules.isAcknowledgement(text), "\(text)")
        }
    }

    @Test func quoteHeadersNameTheUserInSeveralLanguages() {
        let me = Self.me
        #expect(AutoLabelRules.quotesUser("Ok. On Mon, Oct 12, 2026 at 9:00 AM <sam@studio.example> wrote: x", identities: me))
        #expect(AutoLabelRules.quotesUser("Danke! Am 12.10.2026 um 09:00 schrieb Sam Rivera <hello@studio.example>: x",
                                          identities: me))
        #expect(AutoLabelRules.quotesUser("Merci ! Le lun. 12 oct. 2026 à 09:00, Sam Rivera a écrit : x", identities: me))
        #expect(AutoLabelRules.quotesUser("Thanks\nFrom: Sam Rivera <sam@studio.example>\nSent: Monday", identities: me))
        #expect(!AutoLabelRules.quotesUser("On Fri Alex Seller <alex@pipeline.example> wrote: hi", identities: me))
        #expect(!AutoLabelRules.quotesUser("On Fri Sam <sam@other.example> wrote: hi", identities: ["sam"]))
        #expect(!AutoLabelRules.quotesUser("No quote here at all", identities: me))
    }

    @Test func replyPartStopsAtQuotedText() {
        #expect(AutoLabelRules.replyPart("Thanks! On Mon, Sam <sam@studio.example> wrote: long text")
            .trimmingCharacters(in: .whitespaces) == "Thanks!")
        #expect(AutoLabelRules.replyPart("Noted\n> earlier text") == "Noted")
        #expect(AutoLabelRules.replyPart("Plain message") == "Plain message")
        #expect(AutoLabelRules.isReplySubject("RE: Contest") && AutoLabelRules.isReplySubject("Aw: Termin"))
        #expect(!AutoLabelRules.isReplySubject("Resume review"))
    }

    @Test func anAcknowledgementOutsideAReplyIsTheModelsCall() {
        let c = Self.conversation("Your order", [M(fromUser: false, text: "Thanks for your order!")])
        #expect(AutoLabelRules.evaluate(c) == .askModel(forbidden: [], reasons: []))
    }

    @Test func anEmptyConversationAsksTheModelWithNoRule() {
        #expect(AutoLabelRules.evaluate(Self.conversation("x", [])) == .askModel(forbidden: [], reasons: []))
        #expect(AutoLabelRules.resolve(nil, forbidden: [.pitch]) == nil)
    }

    @Test func thePromptDefinesPitchWithNegativeExamples() throws {
        let template = try PromptLibrary.standard.template(named: PromptName.autoLabel.rawValue)
        #expect(template.id.version == 3 && AutoLabelPrompt.version == 3)
        #expect(template.body.contains("pitch: an unsolicited message"))
        #expect(template.body.contains("These are never pitch: a reply to a message the user sent"))
        #expect(template.body.contains("respond: a real person writes to the user and directly asks"))
        #expect(template.body.contains("These are never respond: cold sales"))
        #expect(template.body.contains("When you are unsure, choose other. Never choose respond or pitch when unsure."))
        #expect(template.body.hasSuffix(#"{"category":"<the chosen category>"}"#), "no example category to copy")
    }
}
