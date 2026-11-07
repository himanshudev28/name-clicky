import AppKit
import Foundation

/// Finds and clears data that MacPilot itself creates. Only touches:
/// - screenshots named `macpilot-shot-*` in the temp folder,
/// - Claude Code transcripts for MacPilot's own working folder (MacPilot runs
///   `claude` from a dedicated folder, so these never mix with your other sessions).
enum StorageManager {
    static let workspaceURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("MacPilot/Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: Screenshots

    static func screenshotFiles() -> [URL] {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let files = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("macpilot-shot-") }
    }

    // MARK: Conversation history

    /// Claude Code stores transcripts under ~/.claude/projects/<cwd with non-alphanumerics as "-">.
    static func historyFolder() -> URL? {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let encoded = String(workspaceURL.path.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        // Match exactly, ignoring leading/trailing dashes the CLI may add.
        guard let hit = names.first(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) == encoded })
        else { return nil }
        return projects.appendingPathComponent(hit, isDirectory: true)
    }

    // MARK: Sizes

    static func size(of urls: [URL]) -> Int64 {
        urls.reduce(0) { $0 + size(of: $1) }
    }

    static func size(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: Clearing

    static func clearScreenshots() {
        for f in screenshotFiles() { try? FileManager.default.removeItem(at: f) }
    }

    /// Deletes MacPilot's own screenshots older than `age` (default 1 hour). Returns how many.
    @discardableResult
    static func clearOldScreenshots(olderThan age: TimeInterval = 3600) -> Int {
        let cutoff = Date().addingTimeInterval(-age)
        var removed = 0
        for f in screenshotFiles() {
            let made = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if made < cutoff, (try? FileManager.default.removeItem(at: f)) != nil { removed += 1 }
        }
        return removed
    }

    static func clearHistory() {
        if let folder = historyFolder() { try? FileManager.default.removeItem(at: folder) }
    }

    static func resetSettings() {
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
    }
}
