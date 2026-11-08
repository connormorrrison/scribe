import Foundation

/// Any JSON value, for the parts of a Messages request or reply that have no fixed shape (tool schemas, tool inputs,
/// and content blocks that go back to the API exactly as they came).
enum JSONValue: Codable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        get { if case .object(let o) = self { o[key] } else { nil } }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var number: Double? { if case .number(let n) = self { n } else { nil } }

    static func parse(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}

extension ClaudeClient {
    /// One request with tools, streamed: the reply's content blocks, assembled as they arrive.
    struct ToolTurn {
        /// Every block, in order, exactly as the API sent it (thinking blocks included), to send back unchanged.
        var content: [JSONValue]
        var stopReason: String?
        /// Tool calls whose input didn't arrive whole (the reply was cut off mid-call).
        var brokenToolIDs: Set<String> = []

        var text: String {
            content.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined()
        }

        var toolUses: [(id: String, name: String, input: JSONValue)] {
            content.compactMap { block in
                guard block["type"]?.string == "tool_use", let id = block["id"]?.string,
                      let name = block["name"]?.string else { return nil }
                return (id, name, block["input"] ?? [:])
            }
        }
    }

    /// Sends a Messages request with tools, streaming the reply. `toolStarted` is called with a tool's name as soon
    /// as Claude starts writing a call to it, long before its input is complete.
    func sendWithTools(_ messages: [JSONValue], system: String?, tools: [JSONValue], maxTokens: Int = 32_000,
                       effort: Effort = .medium, toolStarted: @MainActor (String) -> Void = { _ in }) async throws -> ToolTurn {
        var body: JSONValue = [
            "model": .string(ClaudeModel.id),
            "max_tokens": .number(Double(maxTokens)),
            "messages": .array(messages),
            "tools": .array(tools),
            "output_config": ["effort": .string(effort.rawValue)],
            "stream": true
        ]
        if let system { body["system"] = .string(system) }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys // The same bytes every time, so the prompt cache can match.
        request.httpBody = try encoder.encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw Self.apiError(status: status, data: data)
        }

        var stream = StreamAssembler()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = JSONValue.parse(payload) else { continue }
            if let started = try stream.apply(event) { await toolStarted(started) }
        }
        return stream.turn
    }

    static func apiError(status: Int, data: Data) -> APIError {
        struct Envelope: Decodable { struct Detail: Decodable { let type: String?; let message: String? }; let error: Detail? }
        let detail = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
        return APIError(status: status, type: detail?.type, message: detail?.message)
    }
}

/// Builds a reply from Messages API stream events.
struct StreamAssembler {
    private(set) var turn = ClaudeClient.ToolTurn(content: [])
    private var partialJSON: [Int: String] = [:]

    /// Applies one event. Returns a tool's name when a tool call starts.
    mutating func apply(_ event: JSONValue) throws -> String? {
        switch event["type"]?.string {
        case "content_block_start":
            guard let index = event["index"]?.number.map(Int.init), let block = event["content_block"] else { return nil }
            while turn.content.count <= index { turn.content.append(.null) }
            turn.content[index] = block
            if block["type"]?.string == "tool_use" { return block["name"]?.string }
        case "content_block_delta":
            guard let index = event["index"]?.number.map(Int.init), turn.content.indices.contains(index),
                  let delta = event["delta"] else { return nil }
            switch delta["type"]?.string {
            case "text_delta":
                turn.content[index]["text"] = .string((turn.content[index]["text"]?.string ?? "") + (delta["text"]?.string ?? ""))
            case "thinking_delta":
                turn.content[index]["thinking"] = .string((turn.content[index]["thinking"]?.string ?? "")
                    + (delta["thinking"]?.string ?? ""))
            case "signature_delta":
                turn.content[index]["signature"] = delta["signature"]
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"]?.string ?? ""
            default:
                break
            }
        case "content_block_stop":
            guard let index = event["index"]?.number.map(Int.init), turn.content.indices.contains(index),
                  turn.content[index]["type"]?.string == "tool_use" else { return nil }
            let raw = partialJSON[index] ?? ""
            if raw.isEmpty {
                turn.content[index]["input"] = turn.content[index]["input"] ?? [:]
            } else if let input = JSONValue.parse(raw), case .object = input {
                turn.content[index]["input"] = input
            } else {
                // Cut off mid-call: the block goes back with an empty input, and the call is answered with an error.
                turn.content[index]["input"] = [:]
                if let id = turn.content[index]["id"]?.string { turn.brokenToolIDs.insert(id) }
            }
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.string { turn.stopReason = reason }
        case "error":
            let type = event["error"]?["type"]?.string
            throw ClaudeClient.APIError(status: type == "overloaded_error" ? 529 : 0, type: type,
                                        message: event["error"]?["message"]?.string)
        default:
            break
        }
        return nil
    }
}
