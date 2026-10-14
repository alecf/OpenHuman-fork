import Foundation
import Testing
@testable import OpenHumanAI

@Suite struct RuleEngineParityTests {
    typealias M = AutoLabelConversation.Message
    typealias S = AutoLabelConversation.Signals

    static let me: Set<String> = ["sam@studio.example", "hello@studio.example", "sam rivera"]

    static func legacy(_ c: AutoLabelConversation) -> (decided: AutoLabelCategory??, forbidden: Set<AutoLabelCategory>) {
        switch AutoLabelRules.evaluate(c) {
        case .decided(let category, _): return (.some(category), [])
        case .askModel(let forbidden, _): return (nil, forbidden)
        }
    }

    static func engine(_ c: AutoLabelConversation, _ config: ClassificationConfig = .shipped)
        -> (decided: AutoLabelCategory??, forbidden: Set<AutoLabelCategory>) {
        let verdict = RuleEngine.evaluate(config, RuleSubject(conversation: c))
        if let decided = verdict.decided { return (.some(decided), []) }
        return (nil, verdict.forbidden)
    }

    static let suiteCorpus: [AutoLabelConversation] = {
        func c(_ subject: String, _ messages: [M], _ signals: S = S()) -> AutoLabelConversation {
            AutoLabelConversation(subject: subject, messages: messages, userIdentities: me, signals: signals)
        }
        let reply = M(fromUser: false, text: "Thank you so much! On Mon, Oct 12, 2026 at 9:00 AM Sam Rivera "
            + "<hello@studio.example> wrote: Announcing the winners of our spring poster contest")
        let announcement = M(fromUser: true, text: "Announcing the winners of our spring poster contest")
        var list: [AutoLabelConversation] = [
            c("Re: Announcing the winners of our spring poster contest", [reply]),
            c("Re: Announcing the winners", [announcement, reply]),
            c("Re: Announcing the winners", [announcement, reply, M(fromUser: true, text: "Glad you liked it")]),
            c("Re: Announcing the winners", [M(fromUser: false, text: "This is great, my team will try the new templates "
                + "next month and send feedback. On Mon, Oct 12, 2026 at 9:00 AM Sam Rivera <sam@studio.example> wrote: x")]),
            c("Grow your pipeline 10x this quarter", [M(fromUser: false, text: "Hi Sam, I noticed your studio is hiring. "
                + "Our platform books qualified meetings on autopilot. Do you have 15 minutes this week?")]),
            c("Hello from a recruiter", [M(fromUser: false, text: "Hi Sam, I have a senior design role that might interest you.")]),
            c("Re: Grow your pipeline 10x", [M(fromUser: false, text: "Just bumping this to the top of your inbox. On Fri, "
                + "Oct 9, 2026 Alex Seller <alex@pipeline.example> wrote: Hi Sam, I noticed your studio is hiring")]),
            c("This week in type design: five new tools", [M(fromUser: false, text: "Welcome to issue 42. This week: "
                + "variable fonts on the web, a new kerning tool")]),
            c("Re: Pricing for 20 seats", [M(fromUser: true, text: "Hi, could you send pricing for 20 seats?"),
                                           M(fromUser: false, text: "Here is our pricing for 20 seats, with a 10% discount "
                                             + "for annual plans. Happy to set up a call to walk you through it.")]),
            c("Logo files", [M(fromUser: true, text: "Here are the logo files"), M(fromUser: true, text: "And the dark version"),
                             M(fromUser: false, text: "Looks good, I will forward these to our marketing lead")]),
            c("Your order", [M(fromUser: false, text: "Thanks for your order!")]),
            c("x", []),
        ]
        list += AutoLabelRespondEvalTests.cases.map(\.conversation)
        return list
    }()

    static let texts = [
        "Can you review the draft by Friday?",
        "Thanks!",
        "Hi Sam, we help studios like yours win retainers. Worth a quick call next week?",
        "View in browser. This week: five new tools. Unsubscribe",
        "Ok, sounds good. On Mon, Oct 12, 2026 at 9:00 AM Sam Rivera <sam@studio.example> wrote: the plan",
        "Got it, will do. On Mon, Oct 12, 2026 Sam Rivera <sam@studio.example> wrote: please send it",
        "Fwd below. On Fri, Oct 9 Alex Seller <alex@pipeline.example> wrote: we help teams, quick call?",
    ]

    static let shapes: [[Bool]] = [[], [true], [false], [true, false], [true, true], [false, true, false]]

    static let shapeGrid: [AutoLabelConversation] = {
        var out: [AutoLabelConversation] = []
        for shape in shapes {
            for text in texts {
                for subject in ["Studio update", "Re: Studio update"] {
                    let earlier = shape.map { M(fromUser: $0, text: $0 ? "Here is the plan" : "Earlier note") }
                    out.append(AutoLabelConversation(subject: subject, messages: earlier + [M(fromUser: false, text: text)],
                                                     userIdentities: me))
                    out.append(AutoLabelConversation(subject: subject, messages: earlier + [M(fromUser: true, text: text)],
                                                     userIdentities: me))
                }
            }
        }
        return out
    }()

    static let signalGrid: [AutoLabelConversation] = {
        let bases: [(String, [M])] = [
            ("Studio update", [M(fromUser: false, text: texts[0])]),
            ("Partnership idea", [M(fromUser: false, text: texts[2])]),
            ("Issue 42", [M(fromUser: false, text: texts[3])]),
            ("Re: Studio update", [M(fromUser: true, text: "Here is the plan"), M(fromUser: false, text: texts[0])]),
        ]
        var out: [AutoLabelConversation] = []
        for (subject, messages) in bases {
            for unsubscribe in [false, true] {
                for automated in [false, true] {
                    for recipients in [0, 3, 4, 9, 10] {
                        for inTo in [true, false] {
                            for colleague in [false, true] {
                                for sender in ["", "ana@people.example", "newsletter@letters.example",
                                               "hello@send.example.com", "hello@example.com"] {
                                    let signals = S(hasListUnsubscribe: unsubscribe, automatedSender: automated,
                                                    recipientCount: recipients, userIsRecipient: inTo,
                                                    senderSharesUserDomain: colleague, senderAddress: sender)
                                    out.append(AutoLabelConversation(subject: subject, messages: messages,
                                                                     userIdentities: me, signals: signals))
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }()

    @Test func theDefaultsDecideWhatTheOldRulesDecideOnTheSuitesConversations() {
        #expect(Self.suiteCorpus.count >= 12 + AutoLabelRespondEvalTests.cases.count && AutoLabelRespondEvalTests.cases.count > 10)
        for (index, conversation) in Self.suiteCorpus.enumerated() {
            let old = Self.legacy(conversation), new = Self.engine(conversation)
            #expect(old.decided == new.decided, "case \(index): \(conversation.subject)")
            #expect(old.forbidden == new.forbidden, "case \(index): \(conversation.subject)")
        }
    }

    @Test func theDefaultsDecideWhatTheOldRulesDecideOverTheShapeGrid() {
        var decided = 0
        for (index, conversation) in Self.shapeGrid.enumerated() {
            let old = Self.legacy(conversation), new = Self.engine(conversation)
            #expect(old.decided == new.decided, "shape \(index)")
            #expect(old.forbidden == new.forbidden, "shape \(index)")
            if old.decided != nil { decided += 1 }
        }
        #expect(decided > 0 && decided < Self.shapeGrid.count)
    }

    @Test func theDefaultsDecideWhatTheOldRulesDecideOverTheSignalGrid() {
        var forbidding = 0
        for (index, conversation) in Self.signalGrid.enumerated() {
            let old = Self.legacy(conversation), new = Self.engine(conversation)
            #expect(old.decided == new.decided, "signals \(index)")
            #expect(old.forbidden == new.forbidden, "signals \(index)")
            if !old.forbidden.isEmpty { forbidding += 1 }
        }
        #expect(forbidding > 0 && forbidding < Self.signalGrid.count)
    }

    @Test func theLabelAConversationEndsWithIsTheSameForEveryModelAnswer() {
        for conversation in Self.suiteCorpus + Self.shapeGrid.prefix(40) {
            let old = Self.legacy(conversation), new = Self.engine(conversation)
            for answer in [nil] + AutoLabelCategory.modelCategories {
                let oldLabel = old.decided ?? AutoLabelRules.resolve(answer, forbidden: old.forbidden)
                let newLabel = new.decided ?? AutoLabelRules.resolve(answer, forbidden: new.forbidden)
                #expect(oldLabel == newLabel)
            }
        }
    }

    @Test func theStoredShippedConfigDecidesTheSame() throws {
        let stored = try ClassificationConfig.decode(try ClassificationConfig.shipped.json())
        #expect(stored == .shipped)
        for conversation in Self.suiteCorpus {
            #expect(Self.engine(conversation, stored).decided == Self.legacy(conversation).decided)
            #expect(Self.engine(conversation, stored).forbidden == Self.legacy(conversation).forbidden)
        }
    }
}
