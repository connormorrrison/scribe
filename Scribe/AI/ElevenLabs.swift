import Foundation

/// A minimal client for the two ElevenLabs endpoints Scribe uses: speech to text (hearing you) and text to speech
/// (speaking back). Raw HTTP, like `ClaudeClient`.
struct ElevenLabsClient {
    static let base = URL(string: "https://api.elevenlabs.io/v1")!
    /// ElevenLabs' speech-to-text model.
    static let transcriptionModel = "scribe_v1"
    /// ElevenLabs' low-latency text-to-speech model, so replies start quickly.
    static let speechModel = "eleven_flash_v2_5"
    /// "George", one of ElevenLabs' built-in voices (available to every account).
    static let voiceID = "JBFqnCBsd6RMkjVDRZzb"

    let apiKey: String

    /// A client using the key saved in Settings, or nil when there isn't one.
    init?() {
        guard let key = Keychain.read(.voice), !key.isEmpty else { return nil }
        self.apiKey = key
    }

    struct APIError: LocalizedError {
        let status: Int
        let code: String?
        let message: String?

        var errorDescription: String? {
            switch (status, code) {
            case (_, "invalid_api_key"), (401, _): "ElevenLabs rejected your key. Check it in Settings."
            case (_, "missing_permissions"): "Your ElevenLabs key needs Speech to Text and Text to Speech access."
            case (_, "quota_exceeded"): "Your ElevenLabs account is out of credits."
            case (429, _): "ElevenLabs is busy right now. Try again in a moment."
            default: message ?? "ElevenLabs returned an error (\(status))."
            }
        }
    }

    /// Turns a recording into text.
    func transcribe(_ audio: URL) async throws -> String {
        let boundary = "scribe-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model_id", Self.transcriptionModel)
        field("tag_audio_events", "false")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(try Data(contentsOf: audio))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = request(Self.base.appendingPathComponent("speech-to-text"), timeout: 60)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        request.httpBody = body

        struct Transcript: Decodable { let text: String }
        let data = try await send(request)
        return try JSONDecoder().decode(Transcript.self, from: data).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Speaks `text`, returning MP3 audio.
    func speak(_ text: String) async throws -> Data {
        var components = URLComponents(url: Self.base.appendingPathComponent("text-to-speech/\(Self.voiceID)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]

        struct Body: Encodable {
            let text: String
            let model_id: String
        }
        var request = request(components.url!, timeout: 60)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "accept")
        request.httpBody = try JSONEncoder().encode(Body(text: text, model_id: Self.speechModel))
        return try await send(request)
    }

    private func request(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Envelope: Decodable {
                struct Detail: Decodable { let status: String?; let message: String? }
                let detail: Detail?
            }
            let detail = (try? JSONDecoder().decode(Envelope.self, from: data))?.detail
            throw APIError(status: status, code: detail?.status, message: detail?.message)
        }
        return data
    }
}
