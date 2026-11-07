import SwiftUI

/// Settings › AI. Drop into a grouped Form: it returns Sections.
struct AIProviderSettingsSection: View {
    @State private var provider: AIProvider
    @State private var model = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var fetched: [String] = []
    @State private var status: String?
    @State private var statusOK = false
    @State private var busy = false

    init() {
        let p = ProviderConfig.current().provider
        _provider = State(initialValue: p)
    }

    var body: some View {
        Section {
            Picker("Provider", selection: $provider) {
                ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: provider) { _, p in
                UserDefaults.standard.set(p.rawValue, forKey: ProviderConfig.providerKey)
                loadFields(p)
                changed()
            }

            if provider == .claudeCode {
                TerminalAIPicker()
            }

            if provider != .claudeCode {
                if provider.apiStyle != .claudeCLI && (provider.needsKey || provider == .custom) {
                    HStack {
                        SecureField(provider == .custom ? "API key (optional)" : "API key", text: $apiKey)
                            .onChange(of: apiKey) { _, k in
                                SecretStore.set(k, for: provider.keyAccount)
                                changed()
                            }
                        if let url = provider.keyURL { Link("Get a key", destination: url) }
                    }
                }
                HStack {
                    TextField("Model", text: $model, prompt: Text(provider.suggestedModels.first ?? "model id"))
                        .onChange(of: model) { _, m in
                            UserDefaults.standard.set(m, forKey: ProviderConfig.modelKey(provider))
                            changed()
                        }
                    Menu("Choose") {
                        ForEach(menuModels, id: \.self) { m in Button(m) { model = m } }
                    }
                    .fixedSize()
                    .disabled(menuModels.isEmpty)
                    Button("Refresh") { refresh() }.disabled(busy || (provider.needsKey && apiKey.isEmpty))
                }
                TextField("Base URL", text: $baseURL, prompt: Text(provider == .custom ? "https://…/v1 (required)" : provider.defaultBaseURL))
                    .onChange(of: baseURL) { _, u in
                        UserDefaults.standard.set(u, forKey: ProviderConfig.baseURLKey(provider))
                        changed()
                    }
                HStack {
                    Button("Test") { test() }.disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                    if let status {
                        Text(statusOK ? "✓ \(status)" : status)
                            .foregroundStyle(statusOK ? Color.green : Color.red)
                            .font(.caption).lineLimit(3).textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("AI")
        } footer: {
            Text("Claude Code uses your Claude subscription. API keys are billed by that provider and stored in your Keychain. Local models (Ollama, LM Studio) are free and work offline, but the model must support tool calling (for example qwen3 or llama3.1 and newer).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { loadFields(provider) }
    }

    /// Suggestions first, then models fetched from the provider (deduplicated).
    private var menuModels: [String] {
        var seen = Set<String>()
        return (provider.suggestedModels + fetched).filter { seen.insert($0).inserted }
    }

    /// Config as currently edited (fields may be empty-defaulted).
    private var draft: ProviderConfig {
        var c = ProviderConfig.load(provider)
        c.apiKey = apiKey
        if !baseURL.trimmingCharacters(in: .whitespaces).isEmpty { c.baseURL = baseURL }
        if !model.trimmingCharacters(in: .whitespaces).isEmpty { c.model = model }
        return c
    }

    private func loadFields(_ p: AIProvider) {
        let c = ProviderConfig.load(p)
        let d = UserDefaults.standard
        // Show stored values only; empty fields fall back to defaults (shown as prompts).
        model = d.string(forKey: ProviderConfig.modelKey(p)) ?? c.model
        baseURL = d.string(forKey: ProviderConfig.baseURLKey(p)) ?? ""
        apiKey = c.apiKey
        fetched = []
        status = nil
    }

    private func changed() {
        NotificationCenter.default.post(name: ProviderConfig.changedNotification, object: nil)
    }

    private func refresh() {
        let cfg = draft
        busy = true; status = nil
        Task {
            do {
                let ids = try await APIAgent.fetchModels(cfg)
                fetched = ids
                status = "Found \(ids.count) models"; statusOK = true
            } catch {
                status = (error as? APIAgentError)?.message ?? error.localizedDescription; statusOK = false
            }
            busy = false
        }
    }

    private func test() {
        var cfg = draft
        cfg.model = cfg.model.trimmingCharacters(in: .whitespaces)
        if let p = cfg.problem { status = p; statusOK = false; return }
        busy = true; status = nil
        Task {
            do {
                let reply = try await APIAgent.ping(cfg)
                status = "Connected: \(reply.prefix(40))"; statusOK = true
            } catch {
                status = (error as? APIAgentError)?.message ?? error.localizedDescription; statusOK = false
            }
            busy = false
        }
    }
}

/// Lists every terminal AI MacPilot can drive; installed ones are selectable.
private struct TerminalAIPicker: View {
    @AppStorage("terminalAI") private var selected = TerminalAI.claude.rawValue
    @State private var installed: [TerminalAI: Bool] = [:]
    @State private var model = ""

    var body: some View {
        Picker("Terminal AI", selection: $selected) {
            ForEach(TerminalAI.allCases) { t in
                Text(installed[t] == false ? "\(t.label) (not installed)" : t.label)
                    .tag(t.rawValue)
                    .disabled(installed[t] == false)
            }
        }
        .onChange(of: selected) { _, v in
            model = UserDefaults.standard.string(forKey: "terminalAIModel.\(v)") ?? ""
            NotificationCenter.default.post(name: ProviderConfig.changedNotification, object: nil)
        }
        if let t = TerminalAI(rawValue: selected) {
            if installed[t] == false {
                Text("Install: \(t.installHint)")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if t != .claude {
                TextField("Model (optional, e.g. for OpenCode: openrouter/google/gemini-2.5-flash)", text: $model)
                    .onSubmit { save(t) }
                    .onChange(of: model) { _, _ in save(t) }
            }
        }
        Text("Uses that tool's own login and plan, exactly like Claude Code. Installed here: \(installed.filter { $0.value }.map { $0.key.label }.sorted().joined(separator: ", ")).")
            .font(.caption).foregroundStyle(.secondary)
            .task {
                // Detecting tools runs a login shell; do it off the main thread.
                let found = await Task.detached { Dictionary(uniqueKeysWithValues: TerminalAI.allCases.map { ($0, $0.isInstalled) }) }.value
                installed = found
                model = UserDefaults.standard.string(forKey: "terminalAIModel.\(selected)") ?? ""
            }
    }

    private func save(_ t: TerminalAI) {
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespaces), forKey: "terminalAIModel.\(t.rawValue)")
    }
}
