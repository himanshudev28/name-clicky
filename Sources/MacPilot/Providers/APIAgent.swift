import Foundation

/// What the agent needs from the UI layer (implemented by the chat/session object).
@MainActor
protocol AgentHost: AnyObject {
    func agentAppend(_ item: ChatItem)
    func agentUpdateTool(id: String, status: ChatItem.ToolStatus)
    func agentStatus(_ text: String)
    func agentFinished(finalText: String?, error: String?)
    /// Replaces the text of a row added earlier (live-updating replies).
    func agentReplaceText(id: UUID, text: String)
}

struct APIAgentError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Runs one shell command off the main thread. Killable from any thread.
final class CommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { Self.kill(p) }
    }

    /// Kills the shell and its direct children (so a pipe held by a child can't hang the reader).
    private static func kill(_ p: Process) {
        let pid = p.processIdentifier
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-KILL", "-P", String(pid)]
        try? k.run(); k.waitUntilExit()
        p.terminate()
        Foundation.kill(pid, SIGKILL)
    }

    /// Returns combined stdout+stderr and the exit code (-1 = killed/failed to start).
    func run(command: String, timeout: Int, cwd: URL, env: [String: String]) async -> (output: String, code: Int32, timedOut: Bool) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", command]
                p.currentDirectoryURL = cwd
                p.environment = env
                p.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe

                self.lock.lock()
                if self.cancelled { self.lock.unlock(); cont.resume(returning: ("Cancelled.", -1, false)); return }
                do { try p.run() } catch {
                    self.lock.unlock()
                    cont.resume(returning: ("Could not start shell: \(error.localizedDescription)", -1, false)); return
                }
                self.process = p
                self.lock.unlock()

                var timedOut = false
                let flag = NSLock()
                let timer = DispatchWorkItem {
                    flag.lock(); timedOut = true; flag.unlock()
                    Self.kill(p)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout), execute: timer)

                // Keep reading to EOF; cap memory at ~1 MB (the rest is dropped).
                var data = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    if data.count < 1_000_000 { data.append(chunk) }
                }
                p.waitUntilExit()
                timer.cancel()
                flag.lock(); let to = timedOut; flag.unlock()
                cont.resume(returning: (String(decoding: data, as: UTF8.self), p.terminationStatus, to))
            }
        }
    }
}

/// An API-driven agent loop: sends the conversation to a model, runs the shell
/// commands it asks for, feeds results back, repeats until it answers in text.
@MainActor
final class APIAgent {
    private weak var host: AgentHost?
    private var task: Task<Void, Never>?
    private var runner: CommandRunner?
    /// History in the active provider's native message format.
    private var history: [[String: Any]] = []
    private var historyProvider: AIProvider?

    private(set) var isRunning = false
    private let maxSteps = 30
    /// Bumped on every send/cancel so a cancelled run can't clobber a newer one's state.
    private var generation = 0

    static let toolsAddendum = """
    You control this Mac through two tools. run_command runs a zsh command (login shell) and returns its output \
    and exit code: use osascript, open, defaults, shortcuts, mpctl and other CLI tools. Never run interactive \
    commands (no editors, no prompts, no sudo password); prefer one combined command over many small ones. \
    view_image attaches an image file (such as a screenshot taken with mpctl) so you can look at it, when the \
    user has allowed screen access. There is no Read, Write or Edit tool: use the shell (cat, tee, printf, sed). \
    Be fast: act, then reply with a short result.
    """

    init(host: AgentHost) { self.host = host }

    // MARK: Public

    func reset() { cancel(); history = []; historyProvider = nil }

    func cancel() {
        generation += 1
        task?.cancel(); task = nil
        runner?.cancel(); runner = nil
        isRunning = false
    }

    func send(_ userText: String, systemPrompt: String) {
        guard !isRunning else { return }
        let config = ProviderConfig.current()
        if let problem = config.problem ?? (config.provider == .claudeCode ? "Pick an API provider in Settings › AI" : nil) {
            host?.agentFinished(finalText: nil, error: problem); return
        }
        // A provider switch invalidates history (formats differ).
        if historyProvider?.apiStyle != config.provider.apiStyle { history = [] }
        historyProvider = config.provider
        isRunning = true
        generation += 1
        let gen = generation
        task = Task { [weak self] in
            await self?.run(userText, system: systemPrompt, config: config, gen: gen)
        }
    }

    // MARK: Loop

    private func run(_ userText: String, system: String, config: ProviderConfig, gen: Int) async {
        let startCount = history.count
        history.append(["role": "user", "content": userText])
        var lastText: String?
        var failure: String?
        do {
            var steps = 0
            while true {
                try Task.checkCancellation()
                if steps >= maxSteps {
                    host?.agentAppend(ChatItem(kind: .info, text: "Stopped after \(maxSteps) steps. Ask me to continue if needed."))
                    break
                }
                steps += 1
                host?.agentStatus("Thinking…")
                let turn = try await step(config: config, system: system)
                if let t = turn.text, !t.isEmpty {
                    lastText = t
                    host?.agentAppend(ChatItem(kind: .assistant, text: t))
                }
                if turn.calls.isEmpty { break }
                var results: [ToolResult] = []
                for call in turn.calls {
                    try Task.checkCancellation()
                    results.append(await execute(call))
                }
                appendToolResults(results, style: config.provider.apiStyle)
            }
        } catch is CancellationError {
            failure = nil
        } catch let e as URLError where e.code == .cancelled {
            failure = nil
        } catch {
            failure = (error as? APIAgentError)?.message ?? error.localizedDescription
            // Drop the failed turn so the next send starts from a valid history.
            if history.count > startCount { history.removeSubrange(startCount...) }
        }
        let wasCancelled = Task.isCancelled || gen != generation
        if wasCancelled { if history.count > startCount { history.removeSubrange(startCount...) }; return }
        isRunning = false
        task = nil; runner = nil
        host?.agentFinished(finalText: failure == nil ? lastText : nil, error: failure)
    }

    // MARK: Tools

    struct ToolCall { let id: String; let name: String; let input: [String: Any] }
    struct ToolResult { let call: ToolCall; let text: String; let imageBase64: String?; let imageMime: String? }
    struct Turn { var text: String?; var calls: [ToolCall] }

    private func execute(_ call: ToolCall) async -> ToolResult {
        switch call.name {
        case "run_command":
            let cmd = (call.input["command"] as? String) ?? ""
            let t = (call.input["timeout_seconds"] as? Int) ?? Int((call.input["timeout_seconds"] as? Double) ?? 60)
            let timeout = min(max(t, 1), 300)
            let (label, detail) = ToolDescriber.describe(name: "Bash", input: ["command": cmd])
            host?.agentAppend(ChatItem(kind: .tool, text: label, detail: detail, toolStatus: .running, toolUseId: call.id))
            host?.agentStatus("Running a command…")
            guard !cmd.isEmpty else {
                host?.agentUpdateTool(id: call.id, status: .failed)
                return ToolResult(call: call, text: "Error: missing 'command'.", imageBase64: nil, imageMime: nil)
            }
            let env = ClaudeSession.childEnvironment() // main actor: touches AppSettings
            let r = CommandRunner()
            runner = r
            let res = await r.run(command: cmd, timeout: timeout, cwd: StorageManager.workspaceURL, env: env)
            var out = Self.truncate(res.output)
            if res.timedOut { out += "\n[timed out after \(timeout)s and was killed]" }
            out += "\nexit code: \(res.code)"
            host?.agentUpdateTool(id: call.id, status: res.code == 0 ? .ok : .failed)
            return ToolResult(call: call, text: out, imageBase64: nil, imageMime: nil)

        case "view_image":
            let path = ((call.input["path"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            host?.agentAppend(ChatItem(kind: .tool, text: "Looking at an image", detail: path, toolStatus: .running, toolUseId: call.id))
            func fail(_ m: String) -> ToolResult {
                host?.agentUpdateTool(id: call.id, status: .failed)
                return ToolResult(call: call, text: m, imageBase64: nil, imageMime: nil)
            }
            guard Self.screenAccessAllowed() else {
                return fail("Screen access is not allowed for this request, so the image can't be viewed. Tell the user they can enable it in MacPilot settings.")
            }
            let expanded = (path as NSString).expandingTildeInPath
            guard let data = FileManager.default.contents(atPath: expanded) else { return fail("Could not read file: \(path)") }
            guard data.count <= 5_000_000 else { return fail("Image is larger than 5 MB.") }
            let ext = (expanded as NSString).pathExtension.lowercased()
            let mime = ["png": "image/png", "gif": "image/gif", "webp": "image/webp"][ext] ?? "image/jpeg"
            host?.agentUpdateTool(id: call.id, status: .ok)
            return ToolResult(call: call, text: "image attached", imageBase64: data.base64EncodedString(), imageMime: mime)

        default:
            return ToolResult(call: call, text: "Unknown tool: \(call.name)", imageBase64: nil, imageMime: nil)
        }
    }

    /// Same gate as ScreenGate / mpctl: a one-word file in Application Support.
    nonisolated static func screenAccessAllowed() -> Bool {
        let f = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPilot/screen-access")
        return ((try? String(contentsOf: f, encoding: .utf8)) ?? "").contains("allow")
    }

    /// Keeps the head and tail of long output.
    nonisolated static func truncate(_ s: String, limit: Int = 10_000) -> String {
        guard s.count > limit else { return s }
        let half = limit / 2
        return String(s.prefix(half)) + "\n…[\(s.count - limit) characters omitted]…\n" + String(s.suffix(half))
    }

    // MARK: Request shapes

    static let runCommandDescription = "Run a zsh command on the user's Mac and get its combined output and exit code."
    static let viewImageDescription = "Attach an image file (e.g. a screenshot) so you can look at it. Requires screen access to be allowed."

    static var anthropicTools: [[String: Any]] {
        [["name": "run_command", "description": runCommandDescription,
          "input_schema": toolSchema(commandTool: true)],
         ["name": "view_image", "description": viewImageDescription,
          "input_schema": toolSchema(commandTool: false)]]
    }

    static var openAITools: [[String: Any]] {
        [["type": "function", "function": ["name": "run_command", "description": runCommandDescription,
                                           "parameters": toolSchema(commandTool: true)]],
         ["type": "function", "function": ["name": "view_image", "description": viewImageDescription,
                                           "parameters": toolSchema(commandTool: false)]]]
    }

    private static func toolSchema(commandTool: Bool) -> [String: Any] {
        if commandTool {
            return ["type": "object",
                    "properties": ["command": ["type": "string", "description": "The command line to run with zsh -lc"],
                                   "timeout_seconds": ["type": "integer", "description": "Default 60, max 300"]],
                    "required": ["command"]]
        }
        return ["type": "object",
                "properties": ["path": ["type": "string", "description": "Absolute path of the image file"]],
                "required": ["path"]]
    }

    static func anthropicBody(model: String, system: String, messages: [[String: Any]]) -> [String: Any] {
        ["model": model, "max_tokens": 4096, "system": system, "tools": anthropicTools, "messages": messages]
    }

    static func openAIBody(model: String, system: String, messages: [[String: Any]]) -> [String: Any] {
        ["model": model, "tools": openAITools,
         "messages": [["role": "system", "content": system]] + messages]
    }

    private func appendToolResults(_ results: [ToolResult], style: AIAPIStyle) {
        if style == .anthropic {
            let blocks: [[String: Any]] = results.map { r in
                var content: Any = r.text
                if let b64 = r.imageBase64, let mime = r.imageMime {
                    content = [["type": "image", "source": ["type": "base64", "media_type": mime, "data": b64]]]
                }
                return ["type": "tool_result", "tool_use_id": r.call.id, "content": content]
            }
            history.append(["role": "user", "content": blocks])
        } else {
            var images: [[String: Any]] = []
            for r in results {
                history.append(["role": "tool", "tool_call_id": r.call.id, "content": r.text])
                if let b64 = r.imageBase64, let mime = r.imageMime {
                    images.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(b64)"]])
                }
            }
            // Tool messages can't carry images in this API style, so send them as a user message.
            if !images.isEmpty {
                history.append(["role": "user", "content": [["type": "text", "text": "Image from view_image:"]] + images])
            }
        }
    }

    // MARK: Network

    private func step(config: ProviderConfig, system: String) async throws -> Turn {
        if config.provider.apiStyle == .anthropic {
            let json = try await Self.post(config, path: "/v1/messages",
                                           body: Self.anthropicBody(model: config.model, system: system, messages: history))
            let content = (json["content"] as? [[String: Any]]) ?? []
            history.append(["role": "assistant", "content": content])
            var texts: [String] = []
            var calls: [ToolCall] = []
            for b in content {
                switch b["type"] as? String {
                case "text": if let t = b["text"] as? String { texts.append(t) }
                case "tool_use":
                    calls.append(ToolCall(id: (b["id"] as? String) ?? UUID().uuidString,
                                          name: (b["name"] as? String) ?? "",
                                          input: (b["input"] as? [String: Any]) ?? [:]))
                default: break
                }
            }
            return Turn(text: texts.isEmpty ? nil : texts.joined(separator: "\n"), calls: json["stop_reason"] as? String == "tool_use" || !calls.isEmpty ? calls : [])
        } else {
            let json = try await Self.post(config, path: "/chat/completions",
                                           body: Self.openAIBody(model: config.model, system: system, messages: history))
            guard let msg = ((json["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] else {
                throw APIAgentError("The provider returned no message.")
            }
            history.append(msg)
            let text = msg["content"] as? String
            var calls: [ToolCall] = []
            for tc in (msg["tool_calls"] as? [[String: Any]]) ?? [] {
                let fn = (tc["function"] as? [String: Any]) ?? [:]
                let argStr = (fn["arguments"] as? String) ?? "{}"
                let args = (try? JSONSerialization.jsonObject(with: Data(argStr.utf8))) as? [String: Any] ?? [:]
                calls.append(ToolCall(id: (tc["id"] as? String) ?? UUID().uuidString, name: (fn["name"] as? String) ?? "", input: args))
            }
            return Turn(text: text, calls: calls)
        }
    }

    /// Builds the endpoint URL, joining base and path without doubling "/v1".
    nonisolated static func endpoint(_ base: String, _ path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        var p = path
        if b.hasSuffix("/v1") && p.hasPrefix("/v1") { p = String(p.dropFirst(3)) }
        return URL(string: b + p)
    }

    nonisolated static func request(_ config: ProviderConfig, path: String, method: String) throws -> URLRequest {
        guard let url = endpoint(config.baseURL, path) else { throw APIAgentError("Invalid base URL: \(config.baseURL)") }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if config.provider.apiStyle == .anthropic {
            req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if config.provider == .openrouter {
            req.setValue("https://macpilot.app", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("MacPilot", forHTTPHeaderField: "X-Title")
        }
        return req
    }

    nonisolated static func post(_ config: ProviderConfig, path: String, body: [String: Any]) async throws -> [String: Any] {
        var req = try request(config, path: path, method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    nonisolated private static func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw APIAgentError(errorMessage(json, data: data, status: status))
        }
        guard let json else { throw APIAgentError("The provider returned an unreadable response.") }
        return json
    }

    /// Pulls error.message out of the common error shapes (OpenAI, Anthropic, Gemini).
    nonisolated private static func errorMessage(_ json: [String: Any]?, data: Data, status: Int) -> String {
        if let e = json?["error"] as? [String: Any], let m = e["message"] as? String { return "\(m) (HTTP \(status))" }
        if let m = json?["error"] as? String { return "\(m) (HTTP \(status))" }
        if let m = json?["message"] as? String { return "\(m) (HTTP \(status))" }
        if let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
           let m = (arr.first?["error"] as? [String: Any])?["message"] as? String { return "\(m) (HTTP \(status))" }
        let raw = String(decoding: data.prefix(300), as: UTF8.self)
        return "HTTP \(status)\(raw.isEmpty ? "" : ": \(raw)")"
    }

    // MARK: Models list and connection test

    nonisolated static func fetchModels(_ config: ProviderConfig) async throws -> [String] {
        let req = try request(config, path: config.provider.apiStyle == .anthropic ? "/v1/models" : "/models", method: "GET")
        let json = try await send(req)
        let ids = ((json["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        return ids.sorted()
    }

    /// Tiny request without tools; returns the reply text.
    nonisolated static func ping(_ config: ProviderConfig) async throws -> String {
        let msgs: [[String: Any]] = [["role": "user", "content": "Reply with OK"]]
        if config.provider.apiStyle == .anthropic {
            let j = try await post(config, path: "/v1/messages",
                                   body: ["model": config.model, "max_tokens": 16, "messages": msgs])
            return ((j["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "OK"
        }
        let j = try await post(config, path: "/chat/completions", body: ["model": config.model, "messages": msgs])
        let m = (j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        return (m?["content"] as? String) ?? "OK"
    }
}
