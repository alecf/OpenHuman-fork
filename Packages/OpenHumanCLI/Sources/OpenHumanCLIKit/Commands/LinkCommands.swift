import ArgumentParser
import Foundation
import OpenHumanCore
import OpenHumanLinks
import OpenHumanStore

enum LinkSupport {
    static func make(_ link: MailLink, _ ctx: CLIContext, open: Bool) throws -> CommandResult {
        let url = MailLinkBuilder.url(for: link)
        guard case .success = MailLinkParser.parse(url) else {
            throw CLIError.usage("That value cannot be put in a link.", code: "bad_link_input")
        }
        if open, !ctx.dryRun { try ctx.env.openURL(url) }
        return CommandResult(data: obj(["link": .string(url.absoluteString)]), table: Table(columns: ["link"], rows: [[.string(url.absoluteString)]]))
    }

    static func account(_ ctx: CLIContext) throws -> AccountRef {
        AccountRef(try ctx.accounts(.one)[0].email)
    }
}

struct LinkGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link", abstract: "Deep links that open OpenHuman Mail.",
        subcommands: [LinkThread.self, LinkDraft.self, LinkReview.self, LinkSearch.self, LinkCompose.self])
}

struct LinkThread: CLICommand {
    static let path = "link.thread"
    static let configuration = CommandConfiguration(commandName: "thread", abstract: "Link to a thread.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Gmail thread id.") var threadId: String
    @Flag(name: .long, help: "Open it with /usr/bin/open.") var open = false
    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        try LinkSupport.make(.thread(account: LinkSupport.account(ctx), threadID: threadId), ctx, open: open)
    }
}

struct LinkDraft: CLICommand {
    static let path = "link.draft"
    static let configuration = CommandConfiguration(commandName: "draft", abstract: "Link to a draft.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Draft id (local UUID or Gmail draft id).") var draftId: String
    @Flag(name: .long, help: "Open it with /usr/bin/open.") var open = false
    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let draft = try DraftSupport.find(draftId, ctx)
        let account = try ctx.store().accounts().first { $0.id == draft.accountID }
        return try LinkSupport.make(.draft(account: AccountRef(account?.email ?? ""), draftID: draft.id.rawValue), ctx, open: open)
    }
}

struct LinkReview: CLICommand {
    static let path = "link.review"
    static let configuration = CommandConfiguration(commandName: "review", abstract: "Link to the review queue for these drafts.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Draft ids (local UUID or Gmail draft id).") var draftIds: [String]
    @Flag(name: .long, help: "Open it with /usr/bin/open.") var open = false
    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        guard !draftIds.isEmpty else { throw CLIError.usage("At least one draft id is required.", code: "ids_required") }
        guard draftIds.count <= LinkGrammar.maxReviewIDs else { throw CLIError.usage("At most 50 drafts per review link.", code: "too_many_ids") }
        let store = try ctx.store()
        let accounts = Dictionary(uniqueKeysWithValues: try store.accounts().map { ($0.id, $0.email) })
        let refs = try draftIds.map { id -> DraftRef in
            let draft = try DraftSupport.find(id, ctx)
            return DraftRef(account: AccountRef(accounts[draft.accountID] ?? ""), draftID: draft.id.rawValue)
        }
        return try LinkSupport.make(.review(refs), ctx, open: open)
    }
}

struct LinkSearch: CLICommand {
    static let path = "link.search"
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Link that runs a search in the app.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Query.") var query: String
    @Flag(name: .long, help: "Open it with /usr/bin/open.") var open = false
    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        try LinkSupport.make(.search(query: query, account: LinkSupport.account(ctx)), ctx, open: open)
    }
}

struct LinkCompose: CLICommand {
    static let path = "link.compose"
    static let configuration = CommandConfiguration(commandName: "compose", abstract: "Link that opens a pre-filled composer (never sends).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Recipient (repeatable).") var to: [String] = []
    @Option(name: .long, help: "Cc (repeatable).") var cc: [String] = []
    @Option(name: .long, help: "Subject.") var subject: String?
    @Option(name: .long, help: "Body text.") var body: String?
    @Flag(name: .long, help: "Open it with /usr/bin/open.") var open = false
    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let prefill = ComposePrefill(account: try LinkSupport.account(ctx),
                                     to: try DraftInput.addresses(to, field: "to").map(\.email),
                                     cc: try DraftInput.addresses(cc, field: "cc").map(\.email),
                                     subject: try subject.map(DraftInput.subject), body: body)
        return try LinkSupport.make(.compose(prefill), ctx, open: open)
    }
}
