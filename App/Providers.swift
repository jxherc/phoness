import Foundation

enum LLMEvent {
    case text(String)
    case thinking
    case tool(String)
}

// one model turn: anthropic-style content blocks back, plus anthropic's stop reason
@MainActor
protocol LLM {
    func send(
        system: String,
        tools: [[String: Any]],
        messages: [[String: Any]],
        on: @MainActor (LLMEvent) -> Void
    ) async throws -> (content: [[String: Any]], stop: String)
}

// where replies come from. anthropic speaks its own messages api, the rest openai's chat
// completions. the list and urls follow pi's provider catalog. models are ones that take
// images (the agent works from screenshots), checked against models.dev on 2026-10-26
struct Provider: Identifiable {
    enum API { case anthropic, openai }

    var id: String
    var name: String
    var api = API.openai
    // chat/completions goes on the end
    var url = ""
    var hint = "API key"
    var models: [(id: String, name: String)] = []
    // max tokens field, for providers whose default is too short for a turn
    var limit: String?
    // mistral only takes 9 letter or digit tool call ids
    var shortIDs = false
    // deepseek wants reasoning_content on every assistant message in thinking mode
    var alwaysReasoning = false
    // gemini refuses a tool whose parameters have no properties
    var bareTools = false

    func modelName(_ id: String) -> String { models.first { $0.id == id }?.name ?? id }
}

@MainActor
enum Providers {
    static let all: [Provider] = [
        Provider(id: "anthropic", name: "Anthropic", api: .anthropic, hint: "sk-ant-…", models: [
            ("claude-opus-5-5", "Claude Opus 5.5"),
            ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
            ("claude-haiku-5-5", "Claude Haiku 5.5"),
            ("claude-fable-5-1", "Claude Fable 5.1"),
        ]),
        Provider(id: "openai", name: "OpenAI", url: "https://api.openai.com/v1", hint: "sk-…", models: [
            ("gpt-6.1-sol", "GPT-6.1 Sol"),
            ("gpt-6.1-terra", "GPT-6.1 Terra"),
            ("gpt-6-astra", "GPT-6 Astra"),
            ("gpt-6-luna", "GPT-6 Luna"),
        ]),
        Provider(id: "google", name: "Google Gemini", url: "https://generativelanguage.googleapis.com/v1beta/openai", hint: "AIza…", models: [
            ("gemini-4-argon", "Gemini 4 Argon"),
            ("gemini-3.8-flash", "Gemini 3.8 Flash"),
            ("gemini-3.5-flash-lite", "Gemini 3.5 Flash Lite"),
        ], bareTools: true),
        Provider(id: "xai", name: "xAI", url: "https://api.x.ai/v1", hint: "xai-…", models: [
            ("grok-4.7", "Grok 4.7"),
            ("grok-4.6", "Grok 4.6"),
        ]),
        Provider(id: "openrouter", name: "OpenRouter", url: "https://openrouter.ai/api/v1", hint: "sk-or-…", models: [
            ("anthropic/claude-opus-5.5", "Claude Opus 5.5"),
            ("openai/gpt-6.1-sol", "GPT-6.1 Sol"),
            ("google/gemini-4-argon", "Gemini 4 Argon"),
            ("x-ai/grok-4.7", "Grok 4.7"),
            ("moonshotai/kimi-k3.1-pro", "Kimi K3.1 Pro"),
        ]),
        Provider(id: "deepseek", name: "DeepSeek", url: "https://api.deepseek.com", hint: "sk-…", models: [
            ("deepseek-flash", "DeepSeek V4.1 Flash"),
        ], limit: "max_tokens", alwaysReasoning: true),
        Provider(id: "mistral", name: "Mistral", url: "https://api.mistral.ai/v1", models: [
            ("mistral-medium-latest", "Mistral Medium"),
            ("mistral-large-4", "Mistral Large 4"),
            ("mistral-small-latest", "Mistral Small"),
        ], shortIDs: true),
        Provider(id: "groq", name: "Groq", url: "https://api.groq.com/openai/v1", hint: "gsk_…", models: [
            ("qwen/qwen3.8-27b", "Qwen3.8 27B"),
        ]),
        Provider(id: "moonshot", name: "Moonshot (Kimi)", url: "https://api.moonshot.ai/v1", hint: "sk-…", models: [
            ("kimi-k3.1-pro", "Kimi K3.1 Pro"),
            ("kimi-k3", "Kimi K3"),
        ], limit: "max_tokens"),
        // any other openai-compatible server, a local one included
        Provider(id: "custom", name: "Custom", hint: "optional"),
    ]

    static func find(_ id: String) -> Provider { all.first { $0.id == id } ?? all[0] }

    // "model" holds the current provider's model, so installs from before providers keep theirs.
    // each provider's last pick sits in "model.<id>" for switching back
    static var current: Provider { find(UserDefaults.standard.string(forKey: "provider") ?? "") }
    static var model: String {
        let m = (UserDefaults.standard.string(forKey: "model") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? current.models.first?.id ?? "" : m
    }

    static func remembered(_ p: Provider) -> String {
        UserDefaults.standard.string(forKey: "model.\(p.id)") ?? p.models.first?.id ?? ""
    }

    static func url(_ p: Provider) -> String {
        p.id == "custom" ? UserDefaults.standard.string(forKey: "custom.url") ?? "" : p.url
    }

    // the provider is fixed for a run, like the claude login is
    static func client() -> LLM {
        let p = current
        switch p.api {
        case .anthropic: return Claude(model: model)
        case .openai: return OpenAI(provider: p, model: model, key: Keychain.get(p.id) ?? "", url: url(p))
        }
    }
}
