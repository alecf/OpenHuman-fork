import Foundation
import Testing
@testable import OpenHumanMailLive

// Decisions are asked of the delegate directly and the task is never resumed, so nothing leaves the process
@Suite struct OneClickRedirectTests {
    private let delegate = OneClickRedirects()
    private let session = URLSession(configuration: .ephemeral)
    private static let body = Data("List-Unsubscribe=One-Click".utf8)

    private func post(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.body
        return request
    }

    private func proposed(_ status: Int, to location: String, from request: URLRequest) -> URLRequest {
        var next = request
        next.url = URL(string: location)!
        if [301, 302, 303].contains(status) {
            next.httpMethod = "GET"
            next.httpBody = nil
        }
        return next
    }

    private func redirect(_ status: Int, to location: String) async -> URLRequest? {
        let request = post("https://list.example/u/token-1")
        let task = session.dataTask(with: request)
        defer { task.cancel() }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": location])!
        return await delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                         newRequest: proposed(status, to: location, from: request))
    }

    @Test func aRedirectThatKeepsThePostIsFollowedToAnAllowedHost() async throws {
        for status in [307, 308] {
            let next = try #require(await redirect(status, to: "https://lists.example/confirm/token-1"), "\(status)")
            #expect(next.url?.absoluteString == "https://lists.example/confirm/token-1")
            #expect(next.httpMethod == "POST")
            #expect(next.httpBody == Self.body)
            #expect(next.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        }
    }

    @Test func aRedirectThatTurnsThePostIntoAGetIsNotFollowed() async {
        for status in [301, 302, 303] {
            #expect(await redirect(status, to: "https://list.example/u/done") == nil, "\(status)")
        }
    }

    @Test func everyHopMeetsTheRulesOfTheFirstRequest() async {
        let refused = [
            "http://list.example/u/token-1",
            "https://other.example:4443/u/token-1",
            "https://other.example/u/token-1/delete",
            "https://other.example/u/%64elete",
            "https://other.example/u/../token-1",
            "https://name:secret@other.example/u/token-1",
            "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1/trash",
            "https://GMAIL.googleapis.com/u/token-1",
            "https://gmail.googleapis.com./u/token-1",
        ]
        for location in refused {
            for status in [307, 308] {
                #expect(await redirect(status, to: location) == nil, "\(status) \(location)")
            }
        }
    }
}
