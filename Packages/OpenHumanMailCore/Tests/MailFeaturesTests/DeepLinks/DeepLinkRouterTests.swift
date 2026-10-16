import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import OpenHumanLinks
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct DeepLinkRouterTests {
    static let mutations = ReviewQueueTests.mutations
    let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    func url(_ text: String) -> URL { URL(string: text)! }

    @Test func parseFailuresAreInvalidWithOneToastAndCountTowardTheLimit() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let links = DeepLinkRouter(router: { f.router })
        #expect(links.handle(url("openhuman://nowhere/x"), receivedAt: t0) == .invalid)
        #expect(f.toasts.last == DeepLinkRouter.invalidText)
        #expect(links.handle(url("https://example.com"), receivedAt: t0) == .invalid)
        #expect(f.recorder.calls.isEmpty)
    }

    @Test func sixLinksInTenSecondsDropTheSixthWithOneNotice() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let links = DeepLinkRouter(router: { f.router })
        let search = url("openhuman://search?q=budget")
        for i in 0..<5 {
            guard case .followed(let outcome) = links.handle(search, receivedAt: t0.addingTimeInterval(Double(i))) else {
                Issue.record("link \(i) should be followed"); return
            }
            #expect(outcome.handled)
        }
        #expect(links.handle(search, receivedAt: t0.addingTimeInterval(5)) == .dropped)
        #expect(links.handle(search, receivedAt: t0.addingTimeInterval(6)) == .dropped)
        #expect(f.toasts.filter { $0 == DeepLinkRouter.rateLimitedText }.count == 1, "one notice for the burst")
        guard case .followed = links.handle(search, receivedAt: t0.addingTimeInterval(10.5)) else {
            Issue.record("the window should have cleared"); return
        }
    }

    @Test func linksBeforeTheWindowIsReadyQueueUpToTenAndFollowInOrder() async throws {
        let f = ComposeFixture()
        var ready: AppRouter?
        let links = DeepLinkRouter(limits: .init(maxLinks: 100), router: { ready })
        var activated = 0
        links.didFollow = { _ in activated += 1 }
        #expect(links.handle(url("openhuman://search?q=first"), receivedAt: t0) == .queued)
        for i in 0..<12 { _ = links.handle(url("openhuman://search?q=n\(i)"), receivedAt: t0) }
        #expect(links.queuedCount == 10, "the queue holds at most 10")
        ready = f.router
        links.readinessChanged()
        #expect(links.queuedCount == 10)
        await f.loaded()
        await soon { links.queuedCount == 0 }
        #expect(f.router.location == .search("n8"), "the last held link wins the window")
        #expect(activated == 10)
        #expect(f.recorder.calls.filter { Self.mutations.contains($0) }.isEmpty)
    }

    @Test func anUnknownAccountIsANoticeNotAGuess() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let links = DeepLinkRouter(router: { f.router })
        let active = f.router.activeAccountID
        guard case .followed(let outcome) = links.handle(url("openhuman://thread/nobody@example.org/abc"), receivedAt: t0) else {
            Issue.record("expected a refusal"); return
        }
        #expect(outcome == LinkOutcome("No account named “nobody@example.org”.", handled: false))
        #expect(f.toasts.last == "No account named “nobody@example.org”.")
        #expect(f.router.activeAccountID == active)
        #expect(links.handle(url("openhuman://review?ids=abc"), receivedAt: t0) == .invalid)
        #expect(!f.env.review.isOpen)
    }

    @Test func composeLinksNeverSetBccAndAskBeforeTheFirstSend() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let links = DeepLinkRouter(router: { f.router })
        let raw = "openhuman://compose?account=Work&to=a@example.com,b@example.com&cc=c@example.com&subject=Hi&bcc=spy@evil.example"
        guard case .followed(let outcome) = links.handle(url(raw), receivedAt: t0) else { Issue.record("not followed"); return }
        #expect(outcome.handled)
        let session = try #require(f.compose.windowSession)
        #expect(session.linkRecipients?.map(\.email) == ["a@example.com", "b@example.com", "c@example.com"])
        #expect(session.bcc.tokens.isEmpty && session.linkTriedBcc)
        #expect(session.linkBanner?.contains("a@example.com, b@example.com, c@example.com") == true)
        #expect(session.subject == "Hi")
        await session.settle()
        #expect(f.recorder.calls.filter { Self.mutations.contains($0) }.isEmpty, "\(f.recorder.calls)")
        #expect(await f.run(.send, in: session))
        #expect(session.isLinkConfirmationShown && !f.recorder.calls.contains("send"))
        session.confirmLinkRecipients()
        #expect(await f.run(.send, in: session))
        #expect(f.recorder.calls.filter { $0 == "send" }.count == 1)
    }

    @Test func mailtoFromTheReaderOpensTheSameComposerWithoutBcc() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let action = ReaderLinkAction.resolve(url("mailto:dana@example.com?subject=Hello&bcc=spy@evil.example"))
        #expect(action.follow(with: f.router) == nil)
        let session = try #require(f.compose.windowSession)
        #expect(session.linkRecipients?.map(\.email) == ["dana@example.com"] && session.subject == "Hello")
        #expect(session.bcc.tokens.isEmpty)
        #expect(f.recorder.calls.filter { Self.mutations.contains($0) }.isEmpty)
    }

    @Test func aMailtoLinkFromTheSystemOpensADraftThatAsksBeforeTheFirstSend() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let links = DeepLinkRouter(router: { f.router })
        let raw = "mailto:dana@example.test,lee@example.test?cc=kai@example.test&subject=Lunch%3F&body=Noon%0D%0Aworks"
            + "&bcc=spy@evil.example"
        guard case .followed(let outcome) = links.handle(url(raw), receivedAt: t0) else { Issue.record("not followed"); return }
        #expect(outcome.handled)
        let session = try #require(f.compose.windowSession)
        #expect(session.linkRecipients?.map(\.email) == ["dana@example.test", "lee@example.test", "kai@example.test"])
        #expect(session.subject == "Lunch?" && session.bcc.tokens.isEmpty && session.linkTriedBcc)
        #expect(session.linkBanner?.contains("dana@example.test, lee@example.test, kai@example.test") == true)
        await session.settle()
        #expect(f.recorder.calls.filter { Self.mutations.contains($0) }.isEmpty, "\(f.recorder.calls)")
        #expect(await f.run(.send, in: session))
        #expect(session.isLinkConfirmationShown && !f.recorder.calls.contains("send"), "never sent by the link itself")
    }

    @Test func hostileOrEmptyMailtoLinksOpenNothing() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let links = DeepLinkRouter(limits: .init(maxLinks: 100), router: { f.router })
        let hostile = [
            "mailto:a@example.test%0D%0ABcc:%20spy@evil.example",
            "mailto:?to=a@example.test%0ABcc:spy@evil.example",
            "mailto:?cc=a@example.test%0D%0AX-Header:1",
            "mailto:?bcc=spy@evil.example",
            "mailto:?unknown=1",
            "mailto:a@example.test?body=" + String(repeating: "x", count: 33_000),
        ]
        for raw in hostile {
            #expect(links.handle(url(raw), receivedAt: t0) == .invalid, "\(raw.prefix(60))")
        }
        #expect(f.compose.windowSession == nil)
        #expect(f.toasts.last == DeepLinkRouter.invalidText)
        #expect(f.recorder.calls.filter { Self.mutations.contains($0) }.isEmpty)
    }

    @Test func mailtoAndAppLinksParseThroughOneEntry() {
        #expect(DeepLinkRouter.parse(url("MAILTO:dana@example.test")) == .success(.compose(ComposePrefill(to: ["dana@example.test"]))))
        #expect(DeepLinkRouter.parse(url("openhuman://search?q=x")) == .success(.search(query: "x", account: nil)))
        #expect(DeepLinkRouter.parse(url("https://example.test")) == .failure(.wrongScheme))
        #expect(DeepLinkRouter.parse(url("mailto:?subject=Hi%0D%0ABcc:%20spy@evil.example"))
                == .success(.compose(ComposePrefill(subject: "Hi Bcc: spy@evil.example"))), "a subject stays one line")
    }

    @Test func draftLinksOpenTheComposerByLocalIDOrGmailID() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let links = DeepLinkRouter(router: { f.router })
        let key = f.store.agentCreatesDraft(account: ComposeFixture.work,
                                            fields: DraftFields(to: [EmailAddress(email: "dana@acme.example")], subject: "Agent",
                                                                bodyHTML: "<p>Hi</p>"))
        _ = links.handle(url("openhuman://draft/Work/\(key.rawValue)"), receivedAt: t0)
        await soon { f.compose.windowSession?.draftKey == key }
        f.compose.close(try #require(f.compose.windowSession))
        await f.compose.settle()
        let existing = try #require(await pendingGmailDraft(f))
        _ = links.handle(url("openhuman://draft/robin@example.com/\(existing.1.rawValue)"), receivedAt: t0)
        await soon { f.compose.windowSession?.draftKey == existing.0 }
        #expect(f.recorder.calls.filter { Self.mutations.contains($0) && $0 != "flushDraft" && $0 != "discardDraft" }.isEmpty,
                "\(f.recorder.calls)")
        _ = links.handle(url("openhuman://draft/Work/none"), receivedAt: t0)
        await f.toast("Draft not found")
    }

    func pendingGmailDraft(_ f: ComposeFixture) async -> (DraftKey, GmailDraftID)? {
        do {
            for try await rows in f.store.drafts(ComposeFixture.work, review: false) {
                if let row = rows.first(where: { $0.gmailDraftID != nil && $0.status == .editing }), let id = row.gmailDraftID {
                    return (row.id, id)
                }
                return nil
            }
        } catch {}
        return nil
    }

    @Test func everyLinkCaseMakesNoMutationCall() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let links = DeepLinkRouter(limits: .init(maxLinks: 1_000), router: { f.router })
        let thread = try await f.thread(subject: try #require(f.router.list?.rows.first).subject)
        let drafts = [
            "openhuman://thread/Work/\(thread.gmailThreadID.rawValue)",
            "openhuman://thread/Work/unknownthread",
            "openhuman://draft/Work/unknowndraft",
            "openhuman://review?account=Work&ids=a1,b2",
            "openhuman://review?ids=Work:a1,nobody:b2",
            "openhuman://search?q=budget&account=Work",
            "openhuman://compose?to=a@example.com&subject=x&body=hello&bcc=z@example.com",
            "openhuman://compose",
        ]
        for text in drafts { _ = links.handle(url(text), receivedAt: t0) }
        await f.env.review.settle()
        await f.compose.settle()
        await soon { f.toasts.contains("Draft not found") }
        let calls = f.recorder.calls
        #expect(calls.allSatisfy { $0.hasPrefix("fetch") || $0 == "flushDraft" || $0 == "discardDraft" },
                "links only fetch (flush/discard come from closing the replaced composer): \(calls)")
        #expect(!calls.contains("send") && !calls.contains("setReviewState") && !calls.contains("apply"))
        #expect(f.store.pendingOperationCount == 0)
    }
}

@Suite struct LinkSourceScanTests {
    @Test func linksCallNoWritePortAndTheQueueNeverSendsItself() throws {
        let sources = try SendReachabilityTests.sources()
        let write = #"\.(send|sendNow|scheduleSend|cancelScheduledSend|apply|createDraft|updateDraft|flushDraft|discardDraft|setReviewState|resolveDraftConflict|upsertSnippet|unsubscribe)\("#
        #expect(SendReachabilityTests.files(sources.filter { ["DeepLinkRouter.swift", "AppRouter+Links.swift"].contains($0.name) },
                                            matching: write).isEmpty)
        let review = sources.filter { $0.name.hasPrefix("Review") }
        #expect(!review.isEmpty)
        #expect(SendReachabilityTests.files(review, matching: #"commands\??\.(send|sendNow|scheduleSend|apply|createDraft|updateDraft|flushDraft)\("#
            ).isEmpty, "the review queue sends only by pressing the composer's Send (compose.send)")
        #expect(SendReachabilityTests.files(sources, matching: #"bcc:\s*[^\[\n]"#).intersection(["DeepLinkRouter.swift"]).isEmpty)
    }
}
