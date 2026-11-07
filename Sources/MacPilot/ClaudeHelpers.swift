import Foundation

/// Finds the `claude` binary. GUI apps get a minimal PATH, so check known install spots.
enum ClaudeLocator {
    static func find(override: String) -> String? {
        let fm = FileManager.default
        let o = (override as NSString).expandingTildeInPath
        if !o.isEmpty, fm.isExecutableFile(atPath: o) { return o }

        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }

        // Fall back to asking a login shell.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: path) ? path : nil
    }
}

/// Turns a tool call into a short, human label plus a monospaced detail line.
enum ToolDescriber {
    static func describe(name: String, input: [String: Any]) -> (String, String) {
        func s(_ k: String) -> String { (input[k] as? String) ?? "" }
        func short(_ t: String, _ n: Int = 220) -> String {
            let one = t.replacingOccurrences(of: "\n", with: " ⏎ ")
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        switch name {
        case "Bash":
            let cmd = s("command")
            let label: String
            if cmd.contains("mpctl screenshot") || cmd.contains("screencapture") { label = "Looking at the screen" }
            else if cmd.contains("mpctl") { label = "Controlling an app" }
            else if cmd.contains("osascript") { label = "Running AppleScript" }
            else if cmd.hasPrefix("open ") { label = "Opening" }
            else { label = s("description").isEmpty ? "Running a command" : s("description") }
            return (label, short(cmd))
        case "Read": return ("Reading a file", short(s("file_path")))
        case "Write": return ("Writing a file", short(s("file_path")))
        case "Edit", "MultiEdit": return ("Editing a file", short(s("file_path")))
        case "Grep": return ("Searching files", short(s("pattern")))
        case "Glob": return ("Finding files", short(s("pattern")))
        case "WebFetch": return ("Reading a web page", short(s("url")))
        case "WebSearch": return ("Searching the web", short(s("query")))
        case "Task", "Agent": return ("Starting a helper", short(s("description")))
        case "TodoWrite": return ("Planning steps", "")
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                return ("Using \(parts.dropFirst().first ?? "tool")", short(String(name)))
            }
            let json = (try? JSONSerialization.data(withJSONObject: input)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return ("Using \(name)", short(json))
        }
    }
}
