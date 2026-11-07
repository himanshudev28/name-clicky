import Foundation

/// AI command-line tools MacPilot can drive with the user's own login
/// (like Claude Code). Claude Code keeps its dedicated, richer integration in
/// ClaudeSession; the others run one headless process per request here.
enum TerminalAI: String, CaseIterable, Identifiable {
    case claude, codex, gemini, opencode, cursor, copilot, qwen, amp
    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex (ChatGPT)"
        case .gemini: return "Gemini CLI"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor Agent"
        case .copilot: return "GitHub Copilot CLI"
        case .qwen: return "Qwen Code"
        case .amp: return "Amp"
        }
    }

    var binary: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .opencode: return "opencode"
        case .cursor: return "cursor-agent"
        case .copilot: return "copilot"
        case .qwen: return "qwen"
        case .amp: return "amp"
        }
    }

    var installHint: String {
        switch self {
        case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: return "brew install codex  (then run: codex login)"
        case .gemini: return "brew install gemini-cli  (then run: gemini, sign in with Google)"
        case .opencode: return "brew install opencode  (then run: opencode auth login)"
        case .cursor: return "curl https://cursor.com/install -fsS | bash  (then: cursor-agent login)"
        case .copilot: return "npm install -g @github/copilot  (then run: copilot, /login)"
        case .qwen: return "npm install -g @qwen-code/qwen-code  (then run: qwen)"
        case .amp: return "npm install -g @sourcegraph/amp  (then run: amp login)"
        }
    }

    /// Path to the real binary (not cmux's terminal-only shims), or nil if not installed.
    var path: String? {
        if self == .claude { return ClaudeLocator.find(override: AppSettings.shared.claudePathOverride) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                    "\(home)/.bun/bin", "\(home)/.amp/bin", "\(home)/.cursor/bin", "\(home)/.volta/bin"]
        for d in dirs {
            let p = "\(d)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return Self.loginShellLookup(binary)
    }

    var isInstalled: Bool { path != nil }

    /// Asks a login shell (nvm/npm setups), ignoring cmux shim folders.
    private static func loginShellLookup(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "PATH=$(print -rl -- ${(s.:.)PATH} | grep -v cmux-cli-shims | paste -sd: -); command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: s)) ? s : nil
    }

    /// The selected terminal AI (Settings › AI), defaulting to Claude Code.
    static var selected: TerminalAI {
        TerminalAI(rawValue: UserDefaults.standard.string(forKey: "terminalAI") ?? "") ?? .claude
    }

    /// Optional model override per tool (empty = the tool's own default).
    static func model(for t: TerminalAI) -> String {
        UserDefaults.standard.string(forKey: "terminalAIModel.\(t.rawValue)") ?? ""
    }

    /// Command-line arguments for one headless request.
    /// Flags follow each tool's documented non-interactive mode with auto-approval so it can act
    /// on the Mac; anything not verified on this machine is marked.
    func arguments(prompt: String, session: String?, model: String) -> [String] {
        switch self {
        case .claude:
            return [] // handled by ClaudeSession
        case .opencode: // verified: opencode 1.15 `run --format json`
            var a = ["run", "--format", "json"]
            if let session { a += ["--session", session] }
            if !model.isEmpty { a += ["--model", model] }
            return a + [prompt]
        case .codex: // codex exec --json; resume continues a thread (unverified here: codex not installed)
            var a = ["exec"]
            if let session { a += ["resume", session] }
            a += ["--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox"]
            if !model.isEmpty { a += ["--model", model] }
            return a + [prompt]
        case .gemini, .qwen: // Gemini CLI family: -p headless, stream-json, yolo auto-approve (unverified here)
            var a = ["--output-format", "stream-json", "--yolo"]
            if session != nil { a += ["--resume", "latest"] }
            if !model.isEmpty { a += ["--model", model] }
            return a + ["-p", prompt]
        case .cursor: // cursor-agent print mode with stream-json (unverified here)
            var a = ["-p", "--output-format", "stream-json", "--force"]
            if let session { a += ["--resume", session] }
            if !model.isEmpty { a += ["--model", model] }
            return a + [prompt]
        case .copilot: // plain-text output (unverified here)
            var a = ["-p", prompt, "--allow-all-tools"]
            if session != nil { a += ["--continue"] }
            if !model.isEmpty { a += ["--model", model] }
            return a
        case .amp: // amp execute mode, Claude-compatible stream JSON (unverified here)
            var a = ["--dangerously-allow-all", "--stream-json"]
            if let session { a = ["threads", "continue", session] + a }
            return a + ["-x", prompt]
        }
    }
}

/// Runs a non-Claude terminal AI for each request and reports progress like the API agent.
/// Each tool keeps its own conversation; MacPilot passes the session id back on the next request.
@MainActor
final class TerminalAIRunner {
    private weak var host: AgentHost?
    private var process: Process?
    private var buffer = Data()
    private var generation = 0
    private(set) var isRunning = false

    // Per-request parsing state
    private var finalText = ""
    private var lastError: String?
    private var toolSeq = 0
    private var openTools: [String: String] = [:] // tool key → chat row id

    init(host: AgentHost) { self.host = host }

    private func sessionKey(_ t: TerminalAI) -> String { "terminalAISession.\(t.rawValue)" }

    func reset() {
        cancel()
        for t in TerminalAI.allCases { UserDefaults.standard.removeObject(forKey: sessionKey(t)) }
    }

    func cancel() {
        generation += 1
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        isRunning = false
    }

    func send(_ userText: String, systemPrompt: String) {
        let tool = TerminalAI.selected
        guard let path = tool.path else {
            host?.agentFinished(finalText: nil, error: "\(tool.label) isn't installed. Install it with: \(tool.installHint)")
            return
        }
        let session = UserDefaults.standard.string(forKey: sessionKey(tool))
        // These tools have no system-prompt flag: send MacPilot's instructions with the first message.
        let prompt = session == nil ? "\(systemPrompt)\n\n---\n\nUser request:\n\(userText)" : userText

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = tool.arguments(prompt: prompt, session: session, model: TerminalAI.model(for: tool))
        p.currentDirectoryURL = StorageManager.workspaceURL
        p.environment = ClaudeSession.childEnvironment()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        generation += 1
        let gen = generation
        buffer = Data(); finalText = ""; lastError = nil; openTools = [:]; displayedText = false; liveRowId = nil
        var stderrText = ""

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.ingest(chunk, tool: tool)
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: chunk, as: UTF8.self)
            DispatchQueue.main.async { stderrText = String((stderrText + s).suffix(1500)) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.finish(tool: tool, status: status, stderr: stderrText)
                }
            }
        }
        do {
            try p.run()
        } catch {
            host?.agentFinished(finalText: nil, error: "Couldn't start \(tool.label): \(error.localizedDescription)")
            return
        }
        process = p
        isRunning = true
        host?.agentStatus("\(tool.label) is thinking…")
    }

    // MARK: Output parsing (tolerant: each tool's JSON events differ)

    private func ingest(_ chunk: Data, tool: TerminalAI) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                handle(obj, tool: tool)
            } else if tool == .copilot || !line.starts(with: Data("{".utf8)) {
                // Plain-text tools: the output is the answer.
                finalText += String(decoding: line, as: UTF8.self) + "\n"
            }
        }
    }

    private func handle(_ e: [String: Any], tool: TerminalAI) {
        let type = e["type"] as? String ?? ""
        // Session / thread id for continuing the conversation next time.
        for k in ["sessionID", "session_id", "thread_id"] {
            if let sid = e[k] as? String, !sid.isEmpty { UserDefaults.standard.set(sid, forKey: sessionKey(tool)) }
        }

        switch type {
        case "error":
            let err = e["error"] as? [String: Any]
            lastError = ((err?["data"] as? [String: Any])?["message"] as? String)
                ?? (err?["message"] as? String) ?? (e["message"] as? String) ?? "Unknown error"

        case "text": // OpenCode
            if let t = (e["part"] as? [String: Any])?["text"] as? String { setText(t) }

        case "tool_use": // OpenCode (part.tool/state) and Gemini (tool_name/parameters)
            if let part = e["part"] as? [String: Any] {
                let state = part["state"] as? [String: Any] ?? [:]
                let input = state["input"] as? [String: Any] ?? [:]
                let key = part["callID"] as? String ?? part["id"] as? String ?? UUID().uuidString
                toolRow(key: key, name: part["tool"] as? String ?? "tool", input: input,
                        done: (state["status"] as? String).map { $0 == "completed" ? true : ($0 == "error" ? false : nil) } ?? nil)
            } else {
                let key = e["tool_id"] as? String ?? UUID().uuidString
                toolRow(key: key, name: e["tool_name"] as? String ?? "tool", input: e["parameters"] as? [String: Any] ?? [:], done: nil)
            }

        case "tool_result": // Gemini
            if let key = e["tool_id"] as? String { closeTool(key: key, ok: (e["status"] as? String) != "error") }

        case "message": // Gemini: assistant text, possibly streamed in deltas
            if e["role"] as? String == "assistant", let c = e["content"] as? String {
                if e["delta"] as? Bool == true { finalText += c; liveText() } else { setText(c) }
            }

        case "item.started", "item.completed": // Codex
            guard let item = e["item"] as? [String: Any] else { break }
            let key = item["id"] as? String ?? UUID().uuidString
            switch item["type"] as? String {
            case "agent_message":
                if type == "item.completed", let t = item["text"] as? String { setText(t) }
            case "command_execution":
                if type == "item.started" {
                    toolRow(key: key, name: "Bash", input: ["command": item["command"] as? String ?? ""], done: nil)
                } else {
                    closeTool(key: key, ok: (item["exit_code"] as? Int ?? 0) == 0)
                }
            default: break
            }

        case "assistant": // Claude-compatible streams (Cursor, Amp)
            let content = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for b in content {
                if b["type"] as? String == "text", let t = b["text"] as? String { setText(t) }
                if b["type"] as? String == "tool_use" {
                    toolRow(key: b["id"] as? String ?? UUID().uuidString, name: b["name"] as? String ?? "tool",
                            input: b["input"] as? [String: Any] ?? [:], done: nil)
                }
            }
        case "user": // Claude-compatible tool results
            let content = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for b in content where b["type"] as? String == "tool_result" {
                if let id = b["tool_use_id"] as? String { closeTool(key: id, ok: !(b["is_error"] as? Bool ?? false)) }
            }
        case "result": // Claude-compatible / Gemini final
            if let r = e["result"] as? String, !r.isEmpty { setText(r) }
            if e["is_error"] as? Bool == true { lastError = (e["result"] as? String) ?? "Error" }
        default:
            break
        }
    }

    private var liveRowId: UUID?
    private var displayedText = false

    /// Shows the latest assistant text as one live-updating row.
    private func setText(_ t: String) {
        finalText = t
        liveText()
    }

    private func liveText() {
        displayedText = true
        host?.agentStatus("Replying…")
        // A single row per request keeps the chat tidy while text streams in.
        if let id = liveRowId { host?.agentReplaceText(id: id, text: finalText) }
        else {
            let item = ChatItem(kind: .assistant, text: finalText)
            liveRowId = item.id
            host?.agentAppend(item)
        }
    }

    private func toolRow(key: String, name: String, input: [String: Any], done: Bool?) {
        if openTools[key] == nil {
            let mapped = ["bash": "Bash", "shell": "Bash", "run_shell_command": "Bash", "read": "Read",
                          "write": "Write", "edit": "Edit", "glob": "Glob", "grep": "Grep", "webfetch": "WebFetch"][name.lowercased()] ?? name
            let (label, detail) = ToolDescriber.describe(name: mapped, input: input)
            toolSeq += 1
            let rowId = "cli-\(toolSeq)-\(key)"
            openTools[key] = rowId
            host?.agentAppend(ChatItem(kind: .tool, text: label, detail: detail, toolStatus: .running, toolUseId: rowId))
            host?.agentStatus(label + "…")
            liveRowId = nil // text after a tool starts a new row
        }
        if let done { closeTool(key: key, ok: done) }
    }

    private func closeTool(key: String, ok: Bool) {
        guard let rowId = openTools[key] else { return }
        host?.agentUpdateTool(id: rowId, status: ok ? .ok : .failed)
    }

    private func finish(tool: TerminalAI, status: Int32, stderr: String) {
        process = nil
        isRunning = false
        liveRowId = nil
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lastError {
            host?.agentFinished(finalText: nil, error: "\(tool.label): \(lastError)")
        } else if status != 0 && text.isEmpty {
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            var msg = "\(tool.label) stopped (exit \(status))."
            if !tail.isEmpty { msg += "\n\(tail.suffix(500))" }
            if tail.localizedCaseInsensitiveContains("login") || tail.localizedCaseInsensitiveContains("auth") {
                msg += "\n\nLog in once in Terminal: \(tool.binary)"
            }
            host?.agentFinished(finalText: nil, error: msg)
        } else {
            // Plain-text tools never streamed a row: show the answer now.
            if !displayedText && !text.isEmpty { host?.agentAppend(ChatItem(kind: .assistant, text: text)) }
            host?.agentFinished(finalText: text.isEmpty ? nil : text, error: nil)
        }
    }
}
