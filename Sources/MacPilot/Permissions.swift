import AppKit
import Carbon
import ApplicationServices
import AVFoundation
import Speech

/// Checks and requests the macOS privacy permissions MacPilot needs.
/// Child processes (claude → osascript / mpctl) inherit these, because macOS
/// treats MacPilot as their "responsible" app.
enum Permissions {
    enum State { case granted, denied, notAsked }

    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    /// Needed for the global hotkey (a listen-only keyboard event tap).
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    static func requestInputMonitoring() {
        if !CGRequestListenEventAccess() { open(.inputMonitoring) }
    }

    static var microphone: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    static var speech: State {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    static func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { open(.accessibility) }
    }

    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() { open(.screenRecording) }
    }

    static func requestMicrophone() {
        if microphone == .denied { open(.microphone); return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    static func requestSpeech() {
        if speech == .denied { open(.speech); return }
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    // MARK: Full Disk Access

    /// Full Disk Access covers Desktop, Documents, Downloads, iCloud Drive, external drives and
    /// other apps' data in one go, so those folder prompts stop. Only readable when granted.
    static var fullDiskAccess: Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        return FileManager.default.isReadableFile(atPath: probe)
    }

    /// Opens the Full Disk Access list and shows MacPilot in Finder, ready to drag in or add with +.
    static func requestFullDiskAccess() {
        open(.fullDiskAccess)
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    // MARK: Automation ("MacPilot wants to control …")

    /// Asks macOS for permission to control every app that's running right now (plus Finder and
    /// System Events), one prompt each, all in one sitting. macOS only allows asking for running
    /// apps; others ask once the first time MacPilot uses them, then never again.
    /// Calls `done` on the main thread with (allowed, asked).
    static func requestAutomationForRunningApps(done: @escaping @Sendable (Int, Int) -> Void) {
        // System Events does the UI scripting; start it quietly so it can be asked too.
        let sysEvents = URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        NSWorkspace.shared.openApplication(at: sysEvents, configuration: config) { _, _ in
            let me = Bundle.main.bundleIdentifier
            var ids = ["com.apple.systemevents", "com.apple.finder"]
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                if let id = app.bundleIdentifier, id != me, !ids.contains(id) { ids.append(id) }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var allowed = 0
                for id in ids where askAutomation(bundleID: id) == noErr { allowed += 1 }
                DispatchQueue.main.async { done(allowed, ids.count) }
            }
        }
    }

    /// Shows the macOS consent prompt for one app if it hasn't been answered yet. Blocks while it's on screen.
    private static func askAutomation(bundleID: String) -> OSStatus {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = bytes.withUnsafeBytes { AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &target) }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
    }

    // MARK: Everything at once

    /// Requests every missing permission in turn, so setup happens in one sitting.
    @MainActor
    static func requestAllMissing(automationDone: @escaping @Sendable (Int, Int) -> Void) {
        var steps: [() -> Void] = []
        if !accessibility { steps.append(requestAccessibility) }
        if !inputMonitoring { steps.append(requestInputMonitoring) }
        if !screenRecording { steps.append(requestScreenRecording) }
        if microphone != .granted { steps.append(requestMicrophone) }
        if speech != .granted { steps.append(requestSpeech) }
        steps.append { requestAutomationForRunningApps(done: automationDone) }
        if !fullDiskAccess { steps.append(requestFullDiskAccess) }
        // Space the requests out so each macOS dialog appears on its own.
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.2) { step() }
        }
    }

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
        case screenRecording = "Privacy_ScreenCapture"
        case microphone = "Privacy_Microphone"
        case speech = "Privacy_SpeechRecognition"
        case automation = "Privacy_Automation"
        case fullDiskAccess = "Privacy_AllFiles"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
