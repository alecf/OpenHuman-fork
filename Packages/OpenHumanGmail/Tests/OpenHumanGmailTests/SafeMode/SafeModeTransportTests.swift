import Foundation
import Testing
@testable import OpenHumanGmail

@Suite struct SafeModeTransportTests {
    private let write = HTTPRequest(method: "POST",
                                    url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/m1/modify")!,
                                    headers: [:], body: Data("{}".utf8))
    private let read = HTTPRequest(method: "GET", url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/labels")!,
                                   headers: [:])

    @Test func wrapTable() async throws {
        let table: [(SafeMode, [String], Bool)] = [
            (.normal, [GmailScope.modify], true),
            (.normal, [GmailScope.readonly], false),
            (.normal, [], false),
            (.normal, ["https://mail.google.com/"], false),
            (.readOnly, [GmailScope.readonly], false),
            (.readOnly, [GmailScope.modify], false),
            (.readOnly, [GmailScope.readonly, GmailScope.modify], false),
            (.writeAllowlist, [GmailScope.modify], false),
            (.writeAllowlist, [GmailScope.readonly], false),
        ]
        for (mode, scopes, writesPass) in table {
            let inner = ScriptedTransport()
            let transport = SafeModeTransport.wrap(inner, mode: mode, grantedScopes: scopes)
            if writesPass {
                _ = try await transport.send(write)
                #expect(inner.requests.count == 1, "\(mode) \(scopes)")
            } else {
                await #expect(throws: TransportError.blockedBySafeMode("POST /gmail/v1/users/me/messages/m1/modify")) {
                    _ = try await transport.send(write)
                }
                #expect(inner.requests.isEmpty, "\(mode) \(scopes)")
            }
            _ = try await transport.send(read)
            #expect(inner.requests.last?.method == "GET")
        }
    }

    @Test func wrapWithAllowlist() async throws {
        let allowed = HTTPRequest(method: "POST", url: URL(string: WG.api + "threads/t1/trash")!, headers: [:])
        let other = HTTPRequest(method: "POST", url: URL(string: WG.api + "threads/t9/trash")!, headers: [:])
        let table: [(SafeMode, [String], expectGuard: Bool, allowedPasses: Bool)] = [
            (.writeAllowlist, [GmailScope.modify], true, true),
            (.writeAllowlist, [GmailScope.readonly], false, false),
            (.writeAllowlist, [], false, false),
            (.readOnly, [GmailScope.modify], false, false),
            (.normal, [GmailScope.modify], false, true),
        ]
        for (mode, scopes, expectGuard, allowedPasses) in table {
            let inner = ScriptedTransport()
            let store = WriteAllowlistStore(seed: WG.allowlist)
            let transport = SafeModeTransport.wrap(inner, mode: mode, grantedScopes: scopes, allowlist: store)
            #expect((transport is WriteGuard) == expectGuard, "\(mode) \(scopes)")
            if allowedPasses {
                _ = try await transport.send(allowed)
                #expect(inner.requests.count == 1, "\(mode) \(scopes)")
            } else {
                await #expect(throws: TransportError.self) { _ = try await transport.send(allowed) }
                #expect(inner.requests.isEmpty, "\(mode) \(scopes)")
            }
            if mode != .normal {
                let before = inner.requests.count
                await #expect(throws: TransportError.blockedBySafeMode("POST /gmail/v1/users/me/threads/t9/trash")) {
                    _ = try await transport.send(other)
                }
                #expect(inner.requests.count == before)
            }
        }
        let store = WriteAllowlistStore(seed: WG.allowlist)
        let once = SafeModeTransport.wrap(ScriptedTransport(), mode: .writeAllowlist, grantedScopes: [GmailScope.modify],
                                          allowlist: store)
        let twice = SafeModeTransport.wrap(once, mode: .writeAllowlist, grantedScopes: [GmailScope.modify], allowlist: store)
        #expect((once as? WriteGuard) === (twice as? WriteGuard))
    }

    @Test func wrappingIsNotDoubled() {
        let once = SafeModeTransport.wrap(ScriptedTransport(), mode: .readOnly, grantedScopes: [])
        let twice = SafeModeTransport.wrap(once, mode: .readOnly, grantedScopes: [])
        #expect(once is ReadOnlyTransport && twice is ReadOnlyTransport)
    }

    @Test func effectiveMode() {
        #expect(SafeMode.normal.effective(grantedScopes: [GmailScope.modify]) == .normal)
        #expect(SafeMode.normal.effective(grantedScopes: [GmailScope.readonly]) == .readOnly)
        #expect(SafeMode.writeAllowlist.effective(grantedScopes: [GmailScope.modify]) == .writeAllowlist)
        #expect(SafeMode.writeAllowlist.effective(grantedScopes: []) == .readOnly)
        #expect(SafeMode.readOnly.effective(grantedScopes: [GmailScope.modify]) == .readOnly)
    }

    @Test func scopeProfiles() {
        #expect(SafeMode.readOnly.oauthScopes == ["https://www.googleapis.com/auth/gmail.readonly"])
        #expect(SafeMode.normal.oauthScopes == ["https://www.googleapis.com/auth/gmail.modify"])
        #expect(SafeMode.writeAllowlist.oauthScopes == ["https://www.googleapis.com/auth/gmail.modify"])
    }

    @Test func launchParsing() {
        #expect(SafeModeLaunch.resolve(environment: [:]) == .readOnly)
        #expect(SafeModeLaunch.resolve(environment: ["OPENHUMAN_SAFE_MODE": ""]) == .readOnly)
        #expect(SafeModeLaunch.resolve(environment: ["OPENHUMAN_SAFE_MODE": "read-only"]) == .readOnly)
        #expect(SafeModeLaunch.resolve(environment: ["OPENHUMAN_SAFE_MODE": "write-allowlist"]) == .writeAllowlist)
        #expect(SafeModeLaunch.resolve(environment: ["OPENHUMAN_SAFE_MODE": "normal"]) == .normal)
        for unrecognised in ["readonly", "READ-ONLY", "read_only", "yes", " read-only", "Normal", "NORMAL", " normal",
                             "normal ", "write_allowlist", "0", "false"] {
            #expect(SafeModeLaunch.resolve(environment: ["OPENHUMAN_SAFE_MODE": unrecognised]) == .readOnly, "\(unrecognised)")
        }
    }

    @Test func onlyTheAppAndTheCLIResolveTheLaunchMode() throws {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Packages").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "repository root not found")
            root = parent
        }
        var callers: [String] = []
        for directory in ["Packages", "Apps", "Tools"] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(directory),
                                                              includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                let path = file.path
                guard !path.contains("/.build/"), !path.contains("/build/"), !path.contains("/Tests/") else { continue }
                if try String(contentsOf: file, encoding: .utf8).contains("SafeModeLaunch.resolve(") {
                    callers.append(file.lastPathComponent)
                }
            }
        }
        #expect(callers.sorted() == ["LaunchSafeMode.swift", "Policy.swift"])
    }

    @Test func bannerText() {
        #expect(SafeMode.normal.bannerText == nil)
        #expect(SafeMode.readOnly.bannerText == "Safe mode: read-only")
        #expect(SafeMode.writeAllowlist.bannerText == "Safe mode: test writes only")
    }
}
