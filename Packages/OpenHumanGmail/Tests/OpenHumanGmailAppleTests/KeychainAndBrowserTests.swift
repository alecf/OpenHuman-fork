import Foundation
import OpenHumanCore
import OpenHumanGmail
import Security
import Testing
@testable import OpenHumanGmailApple

@Suite struct KeychainTokenStoreQueryTests {
    @Test func baseQueryIsLegacyKeychainGenericPasswordNeverSynchronized() {
        let store = KeychainTokenStore()
        #expect(store.service == "dev.openhuman.mail.oauth.v1")
        #expect(store.service == OHIdentifiers.keychainService)
        let query = store.baseQuery(account: "me@example.com")
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "dev.openhuman.mail.oauth.v1")
        #expect(query[kSecAttrAccount as String] as? String == "me@example.com")
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
        #expect(store.baseQuery(account: nil)[kSecAttrAccount as String] == nil)
    }

    @Test func addAttributesAreAccessibleAfterFirstUnlock() {
        let attributes = KeychainTokenStore().addAttributes(account: "me@example.com", data: Data("{}".utf8))
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
        #expect(attributes[kSecValueData as String] as? Data == Data("{}".utf8))
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test func theCalendarItemsAreTheirOwnFamily() {
        let mail = KeychainTokenStore()
        let calendar = KeychainTokenStore(service: GoogleCalendarAuth.keychainService, label: GoogleCalendarAuth.keychainLabel)
        #expect(calendar.service == "dev.openhuman.mail.calendar.oauth.v1" && calendar.service != mail.service)
        #expect(calendar.baseQuery(account: nil)[kSecAttrService as String] as? String == GoogleCalendarAuth.keychainService)
        #expect(mail.baseQuery(account: nil)[kSecAttrService as String] as? String == OHIdentifiers.keychainService)
        let data = Data("{}".utf8)
        #expect(calendar.addAttributes(account: "me@example.com", data: data)[kSecAttrLabel as String] as? String
                    == "OpenHuman Mail (Google Calendar OAuth)")
        #expect(mail.addAttributes(account: "me@example.com", data: data)[kSecAttrLabel as String] as? String
                    == "OpenHuman Mail (Gmail OAuth)")
    }

    @Test func accountKeyIsLowercasedEmail() throws {
        #expect(try KeychainTokenStore.account("  Me@Example.COM ") == "me@example.com")
        #expect(throws: TokenStoreError.invalidAccount) { try KeychainTokenStore.account(" ") }
    }
}

@Suite struct SystemBrowserPolicyTests {
    @Test func opensOnlyHTTPSURLsWithAHost() throws {
        try SystemBrowser.validate(URL(string: "https://accounts.example.invalid/o/oauth2/auth?x=1")!)
        for bad in ["http://accounts.example.invalid/", "file:///etc/hosts", "openhuman://x", "javascript:alert(1)"] {
            #expect(throws: SystemBrowserError.unsupportedURL) { try SystemBrowser.validate(URL(string: bad)!) }
        }
    }
}
