import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFakes

@Test func replyDraftsComeFromTheSkeleton() async throws {
    let store = makeStore()
    let original = try #require(special(20).detail.messages.first { $0.from?.email != FakeCorpus.me.email })
    let (key, version) = try await store.createDraft(DraftInput(account: work, mode: .reply, replyTo: original.id))
    #expect(version == 1)
    let draft = try #require(try await first(store.draft(key)))
    #expect(draft.fields.to == [try #require(original.from)])
    #expect(draft.fields.subject == "Re: \(special(20).detail.subject)")
    #expect(draft.fields.bodyHTML.components(separatedBy: "data-oh-quote=\"1\"").count == 2, "exactly one quote block")
    #expect(draft.fields.from?.email == FakeCorpus.me.email)
    #expect(draft.thread == special(20).row.id && draft.isDirty)
    #expect(try await first(store.threadDetail(special(20).row.id))?.drafts.map(\.id) == [key])
    #expect(try await window(store, .system(.allMail)).rows.first { $0.id == special(20).row.id }?.draftCount == 1)

    let all = try await store.createDraft(DraftInput(account: work, mode: .replyAll, replyTo: original.id))
    let replyAll = try #require(try await first(store.draft(all.key)))
    #expect(!replyAll.fields.to.contains { $0.email == FakeCorpus.me.email })
    let forward = try await store.createDraft(DraftInput(account: work, mode: .forward, replyTo: original.id))
    #expect(try await first(store.draft(forward.key))?.fields.subject.hasPrefix("Fwd: ") == true)
    let to = EmailAddress(email: "list-owner@news.example")
    let linked = try await store.createDraft(DraftInput(account: work, mode: .new, content: DraftFields(to: [to], subject: "Hi")))
    let mail = try #require(try await first(store.draft(linked.key)))
    #expect(mail.fields.to == [to] && mail.fields.subject == "Hi" && mail.thread == nil)
}

@Test func updateDraftChecksTheVersion() async throws {
    let store = makeStore()
    let (key, version) = try await store.createDraft(DraftInput(account: work, mode: .new))
    let v2 = try await store.updateDraft(key, DraftFields(subject: "One"), expectedVersion: version)
    #expect(v2 == 2)
    await #expect(throws: MailPortError.self) { _ = try await store.updateDraft(key, DraftFields(subject: "Two"), expectedVersion: 1) }
    #expect(try await first(store.draft(key))?.version == 2)
    try await store.flushDraft(key)
    let flushed = try #require(try await first(store.draft(key)))
    #expect(!flushed.isDirty && flushed.gmailDraftID != nil)
    #expect(try await store.fetchDraftNow(work, gmailDraftID: try #require(flushed.gmailDraftID)) == key)
    try await store.discardDraft(key)
    #expect(try await first(store.draft(key)) == nil)
}

@Test func heldSendCanBeCancelledOrSentNow() async throws {
    let store = makeStore()
    let draftKey = try #require(special(0).detail.messages.last?.id)
    let (key, _) = try await store.createDraft(DraftInput(account: work, mode: .reply, replyTo: draftKey))
    let token = try await store.send(key, undoWindow: .seconds(10))
    #expect(token.sendAfter == fixedNow.addingTimeInterval(10))
    #expect(try await first(store.draft(key))?.status == .sending)
    #expect(!(try await first(store.drafts(work, review: false))).contains { $0.id == key })
    #expect(try await store.cancelSend(token))
    #expect(try await first(store.draft(key))?.status == .editing)
    #expect(store.sentMessages.isEmpty)

    let again = try await store.send(key, undoWindow: .seconds(10))
    store.completeHeldSends()
    #expect(try await store.cancelSend(again) == false, "already sent: no undo")
    #expect(try await first(store.draft(key)) == nil)
    #expect(store.sentMessages.map(\.draft) == [key])
    let thread = try #require(try await first(store.threadDetail(special(0).row.id)))
    #expect(thread.messages.last?.from?.email == FakeCorpus.me.email)
    #expect(try await keys(store, .system(.sent)).contains(special(0).row.id))

    let (other, _) = try await store.createDraft(DraftInput(account: work, mode: .new,
                                                            content: DraftFields(to: [EmailAddress(email: "x@example.org")], subject: "New")))
    let held = try await store.send(other, undoWindow: .seconds(30))
    #expect(try await store.sendNow(held))
    #expect(try await store.sendNow(held) == false)
    #expect(try await keys(store, .system(.sent)).first == store.sentMessages.last?.thread)
    let (empty, _) = try await store.createDraft(DraftInput(account: work, mode: .new))
    await #expect(throws: MailPortError.self) { _ = try await store.send(empty, undoWindow: .seconds(5)) }
}

@Test func reviewQueueStatesAndDeferredDiscard() async throws {
    let store = makeStore()
    let queue = try await first(store.reviewQueue(work))
    #expect(queue.count == 4 && queue.allSatisfy { $0.review == .pending && $0.agentSnapshot != nil })
    #expect(queue.map(\.updatedAt) == queue.map(\.updatedAt).sorted(by: >), "newest first")
    #expect(try await first(store.reviewQueue(nil)).count == 8)
    let draft = queue[0]
    try await store.setReviewState(draft.id, .rejected)
    #expect(!(try await first(store.reviewQueue(work))).contains { $0.id == draft.id })
    try await store.setReviewState(draft.id, .pending)
    #expect(try await first(store.reviewQueue(work)).contains { $0.id == draft.id })
    try await store.setReviewState(draft.id, .approved)
    #expect(try await first(store.drafts(work, review: true)).count == 3)
    #expect(try await first(store.counts(work)).pendingReviewCount == 3)
}

@Test func agentRevisionOfAnEditedDraftIsAConflict() async throws {
    let store = makeStore()
    let reply = try #require(special(0).detail.messages.last?.id)
    let original = DraftFields(to: [EmailAddress(email: "dana@example.com")], subject: "Re: x", bodyHTML: "<p>v1</p>")
    let key = store.agentCreatesDraft(account: work, replyTo: reply, fields: original, note: "first try")
    var revised = original
    revised.bodyHTML = "<p>v2</p>"
    store.agentUpdatesDraft(key, fields: revised)
    #expect(try await first(store.draft(key))?.fields.bodyHTML == "<p>v2</p>")
    let draft = try #require(try await first(store.draft(key)))
    var mine = draft.fields
    mine.bodyHTML = "<p>mine</p>"
    _ = try await store.updateDraft(key, mine, expectedVersion: draft.version)
    var third = original
    third.bodyHTML = "<p>v3</p>"
    store.agentUpdatesDraft(key, fields: third)
    let conflicted = try #require(try await first(store.draft(key)))
    #expect(conflicted.hasRemoteConflict && conflicted.fields.bodyHTML == "<p>mine</p>")
    #expect(conflicted.agentSnapshot?.bodyHTML == "<p>v3</p>" && conflicted.review == .pending)
    try await store.resolveDraftConflict(key, .takeRemote)
    let resolved = try #require(try await first(store.draft(key)))
    #expect(!resolved.hasRemoteConflict && resolved.fields.bodyHTML == "<p>v3</p>")
}

@Test func signInNeedsAClientAndSeedsTheDefaultSplit() async throws {
    let store = makeStore(oauthClient: .missing)
    #expect(await first(store.oauthClientStatus()) == .missing)
    await #expect(throws: AccountSetupError.self) { _ = try await store.addAccount(loginHint: nil) }
    await #expect(throws: AccountSetupError.self) { try await store.importOAuthClient(json: Data("{}".utf8)) }
    let json = #"{"installed":{"client_id":"1234-fake.apps.googleusercontent.com","client_secret":"fake-secret","redirect_uris":["http://localhost"]}}"#
    try await store.importOAuthClient(json: Data(json.utf8))
    #expect(await first(store.oauthClientStatus()) == .configured(source: .file))
    store.enqueueSignIn(.cancel)
    await #expect(throws: AccountSetupError(.cancelled, "Sign-in was cancelled.")) { _ = try await store.addAccount(loginHint: nil) }
    let id = try await store.addAccount(loginHint: "new.person@example.org")
    #expect(try await store.addAccount(loginHint: "new.person@example.org") == id, "same address → same account")
    let accounts = try await first(store.accounts())
    #expect(accounts.map(\.email).contains("new.person@example.org") && accounts.count == 3)
    let splits = try await first(store.splits(id))
    #expect(splits.map(\.name) == ["Important", "Calendar"])
    let calendar = try #require(splits.last)
    #expect(calendar.ruleText == "is:event")
    #expect(try await store.get(AppSettings.hideSplitWhenEmpty(id)) == [calendar.id.rawValue])
    #expect(try await window(store, .splitOther, account: id).totalCount == 0)
    #expect(try await first(store.labels(id)).contains { $0.labelID == GmailLabelID("INBOX") })
    try await store.setAlias(id, "Side project")
    #expect(try await first(store.accounts()).first { $0.id == id }?.alias == "Side project")
    try await store.remove(id)
    #expect(try await first(store.accounts()).count == 2)
}

@Test func settingsDefaultPersistAndNotify() async throws {
    let store = makeStore()
    #expect(try await store.get(AppSettings.undoSendSeconds) == 10)
    #expect(try await store.get(AppSettings.remoteImages(work)) == .block)
    var stream = store.observe(AppSettings.undoSendSeconds).makeAsyncIterator()
    #expect(await stream.next() == 10)
    try await store.set(AppSettings.undoSendSeconds, 20)
    #expect(await stream.next() == 20)
    try await store.set(AppSettings.remoteImages(work), .ask)
    #expect(try await store.get(AppSettings.remoteImages(personal)) == .block, "account scope is separate")
    try await store.set(AppSettings.remoteImageSenders(work), ["@news.example"])
    #expect(try await store.get(AppSettings.remoteImageSenders(work)) == ["@news.example"])
    try await store.set(AppSettings.defaultAccount, "robin@example.com")
    #expect(try await store.get(AppSettings.defaultAccount) == "robin@example.com")
}

@Test func snippetsCrudAndRanking() async throws {
    let store = makeStore()
    #expect(try await first(store.snippets(personal)).map(\.shortcut) == ["thx", "intro"], "global ones only")
    let stored = try await store.upsertSnippet(SnippetInfo(account: work, name: "Signoff", shortcut: "bye", bodyHTML: "<p>Best,</p>"))
    #expect(!stored.isNew)
    for _ in 0..<9 { try await store.recordSnippetUse(stored.id) }
    #expect(try await first(store.snippets(work)).first?.id == stored.id, "most used first")
    var edited = stored
    edited.name = "Sign-off"
    _ = try await store.upsertSnippet(edited)
    #expect(try await first(store.snippets(work)).first?.name == "Sign-off")
    try await store.deleteSnippet(stored.id)
    #expect(!(try await first(store.snippets(work))).contains { $0.id == stored.id })
    await #expect(throws: MailPortError.self) { try await store.deleteSnippet(stored.id) }
}

@Test func splitChangesReevaluateTheInbox() async throws {
    let store = makeStore()
    var tabs = store.splits(personal).makeAsyncIterator()
    #expect(try #require(try await tabs.next()).map(\.name) == ["Important"])
    let important = try #require(try await first(store.splits(personal)).first?.id)
    let family = try await store.upsertSplit(SplitDefinition(account: personal, name: "Travel", ruleText: "label:Travel",
                                                             position: 0))
    #expect(try #require(try await tabs.next()).map(\.name) == ["Travel", "Important"])
    let travel = special(21, account: 1).row.id
    #expect(try await keys(store, .split(family), account: personal).contains(travel), "first match wins")
    #expect(!(try await keys(store, .splitOther, account: personal)).contains(travel))
    try await store.reorderSplits(personal, [important, family])
    #expect(try #require(try await tabs.next()).map(\.name) == ["Important", "Travel"])
    await #expect(throws: MailPortError.self) { try await store.reorderSplits(personal, [family]) }
    await #expect(throws: MailPortError.self) {
        _ = try await store.upsertSplit(SplitDefinition(account: personal, name: "Bad", ruleText: "nonsense words"))
    }
    await #expect(throws: MailPortError.self) {
        _ = try await store.upsertSplit(SplitDefinition(account: personal, name: "travel", ruleText: "is:starred"))
    }
    try await store.deleteSplit(personal, family)
    #expect(try await keys(store, .splitOther, account: personal).contains(travel) == !special(21, account: 1).row.isImportant)
}
