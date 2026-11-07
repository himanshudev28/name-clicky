import Foundation

/// Which wire protocol a provider speaks.
enum AIAPIStyle { case claudeCLI, anthropic, openai }

/// Every "brain" MacPilot can use. `claudeCode` is the existing CLI login; the rest
/// are bring-your-own-key HTTP APIs (or local servers) driven by `APIAgent`.
enum AIProvider: String, CaseIterable, Identifiable {
    case claudeCode, anthropic, openai, gemini, groq, openrouter, mistral, deepseek, xai, together, ollama, lmstudio, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code (your login)"
        case .anthropic: return "Anthropic API"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        case .openrouter: return "OpenRouter"
        case .mistral: return "Mistral"
        case .deepseek: return "DeepSeek"
        case .xai: return "xAI (Grok)"
        case .together: return "Together AI"
        case .ollama: return "Ollama (local)"
        case .lmstudio: return "LM Studio (local)"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    var apiStyle: AIAPIStyle {
        switch self {
        case .claudeCode: return .claudeCLI
        case .anthropic: return .anthropic
        default: return .openai
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .claudeCode: return ""
        case .anthropic: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .groq: return "https://api.groq.com/openai/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .xai: return "https://api.x.ai/v1"
        case .together: return "https://api.together.xyz/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .lmstudio: return "http://localhost:1234/v1"
        case .custom: return ""
        }
    }

    /// Local servers and the CLI login need no key; a custom endpoint may or may not.
    var needsKey: Bool {
        switch self {
        case .claudeCode, .ollama, .lmstudio, .custom: return false
        default: return true
        }
    }

    /// Account name in `SecretStore`.
    var keyAccount: String { "ai.\(rawValue)" }

    /// Where the user can create an API key (nil for local/custom).
    var keyURL: URL? {
        let s: String
        switch self {
        case .anthropic: s = "https://console.anthropic.com/settings/keys"
        case .openai: s = "https://platform.openai.com/api-keys"
        case .gemini: s = "https://aistudio.google.com/apikey"
        case .groq: s = "https://console.groq.com/keys"
        case .openrouter: s = "https://openrouter.ai/keys"
        case .mistral: s = "https://console.mistral.ai/api-keys"
        case .deepseek: s = "https://platform.deepseek.com/api_keys"
        case .xai: s = "https://console.x.ai"
        case .together: s = "https://api.together.ai/settings/api-keys"
        default: return nil
        }
        return URL(string: s)
    }

    /// Suggestions only (current, fast, tool-calling capable). The user can type any model id.
    var suggestedModels: [String] {
        switch self {
        case .claudeCode: return []
        case .anthropic: return ["claude-sonnet-5-5", "claude-haiku-5-5"]
        case .openai: return ["gpt-5-mini", "gpt-5"]
        case .gemini: return ["gemini-2.5-flash", "gemini-2.5-pro"]
        case .groq: return ["moonshotai/kimi-k2-instruct", "llama-3.3-70b-versatile"]
        case .openrouter: return ["anthropic/claude-sonnet-4.5", "openai/gpt-5-mini", "google/gemini-2.5-flash"]
        case .mistral: return ["mistral-medium-latest", "mistral-small-latest"]
        case .deepseek: return ["deepseek-chat"]
        case .xai: return ["grok-4", "grok-3-mini"]
        case .together: return ["moonshotai/Kimi-K2-Instruct", "meta-llama/Llama-3.3-70B-Instruct-Turbo"]
        case .ollama: return ["qwen3", "llama3.2"]
        case .lmstudio: return ["qwen3-8b", "llama-3.1-8b-instruct"]
        case .custom: return []
        }
    }
}

/// The active provider settings, resolved from UserDefaults + Keychain.
struct ProviderConfig {
    var provider: AIProvider
    var baseURL: String
    var model: String
    var apiKey: String

    static let providerKey = "aiProvider"
    static func modelKey(_ p: AIProvider) -> String { "aiModel.\(p.rawValue)" }
    static func baseURLKey(_ p: AIProvider) -> String { "aiBaseURL.\(p.rawValue)" }
    static let changedNotification = Notification.Name("macPilotProviderChanged")

    static func current() -> ProviderConfig {
        let d = UserDefaults.standard
        let provider = d.string(forKey: providerKey).flatMap(AIProvider.init(rawValue:)) ?? .claudeCode
        return load(provider)
    }

    /// Settings for a specific provider (used by the settings UI while editing).
    static func load(_ provider: AIProvider) -> ProviderConfig {
        let d = UserDefaults.standard
        func nonEmpty(_ s: String?) -> String? { (s?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } }
        return ProviderConfig(
            provider: provider,
            baseURL: nonEmpty(d.string(forKey: baseURLKey(provider))) ?? provider.defaultBaseURL,
            model: nonEmpty(d.string(forKey: modelKey(provider))) ?? provider.suggestedModels.first ?? "",
            apiKey: SecretStore.get(provider.keyAccount) ?? "")
    }

    var isUsable: Bool { problem == nil }

    /// A user-facing reason the config can't be used yet, or nil when it's fine.
    var problem: String? {
        if provider == .claudeCode { return nil }
        if provider.needsKey && apiKey.isEmpty { return "Add your \(provider.label) key in Settings › AI" }
        if baseURL.isEmpty { return "Add the base URL for \(provider.label) in Settings › AI" }
        if URL(string: baseURL)?.host == nil { return "The base URL for \(provider.label) isn't valid (Settings › AI)" }
        if model.isEmpty { return "Choose a model for \(provider.label) in Settings › AI" }
        return nil
    }
}
