import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private final class SyncingAccounts: AccountManaging {
    private struct State {
        var syncs: [AccountID: SignInSync]
        var calls: [String] = []
    }
    private let state: Mutex<State>

    private let syncsThroughICloud: Bool

    init(_ syncs: [AccountID: SignInSync], syncsThroughICloud: Bool = false) {
        state = Mutex(State(syncs: syncs))
        self.syncsThroughICloud = syncsThroughICloud
    }

    func signInsSyncThroughICloudKeychain() async -> Bool { syncsThroughICloud }

    var calls: [String] { state.withLock { $0.calls } }

    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        let (stream, continuation) = AsyncStream<OAuthClientStatus>.makeStream()
        continuation.yield(.configured(source: .file))
        return stream
    }

    func importOAuthClient(json: Data) async throws {}

    func addAccount(loginHint: String?) async throws -> AccountID {
        throw AccountSetupError(.failed, "Not used by these tests.")
    }

    func signInSync(for account: AccountID) async -> SignInSync? { state.withLock { $0.syncs[account] } }

    func setSignInSync(_ account: AccountID, enabled: Bool) async throws {
        state.withLock { s in
            s.calls.append("sync \(account.rawValue) \(enabled)")
            s.syncs[account] = enabled ? .syncing : .notSyncing
        }
    }

    func remove(_ account: AccountID) async throws {
        state.withLock { $0.calls.append("remove \(account.rawValue)") }
    }

    func removeIncludingSharedSignIn(_ account: AccountID) async throws {
        state.withLock { $0.calls.append("remove with shared \(account.rawValue)") }
    }
}

@MainActor
@Test func signingOutRemovesThisMacsCopyUnlessTheUserAlsoChoosesTheSharedSignIn() async throws {
    let f = SettingsFixture()
    let accounts = SyncingAccounts([f.work: .syncing, f.personal: .notSyncing])
    let model = AccountsSettingsModel(data: f.env.data, accounts: accounts, settings: f.env.settings,
                                      availability: f.availability)

    await model.askToRemove(f.personal)
    #expect(model.confirmingRemoval == f.personal && !model.removalOffersSharedSignIn)
    #expect(model.removalMessage == AccountsSettingsModel.removalConfirmationMessage)
    #expect(model.confirmRemoval(includingSharedSignIn: true) == nil, "nothing shared to remove")
    await model.confirmRemoval()?.value
    #expect(accounts.calls == ["remove \(f.personal.rawValue)"])

    await model.askToRemove(f.work)
    #expect(model.confirmingRemoval == f.work && model.removalOffersSharedSignIn)
    #expect(model.removalMessage == AccountsSettingsModel.removalConfirmationMessage + " "
        + AccountsSettingsModel.removalSharedSignInNote)
    model.cancelRemoval()
    #expect(model.confirmingRemoval == nil && !model.removalOffersSharedSignIn)
    #expect(accounts.calls.count == 1, "nothing removed without the confirmation")

    await model.askToRemove(f.work)
    let task = model.confirmRemoval()
    #expect(model.confirmingRemoval == nil, "the choice is taken before the dialog closes")
    await task?.value
    #expect(accounts.calls.last == "remove \(f.work.rawValue)", "the default is this Mac only")

    await model.askToRemove(f.work)
    await model.confirmRemoval(includingSharedSignIn: true)?.value
    #expect(accounts.calls.last == "remove with shared \(f.work.rawValue)")
    #expect(accounts.calls.count == 3)
}

@MainActor
@Test func eachAccountHasADontSyncThisSignInSwitchWithAPlainSentence() async throws {
    let f = SettingsFixture()
    let accounts = SyncingAccounts([f.work: .syncing, f.personal: .needsSignInHere])
    let model = AccountsSettingsModel(data: f.env.data, accounts: accounts, settings: f.env.settings,
                                      availability: f.availability)
    model.start()
    await eventually(timeout: .seconds(60)) { model.rows.count == 2 && model.rows.allSatisfy { $0.signInSyncNote != nil } }
    let work = try #require(model.rows.first { $0.id == f.work })
    #expect(work.signInSyncNote == "Shared with your other devices through iCloud Keychain, so they can use this "
        + "account without signing in.")
    #expect(!work.dontSyncSignIn && work.canChangeSignInSync)
    let personal = try #require(model.rows.first { $0.id == f.personal })
    #expect(personal.signInSyncNote == "The sign-in from your other device didn't work on this Mac. Sign in again here.")
    #expect(!personal.canChangeSignInSync, "nothing to keep or share until this Mac signs in")

    await model.setDontSyncSignIn(f.work, true)
    #expect(accounts.calls == ["sync \(f.work.rawValue) false"])
    await eventually(timeout: .seconds(60)) { model.rows.first { $0.id == f.work }?.dontSyncSignIn == true }
    #expect(model.rows.first { $0.id == f.work }?.signInSyncNote
        == "Stays on this Mac. Your other devices sign in on their own.")
    #expect(model.rows.first { $0.id == f.personal }?.signInSyncNote == personal.signInSyncNote, "the other is untouched")

    await model.setDontSyncSignIn(f.work, false)
    #expect(accounts.calls.last == "sync \(f.work.rawValue) true")
    await eventually(timeout: .seconds(60)) { model.rows.first { $0.id == f.work }?.dontSyncSignIn == false }
}

@MainActor
@Test func withoutTokenSyncThereIsNoSwitch() async throws {
    let f = SettingsFixture()
    let model = AccountsSettingsModel(data: f.env.data, accounts: SyncingAccounts([:]), settings: f.env.settings,
                                      availability: f.availability)
    model.start()
    await eventually(timeout: .seconds(60)) { model.rows.count == 2 }
    #expect(model.rows.allSatisfy { $0.signInSyncNote == nil && !$0.dontSyncSignIn && !$0.canChangeSignInSync })
}

@MainActor
@Test func everySignInSyncSentenceIsShortAndCalm() throws {
    #expect(AccountsSettingsModel.signInSyncNote(nil) == nil)
    let states: [SignInSync] = [.syncing, .pending, .notSyncing, .unavailable, .ownSignInHere, .needsSignInHere]
    var notes = Set<String>()
    for state in states {
        let note = try #require(AccountsSettingsModel.signInSyncNote(state))
        notes.insert(note)
        let sentences = note.split(separator: ".").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect((1...2).contains(sentences.count), "one or two sentences: \(note)")
        #expect(note.count <= 120)
        for word in ["warning", "danger", "risk", "error", "token", "!"] {
            #expect(!note.lowercased().contains(word), "plain and calm: \(note)")
        }
    }
    #expect(notes.count == states.count)
    #expect(AccountsSettingsModel.dontSync(.notSyncing) && AccountsSettingsModel.dontSync(.ownSignInHere))
    #expect(!AccountsSettingsModel.dontSync(.syncing) && !AccountsSettingsModel.dontSync(.unavailable))
}

@MainActor
@Test func accountsSaysWhereSignInsAreKeptFromWhatTheKeychainDoes() async {
    let f = SettingsFixture()
    let local = AccountsSettingsModel(data: f.env.data, accounts: SyncingAccounts([f.work: .unavailable]),
                                      settings: f.env.settings, availability: f.availability)
    #expect(local.keychainNote == SignInModel.keychainLocalNote, "nothing promised before it is known")
    await local.loadKeychainNote()
    #expect(local.keychainNote == SignInModel.keychainLocalNote)

    let synced = AccountsSettingsModel(data: f.env.data, accounts: SyncingAccounts([f.work: .syncing], syncsThroughICloud: true),
                                       settings: f.env.settings, availability: f.availability)
    await synced.loadKeychainNote()
    #expect(synced.keychainNote == SignInModel.keychainSyncNote)
}

@MainActor
@Test func removingTheSharedSignInIsOfferedOnlyWhileTheSignInIsShared() async {
    let f = SettingsFixture()
    for state in [SignInSync.pending, .notSyncing, .unavailable, .ownSignInHere, .needsSignInHere] {
        let model = AccountsSettingsModel(data: f.env.data, accounts: SyncingAccounts([f.work: state]),
                                          settings: f.env.settings, availability: f.availability)
        await model.askToRemove(f.work)
        #expect(model.confirmingRemoval == f.work && !model.removalOffersSharedSignIn, "\(state)")
        #expect(model.removalMessage == AccountsSettingsModel.removalConfirmationMessage, "\(state)")
    }
}
