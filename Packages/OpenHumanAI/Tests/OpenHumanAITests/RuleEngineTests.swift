import Foundation
import Testing
@testable import OpenHumanAI

@Suite struct RuleEngineTests {
    typealias M = AutoLabelConversation.Message
    typealias S = AutoLabelConversation.Signals

    static let me: Set<String> = ["sam@studio.example", "sam rivera"]

    static func subject(_ messages: [M], signals: S = S(), listID: String? = nil, account: String? = nil,
                        labels: [String] = []) -> RuleSubject {
        titled("Studio update", messages, signals: signals, listID: listID, account: account, labels: labels)
    }

    static func titled(_ subject: String, _ messages: [M], signals: S = S(), listID: String? = nil,
                       account: String? = nil, labels: [String] = []) -> RuleSubject {
        RuleSubject(conversation: AutoLabelConversation(subject: subject, messages: messages, userIdentities: me,
                                                        signals: signals),
                    account: account, listID: listID, gmailLabels: labels)
    }

    static let plain = [M(fromUser: false, text: "Can you review the draft by Friday?")]
    static let bulkSignals = S(hasListUnsubscribe: true, recipientCount: 1)

    static func userRule(_ id: String, _ when: RuleCondition, _ then: RuleAction, enabled: Bool = true,
                         account: String? = nil) -> ClassificationRule {
        ClassificationRule(id: id, title: id, enabled: enabled, account: account, when: when, then: then)
    }

    @Test func aUserRuleDecidesBeforeTheDefaults() {
        let rule = Self.userRule("user.news", .fact(.listID, "contains", .text("letters.example")), .setLabel(.news))
        let config = ClassificationConfig(rules: [rule])
        let verdict = RuleEngine.evaluate(config, Self.subject(Self.plain, listID: "weekly.letters.example"))
        #expect(verdict.outcome == .decided(.news))
        #expect(verdict.decidingRuleID == "user.news")
        #expect(RuleEngine.evaluate(config, Self.subject(Self.plain)).outcome == .askModel)
    }

    @Test func aUserRuleBeatsADefaultSetLabel() {
        let rule = Self.userRule("user.respond", .fact(.sender, "equals", .text("ana@people.example")), .setLabel(.respond))
        let messages = [M(fromUser: false, text: "Hi"), M(fromUser: true, text: "Answer")]
        let verdict = RuleEngine.evaluate(ClassificationConfig(rules: [rule]),
                                          Self.subject(messages, signals: S(senderAddress: "ana@people.example")))
        #expect(verdict.outcome == .decided(.respond))
        #expect(verdict.matches.first { $0.ruleID == DefaultRules.waiting }?.effect == .noEffect)
    }

    @Test func aUserForbidOverridesADefaultSetLabelAndTheModelIsAsked() {
        let cold = [M(fromUser: false, text: "Hi Sam, we help studios like yours win retainers. Worth a quick call?")]
        #expect(RuleEngine.evaluate(.shipped, Self.subject(cold)).outcome == .decided(.pitch))
        let rule = Self.userRule("user.notpitch", .fact(.sender, "domain", .text("people.example")), .forbidLabels([.pitch]))
        let verdict = RuleEngine.evaluate(ClassificationConfig(rules: [rule]),
                                          Self.subject(cold, signals: S(senderAddress: "ana@people.example")))
        #expect(verdict.outcome == .askModel)
        #expect(verdict.forbidden.contains(.pitch))
        #expect(verdict.matches.contains(RuleMatch(ruleID: DefaultRules.coldOutreach, effect: .overridden, categories: [.pitch])))
    }

    @Test func aRejectionForTheConversationBeatsAUserSetLabel() {
        let rule = Self.userRule("user.news", .fact(.listID, "contains", .text("letters")), .setLabel(.news))
        let verdict = RuleEngine.evaluate(ClassificationConfig(rules: [rule]), Self.subject(Self.plain, listID: "letters.example"),
                                          rejected: [.news])
        #expect(verdict.outcome == .decided(nil))
        #expect(verdict.matches.first?.effect == .rejected)
        let off = ClassificationConfig(rules: [rule]).settingDefault(DefaultRules.threadRejections, enabled: false)
        #expect(RuleEngine.evaluate(off, Self.subject(Self.plain, listID: "letters.example"), rejected: [.news]).outcome
            == .decided(.news))
    }

    @Test func forbidsAccumulateWithWhoForbadeWhat() {
        let rule = Self.userRule("user.notsocial", .all([]), .forbidLabels([.social]))
        let verdict = RuleEngine.evaluate(ClassificationConfig(rules: [rule]), Self.subject(Self.plain, signals: Self.bulkSignals),
                                          rejected: [.travel], senderRejected: [.invoice])
        #expect(verdict.outcome == .askModel)
        #expect(verdict.forbidden == [.social, .respond, .travel, .invoice])
        #expect(verdict.forbiddenBy["user.notsocial"] == [.social])
        #expect(verdict.forbiddenBy[DefaultRules.bulkNeverRespond] == [.respond])
        #expect(verdict.forbiddenBy[DefaultRules.threadRejections] == [.travel])
        #expect(verdict.forbiddenBy[DefaultRules.senderRejections] == [.invoice])
        #expect(verdict.resolve(.respond) == nil && verdict.resolve(.meeting) == .meeting)
        let off = ClassificationConfig(rules: [rule]).settingDefault(DefaultRules.senderRejections, enabled: false)
        #expect(!RuleEngine.evaluate(off, Self.subject(Self.plain), senderRejected: [.invoice]).forbidden.contains(.invoice))
    }

    @Test func aDisabledRuleIsSkipped() {
        let bulk = Self.subject(Self.plain, signals: Self.bulkSignals)
        #expect(RuleEngine.evaluate(.shipped, bulk).forbidden.contains(.respond))
        let off = ClassificationConfig.shipped.settingDefault(DefaultRules.bulkNeverRespond, enabled: false)
        #expect(!RuleEngine.evaluate(off, bulk).forbidden.contains(.respond))
        let disabled = Self.userRule("user.x", .all([]), .setLabel(.travel), enabled: false)
        #expect(RuleEngine.evaluate(ClassificationConfig(rules: [disabled]), Self.subject(Self.plain)).outcome == .askModel)
    }

    @Test func editedParametersChangeWhatADefaultSees() {
        let reply = Self.titled("Re: Contest", [M(fromUser: false, text: "Muchas gracias amigo")])
        #expect(RuleEngine.evaluate(.shipped, reply).outcome == .decided(nil))
        let edited = ClassificationConfig.shipped.settingDefault(DefaultRules.acknowledgement,
                                                                 params: RuleParams(acknowledgementPhrases: ["thanks"]))
        #expect(edited.defaultRule(DefaultRules.acknowledgement)?.edited == true)
        #expect(RuleEngine.evaluate(edited, reply).outcome == .askModel)
        let five = Self.subject(Self.plain, signals: S(recipientCount: 5))
        #expect(!RuleEngine.evaluate(.shipped, five).forbidden.contains(.respond))
        let lower = ClassificationConfig.shipped.settingDefault(DefaultRules.bulkNeverRespond, params: RuleParams(massRecipients: 5))
        #expect(RuleEngine.evaluate(lower, five).forbidden.contains(.respond))
        let reset = lower.settingDefault(DefaultRules.bulkNeverRespond, params: nil)
        #expect(reset == .shipped && reset.digest == ClassificationConfig.shipped.digest)
    }

    @Test func anAccountScopedRuleMatchesOnlyThatAccount() {
        let rule = Self.userRule("user.work", .all([]), .setLabel(.meeting), account: "sam@studio.example")
        let config = ClassificationConfig(rules: [rule])
        #expect(RuleEngine.evaluate(config, Self.subject(Self.plain, account: "SAM@studio.example")).outcome == .decided(.meeting))
        #expect(RuleEngine.evaluate(config, Self.subject(Self.plain, account: "sam@home.example")).outcome == .askModel)
        #expect(RuleEngine.evaluate(config, Self.subject(Self.plain)).outcome == .askModel)
    }

    @Test func theBulkMacroBoundaryIsTenRecipients() {
        let nine = Self.subject(Self.plain, signals: S(recipientCount: 9))
        let ten = Self.subject(Self.plain, signals: S(recipientCount: 10))
        #expect(!RuleEngine.value(of: RulePredicate(.bulk), nine))
        #expect(RuleEngine.value(of: RulePredicate(.bulk), ten))
        #expect(RuleEngine.value(of: RulePredicate(.bulk), Self.subject(Self.plain, signals: S(userIsRecipient: false))))
        #expect(RuleEngine.value(of: RulePredicate(.bulk), Self.subject(Self.plain, signals: S(automatedSender: true))))
        #expect(RuleEngine.value(of: RulePredicate(.bulk), Self.subject(Self.plain, signals: S(senderAddress: "newsletter@x.example"))))
    }

    @Test func everyPredicateReadsItsFact() {
        func v(_ p: RulePredicate, _ s: RuleSubject) -> Bool { RuleEngine.value(of: p, s) }
        let thread = [M(fromUser: true, text: "Plan"), M(fromUser: false, text: "Ok. On Mon Sam Rivera <sam@studio.example> wrote: Plan")]
        let s = Self.titled("Re: Plan", thread, signals: S(hasListUnsubscribe: true, automatedSender: true, recipientCount: 4,
                                                             userIsRecipient: true, senderSharesUserDomain: true,
                                                             senderAddress: "ana@team.studio.example"),
                             listID: "news.letters.example", labels: ["Clients"])
        #expect(v(RulePredicate(.userStartedConversation), s) && v(RulePredicate(.userWroteEarlier), s))
        #expect(!v(RulePredicate(.userWroteLast), s) && !v(RulePredicate(.mostlyFromUser), s))
        #expect(v(RulePredicate(.quotesUser), s) && v(RulePredicate(.userInvolved), s) && v(RulePredicate(.isReply), s))
        #expect(v(RulePredicate(.hasListUnsubscribe), s) && v(RulePredicate(.automatedSender), s))
        #expect(v(RulePredicate(.userIsRecipient), s) && v(RulePredicate(.senderSharesUserDomain), s))
        #expect(v(RulePredicate(.recipientCount, op: ">=", value: .number(4)), s))
        #expect(!v(RulePredicate(.recipientCount, op: ">=", value: .number(5)), s))
        #expect(v(RulePredicate(.messageCount, op: "==", value: .number(2)), s))
        #expect(v(RulePredicate(.sender, op: "equals", value: .text("ANA@team.studio.example")), s))
        #expect(v(RulePredicate(.sender, op: "domain", value: .text("studio.example")), s))
        #expect(!v(RulePredicate(.sender, op: "domain", value: .text("dio.example")), s))
        #expect(v(RulePredicate(.sender, op: "contains", value: .text("ana@")), s))
        #expect(v(RulePredicate(.listID, op: "contains", value: .text("letters.example")), s))
        #expect(!v(RulePredicate(.listID, op: "equals", value: .text("letters.example")), s))
        #expect(v(RulePredicate(.subjectContains, value: .text("plan")), s))
        #expect(v(RulePredicate(.textContains, value: .text("wrote")), s))
        #expect(v(RulePredicate(.gmailLabel, value: .text("clients")), s))
        #expect(!v(RulePredicate(.gmailImportant), s) && !v(RulePredicate(.hasAttachments), s))
        #expect(!v(RulePredicate(.sender, op: "equals", value: .text("")), s), "an empty value matches nothing")
        let marketing = Self.subject([M(fromUser: false, text: "View in browser. New tools")],
                                     signals: S(senderAddress: "hello@send.example.com"))
        #expect(v(RulePredicate(.marketingFooter), marketing) && v(RulePredicate(.bulkSender), marketing))
        let seller = Self.subject([M(fromUser: false, text: "We help studios. Worth a quick call?")])
        #expect(v(RulePredicate(.sellerLanguage), seller))
        #expect(v(RulePredicate(.acknowledgement), Self.subject([M(fromUser: false, text: "Thanks!")])))
    }

    @Test func anUnknownPredicateDecodesAndMakesTheRuleInert() throws {
        let json = #"{"id":"user.future","origin":"user","title":"Future","enabled":true,"#
            + #""when":{"all":[{"fact":"sentimentIsAngry"}]},"then":{"setLabel":"respond"},"edited":false}"#
        let rule = try JSONDecoder().decode(ClassificationRule.self, from: Data(json.utf8))
        #expect(!rule.isKnown && !rule.isActive)
        #expect(RuleEngine.evaluate(ClassificationConfig(rules: [rule]), Self.subject(Self.plain)).outcome == .askModel)
        let unknownAction = #"{"id":"user.b","title":"B","when":{"all":[]},"then":{"teleport":"x"}}"#
        let inert = try JSONDecoder().decode(ClassificationRule.self, from: Data(unknownAction.utf8))
        #expect(!inert.isActive)
    }

    @Test func theImportanceGuardRowIsShownButHasNoLabelEffect() {
        let bulk = Self.subject(Self.plain, signals: Self.bulkSignals)
        let verdict = RuleEngine.evaluate(.shipped, bulk)
        #expect(verdict.matches.contains(RuleMatch(ruleID: DefaultRules.importanceGuard, effect: .noEffect)))
        #expect(!DefaultRules.isActiveInThisBuild(DefaultRules.importanceGuard))
        #expect(DefaultRules.v1.count == 9)
    }

    @Test func featuresKeepNoTextAndKeyTheSender() throws {
        let s = Self.titled("Secret subject words", [M(fromUser: false, text: "Private snippet words")],
                             signals: S(senderAddress: "ana@people.example"), listID: "list.example")
        let features = ClassificationFeatures.make(s, salt: Data([1, 2, 3, 4]))
        let json = features.json()
        #expect(!json.contains("Secret") && !json.contains("Private") && !json.contains("ana@"))
        #expect(features.senderDomain == "people.example")
        #expect(features.senderKey?.count == 16 && features.listIDKey?.count == 16)
        #expect(ClassificationFeatures.make(s, salt: Data([9])).senderKey != features.senderKey, "the salt keys the sender")
        #expect(ClassificationFeatures.make(s, salt: nil).senderKey == nil)
    }
}
