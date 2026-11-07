import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let session = ClaudeSession()
    private let voice = VoiceController()
    private let hotkey = HotkeyMonitor()
    private let cursor = AgentCursorController()
    private var cancellables = Set<AnyCancellable>()

    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private var settingsWindow: NSWindow?
    private var permissionPoll: Timer?
    /// Where the current voice request came from: the floating pill or the open chat panel.
    private enum VoiceTarget { case hud, panel }
    private var listeningTarget: VoiceTarget?
    /// Requests waiting for a reply, oldest first (nil target = typed in the chat).
    private struct Turn { let target: VoiceTarget?; let text: String }
    private var turns: [Turn] = []
    private let wake = WakeWordListener()
    /// True while MacPilot is asking "Anything else?" and waiting 3 s for an answer.
    private var inFollowUp = false
    private var wakeWatchdog: Timer?
    private var cleanupTimer: Timer?
    private var hud: VoiceHUDController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        setupStatusItem()

        let actions = ChatActions(
            send: { [weak self] text, screen in self?.send(text, includeScreen: screen) },
            toggleListening: { [weak self] in self?.toggleListening() },
            openSettings: { [weak self] in self?.openSettings() },
            close: { [weak self] in self?.panel.hide() }
        )
        panel = PanelController(rootView: ChatView(session: session, voice: voice, settings: settings, actions: actions))
        panel.statusButton = statusItem.button

        hud = VoiceHUDController(voice: voice, session: session)
        hud.onClick = { [weak self] in
            self?.hud.hide()
            self?.panel.show()
        }

        // Requests run in order (a new one can be queued while Claude is still working),
        // so each reply is matched with the request that caused it.
        session.onTurnFinished = { [weak self] reply in
            guard let self else { return }
            let turn = self.turns.first
            let (display, spoken) = SpeakTag.split(reply)
            if turn?.target == .hud { self.hud.showReply(display.isEmpty ? (spoken ?? "Done") : display) }
            let line = SpeechPolicy.line(reply: reply, request: turn?.text ?? "",
                                         mode: self.settings.spokenReplies, fromVoice: turn?.target != nil)
            voiceLog.notice("turn finished; speak=\(line != nil)")
            let isLast = self.turns.count <= 1
            if turn?.target == .hud && self.settings.followUp && isLast {
                // Siri-style: answer (if there's something to say), then "Anything else?" and listen.
                if let line { self.voice.speak(line) { [weak self] in self?.askFollowUp() } }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.askFollowUp() } }
            } else if let line {
                self.voice.speak(line)
            }
        }
        session.onTurnEnded = { [weak self] in
            guard let self else { return }
            let turn = self.turns.isEmpty ? nil : self.turns.removeFirst()
            if !self.session.isBusy { self.turns.removeAll() }
            // A voice request that ended without a reply (error or stop): say so in the pill.
            if turn?.target == .hud, self.hud.model.phase == .working {
                if let err = self.session.items.last(where: { $0.kind == .error }), self.session.statusText == "Error" {
                    self.hud.showError(String(err.text.prefix(160)))
                } else {
                    self.hud.showError(self.session.statusText == "Stopped" ? "Stopped." : "Something went wrong. Click to see details.")
                }
            }
        }

        // Tap: voice popup starts listening; tap again to send. (Panel only if voice is off.)
        hotkey.onTap = { [weak self] in
            guard let self else { return }
            guard self.settings.voiceInput else { self.panel.toggle(); return }
            if self.voice.isListening { self.finishListening() } else { self.beginListening(in: .hud, handsFree: true) }
        }
        hotkey.onHoldStart = { [weak self] in self?.startVoice() }
        hotkey.onHoldEnd = { [weak self] in self?.finishListening() }
        voice.onUnexpectedEnd = { [weak self] text in self?.sendVoice(text) }
        hotkey.start()

        // The hotkey tap needs Accessibility; keep retrying until it's granted.
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotkey.start() }
        }

        // Load the Whisper model now so the first voice command is fast.
        if settings.speechEngine == .whisperLocal && settings.autoStartVoiceEngines { WhisperLocal.shared.prepare() }
        // Keep the Kokoro voice loaded so replies start speaking quickly.
        if settings.replyVoice == .kokoro && settings.spokenReplies != .off && settings.autoStartVoiceEngines {
            KokoroVoice.shared.prepare()
        }
        settings.$speechEngine.dropFirst().sink { engine in
            if engine == .whisperLocal { WhisperLocal.shared.prepare() } else { WhisperLocal.shared.stop() }
        }.store(in: &cancellables)
        // Boot Claude now so the first request is fast.
        session.prewarm()
        setupWakeWord()
        // Housekeeping: MacPilot's own screenshots are removed after an hour.
        let cleanup = { [weak self] in
            guard let self, self.settings.autoClearScreenshots else { return }
            let n = StorageManager.clearOldScreenshots()
            if n > 0 { voiceLog.notice("auto-cleared \(n) old screenshots") }
        }
        cleanup()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated { cleanup() }
        }
        cursor.start()
        // The virtual cursor follows the session: appears while Claude works, shows progress.
        session.$isBusy.removeDuplicates().sink { [weak self] busy in
            guard let self else { return }
            if busy { self.cursor.begin(status: "Thinking…") }
            else { self.cursor.end(finalText: self.session.statusText == "Error" ? "Something went wrong" : "Done") }
        }.store(in: &cancellables)
        session.$statusText.removeDuplicates().sink { [weak self] text in
            self?.cursor.status(text)
        }.store(in: &cancellables)
        settings.$showAgentCursor.dropFirst().sink { [weak self] on in
            if !on { self?.cursor.hide() }
        }.store(in: &cancellables)
        applyDockIcon(settings.showDockIcon)

        // First run: open the panel and point at the permissions that are missing.
        if !Permissions.accessibility || !Permissions.inputMonitoring {
            panel.show()
            openSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.shutdown()
        WhisperLocal.shared.stop()
    }

    // MARK: - Sending

    private func send(_ text: String, includeScreen: Bool, target: VoiceTarget? = nil) {
        voice.stopSpeaking()
        if !session.isBusy { turns.removeAll() } // nothing pending: drop stale entries
        ScreenGate.set(allowed: ScreenGate.allows(request: text, attachedScreenshot: includeScreen))
        turns.append(Turn(target: target, text: text))
        var context = settings.includeAppContext ? frontAppContext() : nil
        if target != nil && settings.spokenReplies != .off {
            // Ask for a separate line written for listening: per-message instructions are followed
            // far more reliably than the system prompt alone.
            let voiceNote = "voice request. After your normal reply, add a final line <speak>…</speak> with one or two short, " +
                "friendly, conversational sentences written to be heard: no commands, file paths, IDs, IP addresses, symbols, " +
                "markdown or lists; round numbers; say what matters to the user. If this was a simple action that just worked " +
                "(opened, closed, turned on…), leave out <speak> entirely. Reply in the language the user spoke."
            context = [context, voiceNote].compactMap { $0 }.joined(separator: "; ")
        }
        guard includeScreen else {
            session.send(text, context: context)
            return
        }
        // The screenshot is taken off the main thread; Claude gets its path to Read.
        session.send(text, context: context) {
            Self.captureScreen().map { "screenshot of the user's screen attached at \($0) (Read it)" }
        }
    }

    private func frontAppContext() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return "frontmost app is \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))"
    }

    /// Uses the bundled `mpctl screenshot` (point-scaled, matches click coordinates).
    nonisolated private static func captureScreen() -> String? {
        let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mpctl").path ?? ""
        let p = Process()
        let out = Pipe()
        if FileManager.default.isExecutableFile(atPath: helper) {
            p.executableURL = URL(fileURLWithPath: helper)
            p.arguments = ["screenshot"]
        } else {
            let path = NSTemporaryDirectory() + "macpilot-shot-\(Int(Date().timeIntervalSince1970)).jpg"
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-t", "jpg", path]
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // MARK: - Voice

    /// Mic button in the chat panel: dictate into the chat.
    private func toggleListening() {
        if voice.isListening { finishListening() } else { beginListening(in: .panel) }
    }

    /// Hotkey held: the floating voice popup listens until release.
    private func startVoice() {
        session.prewarm() // boots Claude while the user is still talking
        inFollowUp = false
        if voice.isListening { return } // already listening from a tap
        beginListening(in: .hud)
    }

    // MARK: - Wake word & follow-up

    private func setupWakeWord() {
        wake.onWake = { [weak self] in
            guard let self else { return }
            NSSound(named: "Tink")?.play()
            self.inFollowUp = false
            self.beginListening(in: .hud, handsFree: true)
        }
        wake.refresh()
        // Pause the wake word while MacPilot listens or talks (so it never hears itself),
        // and bring it back once things are quiet.
        wakeWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let busyMic = self.voice.isListening || self.voice.isSpeaking || self.voice.isTranscribing || self.inFollowUp
                if busyMic { if self.wake.isRunning { self.wake.pause() } }
                else if self.settings.wakeWordEnabled && !self.wake.isRunning { self.wake.resume() }
                else if !self.settings.wakeWordEnabled && self.wake.isRunning { self.wake.pause() }
            }
        }
    }

    /// "Anything else?" then listen for 3 seconds; silence → "Okay." and back to waiting for the wake word.
    private func askFollowUp() {
        guard !voice.isListening else { return }
        inFollowUp = true
        wake.pause()
        hud.showFollowUp()
        voice.speak("Anything else?") { [weak self] in
            guard let self, self.inFollowUp else { return }
            self.beginListening(in: .hud, handsFree: true, noSpeechTimeout: 3, followUp: true)
        }
    }

    private func endFollowUp() {
        inFollowUp = false
        hud.showReply("Okay")
        voice.speak("Okay.")
    }

    private func beginListening(in target: VoiceTarget, handsFree: Bool = false,
                                noSpeechTimeout: TimeInterval = 5, followUp: Bool = false) {
        wake.pause() // one microphone user at a time
        // Talking over MacPilot stops its speech (the running task keeps going;
        // the new request is queued and runs right after it).
        voice.stopSpeaking()
        // Tap-to-talk stops by itself after you stop speaking (or cancels if you say nothing).
        voice.handsFree = handsFree
        voice.noSpeechTimeout = noSpeechTimeout
        voice.onAutoStop = { [weak self] spoke in
            guard let self else { return }
            if spoke {
                self.inFollowUp = false
                self.finishListening()
            } else {
                self.voice.cancelListening()
                self.listeningTarget = nil
                if followUp { self.endFollowUp() }
                else if target == .hud { self.hud.showError("Didn't hear anything.") }
            }
        }
        voice.startListening()
        guard voice.isListening else {
            if target == .hud, let err = voice.lastError { hud.showError(err) }
            return
        }
        listeningTarget = target
        if target == .hud { hud.showListening() } else { hud.hide() }
    }

    /// Hotkey released (or mic button pressed again).
    private func finishListening() {
        guard voice.isListening else { return }
        inFollowUp = false
        let target = listeningTarget ?? .hud
        if target == .hud { hud.showWorking() }
        voice.stopListening { [weak self] text in self?.sendVoice(text, target: target) }
    }

    private func sendVoice(_ text: String, target: VoiceTarget? = nil) {
        let target = target ?? listeningTarget ?? .hud
        listeningTarget = nil
        guard !text.isEmpty else {
            if target == .hud { hud.showError("Didn't catch that. Hold Control + Option and speak.") }
            return
        }
        if target == .hud { hud.showWorking() }
        send(text, includeScreen: false, target: target)
    }

    // MARK: - Status item & menus

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "MacPilot")
            img?.isTemplate = true
            button.image = img
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Open MacPilot", action: #selector(openPanel), keyEquivalent: "").target = self
            menu.addItem(withTitle: "New Chat", action: #selector(newChat), keyEquivalent: "").target = self
            let shots = StorageManager.screenshotFiles()
            let clear = menu.addItem(withTitle: shots.isEmpty ? "No Screenshots to Clear"
                                     : "Clear Screenshots (\(shots.count), \(StorageManager.format(StorageManager.size(of: shots))))",
                                     action: shots.isEmpty ? nil : #selector(clearScreenshots), keyEquivalent: "")
            clear.target = self
            menu.addItem(.separator())
            menu.addItem(choiceSubmenu(title: "Model", choices: modelChoices, current: settings.model,
                                       action: #selector(pickModel(_:))))
            menu.addItem(choiceSubmenu(title: "Effort", choices: effortChoices, current: settings.effort,
                                       action: #selector(pickEffort(_:))))
            menu.addItem(.separator())
            menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit MacPilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil // keep left-click for the panel
        } else {
            panel.toggle()
        }
    }

    private func choiceSubmenu(title: String, choices: [(id: String, label: String)], current: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "\(title): \(ChatView.shortName(current))", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: title)
        for c in choices {
            let mi = NSMenuItem(title: c.label, action: action, keyEquivalent: "")
            mi.target = self
            mi.representedObject = c.id
            mi.state = c.id == current ? .on : .off
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    @objc private func pickModel(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { settings.model = id } }
    @objc private func pickEffort(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { settings.effort = id } }

    @objc private func clearScreenshots() { StorageManager.clearScreenshots() }

    @objc private func openPanel() { panel.show() }
    @objc private func newChat() { session.newChat(); panel.show() }
    @objc private func openSettingsAction() { openSettings() }

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MacPilot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit MacPilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    // MARK: - Settings & Dock

    private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, session: session,
                                    onDockIconChange: { [weak self] v in self?.applyDockIcon(v) },
                                    onHotkeyChange: { [weak self] in self?.hotkey.restart() })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "MacPilot Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func applyDockIcon(_ show: Bool) {
        let wasSettingsOpen = settingsWindow?.isVisible ?? false
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        // Switching to accessory can hide our windows; bring Settings back if it was open.
        if wasSettingsOpen {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSApp.activate(ignoringOtherApps: true)
                    self.settingsWindow?.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}
