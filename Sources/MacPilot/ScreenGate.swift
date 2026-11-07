import Foundation

/// Decides whether Claude may take a screenshot for the current request and tells
/// `mpctl` through a small file (mpctl refuses screenshots otherwise).
enum ScreenGate {
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPilot/screen-access")
    }

    /// Words that mean the user is asking about what's on the screen.
    private static let screenWords = [
        "screen", "see", "look", "looking", "show me what", "what is this", "what's this", "this item", "this window",
        "this page", "this picture", "this image", "this error", "this dialog", "visible", "on my display",
        "dikh", "dekh", "स्क्रीन", "देख",
    ]

    static func allows(request: String, attachedScreenshot: Bool) -> Bool {
        switch AppSettings.shared.screenAccess {
        case .never: return false
        case .whenNeeded: return true
        case .whenAsked:
            if attachedScreenshot { return true }
            let r = request.lowercased()
            return screenWords.contains { r.contains($0) }
        }
    }

    static func set(allowed: Bool) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (allowed ? "allow" : "deny").write(to: file, atomically: true, encoding: .utf8)
    }
}
