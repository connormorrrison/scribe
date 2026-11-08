import Foundation

/// The only model Scribe ever uses for AI. `ClaudeClient` sends this ID on every request and takes no model parameter,
/// and a build step fails if any other Claude model ID appears in the source.
enum ClaudeModel {
    static let id = "claude-haiku-5-5"
    static let displayName = "Claude Haiku 5.5"
}

/// A minimal client for Anthropic's Messages API (there's no official Swift SDK, so this is raw HTTP).
struct ClaudeClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"

    let apiKey: String

    /// A client using the key saved in Settings, or nil when there isn't one.
    init?() {
        guard let key = Keychain.read(.ai), !key.isEmpty else { return nil }
        self.apiKey = key
    }

    init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum Effort: String, Encodable { case low, medium, high }

    struct Message: Codable {
        enum Role: String, Codable { case user, assistant }
        let role: Role
        let content: String
    }

    struct Reply: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let model: String
        let content: [Block]
        let stopReason: String?

        /// All text blocks joined (thinking blocks are skipped).
        var text: String { content.filter { $0.type == "text" }.compactMap(\.text).joined() }

        /// The answer's text, or an error saying why there isn't one. Check this rather than `text` wherever the
        /// person is waiting on a reply: a refusal or a reply cut off during thinking otherwise looks like silence.
        func answer() throws -> String {
            let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if stopReason == "refusal" { throw ReplyError.declined }
            guard !answer.isEmpty else { throw stopReason == "max_tokens" ? ReplyError.cutOff : ReplyError.empty }
            return answer
        }

        enum CodingKeys: String, CodingKey {
            case model, content
            case stopReason = "stop_reason"
        }
    }

    struct APIError: LocalizedError {
        let status: Int
        let type: String?
        let message: String?

        var errorDescription: String? {
            switch status {
            case 401: "Anthropic rejected your key. Check it in Settings."
            case 403: "Your Anthropic key isn't allowed to use \(ClaudeModel.displayName)."
            case 404: "\(ClaudeModel.displayName) isn't available to your Anthropic key."
            case 429: "Anthropic is rate-limiting your key right now. Try again in a moment."
            case 500..<600: "Anthropic is having trouble right now. Try again in a moment."
            default: message ?? "Anthropic returned an error (\(status))."
            }
        }
    }

    /// A reply that came back without an answer to show.
    enum ReplyError: LocalizedError {
        /// Claude's safety checks declined to answer.
        case declined
        /// The reply ran out of room before any text was written.
        case cutOff
        /// Nothing came back to show.
        case empty

        var errorDescription: String? {
            switch self {
            case .declined: "The agent can't help with that one. Try asking another way."
            case .cutOff: "The agent ran out of room before answering. Try asking for something shorter."
            case .empty: "The agent didn't come back with an answer. Try again."
            }
        }
    }

    /// Sends one Messages request to Claude Haiku 5.5.
    func send(_ messages: [Message], system: String? = nil, maxTokens: Int = 16_000,
              effort: Effort = .medium) async throws -> Reply {
        struct Body: Encodable {
            struct OutputConfig: Encodable { let effort: Effort }
            let model = ClaudeModel.id
            let max_tokens: Int
            let system: String?
            let messages: [Message]
            let output_config: OutputConfig
        }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(
            Body(max_tokens: maxTokens, system: system, messages: messages,
                 output_config: .init(effort: effort)))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Envelope: Decodable { struct Detail: Decodable { let type: String?; let message: String? }; let error: Detail? }
            let detail = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
            throw APIError(status: status, type: detail?.type, message: detail?.message)
        }
        return try JSONDecoder().decode(Reply.self, from: data)
    }

    /// The smallest real request: checks the key works and can use Claude Haiku 5.5.
    func ping() async throws -> Reply {
        try await send([Message(role: .user, content: "Reply with the word OK.")], maxTokens: 256, effort: .low)
    }
}
