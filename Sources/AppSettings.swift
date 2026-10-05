import Foundation

/// Available translation back-ends.
enum TranslationProvider: String, CaseIterable {
    case googleFree
    case googleCloud
    case deepl
    case openai
    case claude

    var title: String {
        switch self {
        case .googleFree: return "Google (free, no key)"
        case .googleCloud: return "Google Cloud Translation"
        case .deepl: return "DeepL"
        case .openai: return "ChatGPT (OpenAI)"
        case .claude: return "Claude (Anthropic)"
        }
    }

    var needsAPIKey: Bool { self != .googleFree }

    /// LLM providers that can proofread/fix text (the ✨ button) and back dictation cleanup.
    var supportsCorrection: Bool { self == .openai || self == .claude }

    /// Providers that require (and accept) an API key — what the keys section lists.
    static var keyedProviders: [TranslationProvider] { allCases.filter { $0.needsAPIKey } }

    /// LLM providers used for the spelling-fix / dictation-cleanup section.
    static var llmProviders: [TranslationProvider] { allCases.filter { $0.supportsCorrection } }
}

/// Thin wrapper over `UserDefaults` for app-wide preferences.
///
/// API keys are stored per provider so the translator and the LLM can use
/// different services at the same time.
enum AppSettings {
    private static let translationProviderKey = "translationProvider"
    private static let llmProviderKey = "llmProvider"
    private static let legacyKeyKey = "translationApiKey"

    private static func keyDefaultsKey(for provider: TranslationProvider) -> String {
        "apiKey.\(provider.rawValue)"
    }

    // MARK: - API keys (per provider)

    static func apiKey(for provider: TranslationProvider) -> String {
        UserDefaults.standard.string(forKey: keyDefaultsKey(for: provider)) ?? ""
    }

    static func setAPIKey(_ key: String, for provider: TranslationProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: keyDefaultsKey(for: provider))
    }

    /// True when the provider can be used: no key needed, or a key is stored.
    static func hasKey(for provider: TranslationProvider) -> Bool {
        !provider.needsAPIKey || !apiKey(for: provider).isEmpty
    }

    // MARK: - Selected providers

    static var translationProvider: TranslationProvider {
        get {
            let stored = TranslationProvider(rawValue: UserDefaults.standard.string(forKey: translationProviderKey) ?? "") ?? .googleFree
            // Never point at a provider whose key has since been removed.
            return hasKey(for: stored) ? stored : .googleFree
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: translationProviderKey) }
    }

    /// The LLM that handles spelling fixes / dictation cleanup.
    static var llmProvider: TranslationProvider {
        get {
            if let raw = UserDefaults.standard.string(forKey: llmProviderKey),
               let provider = TranslationProvider(rawValue: raw), provider.supportsCorrection {
                return provider
            }
            return .openai
        }
        set {
            guard newValue.supportsCorrection else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: llmProviderKey)
        }
    }

    // MARK: - Migration

    /// Moves the old single `translationApiKey` into the per-provider slot of the
    /// provider that was selected at the time. Runs once.
    static func migrateLegacyKeyIfNeeded() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: legacyKeyKey), !legacy.isEmpty else { return }
        let previous = TranslationProvider(rawValue: defaults.string(forKey: translationProviderKey) ?? "") ?? .googleFree
        if previous.needsAPIKey, apiKey(for: previous).isEmpty {
            setAPIKey(legacy, for: previous)
        }
        defaults.removeObject(forKey: legacyKeyKey)
    }
}
