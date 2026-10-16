import Foundation
import Testing
@testable import OpenHumanGmail

@Suite struct OAuthClientConfigTests {
    private func write(_ data: Data, _ url: URL, mode: mode_t = 0o600) throws {
        try data.write(to: url)
        chmod(url.path, mode)
    }

    private func isConfigError(_ error: Error) -> Bool {
        if case OAuthError.configurationMissing = error { return true }
        return false
    }

    @Test func importWritesMode0600AtomicallyAndLoadsBack() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let config = try OAuthClientConfig.importGoogleJSON(Synthetic.installedJSON(), storeDirectory: dir.url)
        #expect(config.clientID == Synthetic.clientID)
        #expect(config.clientSecret == Synthetic.clientSecret)
        #expect(config.tokenURI.absoluteString == "https://oauth2.googleapis.com/token")
        let file = dir.url.appendingPathComponent("oauth-client.json")
        #expect(posixMode(file) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path) == ["oauth-client.json"])
        #expect(OAuthClientConfig.resolveSource(clientFile: nil, storeDirectory: dir.url) == .storeFile)
        let loaded = try OAuthClientConfig.load(clientFile: nil, storeDirectory: dir.url)
        #expect(loaded.clientID == config.clientID && loaded.clientSecret == config.clientSecret)
        #expect(loaded.authURI == config.authURI && loaded.tokenURI == config.tokenURI)
    }

    @Test func importReplacesALooserFileWithMode0600() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let file = dir.url.appendingPathComponent("oauth-client.json")
        try write(Data("{}".utf8), file, mode: 0o644)
        _ = try OAuthClientConfig.importGoogleJSON(Synthetic.installedJSON(), storeDirectory: dir.url)
        #expect(posixMode(file) == 0o600)
    }

    @Test func importCreatesAMissingStoreDirectory() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let store = dir.url.appendingPathComponent("Application Support/OpenHuman", isDirectory: true)
        _ = try OAuthClientConfig.importGoogleJSON(Synthetic.installedJSON(), storeDirectory: store)
        #expect(posixMode(store.appendingPathComponent("oauth-client.json")) == 0o600)
        #expect(posixMode(store) == 0o700)
    }

    @Test func theSecretIsKeptForInstalledWebAndFlatShapes() throws {
        let shapes = [
            #"{"installed":{"client_id":"id-1","client_secret":"SYNTHETIC-S"}}"#,
            #"{"web":{"client_id":"id-1","client_secret":"SYNTHETIC-S"}}"#,
            #"{"client_id":"id-1","client_secret":"SYNTHETIC-S"}"#,
        ]
        for json in shapes {
            let config = try OAuthClientConfig.parseGoogleJSON(Data(json.utf8), source: "test")
            #expect(config.clientSecret == "SYNTHETIC-S" && config.hasClientSecret, "\(json)")
        }
        let none = try OAuthClientConfig.parseGoogleJSON(Data(#"{"installed":{"client_id":"id-1"}}"#.utf8), source: "test")
        #expect(!none.hasClientSecret)
        let empty = try OAuthClientConfig.parseGoogleJSON(Data(#"{"installed":{"client_id":"id-1","client_secret":""}}"#.utf8),
                                                          source: "test")
        #expect(!empty.hasClientSecret)
    }

    @Test func importRejectsWebAndMalformedClientsAndWritesNothing() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let bad: [String] = [
            #"{"web":"x"}"#,
            #"{"installed":{"client_secret":"SYNTHETIC-SECRET-not-a-real-one"}}"#,
            #"{"installed":{"client_id":""}}"#,
            #"{"installed":{"client_id":"x","token_uri":"http://oauth2.example.invalid/token"}}"#,
            #"{"installed":{"client_id":"x","auth_uri":"not a url"}}"#,
            #"{"installed":{"client_id":"x","client_secret":42}}"#,
            #"{"installed":"x"}"#,
            #"{"something":"else"}"#,
            #"[1,2]"#,
            "not json",
        ]
        for json in bad {
            #expect(throws: OAuthError.self) {
                _ = try OAuthClientConfig.importGoogleJSON(Data(json.utf8), storeDirectory: dir.url)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).isEmpty)
    }

    @Test func importAcceptsTheFlatShapeWithGoogleDefaults() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let flat = #"{"client_id":"1234-synthetic.apps.googleusercontent.com","client_secret":"SYNTHETIC-SECRET-not-a-real-one"}"#
        let config = try OAuthClientConfig.importGoogleJSON(Data(flat.utf8), storeDirectory: dir.url)
        #expect(config.authURI.absoluteString == "https://accounts.google.com/o/oauth2/auth")
        #expect(config.tokenURI.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(posixMode(dir.url.appendingPathComponent("oauth-client.json")) == 0o600)
    }

    private func clientJSON(authURI: String? = nil, tokenURI: String? = nil) -> Data {
        var fields = #""client_id":"\#(Synthetic.clientID)","client_secret":"\#(Synthetic.clientSecret)""#
        if let authURI { fields += #","auth_uri":"\#(authURI)""# }
        if let tokenURI { fields += #","token_uri":"\#(tokenURI)""# }
        return Data(#"{"installed":{\#(fields)}}"#.utf8)
    }

    @Test func endpointsOnAnotherHostAreRefusedAndNothingIsWritten() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let hostile = [
            clientJSON(tokenURI: "https://oauth2.example.invalid/token"),
            clientJSON(authURI: "https://accounts.example.invalid/o/oauth2/auth"),
            clientJSON(tokenURI: "https://oauth2.googleapis.com.example.invalid/token"),
            clientJSON(tokenURI: "https://oauth2.googleapis.com:8443/token"),
            clientJSON(tokenURI: "https://user@oauth2.googleapis.com/token"),
            clientJSON(authURI: "https://accounts.google.com/o/oauth2/auth", tokenURI: "https://127.0.0.1/token"),
        ]
        for json in hostile {
            do {
                _ = try OAuthClientConfig.importGoogleJSON(json, storeDirectory: dir.url)
                Issue.record("a client JSON pointing sign-in away from Google was accepted")
            } catch let OAuthError.configurationMissing(why) {
                #expect(why.contains("not Google's sign-in address"), "a clear reason: \(why)")
                #expect(!why.contains("example.invalid") && !why.contains(Synthetic.clientID), "names no value")
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).isEmpty)
    }

    @Test func googleEndpointsInTheFileAreReplacedByTheBuiltInOnes() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let json = clientJSON(authURI: "https://ACCOUNTS.google.com/o/oauth2/v2/auth",
                              tokenURI: "https://accounts.google.com/o/oauth2/token")
        let config = try OAuthClientConfig.importGoogleJSON(json, storeDirectory: dir.url)
        #expect(config.clientID == Synthetic.clientID && config.clientSecret == Synthetic.clientSecret)
        #expect(config.authURI == OAuthClientConfig.defaultAuthURI)
        #expect(config.tokenURI == OAuthClientConfig.defaultTokenURI)
        let loaded = try OAuthClientConfig.load(clientFile: nil, storeDirectory: dir.url)
        #expect(loaded.authURI == OAuthClientConfig.defaultAuthURI && loaded.tokenURI == OAuthClientConfig.defaultTokenURI)
    }

    @Test func anExistingFileOrEnvironmentSourceWithAnotherHostIsRefusedOnLoad() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let hostile = clientJSON(tokenURI: "https://oauth2.example.invalid/token")
        try write(hostile, dir.url.appendingPathComponent("oauth-client.json"))
        #expect(throws: OAuthError.self) {
            _ = try OAuthClientConfig.load(clientFile: nil, storeDirectory: dir.url)
        }
        let envFile = dir.url.appendingPathComponent("client_env.json")
        try write(hostile, envFile)
        #expect(throws: OAuthError.self) {
            _ = try OAuthClientConfig.load(clientFile: envFile.path, storeDirectory: nil)
        }
    }

    @Test func environmentWinsOverStoreFile() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let envFile = dir.url.appendingPathComponent("client_env.json")
        try write(Synthetic.installedJSON(clientID: "env-client"), envFile)
        let store = dir.url.appendingPathComponent("store", isDirectory: true)
        _ = try OAuthClientConfig.importGoogleJSON(Synthetic.installedJSON(clientID: "store-client"), storeDirectory: store)
        let env = envFile.path
        #expect(OAuthClientConfig.resolveSource(clientFile: env, storeDirectory: store) == .environment)
        #expect(try OAuthClientConfig.load(clientFile: env, storeDirectory: store).clientID == "env-client")
        for noEnv in [nil, "  "] as [String?] {
            #expect(OAuthClientConfig.resolveSource(clientFile: noEnv, storeDirectory: store) == .storeFile)
            #expect(try OAuthClientConfig.load(clientFile: noEnv, storeDirectory: store).clientID
                    == "store-client")
        }
        #expect(OAuthClientConfig.resolveSource(clientFile: nil, storeDirectory: dir.url) == .missing)
    }

    @Test func malformedOrUnreadableEnvironmentSourceIsAnErrorNotAFallThrough() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let store = dir.url.appendingPathComponent("store", isDirectory: true)
        _ = try OAuthClientConfig.importGoogleJSON(Synthetic.installedJSON(), storeDirectory: store)
        let malformed = dir.url.appendingPathComponent("bad.json")
        try write(Data(#"{"web":"x"}"#.utf8), malformed)
        for path in [malformed.path, dir.url.appendingPathComponent("missing.json").path] {
            let env = path
            #expect(OAuthClientConfig.resolveSource(clientFile: env, storeDirectory: store) == .environment)
            #expect(throws: OAuthError.self) {
                _ = try OAuthClientConfig.load(clientFile: env, storeDirectory: store)
            }
        }
    }

    @Test func malformedStoreFileIsAnErrorNotAFallThrough() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        try write(Data("{\"installed\":{}}".utf8), dir.url.appendingPathComponent("oauth-client.json"))
        #expect(throws: OAuthError.self) {
            _ = try OAuthClientConfig.load(clientFile: nil, storeDirectory: dir.url)
        }
    }

    @Test func storeFileThatIsASymlinkIsRefused() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let real = dir.url.appendingPathComponent("elsewhere.json")
        try write(Synthetic.installedJSON(), real)
        try FileManager.default.createSymbolicLink(at: dir.url.appendingPathComponent("oauth-client.json"),
                                                   withDestinationURL: real)
        #expect(throws: OAuthError.self) {
            _ = try OAuthClientConfig.load(clientFile: nil, storeDirectory: dir.url)
        }
    }

    @Test func looserStoreFileModeIsTightenedOnLoad() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let file = dir.url.appendingPathComponent("oauth-client.json")
        try write(Synthetic.installedJSON(), file, mode: 0o644)
        _ = try OAuthClientConfig.load(clientFile: nil, storeDirectory: dir.url)
        #expect(posixMode(file) == 0o600)
    }

    @Test func noSourceIsConfigurationMissing() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        #expect(OAuthClientConfig.resolveSource(clientFile: nil, storeDirectory: dir.url) == .missing)
        do {
            _ = try OAuthClientConfig.load(clientFile: nil, storeDirectory: dir.url)
            Issue.record("expected configurationMissing")
        } catch {
            #expect(isConfigError(error))
        }
    }

    @Test func descriptionsAndErrorsNeverContainTheIdOrSecret() throws {
        let config = Synthetic.client
        var dumped = ""
        dump(config, to: &dumped)
        for text in [String(describing: config), "\(config)", String(reflecting: config), dumped] {
            #expect(!text.contains(Synthetic.clientSecret))
            #expect(!text.contains(Synthetic.clientID))
        }
        let token = Synthetic.token(expiry: Date(timeIntervalSince1970: 0))
        var dumpedToken = ""
        dump(token, to: &dumpedToken)
        for text in [String(describing: token), String(reflecting: token), dumpedToken] {
            #expect(!text.contains(token.refreshToken))
            #expect(!text.contains(token.accessToken!))
        }
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let bad = #"{"installed":{"client_id":"\#(Synthetic.clientID)","client_secret":"\#(Synthetic.clientSecret)","token_uri":"http://x"}}"#
        do {
            _ = try OAuthClientConfig.importGoogleJSON(Data(bad.utf8), storeDirectory: dir.url)
            Issue.record("expected an error")
        } catch {
            let text = "\(error) \(String(reflecting: error))"
            #expect(!text.contains(Synthetic.clientSecret))
            #expect(!text.contains(Synthetic.clientID))
        }
    }
}
