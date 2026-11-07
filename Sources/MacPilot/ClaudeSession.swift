import AppKit
import Foundation

/// One row in the chat.
struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable { case user, assistant, tool, error, info }
    enum ToolStatus: Equatable { case running, ok, failed }

    let id = UUID()
    var kind: Kind
    var text: String
    var detail: String = ""
    var toolStatus: ToolStatus = .running
    var toolUseId: String? = nil
}

/// Runs the user's logged-in Claude Code CLI as a long-lived headless process
/// (`claude -p` with stream-json input and output) and turns its event stream
/// into chat rows. No API key is involved: the CLI uses its own login.
@MainActor
final class ClaudeSession: ObservableObject {
    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = "Ready"
    @Published private(set) var sessionId: String?

    /// Final reply text of a successful turn (used for spoken replies).
    var onTurnFinished: ((String) -> Void)?
    /// Any turn end: success, error, stop or crash.
    var onTurnEnded: (() -> Void)?

    private let settings = AppSettings.shared
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var runningSignature = ""
    private var stderrTail = ""
    private var stdoutBuffer = Data()

    /// Bumped whenever a process is started or stopped, so late output from an
    /// old process is ignored.
    private var generation = 0
    private var pendingTurns = 0 { didSet { isBusy = pendingTurns > 0 || preparing > 0 } }
    private var preparing = 0 { didSet { isBusy = pendingTurns > 0 || preparing > 0 } }
    private var interrupting = false
    private var interruptFallback: DispatchWorkItem?
    private var lastUserPayload: String?
    private var retriedResume = false

    // Streaming bookkeeping
    private var currentMessageId: String?
    private var streamedMessageIds = Set<String>()
    private var streamingItemIndex: [String: UUID] = [:] // "msgId#blockIndex" -> item id

    init() {
        sessionId = UserDefaults.standard.string(forKey: "lastSessionId")
        if sessionId != nil {
            items.append(ChatItem(kind: .info, text: "Continuing your last conversation. Start a new chat any time."))
        }
    }

    // MARK: - Public API

    /// Sends a message. `prepare` runs off the main thread first (e.g. taking a
    /// screenshot) and can return extra context to attach.
    func send(_ text: String, context: String? = nil, prepare: (@Sendable () -> String?)? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startFreshIfIdle()
        items.append(ChatItem(kind: .user, text: trimmed))

        guard let prepare else {
            deliver(trimmed, context: context)
            return
        }
        preparing += 1
        statusText = "Looking at the screen…"
        let gen = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let extra = prepare()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.preparing -= 1
                    guard gen == self.generation else { return } // stopped or new chat meanwhile
                    let ctx = [context, extra].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; ")
                    self.deliver(trimmed, context: ctx)
                }
            }
        }
    }

    private func deliver(_ text: String, context: String?) {
        var full = text
        if let context, !context.isEmpty { full = "[Context: \(context)]\n\(text)" }
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": full]]],
            "parent_tool_use_id": NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        lastUserPayload = line
        retriedResume = false
        write(line)
    }

    private func write(_ line: String) {
        if process == nil || runningSignature != settings.sessionSignature {
            stopProcess()
            guard startProcess() else { return }
        }
        do {
            try stdinHandle?.write(contentsOf: Data((line + "\n").utf8))
            pendingTurns += 1
            statusText = "Thinking…"
        } catch {
            appendError("Couldn't talk to Claude Code: \(error.localizedDescription)")
            stopProcess()
        }
    }

    /// Interrupts the current turn but keeps the process and conversation alive.
    /// Falls back to killing the process if the CLI doesn't respond.
    func stop() {
        guard isBusy else { return }
        if preparing > 0 && pendingTurns == 0 {
            generation += 1 // drops the pending screenshot send
            preparing = 0
            markStopped()
            return
        }
        interrupting = true
        statusText = "Stopping…"
        let request: [String: Any] = [
            "type": "control_request",
            "request_id": UUID().uuidString,
            "request": ["subtype": "interrupt"],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: request) {
            try? stdinHandle?.write(contentsOf: data + Data("\n".utf8))
        }
        let fallback = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.interrupting else { return }
                self.stopProcess()
                self.markStopped()
            }
        }
        interruptFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: fallback)
    }

    private func markStopped() {
        interrupting = false
        interruptFallback?.cancel()
        pendingTurns = 0
        finishRunningTools(as: .failed)
        statusText = "Stopped"
        items.append(ChatItem(kind: .info, text: "Stopped."))
        onTurnEnded?()
    }

    func newChat() {
        stopProcess()
        items.removeAll()
        clearSession()
        statusText = "Ready"
        onTurnEnded?()
        prewarm()
    }

    /// Starts `claude` ahead of time so the first message doesn't wait for it to boot.
    func prewarm() {
        guard process == nil || runningSignature != settings.sessionSignature, pendingTurns == 0 else { return }
        stopProcess()
        _ = startProcess()
    }

    /// Called when the app quits.
    func shutdown() { stopProcess() }

    // MARK: - Process

    private func startProcess() -> Bool {
        guard let claude = ClaudeLocator.find(override: settings.claudePathOverride) else {
            appendError("Couldn't find the `claude` command. Install Claude Code, or set its path in Settings › Claude.")
            return false
        }

        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", settings.safety.permissionModeFlag,
            "--append-system-prompt", SystemPrompt.build(custom: settings.customInstructions),
        ]
        // Act directly: helper agents make simple Mac tasks much slower.
        // No helper agents (slow), and screenshots only through mpctl so MacPilot's screen setting applies.
        args += ["--disallowedTools", "Task,Agent,Bash(screencapture:*),Bash(/usr/sbin/screencapture:*)"]
        if settings.fastMode {
            // Skip the user's coding hooks/plugins (user settings) and MCP servers.
            args += ["--setting-sources", "project,local"]
            if !settings.chromeIntegration {
                args += ["--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
            }
        }
        if let resources = Bundle.main.resourceURL?.path { args += ["--add-dir", resources] }
        if settings.model != "default" { args += ["--model", settings.model] }
        if settings.effort != "default" { args += ["--effort", settings.effort] }
        if settings.chromeIntegration { args.append("--chrome") }
        if settings.maxTurns > 0 { args += ["--max-turns", String(settings.maxTurns)] }
        if let sessionId { args += ["--resume", sessionId] }
        args += ArgSplitter.split(settings.extraArgs)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = args
        // A dedicated folder keeps MacPilot's transcripts separate from the user's
        // other Claude Code sessions (so Settings › Storage can clear them safely).
        p.currentDirectoryURL = StorageManager.workspaceURL
        p.environment = Self.childEnvironment()

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        generation += 1
        let gen = generation
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.ingest(chunk)
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.stderrTail = String((self.stderrTail + String(decoding: chunk, as: UTF8.self)).suffix(2000))
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            // Give the stdout drain a moment so a final `result` is handled first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { self?.processEnded(proc, status: status, gen: gen) }
            }
        }

        stderrTail = ""
        stdoutBuffer = Data()
        do {
            try p.run()
        } catch {
            appendError("Couldn't start Claude Code at \(claude): \(error.localizedDescription)")
            return false
        }
        process = p
        stdinHandle = inPipe.fileHandleForWriting
        runningSignature = settings.sessionSignature
        return true
    }

    private func stopProcess() {
        generation += 1
        interrupting = false
        interruptFallback?.cancel()
        pendingTurns = 0
        preparing = 0
        resetStreaming()
        stdoutBuffer = Data()
        guard let p = process else { return }
        process = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        if p.isRunning {
            // Signal the whole process group too, so tool children don't linger.
            let pid = p.processIdentifier
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    private func processEnded(_ proc: Process, status: Int32, gen: Int) {
        // Ignore processes we already replaced or stopped on purpose.
        guard proc === process, gen == generation else { return }
        process = nil
        stdinHandle = nil
        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)

        // The saved conversation can't be resumed: start fresh and resend once.
        if sessionId != nil, !retriedResume,
           tail.range(of: "no conversation found|session.*not found|could not resume", options: [.regularExpression, .caseInsensitive]) != nil {
            retriedResume = true
            clearSession()
            items.append(ChatItem(kind: .info, text: "Couldn't resume the last conversation, so I started a new one."))
            pendingTurns = 0
            if let line = lastUserPayload { write(line) }
            return
        }

        guard isBusy else { return }
        pendingTurns = 0
        finishRunningTools(as: .failed)
        var msg = "Claude Code stopped unexpectedly (exit \(status))."
        if !tail.isEmpty { msg += "\n\(tail.suffix(600))" }
        if tail.range(of: "log ?in|auth|credential|401", options: [.regularExpression, .caseInsensitive]) != nil {
            msg += "\n\nOpen Terminal and run `claude` once to log in, then try again."
        }
        appendError(msg)
        statusText = "Error"
        onTurnEnded?()
    }

    static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        // Put the bundle's own helpers (mpctl) first so Claude can call them by name.
        if let macOSDir = Bundle.main.executableURL?.deletingLastPathComponent().path { paths.insert(macOSDir, at: 0) }
        if let existing = env["PATH"] { paths += existing.split(separator: ":").map(String.init) }
        var seen = Set<String>()
        env["PATH"] = paths.filter { seen.insert($0).inserted }.joined(separator: ":")
        env["HOME"] = home
        // Make sure the CLI uses the user's own login, not an API key or a nested-session marker.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        env["MACPILOT"] = "1"
        // mpctl pauses this long before clicking so the virtual cursor arrives first.
        env["MACPILOT_CURSOR_DELAY_MS"] = AppSettings.shared.showAgentCursor ? String(AgentCursorController.glideDelayMs) : "0"
        return env
    }

    // MARK: - Stream parsing

    private func ingest(_ chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer[stdoutBuffer.startIndex..<nl]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ e: [String: Any]) {
        let type = e["type"] as? String
        // Only show the main conversation, not sub-agent traffic.
        if type != "result", let parent = e["parent_tool_use_id"], !(parent is NSNull) { return }

        switch type {
        case "system":
            if e["subtype"] as? String == "init", let sid = e["session_id"] as? String { setSession(sid) }
        case "stream_event":
            handleStreamEvent(e["event"] as? [String: Any] ?? [:])
        case "assistant":
            handleAssistant(e)
        case "user":
            handleToolResults(e)
        case "result":
            handleResult(e)
        default:
            break
        }
    }

    private func handleStreamEvent(_ ev: [String: Any]) {
        switch ev["type"] as? String {
        case "message_start":
            currentMessageId = (ev["message"] as? [String: Any])?["id"] as? String
        case "content_block_start":
            if let block = ev["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                statusText = "Working…"
            }
        case "content_block_delta":
            guard let delta = ev["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String,
                  let msgId = currentMessageId else { return }
            let key = "\(msgId)#\(ev["index"] as? Int ?? 0)"
            streamedMessageIds.insert(msgId)
            statusText = "Replying…"
            if let itemId = streamingItemIndex[key], let i = items.firstIndex(where: { $0.id == itemId }) {
                items[i].text += text
            } else {
                let item = ChatItem(kind: .assistant, text: text)
                streamingItemIndex[key] = item.id
                items.append(item)
            }
        default:
            break
        }
    }

    private func handleAssistant(_ e: [String: Any]) {
        guard let message = e["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }
        let msgId = message["id"] as? String ?? ""

        for block in content {
            switch block["type"] as? String {
            case "text":
                // Text was already shown live from stream deltas.
                if streamedMessageIds.contains(msgId) { continue }
                if let t = block["text"] as? String, !t.isEmpty { items.append(ChatItem(kind: .assistant, text: t)) }
            case "tool_use":
                let id = block["id"] as? String
                if let id, items.contains(where: { $0.toolUseId == id }) { continue }
                let name = block["name"] as? String ?? "Tool"
                let input = block["input"] as? [String: Any] ?? [:]
                let (label, detail) = ToolDescriber.describe(name: name, input: input)
                items.append(ChatItem(kind: .tool, text: label, detail: detail, toolStatus: .running, toolUseId: id))
                statusText = label + "…"
            default:
                break
            }
        }
    }

    private func handleToolResults(_ e: [String: Any]) {
        guard let message = e["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return }
        for block in content where block["type"] as? String == "tool_result" {
            guard let id = block["tool_use_id"] as? String,
                  let i = items.firstIndex(where: { $0.toolUseId == id }) else { continue }
            items[i].toolStatus = (block["is_error"] as? Bool ?? false) ? .failed : .ok
        }
        statusText = "Thinking…"
    }

    private func handleResult(_ e: [String: Any]) {
        if let sid = e["session_id"] as? String { setSession(sid) }
        pendingTurns = max(0, pendingTurns - 1)
        resetStreaming()

        if interrupting {
            markStopped()
            return
        }
        if pendingTurns == 0 { finishRunningTools(as: .ok) }

        if e["is_error"] as? Bool == true {
            let errors = (e["errors"] as? [String])?.joined(separator: "\n")
            let text = errors ?? (e["result"] as? String) ?? (e["subtype"] as? String ?? "Unknown error")
            appendError(text)
            statusText = "Error"
            onTurnEnded?()
            return
        }
        statusText = pendingTurns > 0 ? "Thinking…" : "Done"
        if let result = e["result"] as? String, !result.isEmpty { onTurnFinished?(result) }
        onTurnEnded?()
    }

    // MARK: - Helpers

    private func resetStreaming() {
        currentMessageId = nil
        streamingItemIndex.removeAll()
        streamedMessageIds.removeAll()
    }

    // MARK: - Keeping conversations small

    /// Idle this long → the next request starts a clean conversation (faster, less usage).
    private let idleReset: TimeInterval = 30 * 60
    private var lastActivity: Date {
        get { UserDefaults.standard.object(forKey: "lastActivity") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "lastActivity") }
    }

    private func startFreshIfIdle() {
        defer { lastActivity = Date() }
        guard sessionId != nil, !isBusy, Date().timeIntervalSince(lastActivity) > idleReset else { return }
        stopProcess()
        clearSession()
        items.append(ChatItem(kind: .info, text: "New conversation (MacPilot starts fresh after 30 minutes idle)."))
    }

    /// Keeps only the newest few MacPilot transcripts. Only MacPilot's own folder is touched.
    private func pruneOldConversations(keep: Int = 3) {
        guard let folder = StorageManager.historyFolder() else { return }
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        for old in files.dropFirst(keep) where !old.lastPathComponent.hasPrefix(sessionId ?? "-") {
            try? fm.removeItem(at: old)
            // A sibling folder with the same id holds that conversation's extras.
            try? fm.removeItem(at: old.deletingPathExtension())
        }
    }

    private func setSession(_ sid: String) {
        if sid != sessionId { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.pruneOldConversations() } } }
        sessionId = sid
        UserDefaults.standard.set(sid, forKey: "lastSessionId")
    }

    private func clearSession() {
        sessionId = nil
        UserDefaults.standard.removeObject(forKey: "lastSessionId")
    }

    private func finishRunningTools(as status: ChatItem.ToolStatus) {
        for i in items.indices where items[i].kind == .tool && items[i].toolStatus == .running {
            items[i].toolStatus = status
        }
    }

    private func appendError(_ text: String) {
        items.append(ChatItem(kind: .error, text: text))
    }
}

/// Splits a flags string like `--foo "a b" --bar` into arguments, honouring quotes.
enum ArgSplitter {
    static func split(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character? = nil, has = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; has = true
            } else if ch == " " || ch == "\t" {
                if has || !cur.isEmpty { out.append(cur); cur = ""; has = false }
            } else {
                cur.append(ch)
            }
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }
}
