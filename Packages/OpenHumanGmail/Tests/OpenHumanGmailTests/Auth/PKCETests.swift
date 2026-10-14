import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanGmail

@Suite struct PKCETests {
    @Test func rfc7636AppendixBVector() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func verifierIs86UnreservedCharacters() {
        let pkce = PKCE.generate()
        #expect(pkce.verifier.count == 86)
        let unreserved = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        #expect(pkce.verifier.unicodeScalars.allSatisfy(unreserved.contains))
        #expect(pkce.challenge == PKCE.challenge(for: pkce.verifier))
        #expect(!pkce.challenge.contains("="))
        #expect(PKCE.generate().verifier != pkce.verifier)
    }

    @Test func stateIs32RandomBytes() {
        let state = OAuthRandom.state()
        #expect(Base64URL.decode(state)?.count == 32)
        #expect(OAuthRandom.state() != state)
    }

    @Test func constantTimeCompare() {
        #expect(constantTimeEquals("abc", "abc"))
        #expect(!constantTimeEquals("abc", "abd"))
        #expect(!constantTimeEquals("abc", "abcd"))
        #expect(!constantTimeEquals("", "a"))
        #expect(constantTimeEquals("", ""))
    }
}
