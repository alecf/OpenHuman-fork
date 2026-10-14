import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct FixPitchLabelTests {
    typealias F = AutoLabelFixture

    static let fan = EmailAddress(name: "Jo Contest", email: "jo@winners.example")
    static let recruiter = EmailAddress(name: "Rae Hunter", email: "rae@talent.example")
    static let roleSubject = "A senior design role"
    static let roleText = "Hi, I have a senior design role that might interest you."

    func me(_ f: F) async throws -> Account {
        try #require(await AIThreadLoader.first(f.store.accounts())?.first { $0.id == F.work })
    }

    func row(_ f: F, _ subject: String) async throws -> ThreadRow {
        try #require(try await f.inbox().first { $0.subject == subject })
    }

    func entry(_ f: F, _ key: ThreadKey) async -> AutoLabelEntry? {
        try? await f.index.entry(account: key.account, thread: key.gmailThreadID)
    }

    @Test func aThankYouToTheUsersAnnouncementIsNeverPitchWhateverTheModelSays() async throws {
        let f = F(writes: true, verdict: { _ in .pitch })
        let me = try await me(f)
        f.store.deliverMessage(account: F.work, from: Self.fan, subject: "Re: Our spring poster contest winners",
                               text: "Thank you so much! On Mon, Oct 12, 2026 at 9:00 AM <\(me.email)> wrote: "
                                   + "Announcing the winners of our spring poster contest")
        f.store.deliverMessage(account: F.work, from: Self.recruiter, subject: Self.roleSubject, text: Self.roleText)
        await f.center.classifyRecent()
        let thanks = try await row(f, "Re: Our spring poster contest winners")
        let role = try await row(f, Self.roleSubject)
        let thanksEntry = try #require(await entry(f, thanks.id))
        #expect(thanksEntry.category == nil && thanksEntry.source == .derived && thanksEntry.modelID == "rules@1")
        #expect(!f.log.all.contains(AIThreadLoader.threadKey(thanks.id)), "the rules decide; the model is never asked")
        #expect(!f.store.labelNames(of: thanks.id).contains("OpenHuman/Pitch"))
        #expect(await entry(f, role.id)?.category == "Pitch")
        #expect(f.store.labelNames(of: role.id).contains("OpenHuman/Pitch"))
        f.store.deliverMessage(account: F.work, to: role.id, from: EmailAddress(name: nil, email: me.email),
                               subject: "Re: " + Self.roleSubject, text: "Not looking right now, but thank you.")
        await f.center.classifyRecent()
        #expect(await entry(f, role.id)?.category == "Waiting")
        let names = f.store.labelNames(of: role.id)
        #expect(names.contains("OpenHuman/Waiting") && !names.contains("OpenHuman/Pitch"))
    }

    @Test func theChipFollowsTheGmailLabelWhileLabelsAreWritten() async throws {
        let f = F(writes: true, verdict: { _ in .pitch })
        f.store.deliverMessage(account: F.work, from: Self.recruiter, subject: Self.roleSubject, text: Self.roleText)
        await f.center.classifyRecent()
        let role = try await row(f, Self.roleSubject)
        #expect(f.center.title(for: role, labels: await f.labelMap()) == "Pitch")
        let pitch = try #require(await f.labels().first { $0.name == "OpenHuman/Pitch" })
        _ = try await f.store.apply(.modifyLabels([role.id], add: [], remove: [pitch.labelID]))
        let after = try await row(f, Self.roleSubject)
        #expect(f.center.category(of: role.id) == "Pitch", "this Mac still holds its answer")
        #expect(f.center.title(for: after, labels: await f.labelMap()) == nil, "but the chip says what Gmail has")
    }

    @Test func aLabelTakenOffInGmailIsLearnedAndNeverPutBack() async throws {
        let f = F(writes: true, verdict: { _ in .pitch })
        await f.env.learning.start()
        await f.env.learning.setOn(true)
        f.center.start()
        await eventually { f.center.isOn }
        f.store.deliverMessage(account: F.work, from: Self.recruiter, subject: Self.roleSubject, text: Self.roleText)
        await eventuallyAsync { (try? await self.row(f, Self.roleSubject)) != nil }
        let role = try await row(f, Self.roleSubject).id
        await eventually { f.store.labelNames(of: role).contains("OpenHuman/Pitch") }
        f.store.deliverMessage(account: F.work, from: Self.fan, subject: "Unrelated", text: "Lunch was great, thanks.")
        await eventuallyAsync { await self.entry(f, role)?.writtenToGmail == true }
        let pitch = try #require(await f.labels().first { $0.name == "OpenHuman/Pitch" })
        _ = try await f.store.apply(.modifyLabels([role], add: [], remove: [pitch.labelID]))
        await eventuallyAsync { await self.entry(f, role)?.source == .user }
        let corrected = try #require(await entry(f, role))
        #expect(corrected.category == nil && corrected.rejected == ["Pitch"] && f.center.corrections == 1)
        await eventually {
            f.env.learning.rejectedAutoLabels(account: F.work, sender: Self.recruiter.email).contains("Pitch")
        }
        let next = f.store.deliverMessage(account: F.work, to: role, from: Self.recruiter, subject: Self.roleSubject,
                                          text: "Following up on the design role.", at: fixedNow.addingTimeInterval(60))
        await eventuallyAsync { await self.entry(f, role)?.latestMessage == next.gmailMessageID }
        #expect(await entry(f, role)?.category == nil)
        #expect(await entry(f, role)?.rejected == ["Pitch"], "the rejection is kept for good")
        #expect(!f.store.labelNames(of: role).contains("OpenHuman/Pitch"))
        f.store.deliverMessage(account: F.work, from: Self.recruiter, subject: "Another role", text: "Another opening.",
                               at: fixedNow.addingTimeInterval(120))
        await eventuallyAsync {
            guard let other = try? await self.row(f, "Another role") else { return false }
            return await self.entry(f, other.id) != nil
        }
        let other = try await row(f, "Another role")
        #expect(await entry(f, other.id)?.category == nil)
        #expect(!f.store.labelNames(of: other.id).contains("OpenHuman/Pitch"))
    }

    @Test func wrongLabelTakesItOffInOneActionWithUndo() async throws {
        let f = F(writes: true, verdict: { _ in .pitch })
        f.store.deliverMessage(account: F.work, from: Self.recruiter, subject: Self.roleSubject, text: Self.roleText)
        await f.center.classifyRecent()
        let role = try await row(f, Self.roleSubject)
        var context = ActionContext(scope: .reader, account: F.work, accountCount: 1, location: .system(.inbox),
                                    selection: [role.id], focusedThread: role.id, canWrite: true)
        context.targets.autoLabel = f.center.title(for: role, labels: await f.labelMap())
        let descriptor = try #require(ActionCatalog.descriptor(.autoLabelWrong))
        #expect(ActionRules.title(for: descriptor, in: context) == "Wrong label (not Pitch)")
        #expect(ActionRules.availability(descriptor, in: context) == .enabled)
        var plain = context
        plain.targets.autoLabel = nil
        #expect(ActionRules.availability(descriptor, in: plain) == .hidden, "no auto label, no entry")
        #expect(await f.env.actions.run(.autoLabelWrong, source: .palette, host: nil, context: context))
        await eventually { !f.store.labelNames(of: role.id).contains("OpenHuman/Pitch") }
        await eventuallyAsync { await self.entry(f, role.id)?.source == .user }
        let corrected = try #require(await entry(f, role.id))
        #expect(corrected.category == nil && corrected.rejected == ["Pitch"] && f.center.corrections == 1)
        let undo = try #require(f.env.undo)
        #expect(undo.canUndo)
        await undo.undoLast()
        await eventually { f.store.labelNames(of: role.id).contains("OpenHuman/Pitch") }
    }

    @Test func inReadOnlyWrongLabelChangesOnlyThisMac() async throws {
        let f = F(safeMode: .readOnly, writes: true, verdict: { _ in .pitch })
        f.store.deliverMessage(account: F.work, from: Self.recruiter, subject: Self.roleSubject, text: Self.roleText)
        await f.center.classifyRecent()
        let role = try await row(f, Self.roleSubject)
        let labels = await f.labelMap()
        #expect(f.center.title(for: role, labels: labels) == "Pitch", "nothing is written, so the chip is local")
        #expect(try await f.center.markWrong(role.id, row: role, labels: labels) == "Pitch")
        #expect(f.center.title(for: role, labels: labels) == nil)
        #expect(f.recorder.calls.isEmpty, "read-only: nothing reaches the mail port")
    }

    @Test func aFailedLabelWriteIsTriedAgainAndTheChipWaitsForGmail() async throws {
        let f = F(writes: true, verdict: { _ in .pitch })
        f.center.start()
        await eventually { f.center.isOn && !f.center.isWorking }
        f.store.failNextCommand()
        f.store.deliverMessage(account: F.work, from: Self.recruiter, subject: Self.roleSubject, text: Self.roleText)
        await eventuallyAsync { (try? await self.row(f, Self.roleSubject)) != nil }
        let role = try await row(f, Self.roleSubject).id
        await eventuallyAsync { await self.entry(f, role)?.category == "Pitch" }
        await eventually { f.center.failures >= 1 && !f.center.isWorking }
        let row = try await row(f, Self.roleSubject)
        #expect(!f.store.labelNames(of: role).contains("OpenHuman/Pitch"))
        #expect(f.center.title(for: row, labels: await f.labelMap()) == nil, "no chip Gmail does not have")
        f.store.deliverMessage(account: F.work, from: Self.fan, subject: "Unrelated", text: "Lunch was great, thanks.")
        await eventually { f.store.labelNames(of: role).contains("OpenHuman/Pitch") }
    }

    @Test func aMarketingNewsletterIsNeverRespond() async throws {
        let subject = "Should you delete old videos after a niche switch?"
        for (answer, expected) in [(AutoLabelCategory.respond, nil), (.pitch, nil), (.marketing, "Marketing"),
                                   (.news, "News")] as [(AutoLabelCategory, String?)] {
            let f = F(writes: false, verdict: { _ in answer })
            f.store.deliverMessage(account: F.work, from: EmailAddress(name: "Example Video", email: "hello@send.example.com"),
                                   subject: subject,
                                   text: "View in browser. Hi Sam, should you delete old videos after a niche switch? "
                                       + "Plus three ways to win back views this week.",
                                   unsubscribe: .oneClick(host: "send.example.com"))
            await f.center.classifyRecent()
            let newsletter = try await row(f, subject)
            #expect(await entry(f, newsletter.id)?.category == expected, "model said \(answer)")
            guard let detail = await AIThreadLoader.first(f.store.threadDetail(newsletter.id)) ?? nil,
                  let latest = detail.messages.last else { Issue.record("no detail"); continue }
            let signals = await f.center.signals(for: latest)
            #expect(signals.hasListUnsubscribe && signals.senderAddress == "hello@send.example.com")
        }
    }

    @Test func notAPitchAlsoTakesThePitchLabelOff() async throws {
        let f = F(writes: true, verdict: { _ in .pitch })
        f.store.deliverMessage(account: F.work, from: Self.recruiter, subject: Self.roleSubject, text: Self.roleText)
        await f.center.classifyRecent()
        let role = try await row(f, Self.roleSubject)
        var context = ActionContext(scope: .reader, account: F.work, accountCount: 1, location: .system(.inbox),
                                    selection: [role.id], focusedThread: role.id, sender: Self.recruiter.email,
                                    canWrite: true)
        context.targets.autoLabel = "Pitch"
        #expect(await f.env.actions.run(.notAPitch, source: .palette, host: nil, context: context))
        await eventually { !f.store.labelNames(of: role.id).contains("OpenHuman/Pitch") }
        await eventuallyAsync { await self.entry(f, role.id)?.rejected == ["Pitch"] }
    }

    @Test func respondNeverGoesToAutomatedOrMassMail() async throws {
        let f = F(writes: false, verdict: { _ in .respond })
        let me = try await me(f)
        f.store.deliverMessage(account: F.work, from: EmailAddress(name: "Exports", email: "noreply@service.example"),
                               subject: "Your export is ready", text: "Your export finished. Download it within 7 days.")
        let crowd = (1...12).map { EmailAddress(name: nil, email: "person\($0)@team.example") }
        f.store.deliverMessage(account: F.work, from: EmailAddress(name: "Ops", email: "ops@team.example"),
                               subject: "All hands moved", text: "Please update your calendars.",
                               recipients: [EmailAddress(name: nil, email: me.email)] + crowd)
        f.store.deliverMessage(account: F.work, from: EmailAddress(name: "Kim", email: "kim@client.example"),
                               subject: "Homepage copy", text: "Can you check the homepage copy before 3pm?")
        await f.center.classifyRecent()
        #expect(await entry(f, try await row(f, "Your export is ready").id)?.category == nil)
        #expect(await entry(f, try await row(f, "All hands moved").id)?.category == nil)
        #expect(await entry(f, try await row(f, "Homepage copy").id)?.category == "Respond")
        #expect(f.center.modelCalls >= 1)
    }
}
