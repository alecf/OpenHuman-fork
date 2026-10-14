import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct SettingsFixture {
    let env: AppEnvironment
    let store: FakeMailStore
    let work: AccountID
    let personal: AccountID

    init(safeMode: SafeModeInfo = .normal, flags: FeatureFlags = FeatureFlags(), corpus: FakeCorpus = .small) {
        env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate, safeMode: safeMode), featureFlags: flags)
        store = env.commands as! FakeMailStore
        work = corpus.mailboxes[0].account.id
        personal = corpus.mailboxes[1].account.id
    }

    var availability: SettingsAvailability { SettingsAvailability(environment: env) }

    func accounts() async throws -> [Account] {
        for try await list in store.accounts() { return list }
        return []
    }

    func splits(_ account: AccountID) async throws -> [SplitInfo] {
        for try await list in store.splits(account) { return list }
        return []
    }

    func snippets() async throws -> [SnippetInfo] {
        for try await list in store.snippets(nil) { return list }
        return []
    }
}

func scratchDefaults() -> (UserDefaults, String) {
    let name = "openhuman.test.settings.\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}
