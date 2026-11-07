import SwiftUI
import Security

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

    /// A cheap, read-only request that succeeds only with a valid key: the provider's "list models".
    func testRequest(key: String) -> URLRequest {
        var request: URLRequest
        switch self {
        case .ai:
            request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!, timeoutInterval: 15)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .voice:
            request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/models")!, timeoutInterval: 15)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
        }
        return request
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
        do {
            let (_, response) = try await URLSession.shared.data(for: model.testRequest(key: key))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200..<300: return .connected
            case 400, 401, 403: return .failed("\(model.provider) rejected this key.")
            case 429: return .failed("The key works, but \(model.provider) is rate-limiting it right now.")
            default: return .failed("\(model.provider) returned an error (\(code)).")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
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
