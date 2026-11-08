import AVFoundation

/// A minimal client for ElevenLabs text to speech (speaking back). Raw HTTP, like `ClaudeClient`. Hearing you is
/// `LiveTranscription`, below.
struct ElevenLabsClient {
    static let base = URL(string: "https://api.elevenlabs.io/v1")!
    /// ElevenLabs' low-latency text-to-speech model, so replies start quickly.
    static let speechModel = "eleven_flash_v2_5"
    /// A little quicker than natural (ElevenLabs allows 0.7 to 1.2), so talking to the agent feels brisk.
    static let speechSpeed = 1.12
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

    /// A spoken reply: MP3 audio, and when each word of the text starts in it.
    struct Speech {
        let audio: Data
        /// Seconds from the start of the audio to each word of the text (words as `AgentReply.words` splits them),
        /// or nil if ElevenLabs didn't say.
        let wordStarts: [TimeInterval]?
    }

    /// Speaks `text`, with the timing of each word so the words can be shown as they're said.
    func speak(_ text: String) async throws -> Speech {
        var components = URLComponents(
            url: Self.base.appendingPathComponent("text-to-speech/\(Self.voiceID)/with-timestamps"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]

        struct Body: Encodable {
            struct VoiceSettings: Encodable { let speed: Double }
            let text: String
            let model_id: String
            let voice_settings: VoiceSettings
        }
        var request = request(components.url!, timeout: 60)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(Body(text: text, model_id: Self.speechModel,
                                                         voice_settings: .init(speed: Self.speechSpeed)))

        struct Response: Decodable {
            struct Alignment: Decodable {
                let characters: [String]
                let character_start_times_seconds: [Double]
            }
            let audio_base64: String
            let alignment: Alignment?
        }
        let response = try JSONDecoder().decode(Response.self, from: try await send(request))
        guard let audio = Data(base64Encoded: response.audio_base64) else { throw SpeechError.unreadableAudio }
        let starts = response.alignment.flatMap {
            Self.wordStarts(characters: $0.characters, times: $0.character_start_times_seconds,
                            words: AgentReply.words(in: text).count)
        }
        return Speech(audio: audio, wordStarts: starts)
    }

    /// Turns per-character timing into the start of each word: a word starts at its first non-space character.
    /// Nil if the words don't line up with the text's.
    static func wordStarts(characters: [String], times: [Double], words: Int) -> [TimeInterval]? {
        guard characters.count == times.count else { return nil }
        var starts: [TimeInterval] = []
        var inWord = false
        for (character, time) in zip(characters, times) {
            if character.allSatisfy(\.isWhitespace) {
                inWord = false
            } else if !inWord {
                starts.append(time)
                inWord = true
            }
        }
        return starts.count == words ? starts : nil
    }

    enum SpeechError: LocalizedError {
        case unreadableAudio
        var errorDescription: String? { "ElevenLabs sent audio Scribe couldn't play. Try again." }
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

/// ElevenLabs' realtime speech to text, over a WebSocket: sound goes up as it's heard, and the words come back as
/// they're recognised (`words`, with the whole transcript so far each time). `finish()` waits for the final
/// transcript. What the person sees while talking is what gets sent to the agent.
@MainActor
final class LiveTranscription {
    static let model = "scribe_v2_realtime"

    private let socket: URLSessionWebSocketTask
    private let outgoing: AsyncStream<(Data, Bool)>.Continuation
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?

    private let words: (String) -> Void
    private let failed: () -> Void
    private var committed: [String] = []
    private var partial = ""
    private var failure: Error?
    private var waiter: CheckedContinuation<String, Error>?

    private var transcript: String {
        (committed + [partial]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Connects straight away. `failed` runs if the connection breaks, so listening can stop early; `finish()`
    /// then throws why.
    init(apiKey: String, words: @escaping (String) -> Void, failed: @escaping () -> Void) {
        self.words = words
        self.failed = failed

        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        components.queryItems = [
            URLQueryItem(name: "model_id", value: Self.model),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            // Scribe decides when the person has finished (a pause, or tapping the dot) and commits then.
            URLQueryItem(name: "commit_strategy", value: "manual"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()

        // One sender, so chunks go up in the order they were heard.
        let (stream, continuation) = AsyncStream.makeStream(of: (Data, Bool).self)
        outgoing = continuation
        sender = Task { [socket] in
            for await (pcm, commit) in stream {
                guard let message = Self.message(pcm, commit: commit) else { continue }
                do { try await socket.send(.string(message)) } catch { break }
            }
        }
        receiver = Task { [weak self, socket] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard case .string(let text) = message else { continue }
                    self?.handle(text)
                } catch {
                    self?.fail(error)
                    return
                }
            }
        }
    }

    /// Sends a tenth of a second of sound (`SpeechAudio.format`).
    func send(_ pcm: Data) {
        outgoing.yield((pcm, false))
    }

    /// Tells ElevenLabs that's everything, and waits for the final transcript (empty if nothing was said).
    func finish() async throws -> String {
        let before = committed.count
        // A moment of silence carries the commit, so it never goes up as an empty message.
        outgoing.yield((Data(count: Int(SpeechAudio.format.sampleRate / 10) * 2), true))
        outgoing.finish()
        await sender?.value
        if let failure { throw failure }
        if committed.count > before { return transcript }

        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            // Don't hang if the final transcript never comes: go with what was heard.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, let waiter = self.waiter else { return }
                self.waiter = nil
                waiter.resume(returning: self.transcript)
            }
        }
    }

    func close() {
        outgoing.finish()
        sender?.cancel()
        receiver?.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: CancellationError())
        }
    }

    private func handle(_ text: String) {
        struct Message: Decodable {
            let message_type: String
            let text: String?
            let error: String?
        }
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)) else { return }
        switch message.message_type {
        case "partial_transcript":
            partial = message.text ?? ""
            words(transcript)
        case "committed_transcript":
            if let text = message.text, !text.isEmpty { committed.append(text) }
            partial = ""
            words(transcript)
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: transcript)
            }
        case "insufficient_audio_activity":
            // Nothing to transcribe: an empty transcript, not an error.
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: transcript)
            }
        case "session_started", "warning", "committed_transcript_with_timestamps":
            break
        default:
            if message.error != nil || message.message_type.hasSuffix("error") {
                fail(TranscriptionError(type: message.message_type, message: message.error))
            }
        }
    }

    private func fail(_ error: Error) {
        guard failure == nil, !(error is CancellationError) else { return }
        failure = error
        failed()
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: error)
        }
    }

    private nonisolated static func message(_ pcm: Data, commit: Bool) -> String? {
        struct Chunk: Encodable {
            let message_type = "input_audio_chunk"
            let audio_base_64: String
            let commit: Bool
            let sample_rate: Int
        }
        let chunk = Chunk(audio_base_64: pcm.base64EncodedString(), commit: commit,
                          sample_rate: Int(SpeechAudio.format.sampleRate))
        return (try? JSONEncoder().encode(chunk)).flatMap { String(data: $0, encoding: .utf8) }
    }

    struct TranscriptionError: LocalizedError {
        let type: String
        let message: String?

        var errorDescription: String? {
            switch type {
            case "auth_error": "ElevenLabs rejected your key. Check it in Settings."
            case "quota_exceeded": "Your ElevenLabs account is out of credits."
            case "rate_limited", "queue_overflow", "resource_exhausted": "ElevenLabs is busy right now. Try again in a moment."
            case "session_time_limit_exceeded": "That went on too long for one go. Try saying it in shorter parts."
            default: message ?? "ElevenLabs couldn't transcribe that (\(type))."
            }
        }
    }
}
