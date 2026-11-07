import AppKit
import ApplicationServices

// MARK: - Resolution

/// Finds a running app by "front", localized name, or bundle id (exact, then prefix, then substring).
func findRunningApp(_ query: String) -> NSRunningApplication? {
    let q = query.lowercased()
    if q == "front" { return NSWorkspace.shared.frontmostApplication }
    let all = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
    let cands = all.filter { $0.activationPolicy == .regular } + all.filter { $0.activationPolicy != .regular }
    func name(_ a: NSRunningApplication) -> String { (a.localizedName ?? "").lowercased() }
    func bid(_ a: NSRunningApplication) -> String { (a.bundleIdentifier ?? "").lowercased() }
    return cands.first { name($0) == q || bid($0) == q }
        ?? cands.first { name($0).hasPrefix(q) }
        ?? cands.first { bid($0).hasPrefix(q) }
        ?? cands.first { name($0).contains(q) }
}

func requireApp(_ query: String) -> NSRunningApplication {
    guard let app = findRunningApp(query) else {
        fail("error: app not running: \(query). Try `mpctl activate \"\(query)\"` or `mpctl apps`.")
    }
    return app
}

// MARK: - Commands

func cmdApps() {
    let front = NSWorkspace.shared.frontmostApplication
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        let isFront = app.processIdentifier == front?.processIdentifier
        print("\(app.localizedName ?? "?") | \(app.bundleIdentifier ?? "-") | \(app.processIdentifier) | \(isFront ? "yes" : "no")")
    }
}

func cmdFront() {
    guard let app = NSWorkspace.shared.frontmostApplication else { fail("error: no frontmost app") }
    var title = ""
    if AXIsProcessTrusted() {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 2)
        if let w = axAttr(ax, kAXFocusedWindowAttribute) {
            title = axString(w as! AXUIElement, kAXTitleAttribute) ?? ""
        }
    }
    print("\(app.localizedName ?? "?") | \(app.bundleIdentifier ?? "-") | \(title)")
}

func cmdWindows(_ args: [String]) {
    let apps: [NSRunningApplication]
    if let q = args.first {
        apps = [requireApp(q)]
    } else {
        apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }
    for app in apps {
        let ax = appElement(app)
        let wins = axAttr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for w in wins {
            let title = axString(w, kAXTitleAttribute) ?? ""
            let f = axFrame(w).map(frameText) ?? "?"
            let min = (axAttr(w, kAXMinimizedAttribute) as? Bool) == true
            print("\(app.localizedName ?? "?") | \(clean(title)) | \(f) | \(min ? "yes" : "no")")
        }
    }
}

// MARK: - Activate / launch

private func applicationURL(for query: String) -> URL? {
    if query.contains("."), !query.contains(" "), !query.contains("/"),
       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
        return url
    }
    let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
    let target = query.lowercased().replacingOccurrences(of: ".app", with: "")
    let fm = FileManager.default
    var prefixHit: URL?
    for dir in dirs {
        for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".app") {
            let base = String(entry.dropLast(4)).lowercased()
            let url = URL(fileURLWithPath: dir).appendingPathComponent(entry)
            if base == target { return url }
            if prefixHit == nil, base.hasPrefix(target) { prefixHit = url }
        }
    }
    return prefixHit
}

func cmdActivate(_ query: String) {
    var app = findRunningApp(query)
    if app == nil {
        guard let url = applicationURL(for: query) else { fail("error: cannot find application '\(query)'") }
        let sem = DispatchSemaphore(value: 0)
        var launchError: Error?
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, err in
            launchError = err
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 15)
        if let e = launchError { fail("error: launch failed: \(e.localizedDescription)") }
        let deadline = Date().addingTimeInterval(8)
        while app == nil, Date() < deadline {
            app = NSWorkspace.shared.runningApplications.first { $0.bundleURL == url }
            if app == nil { Thread.sleep(forTimeInterval: 0.2) }
        }
        guard app != nil else { fail("error: launched '\(query)' but it did not appear as a running app") }
    }
    guard let target = app else { return }
    target.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    if AXIsProcessTrusted() {
        let ax = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 2)
        AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
    print("activated \(target.localizedName ?? query)")
}
