import AppKit
import AVFoundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var session: ClaudeSession
    var onDockIconChange: (Bool) -> Void
    var onHotkeyChange: () -> Void

    var body: some View {
        TabView {
            GeneralTab(settings: settings, onDockIconChange: onDockIconChange, onHotkeyChange: onHotkeyChange)
                .tabItem { Label("General", systemImage: "gearshape") }
            ClaudeTab(settings: settings, session: session)
                .tabItem { Label("Claude", systemImage: "sparkles") }
            VoiceTab(settings: settings)
                .tabItem { Label("Voice", systemImage: "waveform") }
            PermissionsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            StorageTab(session: session)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    var onDockIconChange: (Bool) -> Void
    var onHotkeyChange: () -> Void

    var body: some View {
        Form {
            Section("App") {
                Toggle("Show icon in Dock", isOn: $settings.showDockIcon)
                    .onChange(of: settings.showDockIcon) { _, v in onDockIconChange(v) }
                Text("When off, MacPilot lives only in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open at login", isOn: Binding(get: { settings.launchAtLogin },
                                                       set: { settings.launchAtLogin = $0 }))
            }
            Section("Hotkey") {
                Picker("Shortcut", selection: $settings.hotkey) {
                    ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.hotkey) { _, _ in onHotkeyChange() }
                Text("Hold to talk, release to send. Or tap to start and tap again to send. The chat panel opens from the menu bar icon. Needs Input Monitoring permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar popup") {
                Toggle("Close when I click somewhere else", isOn: $settings.closePopupOnOutsideClick)
                Text("Off: the popup stays open while you work in other apps. Close it with Esc or the menu bar icon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Virtual cursor") {
                Toggle("Show a virtual cursor while MacPilot works", isOn: $settings.showAgentCursor)
                Text("A purple pointer glides to whatever MacPilot clicks or presses and shows what it's doing. Your real mouse is never moved. Turning it off also makes clicks a little faster.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Context") {
                Toggle("Tell Claude which app is in front", isOn: $settings.includeAppContext)
                Text("Lets you say things like “close this tab” or “save this file”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Claude

private struct ClaudeTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var session: ClaudeSession
    @State private var cliInfo = "Checking…"
    @State private var maxTurnsText = ""

    var body: some View {
        Form {
            Section("Model") {
                Picker("Model", selection: $settings.model) {
                    ForEach(modelChoices, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("Effort", selection: $settings.effort) {
                    ForEach(effortChoices, id: \.id) { Text($0.label).tag($0.id) }
                }
                Text("Higher effort thinks longer: better for hard tasks, slower for simple ones. Changes apply to your next message and keep the conversation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Control") {
                Picker("Safety", selection: $settings.safety) {
                    ForEach(SafetyMode.allCases) { Text($0.label).tag($0) }
                }
                Text(settings.safety == .full
                     ? "Claude runs any command without asking. Fastest, but mistakes aren't caught."
                     : "Claude Code's safety check reviews risky actions and blocks dangerous ones.")
                    .font(.caption).foregroundStyle(settings.safety == .full ? .orange : .secondary)
                Picker("Let Claude look at the screen", selection: $settings.screenAccess) {
                    ForEach(ScreenAccess.allCases) { Text($0.label).tag($0) }
                }
                Text("Screenshots are sent to Claude as images. “Only when I ask” allows them when your request is about the screen (“what's on screen?”, “look at this”) or you press 📷.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Fast mode", isOn: $settings.fastMode)
                Text("Skips your Claude Code hooks, plugins and MCP servers (meant for coding) so MacPilot starts and acts faster.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Use Claude in Chrome extension (--chrome)", isOn: $settings.chromeIntegration)
                TextField("Max steps per request (0 = no limit)", text: $maxTurnsText)
                    .onAppear { maxTurnsText = String(settings.maxTurns) }
                    .onChange(of: maxTurnsText) { _, v in settings.maxTurns = max(0, Int(v) ?? 0) }
            }
            Section("Your instructions") {
                TextEditor(text: $settings.customInstructions)
                    .font(.system(size: 12))
                    .frame(height: 70)
                Text("Added to every conversation, e.g. “Always use Chrome, not Safari.”")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code") {
                LabeledContent("CLI", value: cliInfo)
                TextField("Custom path to claude (optional)", text: $settings.claudePathOverride)
                TextField("Extra CLI flags (advanced)", text: $settings.extraArgs)
                    .font(.system(size: 12, design: .monospaced))
                LabeledContent("Conversation", value: session.sessionId.map { String($0.prefix(8)) + "…" } ?? "New")
                Button("Start a new conversation") { session.newChat() }
            }
        }
        .formStyle(.grouped)
        .task(id: settings.claudePathOverride) { cliInfo = await Self.detect(settings.claudePathOverride) }
    }

    static func detect(_ override: String) async -> String {
        await Task.detached {
            guard let path = ClaudeLocator.find(override: override) else { return "Not found" }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["--version"]
            p.environment = await ClaudeSession.childEnvironment()
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return path }
            p.waitUntilExit()
            let v = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? path : "\(v) · \((path as NSString).abbreviatingWithTildeInPath)"
        }.value
    }
}

// MARK: - Voice

private struct VoiceTab: View {
    @ObservedObject var settings: AppSettings
    private let voices = VoiceController.availableVoices
    @State private var groqKey = ""
    @StateObject private var previewVoice = VoiceController()

    var body: some View {
        Form {
            Section("Speech recognition") {
                Picker("Engine", selection: $settings.speechEngine) {
                    ForEach(SpeechEngine.allCases) { Text($0.label).tag($0) }
                }
                Picker("Language", selection: $settings.speechLanguage) {
                    ForEach(SpeechLanguage.allCases) { Text($0.label).tag($0) }
                }
                switch settings.speechEngine {
                case .apple:
                    Text("Free and private. Less accurate with accents, Hinglish and app names.")
                        .font(.caption).foregroundStyle(.secondary)
                case .whisperLocal:
                    LabeledContent("Status", value: WhisperLocal.statusText)
                    HStack {
                        Text("Runs offline on your Mac. Words still appear live while you talk; Whisper writes the final text.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Models Folder") {
                            try? FileManager.default.createDirectory(at: WhisperLocal.modelsFolder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(WhisperLocal.modelsFolder)
                        }
                    }
                case .groq:
                    SecureField("Groq API key", text: $groqKey)
                        .onAppear { groqKey = Keychain.groqKey ?? "" }
                        .onSubmit { Keychain.groqKey = groqKey }
                        .onChange(of: groqKey) { _, v in Keychain.groqKey = v }
                    Text("Stored in your macOS Keychain. Get a key at console.groq.com. Your voice clip is sent to Groq; falls back to Apple if it fails.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Wake word") {
                Toggle("Wake MacPilot by saying its name", isOn: $settings.wakeWordEnabled)
                TextField("Wake word", text: $settings.wakeWord)
                Toggle("Ask “Anything else?” after voice requests", isOn: $settings.followUp)
                Text("Say “\(settings.wakeWord)” and a sound plays; then say what you need. After each voice task MacPilot asks “Anything else?” and listens for 3 seconds. Note: to hear the wake word the microphone has to stay on all the time (audio is checked on your Mac and thrown away), so macOS shows the orange microphone dot. When off, the mic is only used while you hold or tap the hotkey.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Talking to MacPilot") {
                Toggle("Hold the hotkey to talk", isOn: $settings.voiceInput)
                Picker("Voice popup position", selection: $settings.hudPosition) {
                    ForEach(HUDPosition.allCases) { Text($0.label).tag($0) }
                }
                Text("Hold Control + Option, speak, release. A small popup listens, works, and shows the answer. Uses Apple's built-in speech recognition.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spoken replies") {
                Picker("Speak replies", selection: $settings.spokenReplies) {
                    ForEach(SpokenReplies.allCases) { Text($0.label).tag($0) }
                }
                Text("“Only when useful” stays quiet after simple actions and speaks answers, information you asked for, problems, or questions back to you.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Reply voice", selection: $settings.replyVoice) {
                    ForEach(ReplyVoice.allCases) { Text($0.label).tag($0) }
                }
                if settings.replyVoice == .kokoro {
                    LabeledContent("Kokoro", value: KokoroVoice.statusText)
                    Text("English replies use Kokoro; Hindi replies use Apple's Hindi voice.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Apple voice", selection: $settings.voiceIdentifier) {
                    Text("Automatic (best installed: \(VoiceController.bestVoice?.name ?? "default"))").tag("")
                    ForEach(voices, id: \.identifier) { v in
                        Text("\(v.name)\(v.quality == .premium ? " (Premium)" : v.quality == .enhanced ? " (Enhanced)" : "")")
                            .tag(v.identifier)
                    }
                }
                Slider(value: $settings.speechRate, in: 0.3...0.7) { Text("Speed") }
                HStack {
                    Button("Preview") { previewVoice.speak("Hi, I'm MacPilot. I turned on dark mode for you.") }
                    Button("Get better voices…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                    }
                }
                Text("For a natural voice: System Settings › Accessibility › Spoken Content › System voice › Manage Voices… › English › download “Ava (Premium)” or “Zoe (Premium)”. MacPilot picks it up automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions

/// Polled permission state (cheap checks), so rows update after the user grants access.
private final class PermissionState: ObservableObject {
    @Published var ax = false
    @Published var input = false
    @Published var screen = false
    @Published var mic = false
    @Published var speech = false
    @Published var fda = false
    func refresh() {
        fda = Permissions.fullDiskAccess
        ax = Permissions.accessibility
        input = Permissions.inputMonitoring
        screen = Permissions.screenRecording
        mic = Permissions.microphone == .granted
        speech = Permissions.speech == .granted
    }
}

private struct PermissionsTab: View {
    @StateObject private var state = PermissionState()
    @State private var automationResult = ""
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Set everything up once").font(.headline)
                        Text("Asks for every missing permission in a row. Click Allow (or switch MacPilot on) for each. macOS never lets an app grant itself access, but after this the prompts stop.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Grant all missing") {
                        Permissions.requestAllMissing { allowed, asked in
                            DispatchQueue.main.async { automationResult = "Allowed for \(allowed) of \(asked) apps" }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Section {
                row("Accessibility", "Control apps, click and type.", ok: state.ax) { Permissions.requestAccessibility() }
                row("Input Monitoring", "The global hotkey (Control + Option).", ok: state.input) { Permissions.requestInputMonitoring() }
                row("Screen Recording", "See the screen when nothing else works.", ok: state.screen) { Permissions.requestScreenRecording() }
                row("Microphone", "Voice input.", ok: state.mic) { Permissions.requestMicrophone() }
                row("Speech Recognition", "Live words while you talk.", ok: state.speech) { Permissions.requestSpeech() }
                row("Full Disk Access", "Stops the Desktop / Documents / Downloads / other-app folder prompts.",
                    ok: state.fda) { Permissions.requestFullDiskAccess() }
            } header: {
                Text("Permissions")
            } footer: {
                Text("For Full Disk Access, switch MacPilot on in the list (or drag MacPilot from the Finder window that opens). After granting Input Monitoring or Screen Recording, quit and reopen MacPilot. macOS 15 may re-confirm Screen Recording about once a month.")
            }
            Section("Controlling other apps") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Automation")
                        Text(automationResult.isEmpty
                             ? "Asks to control every app that's open now, plus Finder and System Events, all at once. Apps that aren't open will ask once, the first time MacPilot uses them."
                             : automationResult)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Allow open apps") {
                        Permissions.requestAutomationForRunningApps { allowed, asked in
                            DispatchQueue.main.async { automationResult = "Allowed for \(allowed) of \(asked) apps" }
                        }
                    }
                    Button("Open") { Permissions.open(.automation) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { state.refresh() }
        .onReceive(timer) { _ in state.refresh() }
    }

    private func row(_ title: String, _ subtitle: String, ok: Bool, grant: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if ok { Text("Granted").foregroundStyle(.secondary) } else { Button("Grant", action: grant) }
        }
    }
}

// MARK: - Storage

private struct StorageTab: View {
    @ObservedObject var session: ClaudeSession
    @ObservedObject var settings = AppSettings.shared
    @State private var shots: (count: Int, bytes: Int64) = (0, 0)
    @State private var history: Int64 = 0
    @State private var workspace: Int64 = 0
    @State private var confirm: Confirm?

    enum Confirm: Identifiable {
        case screenshots, history, settings
        var id: Self { self }
    }

    var body: some View {
        Form {
            Section {
                item("Screenshots", "Screen images MacPilot took for Claude (\(shots.count) files).",
                     size: shots.bytes, button: "Clear") { confirm = .screenshots }
                Toggle("Delete screenshots automatically after 1 hour", isOn: $settings.autoClearScreenshots)
                item("Conversation history", "MacPilot's own Claude Code transcripts. Your other Claude Code sessions are not touched.",
                     size: history, button: "Clear") { confirm = .history }
            } header: {
                Text("Safe to clear")
            } footer: {
                Text("Only files created by MacPilot are removed.")
            }
            Section("Kept") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Working folder")
                        Text("Scratch files Claude made while working. Not cleared automatically, in case something you need is there.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(StorageManager.format(workspace)).foregroundStyle(.secondary)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([StorageManager.workspaceURL]) }
                }
            }
            Section("Settings") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Reset all settings")
                        Text("Restores defaults and relaunches MacPilot. macOS permissions stay as they are.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset…", role: .destructive) { confirm = .settings }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .alert(item: $confirm) { c in
            switch c {
            case .screenshots:
                return Alert(title: Text("Delete \(shots.count) screenshots?"),
                             message: Text("Frees \(StorageManager.format(shots.bytes))."),
                             primaryButton: .destructive(Text("Delete")) { StorageManager.clearScreenshots(); refresh() },
                             secondaryButton: .cancel())
            case .history:
                return Alert(title: Text("Clear MacPilot's conversation history?"),
                             message: Text("Starts a new chat and frees \(StorageManager.format(history)). This can't be undone."),
                             primaryButton: .destructive(Text("Clear")) {
                                 session.newChat()
                                 StorageManager.clearHistory()
                                 refresh()
                             },
                             secondaryButton: .cancel())
            case .settings:
                return Alert(title: Text("Reset all MacPilot settings?"),
                             message: Text("MacPilot will relaunch with default settings."),
                             primaryButton: .destructive(Text("Reset")) { resetAndRelaunch() },
                             secondaryButton: .cancel())
            }
        }
    }

    private func item(_ title: String, _ subtitle: String, size: Int64, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(StorageManager.format(size)).foregroundStyle(.secondary).monospacedDigit()
            Button(button, action: action).disabled(size == 0)
        }
    }

    private func refresh() {
        let files = StorageManager.screenshotFiles()
        shots = (files.count, StorageManager.size(of: files))
        history = StorageManager.historyFolder().map { StorageManager.size(of: $0) } ?? 0
        workspace = StorageManager.size(of: StorageManager.workspaceURL)
    }

    private func resetAndRelaunch() {
        session.shutdown()
        StorageManager.resetSettings()
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
