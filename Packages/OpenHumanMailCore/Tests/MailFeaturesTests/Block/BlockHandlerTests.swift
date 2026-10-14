import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct BlockHandlerTests {
    let account = AccountID(1)

    func deliver(_ f: ActionFixture, _ senders: [String]) async -> [String: ThreadKey] {
        for sender in senders {
            f.store.deliverMessage(account: account, from: EmailAddress(name: nil, email: sender), subject: "Synthetic from \(sender)")
        }
        await eventually { senders.allSatisfy { s in f.rows.contains { $0.participants.contains { $0.email == s } } } }
        var keys: [String: ThreadKey] = [:]
        for sender in senders {
            keys[sender] = f.rows.first { $0.participants.contains { $0.email == sender } }?.id
        }
        return keys
    }

    func context(_ f: ActionFixture, thread: ThreadKey, sender: String) -> ActionContext {
        var c = f.router.actionContext()
        c.account = account
        c.focusedThread = thread
        c.selection = [thread]
        c.sender = sender
        return c
    }

    func rules(_ f: ActionFixture) async -> [BlockRule] {
        (try? await f.store.get(BlockKeys.rules(account))) ?? []
    }

    func inInbox(_ f: ActionFixture, _ key: ThreadKey?) -> Bool {
        guard let key else { return false }
        return f.rows.contains { $0.id == key }
    }

    @Test func blockDomainCleansUpTheDomainAndItsSubdomainsButNeverALookAlike() async throws {
        let f = ActionFixture(corpus: .make(threadCount: 6, now: fixedNow))
        await f.loaded()
        let keys = await deliver(f, ["news@acme.example", "alerts@mail.acme.example", "promo@acme.example.net",
                                     "offers@notacme.example"])
        let news = try #require(keys["news@acme.example"])
        #expect(await f.run(.blockDomain, context: context(f, thread: news, sender: "news@acme.example")))
        await eventually { f.env.notices.toasts.contains { $0.message.hasPrefix("Blocked acme.example. Clean up") } }
        #expect(await rules(f).map(\.id) == ["domain:acme.example"])
        let offer = try #require(f.env.notices.toasts.first { $0.message.hasPrefix("Blocked acme.example. Clean up") })
        #expect(offer.message == "Blocked acme.example. Clean up 2 conversations from them?")
        #expect(offer.actionTitle == "Archive all" && offer.secondaryActionTitle == "Move to Trash", "the default leads")

        await f.env.notices.activate(offer.id)
        await eventually { !inInbox(f, news) && !inInbox(f, keys["alerts@mail.acme.example"]) }
        #expect(inInbox(f, keys["promo@acme.example.net"]), "a look-alike domain is not acme.example")
        #expect(inInbox(f, keys["offers@notacme.example"]))

        #expect(await f.run(.undo))
        await eventually { inInbox(f, news) && inInbox(f, keys["alerts@mail.acme.example"]) }
        await eventually { f.env.undo?.stack.isEmpty == true }
        #expect(await rules(f).isEmpty)
    }

    @Test func blockSenderOfSomeoneYouWroteToAsksFirst() async throws {
        let corpus = FakeCorpus.make(threadCount: 10, now: fixedNow)
        let thread = try #require(corpus.threads.first { t in
            t.detail.messages.contains { $0.from?.email == FakeCorpus.me.email && !$0.to.isEmpty }
        })
        let counterpart = try #require(thread.detail.messages.first { $0.from?.email != FakeCorpus.me.email }?.from?.email)
        let f = ActionFixture(corpus: corpus)
        await f.loaded()
        let question = "You've written to \(counterpart). Block it anyway?"

        #expect(await f.run(.blockSender, context: context(f, thread: thread.row.id, sender: counterpart)))
        await f.toast(question)
        let ask = try #require(f.env.notices.toasts.first { $0.message == question })
        #expect(ask.actionTitle == "Block anyway" && ask.secondaryActionTitle == "Cancel")
        #expect(await rules(f).isEmpty, "nothing is saved before the answer")
        await f.env.notices.activateSecondary(ask.id)
        #expect(await rules(f).isEmpty, "Cancel saves nothing")

        #expect(await f.run(.blockSender, context: context(f, thread: thread.row.id, sender: counterpart)))
        await f.toast(question)
        let again = try #require(f.env.notices.toasts.first { $0.message == question })
        await f.env.notices.activate(again.id)
        await eventually { f.env.undo?.stack.contains { String(localized: $0.title) == "Blocked \(counterpart)" } == true }
        #expect(await rules(f).map(\.id) == ["sender:\(counterpart)"])
    }

    @Test func blockingTheSameSenderTwiceSaysSoAndAddsNothing() async throws {
        let f = ActionFixture(corpus: .make(threadCount: 4, now: fixedNow))
        await f.loaded()
        let keys = await deliver(f, ["news@acme.example"])
        let news = try #require(keys["news@acme.example"])
        #expect(await f.run(.blockSender, context: context(f, thread: news, sender: "news@acme.example")))
        await eventually { f.env.notices.toasts.contains { $0.message.hasPrefix("Blocked news@acme.example. Clean up") } }
        #expect(await f.run(.blockSender, context: context(f, thread: news, sender: "News+Promo@Acme.Example")))
        await f.toast("Already blocked: news@acme.example")
        #expect(await rules(f).count == 1)
        #expect(f.env.undo?.stack.count == 1)
    }
}

@MainActor
@Suite struct BlockedSettingsShowMailTests {
    @Test func showMailSearchesTheRulesAccountForEverythingFromIt() async throws {
        let f = SettingsFixture()
        let router = f.env.router
        router.start()
        await eventually { router.active != nil && router.accounts.count == 2 }
        router.switchAccount(to: f.work)
        let model = BlockedSettingsModel(environment: f.env)
        model.start()
        await eventually { model.accounts.count == 2 }
        model.account = f.personal
        let rule = try #require(BlockRule(kind: .domain, value: "acme.example", createdAt: Date()))

        model.showMail(rule)
        #expect(router.activeAccountID == f.personal, "the rule's account, not the one the window was on")
        #expect(f.env.overlays.search.text == "from:\"acme.example\"")
        #expect(router.active?.location == .search("from:\"acme.example\""))
    }
}
