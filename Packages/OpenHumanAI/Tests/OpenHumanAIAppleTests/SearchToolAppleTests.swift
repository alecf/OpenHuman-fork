import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAIApple
@testable import OpenHumanAITesting

@Suite struct SearchToolAppleTests {
    @available(macOS 27, iOS 27, *)
    @Test func theToolPassesTheModelsArgumentsToTheSessionAndReturnsDelimitedText() async throws {
        let backend = FakeSearchToolBackend(hits: [
            AISearchToolHit(id: "t1", sender: "Sam Sample", subject: "Invoice 42", date: nil, snippet: "Attached."),
        ])
        let session = AISearchToolSession(backend: backend, nonce: "N0nceN0nce12")
        let tool = FMSearchMailTool(session: session)
        #expect(tool.name == "searchMail")
        let text = try await tool.call(arguments: .init(keywords: ["invoice"], sender: "Sam", withinDays: 7))
        #expect(text.contains("<email_data nonce=\"N0nceN0nce12\""))
        #expect(backend.queries == [AISearchToolQuery(keywords: ["invoice"], sender: "Sam", withinDays: 7)])
        #expect(session.hits.map(\.id) == ["t1"])
    }
}
