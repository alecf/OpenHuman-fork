import Foundation
import Testing
@testable import OpenHumanAI

@Suite struct ClassificationConfigCodingTests {
    static let listRule = ClassificationRule(
        id: "user.6F2C", origin: .user, title: "Newsletters from the example list are News",
        when: .all([.fact(.listID, "contains", .text("newsletter.example.com"))]), then: .setLabel(.news))

    @Test func aConfigRoundTripsThroughJSON() throws {
        let config = ClassificationConfig(rules: [Self.listRule,
                                                  ClassificationRule(id: "user.n", title: "No label", when: .not(.fact(.gmailImportant)),
                                                                     then: .setLabel(nil)),
                                                  ClassificationRule(id: "user.f", title: "Never social",
                                                                     when: .any([.fact(.recipientCount, ">=", .number(20))]),
                                                                     then: .forbidLabels([.social]))])
            .settingDefault(DefaultRules.marketingNeverPitch, enabled: false)
            .settingDefault(DefaultRules.bulkNeverRespond, params: RuleParams(massRecipients: 6))
        let back = try ClassificationConfig.decode(try config.json())
        #expect(back == config)
        #expect(back.digest == config.digest)
        #expect(back.rules[1].then == .setLabel(nil))
    }

    @Test func theRuleJSONHasTheDesignedShape() throws {
        let json = try String(decoding: JSONEncoder().encode(Self.listRule), as: UTF8.self)
        #expect(json.contains(#""fact":"listID""#) && json.contains(#""op":"contains""#))
        #expect(json.contains(#""setLabel":"news""#))
    }

    @Test func unknownFieldsAreIgnoredAndMissingOnesDefault() throws {
        let json = #"{"format":"openhuman-classification-config","formatVersion":1,"futureField":{"x":1},"#
            + #""rules":[{"id":"user.a","title":"A","when":{"fact":"hasAttachments"},"then":{"setLabel":"invoice"},"colour":"red"}]}"#
        let config = try ClassificationConfig.decode(json)
        #expect(config.rules.count == 1 && config.rules[0].enabled && config.rules[0].origin == .user)
        #expect(config.defaults.isEmpty)
        #expect(try ClassificationConfig.decode("{}") == .shipped)
    }

    @Test func theDigestIsStableAcrossKeyOrder() throws {
        let a = #"{"rules":[],"defaults":[{"id":"default.ack.no-label","enabled":false}],"format":"openhuman-classification-config","formatVersion":1}"#
        let b = #"{"formatVersion":1,"defaults":[{"enabled":false,"id":"default.ack.no-label"}],"format":"openhuman-classification-config","rules":[]}"#
        let first = try ClassificationConfig.decode(a), second = try ClassificationConfig.decode(b)
        #expect(first.digest == second.digest)
        #expect(first.digest != ClassificationConfig.shipped.digest)
        #expect(first.rulesModelID.hasPrefix("rules@") && first.rulesModelID.count == "rules@".count + 12)
        #expect(ClassificationConfig.shipped.rulesModelID == "rules@1", "the shipped set keeps the version-1 cache id")
    }

    @Test func defaultStatesNormalizeAndReset() {
        let off = ClassificationConfig.shipped.settingDefault(DefaultRules.withYou, enabled: false)
        #expect(off.defaults == [DefaultRuleState(id: DefaultRules.withYou, enabled: false)])
        #expect(off.settingDefault(DefaultRules.withYou, enabled: true) == .shipped, "back on with no edit says nothing")
        let same = ClassificationConfig.shipped.settingDefault(DefaultRules.bulkNeverRespond,
                                                               params: RuleParams(massRecipients: AutoLabelRules.massRecipientCount))
        #expect(same == .shipped)
        #expect(same.defaultRule(DefaultRules.bulkNeverRespond)?.edited == false)
        let edited = off.settingDefault(DefaultRules.withYou, params: RuleParams(massRecipients: 3))
        #expect(edited.defaultRule(DefaultRules.withYou)?.enabled == false)
        #expect(edited.defaultRule(DefaultRules.withYou)?.edited == true)
    }

    @Test func theNineDefaultRowsAreInShippedOrderWithParamsWhereEditable() {
        #expect(DefaultRules.v1.map(\.id) == [DefaultRules.waiting, DefaultRules.acknowledgement, DefaultRules.coldOutreach,
                                              DefaultRules.withYou, DefaultRules.bulkNeverRespond,
                                              DefaultRules.marketingNeverPitch, DefaultRules.importanceGuard,
                                              DefaultRules.threadRejections, DefaultRules.senderRejections])
        #expect(DefaultRules.v1.allSatisfy { $0.origin == .default && $0.shippedVersion == 1 && $0.enabled })
        #expect(DefaultRules.hasParams(DefaultRules.acknowledgement) && !DefaultRules.hasParams(DefaultRules.threadRejections))
        #expect(DefaultRules.v1.allSatisfy { !DefaultRules.summary($0.id).isEmpty })
    }
}
