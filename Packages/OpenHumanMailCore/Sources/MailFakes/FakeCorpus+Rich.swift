import Foundation
import MailModel
import OpenHumanCore

extension FakeCorpus {
    public static var small: FakeCorpus { rich(threadCount: 200) }
    public static var large: FakeCorpus { rich(threadCount: 50_000) }

    public static let personalMe = EmailAddress(name: "Robin Example", email: "robin.home@example.net")

    public static func rich(threadCount: Int, now: Date = Date(), seed: UInt64 = 0x0de1_7a11) -> FakeCorpus {
        var generator = RichGenerator(now: now, seed: seed)
        let workCount = threadCount - threadCount * 3 / 10
        let work = generator.mailbox(
            account: Account(id: AccountID(1), email: me.email, displayName: me.name, alias: "Work", health: .active,
                             sendAs: [SenderIdentity(email: me.email, name: me.name, isDefault: true, isPrimary: true,
                                                     signatureHTML: "<p>Robin Example<br>Example Co.</p>"),
                                      SenderIdentity(email: "robin@team.example", name: "Robin (Team)", isDefault: false,
                                                     isPrimary: false, signatureHTML: "<p>Robin · Team</p>")]),
            threadCount: workCount, profile: .work)
        let personal = generator.mailbox(
            account: Account(id: AccountID(2), email: personalMe.email, displayName: personalMe.name, alias: "Personal",
                             health: .active,
                             sendAs: [SenderIdentity(email: personalMe.email, name: personalMe.name, isDefault: true,
                                                     isPrimary: true)]),
            threadCount: threadCount - workCount, profile: .personal)
        var ids = generator.ids
        let snippets = [
            SnippetInfo(id: ids.nextSnippet(), name: "Thanks", shortcut: "thx",
                        bodyHTML: "<p>Thanks, {{first_name}}! I'll take a look today.</p>",
                        variables: [SnippetVariableInfo(name: "first_name")], useCount: 7),
            SnippetInfo(id: ids.nextSnippet(), name: "Intro", shortcut: "intro", subject: "Introduction",
                        bodyHTML: "<p>Hi {{first_name}}, meet {{other_name}}. I think you two should talk.</p>",
                        variables: [SnippetVariableInfo(name: "first_name"),
                                    SnippetVariableInfo(name: "other_name", defaultValue: "my colleague")], useCount: 2),
            SnippetInfo(id: ids.nextSnippet(), account: AccountID(1), name: "Follow up", shortcut: "fu",
                        bodyHTML: "<p>Following up on this, {{first_name}}. Could you send an update by {{date+3}}?</p>",
                        variables: [SnippetVariableInfo(name: "first_name")], useCount: 4),
        ]
        return FakeCorpus(mailboxes: [work, personal], snippets: snippets)
    }
}

private enum RichProfile {
    case work, personal

    var topics: [String] {
        switch self {
        case .work: FakeCorpus.topics
        case .personal:
            ["Weekend plans", "Dinner on Friday", "Flight confirmation", "Photos from the trip", "Rent receipt",
             "Book club", "Dentist appointment", "Birthday gift ideas", "Garden project", "Concert tickets",
             "Car service", "Family reunion"]
        }
    }

    var people: [EmailAddress] {
        switch self {
        case .work: FakeCorpus.people
        case .personal:
            [.init(name: "Alex Rivera", email: "alex.rivera@example.org"), .init(name: "Jamie Park", email: "jamie@example.net"),
             .init(name: "Morgan Lee", email: "morgan@example.com"), .init(name: "Book Club", email: "club@lists.example"),
             .init(name: "City Library", email: "notices@library.example"), .init(name: "Fly Example", email: "trips@air.example"),
             .init(name: "Shop Example", email: "orders@shop.example"), .init(name: "Chris Diaz", email: "chris@example.com")]
        }
    }

    var userLabels: [(String, (String, String)?)] {
        switch self {
        case .work:
            [("Clients", ("#fb4c2f", "#ffffff")), ("Receipts", ("#16a766", "#ffffff")), ("Travel", nil),
             ("Hiring", ("#4a86e8", "#ffffff")), ("Projects", nil), ("Projects/Atlas", ("#a479e2", "#ffffff")),
             ("Projects/Beacon", nil)]
        case .personal:
            [("Family", ("#f691b3", "#000000")), ("Receipts", ("#16a766", "#ffffff")), ("Travel", nil), ("Bills", nil)]
        }
    }
}

private struct RichGenerator {
    let now: Date
    var rng: SplitMix64
    var ids = FakeIDs()
    var threadRow: Int64 = 1
    var messageRow: Int64 = 1
    var attachmentID: Int64 = 1
    var gmailDraft = 1
    var snippets: [FakeBodySpec: String] = [:]

    init(now: Date, seed: UInt64) {
        self.now = now
        self.rng = SplitMix64(seed: seed)
    }

    mutating func mailbox(account: Account, threadCount: Int, profile: RichProfile) -> FakeCorpus.Mailbox {
        let me = EmailAddress(name: account.displayName, email: account.email)
        let meSet: Set<String> = Set([account.email.lowercased()] + account.sendAs.map { $0.email.lowercased() })
        var labels = FakeLabels.standard(account: account.id, ids: &ids)
        var position = labels.count
        var byName: [String: GmailLabelID] = [:]
        func addLabel(_ name: String, _ color: (String, String)?) -> GmailLabelID {
            if let id = byName[name] { return id }
            let label = FakeLabels.user(name, account: account.id, position: position, color: color, ids: &ids)
            position += 1
            labels.append(label)
            byName[name] = label.labelID
            return label.labelID
        }
        for (name, color) in profile.userLabels { _ = addLabel(name, color) }
        let snoozedMarker = addLabel(OHGmailLabels.snoozed, nil)
        _ = addLabel(OHGmailLabels.scheduled, nil)
        _ = addLabel(OHGmailLabels.agent, nil)
        var userLabelRows: [GmailLabelID: Int64] = [:]
        for label in labels where label.kind == .user && !label.isHidden && !label.name.hasPrefix(ScheduleLabel.prefix) {
            userLabelRows[label.labelID] = label.id
        }
        let topics = profile.topics
        let people = profile.people

        var threads: [FakeCorpus.Thread] = []
        threads.reserveCapacity(threadCount)
        var drafts: [DraftSummary] = []
        var stamps: [DraftKey: String] = [:]
        var reminders: [ReminderItem] = []
        var lastAt = now.addingTimeInterval(-Double(rng.next(in: 3...20)) * 60)

        for index in 0..<threadCount {
            let topic = topics[index % topics.count]
            let counterpart = people[Int(rng.next(in: 0...UInt64(people.count - 1)))]
            let other = people[(index + 3) % people.count]
            let isList = counterpart.email.contains("news.") || counterpart.email.contains("lists.")
                || counterpart.email.contains("notices@")
            let key = ThreadKey(account: account.id, rowID: threadRow, gmailThreadID: GmailThreadID("fake-t\(threadRow)"))
            threadRow += 1

            var messageCount = isList ? 1 : Int(rng.next(in: 1...4))
            var kinds: [FakeBodyKind] = []
            var inInbox = rng.chance(62)
            var unread = inInbox && (index < 8 ? rng.chance(70) : rng.chance(18))
            var starred = rng.chance(8)
            var important = !isList && rng.chance(33)
            var trashed = false, spam = false, sentOnly = false
            var extraLabels: [GmailLabelID] = []
            var attachmentKinds: [String] = rng.chance(12) ? ["pdf"] : (rng.chance(5) ? ["png"] : [])
            var unsubscribe: UnsubscribeInfo?
            var category: GmailLabelID? = isList ? FakeLabels.updates : nil
            var snoozeLabels: [GmailLabelID] = []
            var subject = isList ? "\(topic) weekly" : topic

            switch index {
            case 0: inInbox = true; unread = true; important = true
            case 1: inInbox = true; unread = true; starred = true; messageCount = 1; kinds = [.calendarInvite]
                subject = "Invitation: \(topic) review"
            case 2: inInbox = true; messageCount = 2; kinds = [.plainShort, .cidImage]; attachmentKinds = ["cid", "pdf"]
            case 3: inInbox = true; messageCount = 12
            case 4:
                inInbox = true; unread = true; messageCount = 1
                kinds = [profile == .work ? .hostile : .receipt]
                subject = profile == .work ? "Action required: verify your account" : "Your order receipt"
            case 5: inInbox = true; messageCount = 1; kinds = [.newsletter]; unsubscribe = .oneClick(host: "news.example")
                category = FakeLabels.promotions; subject = "\(topic) weekly"
            case 6: inInbox = true; messageCount = 1; kinds = [.newsletter]; category = FakeLabels.updates
                unsubscribe = .mailto(EmailAddress(email: "unsubscribe@news.example"), subject: "unsubscribe")
                subject = "\(topic) digest"
            case 7: inInbox = true; messageCount = 1; kinds = [.newsletter]; category = FakeLabels.social
                unsubscribe = URL(string: "https://news.example/preferences").map { .link($0) }
                subject = "\(topic) roundup"
            case 8, 9, 10:
                inInbox = false; unread = false
                snoozeLabels = [snoozedMarker]
                switch index {
                case 8: snoozeLabels.append(addLabel(ScheduleLabel(kind: .snoozed, due: now.addingTimeInterval(86_400)).name, nil))
                case 9:
                    snoozeLabels.append(addLabel(ScheduleLabel(kind: .snoozed, due: now.addingTimeInterval(3 * 86_400)).name, nil))
                    snoozeLabels.append(addLabel(ScheduleLabel(kind: .snoozed, due: now.addingTimeInterval(4 * 86_400)).name, nil))
                default: snoozeLabels.append(addLabel("\(OHGmailLabels.snoozed)/next-week", nil))
                }
            case 11: inInbox = true
            case 12: inInbox = false; unread = false
            case 13, 22: inInbox = false; unread = false; messageCount = max(messageCount, 2)
            case 14, 15, 16: inInbox = true; messageCount = max(messageCount, 2)
            case 17: trashed = true; inInbox = false
            case 18: spam = true; inInbox = false; messageCount = 1; kinds = [.simpleHTML]; subject = "You won a prize"
            case 19: sentOnly = true; inInbox = false; unread = false; messageCount = 1
            case 20: inInbox = false; unread = false; extraLabels = [addLabel(profile == .work ? "Clients" : "Family", nil)]
            case 21:
                inInbox = true
                extraLabels = profile == .work ? [addLabel("Projects/Atlas", nil), addLabel("Clients", nil)] : [addLabel("Travel", nil)]
            case 23: inInbox = true; messageCount = 1; kinds = [.receipt]; extraLabels = [addLabel("Receipts", nil)]
                subject = "Receipt for order \(index * 1_013)"
            default:
                if !isList, rng.chance(12), let pick = profile.userLabels.randomElement(using: &rng) {
                    extraLabels.append(addLabel(pick.0, nil))
                }
                if rng.chance(2) { trashed = true; inInbox = false }
            }
            if kinds.isEmpty {
                kinds = (0..<messageCount).map { i in
                    if isList { return .newsletter }
                    let pool: [FakeBodyKind] = [.plainReply, .simpleHTML, .gmailReply, .plainShort, .simpleHTML]
                    return i == 0 && index % 17 == 5 ? .receipt : pool[Int(rng.next(in: 0...4))]
                }
            }

            var dates = [lastAt]
            for _ in 1..<max(messageCount, 1) {
                dates.insert(dates[0].addingTimeInterval(-Double(rng.next(in: 20...600)) * 60), at: 0)
            }
            var blueprints: [FakeMessageBlueprint] = []
            blueprints.reserveCapacity(messageCount)
            for i in 0..<messageCount {
                let fromMe = sentOnly || (!isList && messageCount > 1 && i % 2 == 1)
                let sender = fromMe ? me : counterpart
                let isLast = i == messageCount - 1
                let msgKey = MessageKey(account: account.id, rowID: messageRow,
                                        gmailMessageID: GmailMessageID("fake-m\(messageRow)"))
                messageRow += 1
                var labelIDs: [GmailLabelID] = []
                if fromMe { labelIDs.append(FakeLabels.sent) }
                if inInbox && (!fromMe || messageCount > 1) { labelIDs.append(FakeLabels.inbox) }
                if unread && isLast && !fromMe { labelIDs.append(FakeLabels.unread) }
                if starred && isLast { labelIDs.append(FakeLabels.starred) }
                if important { labelIDs.append(FakeLabels.important) }
                if trashed { labelIDs.append(FakeLabels.trash) }
                if spam { labelIDs.append(FakeLabels.spam) }
                if let category, !fromMe { labelIDs.append(category) }
                labelIDs += extraLabels
                if isLast { labelIDs += snoozeLabels }
                var attachments: [AttachmentInfo] = []
                if isLast {
                    for kind in attachmentKinds { attachments.append(attachment(kind, topic: topic)) }
                    if kinds[i] == .calendarInvite { attachments.append(attachment("ics", topic: topic)) }
                }
                let body = FakeBodySpec(kind: kinds[i], sender: sender.name ?? sender.email, topic: topic,
                                        other: other.name ?? other.email)
                let snippet = snippets[body] ?? body.snippet
                snippets[body] = snippet
                blueprints.append(FakeMessageBlueprint(
                    key: msgKey, from: sender, to: fromMe ? [counterpart] : [me],
                    cc: messageCount > 2 && i == 0 ? [other] : [], date: dates[i], body: body,
                    labels: labelIDs, attachments: attachments, isFromMe: fromMe,
                    hasCalendarInvite: kinds[i] == .calendarInvite,
                    unsubscribe: fromMe ? nil : unsubscribe,
                    listID: isList ? "\(topic.lowercased().replacingOccurrences(of: " ", with: "-")).\(counterpart.email.split(separator: "@").last ?? "")" : nil,
                    snippet: snippet))
            }
            let thread = FakeThreadBuilder.thread(key: key, subject: subject, messages: blueprints, me: meSet,
                                                  userLabelRows: userLabelRows)
            threads.append(thread)

            let lastMessage = thread.allMessages.last
            guard index <= 23 else {
                let gapMinutes: UInt64 = index < 60 ? rng.next(in: 60...400) : rng.next(in: 300...1_500)
                lastAt = lastAt.addingTimeInterval(-Double(gapMinutes) * 60)
                continue
            }
            let replyFields = DraftFields(from: me, to: [counterpart], subject: "Re: \(subject)",
                                          bodyHTML: "<p>Thanks, I'll get back to you on \(topic.lowercased()) by Friday.</p>",
                                          bodyText: "Thanks, I'll get back to you on \(topic.lowercased()) by Friday.")
            switch index {
            case 0:
                drafts.append(DraftSummary(id: ids.nextDraft(), account: account.id, gmailDraftID: nextGmailDraft(),
                                           thread: key, mode: .reply, replyToGmailMessageID: lastMessage?.id.gmailMessageID,
                                           fields: replyFields, updatedAt: now.addingTimeInterval(-600)))
            case 13, 14, 15:
                let agentFields = DraftFields(from: me, to: [counterpart], subject: "Re: \(subject)",
                                              bodyHTML: "<p>Hi \(counterpart.name?.split(separator: " ").first ?? "there"),</p><p>Thanks for the note on \(topic.lowercased()). Tuesday at 10 works for me.</p>",
                                              bodyText: "Thanks for the note on \(topic.lowercased()). Tuesday at 10 works for me.")
                drafts.append(DraftSummary(id: ids.nextDraft(), account: account.id, gmailDraftID: nextGmailDraft(),
                                           thread: key, mode: .reply, replyToGmailMessageID: lastMessage?.id.gmailMessageID,
                                           fields: agentFields, source: .agent, review: .pending,
                                           agentNote: "Proposed Tuesday 10:00 because the calendar is free then.",
                                           agentSnapshot: agentFields,
                                           updatedAt: now.addingTimeInterval(-Double(index) * 60)))
            case 16:
                let id = ids.nextDraft()
                let sendAt = ScheduleStamp.floorToMinute(now.addingTimeInterval(2 * 86_400))
                stamps[id] = ScheduleStamp.format(sendAt)
                drafts.append(DraftSummary(id: id, account: account.id, gmailDraftID: nextGmailDraft(), thread: key,
                                           mode: .reply, replyToGmailMessageID: lastMessage?.id.gmailMessageID,
                                           fields: replyFields, status: .scheduled, sendAt: sendAt,
                                           updatedAt: now.addingTimeInterval(-3_600)))
            case 22:
                drafts.append(DraftSummary(id: ids.nextDraft(), account: account.id, gmailDraftID: nextGmailDraft(),
                                           thread: key, mode: .reply, replyToGmailMessageID: lastMessage?.id.gmailMessageID,
                                           fields: replyFields, source: .agent, review: .approved,
                                           agentNote: "Short confirmation.", agentSnapshot: replyFields,
                                           updatedAt: now.addingTimeInterval(-7_200)))
            case 11:
                reminders.append(ReminderItem(id: ids.nextReminder(), thread: key, subject: subject,
                                              dueAt: ScheduleStamp.floorToMinute(now.addingTimeInterval(20 * 3_600)),
                                              kind: .always))
            case 12:
                reminders.append(ReminderItem(id: ids.nextReminder(), thread: key, subject: subject,
                                              dueAt: ScheduleStamp.floorToMinute(now.addingTimeInterval(2 * 86_400)),
                                              kind: .ifNoReply))
            default:
                break
            }

            let gapMinutes: UInt64 = index < 12 ? rng.next(in: 10...60) : (index < 60 ? rng.next(in: 60...400) : rng.next(in: 300...1_500))
            lastAt = lastAt.addingTimeInterval(-Double(gapMinutes) * 60)
        }

        if threadCount >= 24 {
            let newFields = DraftFields(from: me, to: [people[0]], subject: "Quick question",
                                        bodyHTML: "<p>Do you have ten minutes this week?</p>",
                                        bodyText: "Do you have ten minutes this week?")
            drafts.append(DraftSummary(id: ids.nextDraft(), account: account.id, mode: .new, fields: newFields,
                                       version: 3, isDirty: true, updatedAt: now.addingTimeInterval(-300)))
            let scheduled = ids.nextDraft()
            let sendAt = ScheduleStamp.floorToMinute(now.addingTimeInterval(86_400))
            stamps[scheduled] = ScheduleStamp.format(sendAt)
            var weekly = newFields
            weekly.subject = "Weekly update"
            weekly.bodyHTML = "<p>Here is this week's update.</p>"
            drafts.append(DraftSummary(id: scheduled, account: account.id, gmailDraftID: nextGmailDraft(), mode: .new,
                                       fields: weekly, status: .scheduled, sendAt: sendAt,
                                       updatedAt: now.addingTimeInterval(-5_400)))
            let broken = ids.nextDraft()
            stamps[broken] = "2026-10-12 09:00"
            var reminder = newFields
            reminder.subject = "Reminder: invoices"
            drafts.append(DraftSummary(id: broken, account: account.id, gmailDraftID: nextGmailDraft(), mode: .new,
                                       fields: reminder, status: .failed, lastError: "scheduled time unreadable",
                                       updatedAt: now.addingTimeInterval(-86_400)))
            var cli = newFields
            cli.to = [people[1]]
            cli.subject = "Notes from today"
            cli.bodyHTML = "<p>Summary of today's discussion, drafted from the CLI.</p>"
            drafts.append(DraftSummary(id: ids.nextDraft(), account: account.id, mode: .new, fields: cli, source: .cli,
                                       review: .pending, agentNote: "Drafted by `openhuman gmail draft`.",
                                       agentSnapshot: cli, updatedAt: now.addingTimeInterval(-120)))
        }

        var splits = [FakeLabels.importantSplit(account: account.id, ids: &ids)]
        if profile == .work {
            splits.append(SplitInfo(id: ids.nextSplit(), account: account.id, name: "Newsletters", position: 1,
                                    ruleText: "category:promotions OR category:updates OR category:social"))
        }
        return FakeCorpus.Mailbox(account: account, threads: threads, labels: labels, splits: splits, drafts: drafts,
                                  reminders: reminders, draftSendStamps: stamps)
    }

    mutating func nextGmailDraft() -> GmailDraftID {
        defer { gmailDraft += 1 }
        return GmailDraftID("r-fake-\(gmailDraft)")
    }

    mutating func attachment(_ kind: String, topic: String) -> AttachmentInfo {
        defer { attachmentID += 1 }
        let slug = topic.lowercased().replacingOccurrences(of: " ", with: "-")
        switch kind {
        case "png":
            return AttachmentInfo(id: attachmentID, filename: "\(slug).png", mimeType: "image/png", size: 48_213,
                                  contentID: nil, isInline: false)
        case "cid":
            return AttachmentInfo(id: attachmentID, filename: "chart.png", mimeType: "image/png", size: 22_904,
                                  contentID: FakeBodies.inlineImageContentID, isInline: true)
        case "ics":
            return AttachmentInfo(id: attachmentID, filename: "invite.ics", mimeType: "text/calendar", size: 612,
                                  contentID: nil, isInline: false)
        default:
            return AttachmentInfo(id: attachmentID, filename: "\(topic).pdf", mimeType: "application/pdf",
                                  size: 120_000 + Int(attachmentID) * 37, contentID: nil, isInline: false)
        }
    }
}

extension SplitMix64: RandomNumberGenerator {}
