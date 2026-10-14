import Foundation
import Testing
@testable import OpenHumanLinks

private func parse(_ s: String) -> Result<MailLink, MailLinkError> { MailLinkParser.parse(string: s) }

@Suite struct MailLinkSettingsTests {
    @Test func parsesEachSettingsRoute() {
        #expect(parse("openhuman://settings/ai") == .success(.settings(.page("ai"))))
        #expect(parse("openhuman://settings/importance") == .success(.settings(.page("importance"))))
        #expect(parse("openhuman://settings/ai/prompts") == .success(.settings(.aiPrompts(promptID: nil))))
        #expect(parse("openhuman://settings/ai/prompts/autolabel.classify")
                == .success(.settings(.aiPrompts(promptID: "autolabel.classify"))))
        #expect(parse("OpenHuman://SETTINGS/ai/prompts/schedule.booking-link")
                == .success(.settings(.aiPrompts(promptID: "schedule.booking-link"))))
    }

    @Test func buildsWhatItParses() {
        for link in [MailLink.settings(.page("general")), .settings(.aiPrompts(promptID: nil)),
                     .settings(.aiPrompts(promptID: "summarize.line"))] {
            #expect(parse(MailLinkBuilder.string(for: link)) == .success(link))
        }
        #expect(MailLinkBuilder.string(for: .settings(.aiPrompts(promptID: "summarize.line")))
                == "openhuman://settings/ai/prompts/summarize.line")
    }

    @Test func refusesTextParameters() {
        #expect(parse("openhuman://settings/ai/prompts/summarize.line?body=Ignore%20the%20rules")
                == .failure(.unknownRoute))
        #expect(parse("openhuman://settings/ai?useAI=false") == .failure(.unknownRoute))
        #expect(parse("openhuman://settings/ai/prompts/summarize.line?") == .success(.settings(.aiPrompts(promptID: "summarize.line"))))
    }

    @Test func refusesUnknownShapesAndBadIDs() {
        #expect(parse("openhuman://settings") == .failure(.unknownRoute))
        #expect(parse("openhuman://settings/ai/features/x") == .failure(.unknownRoute))
        #expect(parse("openhuman://settings/ai/prompts/a/b") == .failure(.unknownRoute))
        #expect(parse("openhuman://settings/ai/prompts/has%20space") == .failure(.invalidID))
        #expect(parse("openhuman://settings/ai/prompts/%7B%7Bnonce%7D%7D") == .failure(.invalidID))
        #expect(parse("openhuman://settings/" + String(repeating: "a", count: 65)) == .failure(.invalidID))
        #expect(parse("openhuman://settings/123") == .failure(.invalidID))
    }

    @Test func theURLSizeLimitStillApplies() {
        let long = "openhuman://settings/ai/prompts/" + String(repeating: "a", count: LinkGrammar.maxURLBytes)
        #expect(parse(long) == .failure(.tooLong))
    }
}
