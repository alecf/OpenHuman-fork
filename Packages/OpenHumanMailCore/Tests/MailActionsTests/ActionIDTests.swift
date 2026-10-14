import Testing
@testable import MailActions

@Test func sliceNavigationIDsFollowTheNamingRule() {
    let ids: [ActionID] = [.nextThread, .previousThread, .openThread, .backToList]
    #expect(Set(ids).count == ids.count)
    for id in ids {
        let parts = id.rawValue.split(separator: ".")
        #expect(parts.count == 2, "\(id) is not <noun>.<verb>")
        #expect(parts.allSatisfy { $0.first?.isLowercase == true }, "\(id) is not lowerCamel")
    }
}
