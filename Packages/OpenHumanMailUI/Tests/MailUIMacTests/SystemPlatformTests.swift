import Foundation
import MailModel
import ServiceManagement
import Testing
@testable import MailUIMac

struct SystemPlatformTests {
    @Test func loginItemStatusMapping() {
        #expect(MacLoginItem.map(.enabled) == .enabled)
        #expect(MacLoginItem.map(.requiresApproval) == .requiresApproval)
        #expect(MacLoginItem.map(.notFound) == .notFound)
        #expect(MacLoginItem.map(.notRegistered) == .notRegistered)
    }
}
