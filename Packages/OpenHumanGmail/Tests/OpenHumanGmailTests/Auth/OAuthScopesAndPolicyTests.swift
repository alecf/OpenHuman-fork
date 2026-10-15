import Foundation
import Testing
@testable import OpenHumanGmail

@Suite struct OAuthScopesAndPolicyTests {
    @Test func parseNormalizesGoogleScopeFields() {
        #expect(OAuthScopes.parse(nil) == [])
        #expect(OAuthScopes.parse("") == [])
        #expect(OAuthScopes.parse("  \(GmailScope.readonly)  \(GmailScope.modify) \(GmailScope.readonly) ")
                == [GmailScope.modify, GmailScope.readonly])
    }

    @Test func theMailRequestIsExactlyGmailModify() {
        #expect(OAuthScopes.mailRequest == [GmailScope.modify])
        #expect(OAuthScopes.mailRequest == ["https://www.googleapis.com/auth/gmail.modify"])
        #expect(OAuthScopes.carriesMailWrite(OAuthScopes.mailRequest))
    }

    @Test func mailWriteDetectionAndScopeChecks() {
        #expect(!OAuthScopes.carriesMailWrite([GmailScope.readonly, "openid", "email"]))
        for scope in OAuthScopes.mailWrite { #expect(OAuthScopes.carriesMailWrite([GmailScope.readonly, scope])) }
        #expect(OAuthScopes.mailWrite.contains("https://mail.google.com/"))
        #expect(OAuthScopes.missing(OAuthScopes.mailRequest, in: [GmailScope.readonly]) == [GmailScope.modify])
        #expect(OAuthScopes.missing(OAuthScopes.mailRequest, in: [GmailScope.modify, "openid"]).isEmpty)
        #expect(OAuthScopes.extra(["openid", GmailScope.readonly, "https://www.googleapis.com/auth/userinfo.email"],
                                  beyond: [GmailScope.readonly]).isEmpty)
        #expect(OAuthScopes.extra([GmailScope.readonly, GmailScope.modify], beyond: [GmailScope.readonly])
                == [GmailScope.modify])
        #expect(!OAuthScopes.differ([GmailScope.modify, GmailScope.readonly], [GmailScope.readonly, GmailScope.modify]))
        #expect(OAuthScopes.differ([GmailScope.readonly], [GmailScope.readonly, GmailScope.modify]))
    }

    // Why: the OAuth client is shared with other tools, so revoking a grant at Google would sign them out too
    @Test func noSourceFileCallsAGoogleRevocationEndpoint() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = packageRoot.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 20)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8).lowercased()
            for needle in ["/revoke", "revoke?token", "oauth2/revoke", "revoketoken"] {
                #expect(!text.contains(needle), "\(file.lastPathComponent) mentions \(needle)")
            }
        }
    }

    @Test func theShippedExampleClientJSONParsesAsADesktopClient() throws {
        let example = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OAuthClient.example.json")
        let config = try OAuthClientConfig.parseGoogleJSON(Data(contentsOf: example), source: "example")
        #expect(config.clientID.hasPrefix("YOUR_CLIENT_ID"))
        #expect(config.tokenURI.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(config.authURI.host == "accounts.google.com")
    }
}
