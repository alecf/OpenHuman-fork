import Foundation
import OpenHumanCore
import OpenHumanStore
import Testing

@Test func hybridSearchContractsInstantiate() {
    let candidate = ExternalSearchCandidate(message: MessageRowID(rawValue: 1), gmailMessageID: GmailMessageID("m1"), score: 0.5)
    let external = ExternalSearchCandidates(source: .semantic, candidates: [candidate])
    #expect(external.candidates == [candidate])
    #expect(ExternalSearchCandidates.maximumCount == 1_000)
    let message = IndexableMessage(message: MessageRowID(rawValue: 1), account: AccountID(1), gmailMessageID: GmailMessageID("m1"),
                                   thread: ThreadRowID(rawValue: 2), internalDate: Date(timeIntervalSince1970: 0),
                                   bodyState: .stored, isDraft: false, inSpam: false)
    let document = IndexableDocument(message: MessageRowID(rawValue: 1), subject: "Subject", body: "Body",
                                     attachmentNames: [], hasStoredBody: true)
    #expect(message.bodyState == .stored)
    #expect(document.fromName == nil)
    #expect(BodyDownloadStatus(rawValue: "capped") == .capped)
    let ranking: any SearchRanking = HybridRRFRanking(k: 20, lexicalWeight: 1, externalWeight: 1.5, recencyWeight: 0)
    #expect(ranking.scores(for: [], query: SearchQuery(text: "", terms: []), now: Date()).isEmpty)
    #expect(SearchMatchSource.allSources.count == 2)
}

private extension SearchMatchSource {
    static var allSources: [SearchMatchSource] { [.lexical, .semantic] }
}
