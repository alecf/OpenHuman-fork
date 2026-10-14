import Crypto
import Foundation
import OpenHumanCore

public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public static let method = "S256"

    public static func generate() -> PKCE { generate(randomBytes: OAuthRandom.bytes) }

    static func generate(randomBytes: @Sendable (Int) -> Data) -> PKCE {
        let verifier = Base64URL.encode(randomBytes(64))
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

enum OAuthRandom {
    @Sendable static func bytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func state(randomBytes: @Sendable (Int) -> Data = OAuthRandom.bytes) -> String {
        Base64URL.encode(randomBytes(32))
    }
}

func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8), b = Array(rhs.utf8)
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in a.indices { diff |= a[i] ^ b[i] }
    return diff == 0
}
