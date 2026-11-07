import SwiftUI

/// Actions the chat view asks the app to perform.
struct ChatActions {
    var send: (_ text: String, _ includeScreen: Bool) -> Void
    var toggleListening: () -> Void
    var openSettings: () -> Void
    var close: () -> Void
}

struct ChatView: View {
    @ObservedObject var session: ClaudeSession
    @ObservedObject var voice: VoiceController
    @ObservedObject var settings: AppSettings
    let actions: ChatActions

    @State private var draft = ""
    @AppStorage("aiProvider") private var aiProvider = AIProvider.claudeCode.rawValue
    @AppStorage("terminalAI") private var terminalAI = TerminalAI.claude.rawValue
    @State private var includeScreen = false
    @State private var hotkeyGlobal = HotkeyMonitor.hasGlobalAccess
    private let permTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if !hotkeyGlobal && settings.hotkey != .off { permissionBanner }
            Divider().opacity(0.5)
            messages
            Divider().opacity(0.5)
            inputBar
        }
        .frame(minWidth: 320, minHeight: 340)
        .onReceive(NotificationCenter.default.publisher(for: .macPilotFocusInput)) { _ in
            inputFocused = true
        }
        .onReceive(permTimer) { _ in hotkeyGlobal = HotkeyMonitor.hasGlobalAccess }
    }

    // MARK: Permission banner

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "keyboard.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(settings.hotkey.label) only works while this panel is open")
                    .font(.system(size: 12, weight: .semibold))
                Text("Turn on MacPilot in Input Monitoring so it works in every app.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Fix") { Permissions.requestInputMonitoring(); Permissions.open(.inputMonitoring) }
                .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("MacPilot").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(voice.isListening ? "Listening…" : session.statusText)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            modelMenu
            iconButton("square.and.pencil", help: "New chat") { session.newChat() }
            iconButton("gearshape", help: "Settings") { actions.openSettings() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var statusColor: Color {
        if voice.isListening { return .red }
        if session.isBusy { return .orange }
        if session.statusText == "Error" { return .red }
        return .green
    }

    /// Native pull-down to switch model and effort right from the popup.
    @ViewBuilder private var modelMenu: some View {
        if let p = AIProvider(rawValue: aiProvider), p != .claudeCode {
            // API key / local model: show which one; change it in Settings › AI.
            Button { actions.openSettings() } label: {
                Text("\(p.label.components(separatedBy: " (").first ?? p.label) · \(ProviderConfig.current().model)")
                    .lineLimit(1)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.7), in: Capsule())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 170)
            }
            .buttonStyle(.plain)
            .help("AI provider and model (Settings › AI)")
        } else if let t = TerminalAI(rawValue: terminalAI), t != .claude {
            Button { actions.openSettings() } label: {
                Text(t.label)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.7), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Terminal AI in use (Settings › AI)")
        } else {
            claudeModelMenu
        }
    }

    private var claudeModelMenu: some View {
        Menu {
            Picker("Model", selection: $settings.model) {
                ForEach(modelChoices, id: \.id) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.inline)
            Picker("Effort", selection: $settings.effort) {
                ForEach(effortChoices, id: \.id) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text("\(Self.shortName(settings.model)) · \(Self.shortName(settings.effort))")
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary.opacity(0.7), in: Capsule())
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model and effort. Changes apply to your next message.")
    }

    static func shortName(_ id: String) -> String {
        switch id {
        case "default": return "Default"
        case "xhigh": return "X-High"
        case "opusplan": return "Opus Plan"
        case "sonnet[1m]": return "Sonnet 1M"
        case "opus[1m]": return "Opus 1M"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help("Change in Settings › Claude")
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if session.items.isEmpty { emptyState }
                    ForEach(session.items) { item in
                        ChatRow(item: item).id(item.id)
                    }
                    if voice.isListening && !voice.transcript.isEmpty {
                        Text(voice.transcript)
                            .font(.system(size: 13))
                            .italic()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: session.items) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: voice.transcript) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What should I do?")
                .font(.system(size: 15, weight: .semibold))
            Text("Settings, Finder, Chrome, any app. Just ask.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ForEach(["Turn on dark mode and set volume to 30%",
                     "Close all YouTube tabs in Chrome",
                     "What's using the most memory?"], id: \.self) { s in
                Button { draft = s; inputFocused = true } label: {
                    Text(s).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Text(settings.hotkey == .off ? "" :
                 "Tip: hold \(settings.hotkey.label) anywhere to talk to MacPilot.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 8)
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = voice.lastError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { includeScreen.toggle() } label: {
                    Image(systemName: includeScreen ? "camera.fill" : "camera")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(includeScreen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .help("Attach a screenshot of your screen to this message")

                TextField("Ask MacPilot to do anything…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(submit)
                    .padding(.vertical, 5)

                Button { actions.toggleListening() } label: {
                    Image(systemName: voice.isListening ? "mic.fill" : "mic")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(voice.isListening ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .help("Talk (or hold the hotkey)")

                if session.isBusy {
                    Button { session.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Stop")
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(draft.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actions.send(text, includeScreen)
        draft = ""
        includeScreen = false
    }
}

private struct ChatRow: View {
    let item: ChatItem
    @State private var expanded = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            }
        case .assistant:
            Text(markdown(SpeakTag.strip(item.text)))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            VStack(alignment: .leading, spacing: 3) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        statusIcon.frame(width: 12)
                        Text(item.text).font(.system(size: 11, weight: .medium))
                        if !item.detail.isEmpty {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                if expanded && !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        case .error:
            Label { Text(markdown(item.text)).textSelection(.enabled) } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .info:
            Text(item.text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.toolStatus {
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
