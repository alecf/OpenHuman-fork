import ArgumentParser
import Foundation
import OpenHumanCore
import OpenHumanMIME
import OpenHumanStore
import OpenHumanSync

typealias SnippetFile = SnippetsFile

extension SnippetsFile {
    static let maxFileBytes = 256 * 1_048_576

    init(stored: [SnippetItem], location: StoreLocation, unreadable: inout Int) {
        var snippets: [Snippet] = []
        for s in stored.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            var files: [File] = []
            for attachment in s.attachments {
                guard let url = location.snippetFileURL(attachment), let bytes = try? Data(contentsOf: url),
                      bytes.count == attachment.size else {
                    unreadable += 1
                    continue
                }
                files.append(File(filename: attachment.filename, mimeType: attachment.mimeType, size: attachment.size,
                                  contentHash: attachment.contentHash, data: bytes))
            }
            snippets.append(Snippet(name: s.name, shortcut: s.shortcut, subject: s.subject, bodyHTML: s.bodyHTML,
                                    variables: s.variables.map { Variable(name: $0.name, defaultValue: $0.defaultValue) },
                                    to: s.to.isEmpty ? nil : s.to, cc: s.cc.isEmpty ? nil : s.cc, bcc: s.bcc.isEmpty ? nil : s.bcc,
                                    files: files.isEmpty ? nil : files))
        }
        self.init(snippets: snippets)
    }

    var value: OutValue {
        func addresses(_ list: [EmailAddress]?) -> OutValue? {
            list.map { .array($0.map { obj(["name": OutValue.optUntrusted($0.name), "email": .string($0.email)]) }) }
        }
        return obj([
            "format": .string(format), "version": .int(version),
            "snippets": .array(snippets.map { s in
                obj(["name": .untrusted(s.name), "shortcut": OutValue.optString(s.shortcut), "subject": OutValue.optUntrusted(s.subject),
                     "bodyHTML": .body(s.bodyHTML),
                     "variables": .array(s.variables.map { obj(["name": .untrusted($0.name), "defaultValue": OutValue.optUntrusted($0.defaultValue)]) }),
                     "to": addresses(s.to), "cc": addresses(s.cc), "bcc": addresses(s.bcc),
                     "files": s.files.map { files in .array(files.map { f in
                         obj(["filename": .untrusted(f.filename), "mimeType": .untrusted(f.mimeType), "size": .int(f.size),
                              "contentHash": OutValue.optString(f.contentHash), "data": .string(f.data.base64EncodedString())])
                     }) }])
            }),
        ])
    }
}

enum SnippetSupport {
    static func normalizedShortcut(_ text: String) -> String? {
        var cleaned = text.trimmingCharacters(in: .whitespaces).lowercased()
        if cleaned.hasPrefix(";;") { cleaned.removeFirst(2) }
        let allowed = cleaned.unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
        let result = String(String.UnicodeScalarView(allowed))
        return result.isEmpty ? nil : result
    }

    static func isVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, ("a"..."z").contains(first), name.unicodeScalars.count <= 64 else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    static func scope(_ ctx: CLIContext) throws -> AccountItem? {
        guard let selector = ctx.global.account, !selector.isEmpty, selector.lowercased() != "all" else { return nil }
        return try ctx.accounts(.one)[0]
    }

    static func visible(_ ctx: CLIContext) throws -> [SnippetItem] {
        try ctx.store().snippets(account: try scope(ctx)?.id)
    }

    static func find(_ key: String, in snippets: [SnippetItem]) throws -> SnippetItem {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        if let byID = snippets.first(where: { $0.id == trimmed }) { return byID }
        if trimmed.hasPrefix(";;"), let shortcut = normalizedShortcut(trimmed),
           let hit = snippets.first(where: { $0.shortcut?.lowercased() == shortcut }) { return hit }
        let named = snippets.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if named.count > 1 {
            if let shared = named.first(where: { $0.accountID == nil }), named.filter({ $0.accountID == nil }).count == 1 { return shared }
            throw CLIError.usage("Several snippets have that name. Pass the snippet id.", code: "ambiguous_snippet",
                                 details: ["ids": .strings(named.map(\.id))])
        }
        if let hit = named.first { return hit }
        if let shortcut = normalizedShortcut(trimmed), let hit = snippets.first(where: { $0.shortcut?.lowercased() == shortcut }) { return hit }
        throw CLIError.notFound("The snippet", id: nil)
    }

    static func value(_ s: SnippetItem, _ mapper: Mapper, html: Bool = false) -> OutValue {
        obj([
            "snippetId": .string(s.id),
            "name": .untrusted(s.name),
            "shortcut": OutValue.optString(s.shortcut),
            "account": .string(s.accountID.map(mapper.email) ?? "all"),
            "subject": OutValue.optUntrusted(s.subject),
            "bodyText": .body(HTMLText.extract(s.bodyHTML)),
            "bodyHtml": html ? .body(s.bodyHTML) : nil,
            "variables": .array(s.variables.map { obj(["name": .untrusted($0.name), "default": OutValue.optUntrusted($0.defaultValue)]) }),
            "useCount": .int(s.useCount),
        ])
    }

    static func row(_ s: SnippetItem, _ mapper: Mapper) -> [OutValue] {
        [.string(s.id), .untrusted(s.name), .string(s.shortcut ?? ""), .string(s.accountID.map(mapper.email) ?? "all"),
         .untrusted(s.subject ?? ""), .array(s.variables.map { .untrusted($0.name) }), .int(s.useCount)]
    }

    static func result(_ snippets: [SnippetItem], _ mapper: Mapper, html: Bool = false, single: Bool = false,
                       extra: [String: OutValue] = [:]) -> CommandResult {
        let values = snippets.map { value($0, mapper, html: html) }
        var data: OutValue = single ? (values.first ?? obj([:])) : obj(["snippets": .array(values)])
        if case .object(var fields) = data, !extra.isEmpty {
            for (k, v) in extra { fields[k] = v }
            data = .object(fields)
        }
        return CommandResult(data: data, items: single ? nil : values,
                             table: Table(columns: CommandCatalog.snippetColumns, rows: snippets.map { row($0, mapper) }))
    }
}

enum SnippetRenderer {
    static func dateOffset(_ name: String) -> Int? {
        guard name.hasPrefix("date"), name.count > 5 else { return nil }
        let rest = name.dropFirst(4)
        guard let sign = rest.first, sign == "+" || sign == "-" else { return nil }
        let digits = rest.dropFirst()
        guard !digits.isEmpty, digits.count <= 4, digits.allSatisfy(\.isASCII), let n = Int(digits), n <= 3650 else { return nil }
        return sign == "+" ? n : -n
    }

    static func isValidName(_ name: String) -> Bool {
        dateOffset(name) != nil || SnippetSupport.isVariableName(name)
    }

    static func nameParts(_ recipient: EmailAddress?) -> (first: String?, last: String?, full: String?) {
        guard let recipient else { return (nil, nil, nil) }
        let name = recipient.name?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
        if let name, !name.isEmpty {
            let ordered: [String] = name.contains(",")
                ? name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.reversed().filter { !$0.isEmpty }
                : [name]
            let words = ordered.joined(separator: " ").split(whereSeparator: \.isWhitespace).map(String.init)
            return (words.first, words.count > 1 ? words.last : nil, words.joined(separator: " "))
        }
        let local = recipient.email.split(separator: "@").first.map(String.init) ?? recipient.email
        let first = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).first.map(String.init) ?? local
        return (first.prefix(1).uppercased() + first.dropFirst(), nil, nil)
    }

    static func render(_ text: String, escape: (String) -> String, value: (String) -> String?) -> (text: String, unresolved: [String]) {
        let u = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var unresolved: [String] = []
        var i = 0
        while i < u.count {
            if u[i] == "\\", i + 1 < u.count, u[i + 1] == "{" {
                if i + 2 < u.count, u[i + 2] == "{" { out.append("{"); out.append("{"); i += 3 } else { out.append("{"); i += 2 }
                continue
            }
            if u[i] == "{", i + 1 < u.count, u[i + 1] == "{" {
                var j = i + 2
                while j < u.count, j - i < 70, u[j] != "}", u[j] != "{" { j += 1 }
                if j + 1 < u.count, u[j] == "}", u[j + 1] == "}" {
                    let name = String(String.UnicodeScalarView(u[(i + 2)..<j]))
                    if isValidName(name) {
                        if let v = value(name), !v.isEmpty {
                            out.append(contentsOf: escape(v).unicodeScalars)
                        } else {
                            out.append(contentsOf: escape(name).unicodeScalars)
                            if !unresolved.contains(name) { unresolved.append(name) }
                        }
                        i = j + 2
                        continue
                    }
                }
            }
            out.append(u[i])
            i += 1
        }
        return (String(out), unresolved)
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

struct SnippetsGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snippets", abstract: "Snippets (text templates) on this Mac. Local only: nothing here reaches Gmail.",
        subcommands: [SnippetsList.self, SnippetsShow.self, SnippetsRender.self, SnippetsAdd.self, SnippetsDelete.self,
                      SnippetsExport.self, SnippetsImport.self])
}

struct SnippetsList: CLICommand {
    static let path = "gmail.snippets.list"
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List snippets (with --account: that account's and the shared ones).")
    @OptionGroup var global: GlobalOptions

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        SnippetSupport.result(try SnippetSupport.visible(ctx), try Mapper(store: try ctx.store()))
    }
}

struct SnippetsShow: CLICommand {
    static let path = "gmail.snippets.show"
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show one snippet by name, ;;shortcut or id.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Snippet name, ;;shortcut or id.") var name: String

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let snippet = try SnippetSupport.find(name, in: try SnippetSupport.visible(ctx))
        return SnippetSupport.result([snippet], try Mapper(store: try ctx.store()), html: true, single: true)
    }
}

struct SnippetsRender: CLICommand {
    static let path = "gmail.snippets.render"
    static let configuration = CommandConfiguration(commandName: "render", abstract: "Fill a snippet's {{variables}} and print the text. Writes nothing.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Snippet name, ;;shortcut or id.") var name: String
    @Option(name: .long, help: "A variable, name=value (repeatable).") var `var`: [String] = []
    @Option(name: .long, help: "The recipient for {{first_name}}, {{last_name}} and {{full_name}}.") var to: String?

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        var values: [String: String] = [:]
        for pair in `var` {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, SnippetRenderer.isValidName(parts[0]) else {
                throw CLIError.usage("Each --var must look like name=value (name: a-z, 0-9, _).", code: "bad_var")
            }
            values[parts[0]] = parts[1]
        }
        let recipient = try to.map { try DraftInput.addresses([$0], field: "to") }?.first
        let snippet = try SnippetSupport.find(name, in: try SnippetSupport.visible(ctx))
        let me = (try? SnippetSupport.scope(ctx)) ?? nil
        let myName = me?.displayName ?? (try? ctx.store().accounts())?.first(where: { $0.id == snippet.accountID })?.displayName
        let defaults = Dictionary(snippet.variables.compactMap { v in v.defaultValue.map { (v.name, $0) } }, uniquingKeysWith: { a, _ in a })
        let parts = SnippetRenderer.nameParts(recipient)
        let now = ctx.now
        let zone = ctx.env.timeZone
        func value(_ key: String) -> String? {
            if let typed = values[key] { return typed }
            if let offset = SnippetRenderer.dateOffset(key) {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = zone
                let day = calendar.date(byAdding: .day, value: offset, to: now) ?? now
                var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: .current)
                style.timeZone = zone
                return day.formatted(style.weekday(.abbreviated))
            }
            switch key {
            case "first_name": return parts.first
            case "last_name": return parts.last
            case "full_name": return parts.full
            case "my_name": return myName.flatMap { $0.isEmpty ? nil : $0 }
            default: return defaults[key]
            }
        }
        let body = SnippetRenderer.render(snippet.bodyHTML, escape: SnippetRenderer.escapeHTML, value: value)
        let subject = snippet.subject.map { text in SnippetRenderer.render(text, escape: { plain in plain }, value: value) }
        var unresolved = subject?.unresolved ?? []
        for name in body.unresolved where !unresolved.contains(name) { unresolved.append(name) }
        let text = HTMLText.extract(body.text)
        let data = obj([
            "snippetId": .string(snippet.id), "name": .untrusted(snippet.name),
            "subject": subject.map { OutValue.untrusted($0.text) },
            "bodyText": .body(text), "bodyHtml": .body(body.text),
            "unresolved": .array(unresolved.map { .untrusted($0) }),
        ])
        var warnings: [String] = []
        if !unresolved.isEmpty { warnings.append("\(unresolved.count) variable(s) have no value; pass --var name=value") }
        return CommandResult(data: data, table: Table(columns: ["name", "subject", "bodyText", "unresolved"],
                                                      rows: [[.untrusted(snippet.name), .untrusted(subject?.text ?? ""), .body(text),
                                                              .array(unresolved.map { .untrusted($0) })]]),
                             warnings: warnings)
    }
}

struct SnippetsAdd: CLICommand {
    static let path = "gmail.snippets.add"
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a snippet (or --replace the one with that name). Local only.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Snippet name.") var name: String
    @Option(name: .long, help: "Body text file (`-` for stdin).") var bodyFile: String?
    @Option(name: .long, help: "Body text, or `-` for stdin. {{name}} marks a variable.") var body: String?
    @Option(name: .long, help: "Subject the snippet sets.") var subject: String?
    @Option(name: .long, help: "Shortcut typed after ;; in the composer.") var shortcut: String?
    @Option(name: .long, help: "A variable, name or name=default (repeatable).") var `var`: [String] = []
    @Flag(name: .long, help: "Replace the text of the snippet with the same name instead of refusing; its recipients and files stay.")
    var replace = false

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let title = name.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title.count <= 200, !title.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw CLIError.usage("The name must be one line of 1 to 200 characters.", code: "bad_name")
        }
        guard let text = try DraftInput.body(file: bodyFile, inline: body, ctx),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.usage("A body is required: --body-file F or --body -.", code: "body_required")
        }
        let subjectText = try subject.map(DraftInput.subject)
        var normalized: String?
        if let shortcut {
            guard let n = SnippetSupport.normalizedShortcut(shortcut) else {
                throw CLIError.usage("A shortcut uses a-z, 0-9, - and _.", code: "bad_shortcut")
            }
            normalized = n
        }
        var variables: [SnippetVariable] = []
        for item in `var` {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard SnippetSupport.isVariableName(parts[0]), !variables.contains(where: { $0.name == parts[0] }) else {
                throw CLIError.usage("Each --var must be name or name=default (name: a-z, 0-9, _; once each).", code: "bad_var")
            }
            variables.append(SnippetVariable(name: parts[0], defaultValue: parts.count == 2 ? parts[1] : nil))
        }
        let account = try SnippetSupport.scope(ctx)
        if let account { try ctx.requireWritable(account) }
        let all = try ctx.store().snippets(account: nil)
        let existing = all.first { $0.accountID == account?.id && $0.name.caseInsensitiveCompare(title) == .orderedSame }
        if existing != nil, !replace {
            throw CLIError.usage("A snippet with that name exists. Pass --replace to change it.", code: "snippet_exists")
        }
        if let normalized, all.contains(where: { $0.id != existing?.id && $0.shortcut?.lowercased() == normalized }) {
            throw CLIError.usage("Another snippet already uses that shortcut.", code: "shortcut_taken")
        }
        let item = SnippetItem(id: existing?.id ?? UUID().uuidString, accountID: account?.id, name: title, shortcut: normalized,
                               subject: subjectText, bodyHTML: DraftInput.html(text), variables: variables,
                               useCount: existing?.useCount ?? 0, to: existing?.to ?? [], cc: existing?.cc ?? [],
                               bcc: existing?.bcc ?? [], attachments: existing?.attachments ?? [])
        let mapper = try Mapper(store: try ctx.store())
        let status = existing == nil ? "added" : "replaced"
        if ctx.dryRun {
            return SnippetSupport.result([item], mapper, single: true, extra: ["dryRun": .bool(true), "status": .string(status)])
        }
        let saved = try await ctx.engine().upsertSnippet(item)
        return SnippetSupport.result([saved], mapper, single: true, extra: ["status": .string(status)])
    }
}

struct SnippetsDelete: CLICommand {
    static let path = "gmail.snippets.delete"
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a snippet on this Mac. Needs --yes under --no-input.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Snippet name, ;;shortcut or id.") var name: String
    @Flag(name: .long, help: "Confirm under --no-input.") var yes = false

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let snippet = try SnippetSupport.find(name, in: try SnippetSupport.visible(ctx))
        let mapper = try Mapper(store: try ctx.store())
        if ctx.dryRun { return SnippetSupport.result([snippet], mapper, single: true, extra: ["dryRun": .bool(true)]) }
        try await ctx.engine().deleteSnippet(id: snippet.id)
        return SnippetSupport.result([snippet], mapper, single: true, extra: ["deleted": .bool(true)])
    }
}

struct SnippetsExport: CLICommand {
    static let path = "gmail.snippets.export"
    static let configuration = CommandConfiguration(commandName: "export",
                                                    abstract: "Write every snippet to an openhuman-snippets file (no account addresses).")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "File to write. Without it the file is in data.file.") var out: String?
    @Flag(name: .long, help: "Overwrite an existing --out file.") var force = false

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let store = try ctx.store()
        var unreadable = 0
        let file = SnippetFile(stored: try store.snippets(account: nil), location: store.location, unreadable: &unreadable)
        let warnings = unreadable == 0 ? [] : ["\(unreadable) snippet file(s) couldn't be read and are not in the export"]
        let columns = ["format", "version", "count", "path"]
        guard let out else {
            return CommandResult(data: obj(["format": .string(file.format), "version": .int(file.version), "count": .int(file.snippets.count),
                                            "file": file.value]),
                                 table: Table(columns: columns, rows: [[.string(file.format), .int(file.version), .int(file.snippets.count), .string("")]]),
                                 warnings: warnings)
        }
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path), !force {
            throw CLIError.usage("The --out file exists. Pass --force to overwrite it.", code: "file_exists")
        }
        if !ctx.dryRun {
            do { try file.encoded().write(to: url, options: .atomic) } catch {
                throw CLIError("write_failed", "Cannot write the --out file.", .failure)
            }
        }
        return CommandResult(data: obj(["format": .string(file.format), "version": .int(file.version), "count": .int(file.snippets.count),
                                        "path": .string(url.path), "dryRun": ctx.dryRun ? .bool(true) : nil]),
                             table: Table(columns: columns, rows: [[.string(file.format), .int(file.version), .int(file.snippets.count), .string(url.path)]]),
                             warnings: warnings)
    }
}

enum SnippetImportPlan {
    struct Item {
        var snippet: SnippetFile.Snippet
        var match: SnippetItem?
        var dropsShortcut: Bool
    }

    static func acceptedFiles(_ files: [SnippetFile.File]) -> [SnippetFile.File] {
        SnippetFile.acceptedFiles(files, maxFiles: SnippetAttachmentLimits.maxFiles, maxFileBytes: SnippetAttachmentLimits.maxFileBytes,
                                  maxTotalBytes: SnippetAttachmentLimits.maxTotalBytes)
    }

    static func validRecipients(_ list: [EmailAddress]) -> [EmailAddress] {
        var seen = Set<String>()
        return list.filter { address in
            DraftInput.valid(address.email)
                && !(address.name?.unicodeScalars.contains { $0.properties.generalCategory == .control } ?? false)
                && seen.insert(address.email.lowercased()).inserted
        }
    }

    static func plan(_ snippets: [SnippetFile.Snippet], existing: [SnippetItem]) -> [Item] {
        var taken = Dictionary(existing.compactMap { s in s.shortcut.map { ($0.lowercased(), s.id) } }, uniquingKeysWith: { first, _ in first })
        return snippets.map { snippet in
            let same = existing.filter { $0.name.caseInsensitiveCompare(snippet.name) == .orderedSame }
            let match = same.first { $0.accountID == nil } ?? same.first
            var drops = false
            if let shortcut = snippet.shortcut.flatMap(SnippetSupport.normalizedShortcut) {
                if let owner = taken[shortcut], owner != match?.id {
                    drops = true
                } else {
                    taken[shortcut] = match?.id ?? "new:\(snippet.name.lowercased())"
                }
            }
            return Item(snippet: snippet, match: match, dropsShortcut: drops)
        }
    }
}

struct SnippetsImport: CLICommand {
    static let path = "gmail.snippets.import"
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Add or replace snippets from an openhuman-snippets file; never deletes. --dry-run shows the preview. Needs --yes under --no-input.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "An openhuman-snippets file.") var file: String
    @Flag(name: .long, help: "Confirm under --no-input.") var yes = false

    func handle(_ ctx: CLIContext) async throws -> CommandResult {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else { throw CLIError.usage("Cannot read that file.", code: "bad_file") }
        guard data.count <= SnippetFile.maxFileBytes else { throw CLIError.usage("That file is larger than 256 MiB.", code: "file_too_large") }
        let bundle: SnippetFile
        do {
            bundle = try SnippetFile.decode(data)
        } catch .notASnippetsFile {
            throw CLIError.usage("That isn't a Mail snippets file.", code: "not_a_snippets_file")
        } catch .newerVersion {
            throw CLIError("snippets_file_too_new", "That file was made by a newer version of Mail.", .incompatible)
        }
        let items = SnippetImportPlan.plan(bundle.usableSnippets, existing: try ctx.store().snippets(account: nil))
        let toAdd = items.filter { $0.match == nil }.count
        let files = items.map { SnippetImportPlan.acceptedFiles($0.snippet.files ?? []).count }.reduce(0, +)
        let preview: [String: OutValue] = ["toAdd": .int(toAdd), "toReplace": .int(items.count - toAdd),
                                           "shortcutsDropped": .int(items.filter(\.dropsShortcut).count),
                                           "withRecipients": .int(items.filter(\.snippet.hasRecipients).count),
                                           "files": .int(files),
                                           "filesDropped": .int(items.map { $0.snippet.files?.count ?? 0 }.reduce(0, +) - files)]
        func result(_ status: String, saved: Int, failed: Int, exit: CLIStatus = .ok) -> CommandResult {
            var fields = preview
            fields["status"] = .string(status)
            fields["saved"] = .int(saved)
            fields["failed"] = .int(failed)
            if ctx.dryRun { fields["dryRun"] = .bool(true) }
            return CommandResult(data: .object(fields),
                                 table: Table(columns: ["status", "toAdd", "toReplace", "shortcutsDropped"],
                                              rows: [[.string(status), preview["toAdd"]!, preview["toReplace"]!, preview["shortcutsDropped"]!]]),
                                 status: exit)
        }
        if ctx.dryRun { return result("dry_run", saved: 0, failed: 0) }
        let engine = try ctx.engine()
        var saved = 0, failed = 0
        for item in items {
            let s = item.snippet
            let shortcut = item.dropsShortcut ? item.match?.shortcut : s.shortcut.flatMap(SnippetSupport.normalizedShortcut)
            do {
                var stored: [SnippetAttachment] = []
                for file in SnippetImportPlan.acceptedFiles(s.files ?? []) {
                    stored.append(try await engine.storeSnippetAttachment(data: file.data, filename: file.filename, mimeType: file.mimeType))
                }
                let match = item.match
                _ = try await engine.upsertSnippet(SnippetItem(
                    id: match?.id ?? UUID().uuidString, accountID: match?.accountID, name: s.name, shortcut: shortcut,
                    subject: s.subject, bodyHTML: s.bodyHTML,
                    variables: s.variables.map { SnippetVariable(name: $0.name, defaultValue: $0.defaultValue) },
                    useCount: match?.useCount ?? 0,
                    to: s.to.map(SnippetImportPlan.validRecipients) ?? match?.to ?? [],
                    cc: s.cc.map(SnippetImportPlan.validRecipients) ?? match?.cc ?? [],
                    bcc: s.bcc.map(SnippetImportPlan.validRecipients) ?? match?.bcc ?? [],
                    attachments: s.files == nil ? (match?.attachments ?? []) : stored))
                saved += 1
            } catch {
                failed += 1
            }
        }
        if failed == 0 { return result("imported", saved: saved, failed: 0) }
        return result(saved == 0 ? "failed" : "partial", saved: saved, failed: failed, exit: saved == 0 ? .failure : .partial)
    }
}
