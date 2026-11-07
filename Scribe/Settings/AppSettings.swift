import SwiftUI
import Security
import CryptoKit

/// `UserDefaults` keys for app settings (read with `@AppStorage`). API keys are not here: they live in the Keychain.
enum AppSettings {
    static let appearance = "appearance"
    static let pageBackground = "pageBackground"
    static let drawWithFinger = "drawWithFinger"
}

/// Light, dark, or follow the system.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The pattern printed on a note's pages.
enum PageBackground: String, CaseIterable, Identifiable {
    case dots, grid, none

    var id: Self { self }

    var title: String {
        switch self {
        case .dots: "Dots"
        case .grid: "Grid"
        case .none: "None"
        }
    }
}

// MARK: - Models

/// The two models Scribe calls: Anthropic for the agents, ElevenLabs for voice.
enum ModelService: String, CaseIterable {
    case ai = "ai-model"
    case voice = "voice-model"

    var provider: String {
        switch self {
        case .ai: "Anthropic"
        case .voice: "ElevenLabs"
        }
    }

    /// Requests that ElevenLabs refuses without generating any audio (so they cost no credits), but only after it has
    /// checked the key and its permission for that endpoint: text to speech with no text, and speech to text with no
    /// file (JBFqnCBsd6RMkjVDRZzb is one of ElevenLabs' built-in voices). These are the two things Scribe uses ElevenLabs for.
    static func voiceProbes(key: String) -> [(name: String, request: URLRequest)] {
        var tts = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb")!,
                             timeoutInterval: 15)
        tts.httpMethod = "POST"
        tts.setValue("application/json", forHTTPHeaderField: "content-type")
        tts.httpBody = Data(#"{"text":""}"#.utf8)

        var stt = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!, timeoutInterval: 15)
        stt.httpMethod = "POST"
        stt.setValue("multipart/form-data; boundary=scribe", forHTTPHeaderField: "content-type")
        stt.httpBody = Data("--scribe\r\nContent-Disposition: form-data; name=\"model_id\"\r\n\r\nscribe_v1\r\n--scribe--\r\n".utf8)

        return [("Text to Speech", tts), ("Speech to Text", stt)].map { name, request in
            var request = request
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            return (name, request)
        }
    }
}

/// The result of testing a key.
enum ConnectionStatus: Equatable {
    case idle, testing, connected
    case failed(String)
}

enum ConnectionTester {
    static func test(_ model: ModelService, key: String) async -> ConnectionStatus {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failed("Enter an API key first.") }
        switch model {
        case .ai: return await testClaude(key: key)
        case .voice: return await testElevenLabs(key: key)
        }
    }

    /// Sends a real one-line request to Claude Haiku 5.5, so a pass means the agents will work.
    private static func testClaude(key: String) async -> ConnectionStatus {
        do {
            let reply = try await ClaudeClient(apiKey: key).ping()
            guard reply.model == ClaudeModel.id else {
                return .failed("Anthropic answered with \(reply.model) instead of \(ClaudeModel.displayName).")
            }
            return .connected
        } catch let error as ClaudeClient.APIError {
            switch error.status {
            case 401: return .failed("Anthropic rejected this key.")
            case 403: return .failed("This key isn't allowed to use \(ClaudeModel.displayName).")
            case 404: return .failed("\(ClaudeModel.displayName) isn't available to this key.")
            case 429: return .failed("The key works, but Anthropic is rate-limiting it right now.")
            case 529: return .failed("The key works, but Anthropic is overloaded. Try again soon.")
            default: return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func testElevenLabs(key: String) async -> ConnectionStatus {
        struct Envelope: Decodable {
            struct Detail: Decodable { let status: String?; let message: String? }
            let detail: Detail?
        }
        var missing: [String] = []
        for probe in ModelService.voiceProbes(key: key) {
            do {
                let (data, response) = try await URLSession.shared.data(for: probe.request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let detail = (try? JSONDecoder().decode(Envelope.self, from: data))?.detail
                switch (code, detail?.status) {
                case (_, "invalid_api_key"):
                    return .failed("ElevenLabs doesn't recognise this key. Check it was copied in full.")
                case (_, "missing_permissions"):
                    missing.append(probe.name)
                case (429, _):
                    return .failed("The key works, but ElevenLabs is rate-limiting it right now.")
                case (500..., _):
                    return .failed("ElevenLabs returned an error (\(code)). Try again soon.")
                default:
                    // Refused only because the request is empty: the key is accepted for this endpoint.
                    break
                }
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        if missing.isEmpty { return .connected }
        return .failed("The key works, but needs access to \(missing.joined(separator: " and ")) in ElevenLabs.")
    }
}

/// Remembers which key last passed its connection test, so Settings still says "Connected" after a relaunch or
/// rebuild. Only a SHA-256 fingerprint is kept (in UserDefaults), never the key, and a different key doesn't match.
enum ConnectionMemory {
    private static func defaultsKey(_ model: ModelService) -> String { "connected.\(model.rawValue)" }

    private static func fingerprint(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isConnected(_ model: ModelService, key: String) -> Bool {
        !key.isEmpty && UserDefaults.standard.string(forKey: defaultsKey(model)) == fingerprint(key)
    }

    static func record(_ status: ConnectionStatus, for model: ModelService, key: String) {
        switch status {
        case .connected: UserDefaults.standard.set(fingerprint(key), forKey: defaultsKey(model))
        case .failed: forget(model)
        case .idle, .testing: break
        }
    }

    static func forget(_ model: ModelService) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(model))
    }
}

// MARK: - Keychain

/// A small wrapper over the Keychain for API keys: stored only on this device, readable only while it's unlocked.
enum Keychain {
    private static let service = "com.connormorrison.scribe.api-keys"

    static func read(_ model: ModelService) -> String? { read(model.rawValue) }
    static func save(_ value: String, for model: ModelService) { save(value, for: model.rawValue) }

    static func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `value`, or removes the key when `value` is empty.
    static func save(_ value: String, for account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { delete(account); return }
        let data = Data(trimmed.utf8)
        let update = [kSecValueData as String: data]
        if SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
