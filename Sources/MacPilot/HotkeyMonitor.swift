import AppKit
import CoreGraphics

/// Global modifier-only hotkey (Control+Option or Fn+Control), adapted from clicky's
/// listen-only CGEvent tap. Tap the combo quickly → toggle the panel.
/// Hold it → push-to-talk until released. Needs Accessibility permission.
@MainActor
final class HotkeyMonitor {
    var onTap: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?

    private let settings = AppSettings.shared
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private var comboDown = false
    private var otherKeyPressed = false
    private var holdActive = false
    private var downAt = Date()
    private var holdTimer: Timer?
    private let holdThreshold: TimeInterval = 0.35
    private var askedForPermission = false
    private var tapIsGlobal = false

    var isRunning: Bool { tap != nil }

    /// Safe to call repeatedly (the permission poller does).
    /// True when the hotkey works in every app (not just while MacPilot is focused).
    static var hasGlobalAccess: Bool { CGPreflightListenEventAccess() || AXIsProcessTrusted() }

    func start() {
        guard settings.hotkey != .off else { return }
        // Without Input Monitoring (or Accessibility) macOS still creates the tap but only
        // delivers MacPilot's own key events. So don't settle for that: ask, and rebuild
        // the tap as soon as access is granted (the poller calls start() every 2 s).
        let global = Self.hasGlobalAccess
        if tap != nil {
            if global && !tapIsGlobal { stop() } else { return }
        }
        if !global && !askedForPermission {
            askedForPermission = true
            _ = CGRequestListenEventAccess()
        }
        tapIsGlobal = global
        let types: [CGEventType] = [.flagsChanged, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        let callback: CGEventTapCallBack = { _, type, event, info in
            if let info {
                let me = Unmanaged<HotkeyMonitor>.fromOpaque(info).takeUnretainedValue()
                // The tap is added to the main run loop, so this runs on the main thread.
                MainActor.assumeIsolated { me.handle(type: type, event: event) }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        reset()
    }

    func restart() { stop(); start() }

    private func reset() {
        holdTimer?.invalidate()
        holdTimer = nil
        comboDown = false
        holdActive = false
        otherKeyPressed = false
    }

    private func isCombo(_ flags: CGEventFlags) -> Bool {
        let ctrl = flags.contains(.maskControl)
        let opt = flags.contains(.maskAlternate)
        let cmd = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let fn = flags.contains(.maskSecondaryFn)
        switch settings.hotkey {
        case .ctrlOption: return ctrl && opt && !cmd && !shift
        case .fnCtrl: return fn && ctrl && !cmd && !shift && !opt
        case .off: return false
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // We may have missed the key release: end any hold so the mic doesn't stay on.
            if holdActive { onHoldEnd?() }
            reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            // Combo used as part of another shortcut (e.g. Ctrl+Opt+Left): not ours.
            if comboDown { otherKeyPressed = true; holdTimer?.invalidate() }
        case .flagsChanged:
            let combo = isCombo(event.flags)
            // An extra modifier (Ctrl+Opt+Cmd…) means another shortcut, not a tap.
            if comboDown && (event.flags.contains(.maskCommand) || event.flags.contains(.maskShift)) {
                otherKeyPressed = true
                holdTimer?.invalidate()
            }
            if combo && !comboDown {
                comboDown = true
                otherKeyPressed = false
                downAt = Date()
                holdTimer?.invalidate()
                let timer = Timer(timeInterval: holdThreshold, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.comboDown, !self.otherKeyPressed, self.settings.voiceInput else { return }
                        self.holdActive = true
                        self.onHoldStart?()
                    }
                }
                RunLoop.main.add(timer, forMode: .common) // also fires while menus are tracking
                holdTimer = timer
            } else if !combo && comboDown {
                let wasHold = holdActive
                let quick = Date().timeIntervalSince(downAt) < holdThreshold
                let clean = !otherKeyPressed
                reset()
                if wasHold { onHoldEnd?() }
                else if clean && (quick || !settings.voiceInput) { onTap?() }
            }
        default:
            break
        }
    }
}
