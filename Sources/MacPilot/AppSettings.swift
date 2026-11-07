import Foundation
import ServiceManagement

enum SafetyMode: String, CaseIterable, Identifiable {
    case full, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: return "Full control (no checks)"
        case .auto: return "Auto-check risky actions"
        }
    }
    var permissionModeFlag: String {
        switch self {
        case .full: return "bypassPermissions"
        case .auto: return "auto"
        }
    }
}

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case ctrlOption, fnCtrl, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ctrlOption: return "Control + Option"
        case .fnCtrl: return "Fn + Control"
        case .off: return "Off"
        }
    }
}

enum HUDPosition: String, CaseIterable, Identifiable {
    case island, bottom, top, cursor
    var id: String { rawValue }
    var label: String {
        switch self {
        case .island: return "Dynamic Island (top center)"
        case .bottom: return "Bottom of screen"
        case .top: return "Top of screen"
        case .cursor: return "Next to the cursor"
        }
    }
}

enum ReplyVoice: String, CaseIterable, Identifiable {
    case kokoro, apple
    var id: String { rawValue }
    var label: String {
        switch self {
        case .kokoro: return "Kokoro · Heart (natural, offline)"
        case .apple: return "Apple voices"
        }
    }
}

enum ScreenAccess: String, CaseIterable, Identifiable {
    case whenAsked, whenNeeded, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .whenAsked: return "Only when I ask about the screen"
        case .whenNeeded: return "Whenever Claude needs it"
        case .never: return "Never"
        }
    }
}

enum SpokenReplies: String, CaseIterable, Identifiable {
    case off, smart, always
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Never"
        case .smart: return "Only when useful (answers & questions)"
        case .always: return "Always"
        }
    }
}

/// Model aliases accepted by `claude --model`. "default" means: don't pass the flag.
let modelChoices: [(id: String, label: String)] = [
    ("default", "Your Claude Code default (can be slow)"),
    ("best", "Best available"),
    ("opus", "Opus"),
    ("sonnet", "Sonnet (fastest for Mac tasks, recommended)"),
    ("haiku", "Haiku"),
    ("fable", "Fable"),
    ("opusplan", "Opus plan + Sonnet execute"),
    ("sonnet[1m]", "Sonnet, 1M context"),
    ("opus[1m]", "Opus, 1M context"),
]

/// Values accepted by `claude --effort`. "default" means: don't pass the flag.
let effortChoices: [(id: String, label: String)] = [
    ("default", "Default"),
    ("low", "Low (fastest, recommended)"),
    ("medium", "Medium"),
    ("high", "High"),
    ("xhigh", "Extra high"),
    ("max", "Max (slowest, smartest)"),
]

/// All user settings, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // General
    @Published var showDockIcon: Bool { didSet { d.set(showDockIcon, forKey: "showDockIcon") } }
    @Published var hotkey: HotkeyChoice { didSet { d.set(hotkey.rawValue, forKey: "hotkey") } }
    @Published var includeAppContext: Bool { didSet { d.set(includeAppContext, forKey: "includeAppContext") } }
    /// Close the menu bar popup when clicking somewhere else (off: it stays until closed).
    @Published var closePopupOnOutsideClick: Bool { didSet { d.set(closePopupOnOutsideClick, forKey: "closePopupOnOutsideClick") } }
    /// Delete MacPilot's screenshots automatically after an hour.
    @Published var autoClearScreenshots: Bool { didSet { d.set(autoClearScreenshots, forKey: "autoClearScreenshots") } }
    @Published var screenAccess: ScreenAccess { didSet { d.set(screenAccess.rawValue, forKey: "screenAccess") } }
    @Published var showAgentCursor: Bool { didSet { d.set(showAgentCursor, forKey: "showAgentCursor") } }

    // Claude
    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    @Published var effort: String { didSet { d.set(effort, forKey: "effort") } }
    @Published var safety: SafetyMode { didSet { d.set(safety.rawValue, forKey: "safety") } }
    @Published var chromeIntegration: Bool { didSet { d.set(chromeIntegration, forKey: "chromeIntegration") } }
    @Published var maxTurns: Int { didSet { d.set(maxTurns, forKey: "maxTurns") } }
    @Published var customInstructions: String { didSet { d.set(customInstructions, forKey: "customInstructions") } }
    @Published var claudePathOverride: String { didSet { d.set(claudePathOverride, forKey: "claudePathOverride") } }
    @Published var extraArgs: String { didSet { d.set(extraArgs, forKey: "extraArgs") } }
    /// Skip the user's Claude Code hooks, plugins and MCP servers (they're for coding and slow MacPilot down).
    @Published var fastMode: Bool { didSet { d.set(fastMode, forKey: "fastMode") } }

    // Voice
    @Published var voiceInput: Bool { didSet { d.set(voiceInput, forKey: "voiceInput") } }
    @Published var spokenReplies: SpokenReplies { didSet { d.set(spokenReplies.rawValue, forKey: "spokenReplies") } }
    @Published var voiceIdentifier: String { didSet { d.set(voiceIdentifier, forKey: "voiceIdentifier") } }
    @Published var speechRate: Double { didSet { d.set(speechRate, forKey: "speechRate") } }
    @Published var replyVoice: ReplyVoice { didSet { d.set(replyVoice.rawValue, forKey: "replyVoice") } }
    /// Load Whisper and the Kokoro voice when MacPilot opens (faster first use, uses memory).
    @Published var autoStartVoiceEngines: Bool { didSet { d.set(autoStartVoiceEngines, forKey: "autoStartVoiceEngines") } }
    @Published var speechEngine: SpeechEngine { didSet { d.set(speechEngine.rawValue, forKey: "speechEngine") } }
    @Published var speechLanguage: SpeechLanguage { didSet { d.set(speechLanguage.rawValue, forKey: "speechLanguage") } }
    @Published var wakeWordEnabled: Bool { didSet { d.set(wakeWordEnabled, forKey: "wakeWordEnabled") } }
    @Published var wakeWord: String { didSet { d.set(wakeWord, forKey: "wakeWord") } }
    /// After a voice request, ask "Anything else?" and listen for 3 seconds.
    @Published var followUp: Bool { didSet { d.set(followUp, forKey: "followUp") } }
    @Published var hudPosition: HUDPosition { didSet { d.set(hudPosition.rawValue, forKey: "hudPosition") } }

    private init() {
        d.register(defaults: [
            "showDockIcon": false,
            "hotkey": HotkeyChoice.ctrlOption.rawValue,
            "includeAppContext": true,
            "showAgentCursor": true,
            "closePopupOnOutsideClick": false,
            "autoClearScreenshots": true,
            "model": "sonnet",
            "effort": "low",
            "fastMode": true,
            "safety": SafetyMode.full.rawValue,
            "chromeIntegration": false,
            "maxTurns": 0,
            "customInstructions": "",
            "claudePathOverride": "",
            "extraArgs": "",
            "voiceInput": true,
            "spokenReplies": SpokenReplies.smart.rawValue,
            "voiceIdentifier": "",
            "speechRate": 0.5,
            "hudPosition": HUDPosition.island.rawValue,
            "speechLanguage": SpeechLanguage.auto.rawValue,
            "autoStartVoiceEngines": true,
            "wakeWordEnabled": false, // keeps the mic on all the time, so it's opt-in
            "wakeWord": "Clicky",
            "followUp": true,
        ])
        showDockIcon = d.bool(forKey: "showDockIcon")
        hotkey = HotkeyChoice(rawValue: d.string(forKey: "hotkey") ?? "") ?? .ctrlOption
        includeAppContext = d.bool(forKey: "includeAppContext")
        showAgentCursor = d.bool(forKey: "showAgentCursor")
        autoClearScreenshots = d.bool(forKey: "autoClearScreenshots")
        screenAccess = ScreenAccess(rawValue: d.string(forKey: "screenAccess") ?? "") ?? .whenAsked
        closePopupOnOutsideClick = d.bool(forKey: "closePopupOnOutsideClick")
        model = d.string(forKey: "model") ?? "sonnet"
        effort = d.string(forKey: "effort") ?? "low"
        fastMode = d.bool(forKey: "fastMode")
        safety = SafetyMode(rawValue: d.string(forKey: "safety") ?? "") ?? .full
        chromeIntegration = d.bool(forKey: "chromeIntegration")
        maxTurns = d.integer(forKey: "maxTurns")
        customInstructions = d.string(forKey: "customInstructions") ?? ""
        claudePathOverride = d.string(forKey: "claudePathOverride") ?? ""
        extraArgs = d.string(forKey: "extraArgs") ?? ""
        voiceInput = d.bool(forKey: "voiceInput")
        spokenReplies = SpokenReplies(rawValue: d.string(forKey: "spokenReplies") ?? "") ?? .smart
        voiceIdentifier = d.string(forKey: "voiceIdentifier") ?? ""
        speechRate = d.double(forKey: "speechRate")
        // Default to local Whisper when it's installed, otherwise Apple.
        let defaultEngine: SpeechEngine = (WhisperLocal.serverBinary != nil && WhisperLocal.modelPath != nil) ? .whisperLocal : .apple
        replyVoice = ReplyVoice(rawValue: d.string(forKey: "replyVoice") ?? "") ?? (KokoroVoice.isInstalled ? .kokoro : .apple)
        autoStartVoiceEngines = d.bool(forKey: "autoStartVoiceEngines")
        speechEngine = SpeechEngine(rawValue: d.string(forKey: "speechEngine") ?? "") ?? defaultEngine
        speechLanguage = SpeechLanguage(rawValue: d.string(forKey: "speechLanguage") ?? "") ?? .auto
        wakeWordEnabled = d.bool(forKey: "wakeWordEnabled")
        wakeWord = d.string(forKey: "wakeWord") ?? "Clicky"
        followUp = d.bool(forKey: "followUp")
        hudPosition = HUDPosition(rawValue: d.string(forKey: "hudPosition") ?? "") ?? .island
    }

    /// Settings that require restarting the `claude` process when they change.
    /// The conversation continues afterwards via `--resume`.
    var sessionSignature: String {
        [model, effort, safety.rawValue, String(chromeIntegration), String(maxTurns),
         customInstructions, claudePathOverride, extraArgs, String(showAgentCursor), String(fastMode)].joined(separator: "\u{1F}")
    }

    // Launch at login (only works from the bundled .app)
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("MacPilot: launch at login change failed: \(error)")
            }
        }
    }
}
