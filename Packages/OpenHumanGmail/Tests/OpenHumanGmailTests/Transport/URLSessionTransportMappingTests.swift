import Foundation
import Testing
@testable import OpenHumanGmail

@Suite struct URLSessionTransportMappingTests {
    @Test func urlErrorMapping() {
        let table: [(URLError.Code, TransportError)] = [
            (.timedOut, .timedOut),
            (.notConnectedToInternet, .notConnected),
            (.networkConnectionLost, .connectionLost(requestMayHaveBeenSent: true)),
            (.cannotConnectToHost, .cannotConnect),
            (.cannotFindHost, .cannotConnect),
            (.dnsLookupFailed, .cannotConnect),
            (.cancelled, .cancelled),
        ]
        for (code, expected) in table { #expect(URLSessionTransport.map(URLError(code)) == expected) }
        if case .tls = URLSessionTransport.map(URLError(.serverCertificateUntrusted)) {} else { Issue.record("tls") }
        if case .other = URLSessionTransport.map(URLError(.badServerResponse)) {} else { Issue.record("other") }
    }
}
