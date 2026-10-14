import Foundation
import OpenHumanAI

enum ParsedCLIEvent: Sendable, Hashable {
    case model(String)
    case textDelta(String)
    case finalText(String)
    case structured(Data)
    case usage(AIUsage)
    case failure(String)
}

extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var objectData: Data? {
        guard case .object = self else { return nil }
        return try? JSONEncoder().encode(self)
    }
}

struct ClaudeOutputParser {
    private(set) var sawDeltas = false
    private var assistantText = ""

    mutating func parse(line: String) -> [ParsedCLIEvent] {
        guard let data = line.data(using: .utf8), let value = try? JSONValue.parse(data) else { return [] }
        return parse(value: value)
    }

    mutating func parse(document: String) -> [ParsedCLIEvent] {
        guard let data = document.data(using: .utf8), let value = try? JSONValue.parse(data) else { return [] }
        if let items = value.arrayValue { return items.flatMap { parse(value: $0) } }
        return parse(value: value)
    }

    private mutating func parse(value: JSONValue) -> [ParsedCLIEvent] {
        switch value["type"]?.stringValue {
        case "system":
            if value["subtype"]?.stringValue == "init", let model = value["model"]?.stringValue { return [.model(model)] }
            return []
        case "stream_event":
            guard let event = value["event"], event["type"]?.stringValue == "content_block_delta",
                let delta = event["delta"], delta["type"]?.stringValue == "text_delta", let text = delta["text"]?.stringValue,
                !text.isEmpty
            else { return [] }
            sawDeltas = true
            return [.textDelta(text)]
        case "assistant":
            let blocks = value["message"]?["content"]?.arrayValue ?? []
            for block in blocks where block["type"]?.stringValue == "text" {
                assistantText += block["text"]?.stringValue ?? ""
            }
            return []
        case "result":
            return parseResult(value)
        default:
            return []
        }
    }

    private func parseResult(_ value: JSONValue) -> [ParsedCLIEvent] {
        var events: [ParsedCLIEvent] = []
        if let usage = value["usage"] {
            events.append(
                .usage(
                    AIUsage(
                        inputTokens: usage["input_tokens"]?.integerValue, outputTokens: usage["output_tokens"]?.integerValue,
                        cachedTokens: usage["cache_read_input_tokens"]?.integerValue)))
        }
        if case .bool(true)? = value["is_error"] {
            let message = value["result"]?.stringValue ?? value["subtype"]?.stringValue ?? "error"
            events.append(.failure(message))
            return events
        }
        if let structured = value["structured_output"], let data = structured.objectData {
            events.append(.structured(data))
        } else {
            let text = value["result"]?.stringValue ?? assistantText
            if !sawDeltas, !text.isEmpty { events.append(.finalText(text)) }
        }
        return events
    }
}

struct CodexOutputParser {
    private(set) var lastMessage: String?

    mutating func parse(line: String) -> [ParsedCLIEvent] {
        guard let data = line.data(using: .utf8), let value = try? JSONValue.parse(data) else { return [] }
        switch value["type"]?.stringValue {
        case "item.completed":
            if let item = value["item"], item["type"]?.stringValue == "agent_message", let text = item["text"]?.stringValue {
                lastMessage = text
            }
            return []
        case "turn.completed":
            guard let usage = value["usage"] else { return [] }
            return [
                .usage(
                    AIUsage(
                        inputTokens: usage["input_tokens"]?.integerValue, outputTokens: usage["output_tokens"]?.integerValue,
                        cachedTokens: usage["cached_input_tokens"]?.integerValue,
                        reasoningTokens: usage["reasoning_output_tokens"]?.integerValue))
            ]
        case "turn.failed":
            return [.failure(value["error"]?["message"]?.stringValue ?? "turn failed")]
        case "error":
            return [.failure(value["message"]?.stringValue ?? "error")]
        default:
            return []
        }
    }
}

enum CLIFailureClassifier {
    static func classify(_ text: String, kind: AgentCLIKind, inputTokens: Int, limit: Int?) -> AIError {
        let lower = text.lowercased()
        if lower.contains("not logged in") || lower.contains("please run /login") || lower.contains("log in")
            || lower.contains("login required") || lower.contains("unauthorized") || lower.contains("authentication")
            || lower.contains("invalid api key") || lower.contains("401")
        {
            return .unavailable(.notLoggedIn(name: kind.executableName))
        }
        if lower.contains("unknown option") || lower.contains("unknown flag") || lower.contains("unrecognized")
            || lower.contains("unexpected argument") || lower.contains("unknown argument")
        {
            return .unavailable(.unsupportedVersion(found: "unknown", minimum: kind.minimumVersion?.description ?? "latest"))
        }
        if lower.contains("context") && (lower.contains("too long") || lower.contains("exceed") || lower.contains("window"))
            || lower.contains("prompt is too long")
        {
            return .contextOverflow(counted: inputTokens, limit: limit ?? 0)
        }
        if lower.contains("rate limit") || lower.contains("429") || lower.contains("usage limit") || lower.contains("quota") {
            return .providerFailed("\(kind.displayName) is rate limited")
        }
        return .providerFailed("\(kind.displayName) failed")
    }
}
