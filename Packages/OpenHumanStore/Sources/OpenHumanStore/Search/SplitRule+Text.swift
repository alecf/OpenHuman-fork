import Foundation

extension SplitRule {
    public static func parse(_ text: String) throws -> SplitRule {
        let nodes = try SearchParser.parseNodes(text)
        guard !nodes.isEmpty else { throw StoreError.invalidQuery("empty rule", position: 0) }
        return try combine(nodes.map(rule(for:)), as: .and)
    }

    public var canonicalText: String { Self.render(self, top: true) }

    private enum Join { case and, or }

    private static func combine(_ rules: [SplitRule], as join: Join) throws -> SplitRule {
        if rules.count == 1, let only = rules.first { return only }
        return join == .and ? .and(rules) : .or(rules)
    }

    private static func rule(for node: SearchParseNode) throws -> SplitRule {
        switch node {
        case let .and(children, _): return try combine(children.map(rule(for:)), as: .and)
        case let .or(children, _): return try combine(children.map(rule(for:)), as: .or)
        case let .not(inner, _): return .not(try rule(for: inner))
        case let .leaf(term, position): return try leaf(term, position: position)
        }
    }

    private static func leaf(_ term: SearchTerm, position: Int) throws -> SplitRule {
        func unsupported(_ what: String) -> StoreError {
            .invalidQuery("\(what) is not supported in split rules", position: position)
        }
        switch term {
        case let .address(.from, value):
            if value.lowercased() == "me" { throw StoreError.invalidQuery("from:me is not supported in split rules; use is:fromme", position: position) }
            return .from(value)
        case let .address(.to, value), let .address(.cc, value): return .to(value)
        case .address(.bcc, _): throw unsupported("bcc:")
        case let .label(name):
            if name.hasPrefix("CATEGORY_") {
                let category = name.dropFirst("CATEGORY_".count).lowercased()
                return .category(category)
            }
            return .label(name)
        case .isFlag(.important): return .isImportant
        case .isFlag(.starred): return .isStarred
        case .isFlag(.unread): return .isUnread
        case .isFlag(.event): return .isEvent
        case .has(.attachment): return .hasAttachment
        case .has(.invite): return .hasCalendarInvite
        case let .listID(id): return .list(id)
        case let .text(value, field):
            if field == .subject { return .subjectContains(value) }
            if field == nil, value == "is:fromme" { return .fromMeOnly }
            throw StoreError.invalidQuery("free text is not allowed in split rules; use subject:", position: position)
        case let .not(inner): return .not(try leaf(inner, position: position))
        default: throw unsupported("this term")
        }
    }

    private static func render(_ rule: SplitRule, top: Bool) -> String {
        func wrap(_ text: String) -> String { top ? text : "(" + text + ")" }
        switch rule {
        case let .from(v): return "from:" + SearchSerializer.value(v)
        case let .to(v): return "to:" + SearchSerializer.value(v)
        case let .label(v): return "label:" + SearchSerializer.value(v)
        case let .category(v): return "category:" + (v == "personal" ? "primary" : SearchSerializer.value(v))
        case .isImportant: return "is:important"
        case .isStarred: return "is:starred"
        case .isUnread: return "is:unread"
        case .hasAttachment: return "has:attachment"
        case .hasCalendarInvite: return "has:invite"
        case .isEvent: return "is:event"
        case let .list(v): return "list:" + SearchSerializer.value(v)
        case let .subjectContains(v): return "subject:" + SearchSerializer.value(v)
        case .fromMeOnly: return "is:fromme"
        case let .and(items):
            if items.isEmpty { return "()" }
            if items.count == 1, let only = items.first { return render(only, top: top) }
            return wrap(items.map { render($0, top: false) }.joined(separator: " "))
        case let .or(items):
            if items.isEmpty { return "{}" }
            if items.count == 1, let only = items.first { return render(only, top: top) }
            return wrap(items.map { render($0, top: false) }.joined(separator: " OR "))
        case let .not(inner): return "-" + render(inner, top: false)
        }
    }
}
