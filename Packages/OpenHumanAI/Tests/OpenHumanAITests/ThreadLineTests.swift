import Foundation
import Testing
@testable import OpenHumanAI

struct ThreadLineTests {
    @Test func theAnswerBecomesOneCleanSentenceOfAtMost14Words() {
        #expect(OutputGuard.threadLine("Dana and Robin move their launch review to Thursday.")
                == "Dana and Robin move their launch review to Thursday.")
        #expect(OutputGuard.threadLine("**\"Sam asks Robin for the budget numbers.\"** Then more.\nSecond line")
                == "Sam asks Robin for the budget numbers.")
        let long = (1...30).map { "word\($0)" }.joined(separator: " ")
        let cut = OutputGuard.threadLine(long)
        #expect(cut?.split(separator: " ").count == AIPolicy.threadLineWords)
        #expect(cut?.hasSuffix(".") == true)
        #expect(OutputGuard.threadLine("  \n  ") == nil)
        #expect(OutputGuard.threadLine("- Dana shares the venue options") == "Dana shares the venue options.")
    }

    @Test func theLinePromptIsAnOnDeviceSummaryTask() {
        #expect(PromptName.summarizeLine.task == .summarize)
        #expect(PromptName.summarizeLine.rawValue == "summarize.line")
    }

    @Test func theLinePromptNeverTurnsBulkMailIntoAConversation() throws {
        let template = try PromptLibrary.standard.template(named: PromptName.summarizeLine.rawValue)
        #expect(template.id.version == 3)
        #expect(template.body.contains("is not a conversation: never write that people discuss, talk or chat"))
        #expect(template.body.contains("name the sender and say what it is about"))
    }
}
