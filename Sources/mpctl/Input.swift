import AppKit
import Carbon.HIToolbox
import CoreGraphics

private let source = CGEventSource(stateID: .combinedSessionState)

private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

// MARK: - Overlay notification

/// Asks the MacPilot app to flash a ring at a CG global point.
/// Tells the MacPilot app where the next action happens so its virtual cursor
/// can glide there. When the app sets MACPILOT_CURSOR_DELAY_MS, wait that long
/// so the cursor arrives before the action does.
func postPoint(x: Double, y: Double, label: String) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.macpilot.point"),
        object: nil,
        userInfo: ["x": x, "y": y, "label": label],
        deliverImmediately: true
    )
    let ms = Double(ProcessInfo.processInfo.environment["MACPILOT_CURSOR_DELAY_MS"] ?? "") ?? 0
    RunLoop.current.run(until: Date().addingTimeInterval(max(0.05, min(ms, 2000) / 1000)))
}

/// Updates the virtual cursor's label without moving it (typing, key presses).
func postStatus(_ label: String) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.macpilot.point"),
        object: nil,
        userInfo: ["label": label],
        deliverImmediately: true
    )
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
}

// MARK: - Mouse

private func mouseEvent(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clickState: Int64? = nil) {
    guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
    if let c = clickState { e.setIntegerValueField(.mouseEventClickState, value: c) }
    e.post(tap: .cghidEventTap)
}

private func point(_ args: [String], _ i: Int, usageText: String) -> CGPoint {
    guard args.count > i + 1 else { usage(usageText) }
    return CGPoint(x: number(args[i], "x"), y: number(args[i + 1], "y"))
}

func cmdClick(_ rawArgs: [String]) {
    var args = rawArgs
    let right = takeFlag("--right", &args)
    let double = takeFlag("--double", &args)
    guard args.count == 2 else { usage("click <x> <y> [--right] [--double]") }
    let p = point(args, 0, usageText: "click <x> <y> [--right] [--double]")
    let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
    let button: CGMouseButton = right ? .right : .left

    postPoint(x: p.x, y: p.y, label: double ? "Double-click" : right ? "Right-click" : "Click")
    mouseEvent(.mouseMoved, p)
    pause(0.03)
    for n in 1...(double ? 2 : 1) {
        mouseEvent(down, p, button: button, clickState: Int64(n))
        pause(0.02)
        mouseEvent(up, p, button: button, clickState: Int64(n))
        pause(0.04)
    }
    print("clicked \(Int(p.x)),\(Int(p.y))" + (right ? " (right)" : "") + (double ? " (double)" : ""))
}

func cmdMove(_ args: [String]) {
    guard args.count == 2 else { usage("move <x> <y>") }
    let p = point(args, 0, usageText: "move <x> <y>")
    mouseEvent(.mouseMoved, p)
    print("moved \(Int(p.x)),\(Int(p.y))")
}

func cmdDrag(_ args: [String]) {
    guard args.count == 4 else { usage("drag <x1> <y1> <x2> <y2>") }
    let a = point(args, 0, usageText: "drag <x1> <y1> <x2> <y2>")
    let b = point(args, 2, usageText: "drag <x1> <y1> <x2> <y2>")
    postPoint(x: a.x, y: a.y, label: "Drag")
    mouseEvent(.mouseMoved, a)
    pause(0.05)
    mouseEvent(.leftMouseDown, a, clickState: 1)
    let steps = 16
    for s in 1...steps {
        let t = Double(s) / Double(steps)
        mouseEvent(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        pause(0.012)
    }
    pause(0.03)
    mouseEvent(.leftMouseUp, b, clickState: 1)
    postPoint(x: b.x, y: b.y, label: "Drop")
    print("dragged \(Int(a.x)),\(Int(a.y)) -> \(Int(b.x)),\(Int(b.y))")
}

func cmdScroll(_ args: [String]) {
    guard (1...2).contains(args.count) else { usage("scroll <dy> [<dx>]") }
    let dy = Int32(number(args[0], "dy"))
    let dx = args.count > 1 ? Int32(number(args[1], "dx")) : 0
    guard let e = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
        fail("error: could not create scroll event")
    }
    e.post(tap: .cghidEventTap)
    print("scrolled dy=\(dy) dx=\(dx)")
}

func cmdPoint(_ args: [String]) {
    guard args.count >= 2 else { usage("point <x> <y> [label]") }
    let p = point(args, 0, usageText: "point <x> <y> [label]")
    postPoint(x: p.x, y: p.y, label: args.dropFirst(2).joined(separator: " "))
    print("pointed \(Int(p.x)),\(Int(p.y))")
}

// MARK: - Keyboard

private func tap(code: Int, flags: CGEventFlags = []) {
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
        e.flags = flags
        e.post(tap: .cghidEventTap)
        pause(0.012)
    }
}

private func typeChunk(_ units: [UniChar]) {
    guard !units.isEmpty else { return }
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
        e.flags = []
        units.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
        e.post(tap: .cghidEventTap)
        pause(0.006)
    }
    pause(0.01)
}

func cmdType(_ args: [String]) {
    guard !args.isEmpty else { usage("type <text>") }
    let text = args.joined(separator: " ")
    postStatus("Typing “\(text.prefix(30))\(text.count > 30 ? "…" : "")”")
    var chunk: [UniChar] = []
    for ch in text {
        if ch == "\n" || ch == "\r" || ch == "\r\n" {
            typeChunk(chunk); chunk = []
            tap(code: kVK_Return)
        } else if ch == "\t" {
            typeChunk(chunk); chunk = []
            tap(code: kVK_Tab)
        } else {
            let units = Array(String(ch).utf16)
            if chunk.count + units.count > 20 { typeChunk(chunk); chunk = [] }
            chunk += units
        }
    }
    typeChunk(chunk)
    print("typed \(text.count) characters")
}

private let keyCodes: [String: Int] = [
    "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
    "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
    "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
    "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
    "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
    "z": kVK_ANSI_Z,
    "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
    "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    "-": kVK_ANSI_Minus, "minus": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "equal": kVK_ANSI_Equal,
    "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, ";": kVK_ANSI_Semicolon,
    "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, "comma": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
    "period": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "slash": kVK_ANSI_Slash,
    "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
    "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space,
    "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
    "esc": kVK_Escape, "escape": kVK_Escape,
    "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
    "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
    "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
    "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17,
    "f18": kVK_F18, "f19": kVK_F19, "f20": kVK_F20,
]

private func modifierFlag(_ name: String) -> CGEventFlags? {
    switch name {
    case "cmd", "command": return .maskCommand
    case "shift": return .maskShift
    case "opt", "option", "alt": return .maskAlternate
    case "ctrl", "control": return .maskControl
    case "fn": return .maskSecondaryFn
    default: return nil
    }
}

func cmdKey(_ args: [String]) {
    guard args.count == 1 else { usage("key <combo>   e.g. cmd+shift+t, return, esc") }
    var combo = args[0].lowercased()
    postStatus("Pressing \(args[0])")
    var flags: CGEventFlags = []
    var keyName: String

    // "cmd++" / "plus" mean the + key (shift+=).
    if combo.hasSuffix("++") || combo == "+" || combo.hasSuffix("+plus") || combo == "plus" {
        combo = combo.hasSuffix("++") ? String(combo.dropLast(2)) : (combo.hasSuffix("+plus") ? String(combo.dropLast(5)) : "")
        flags.insert(.maskShift)
        keyName = "="
    } else {
        var parts = combo.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        guard let last = parts.popLast() else { usage("key <combo>") }
        keyName = last
        combo = parts.joined(separator: "+")
    }
    for m in combo.split(separator: "+").map(String.init) {
        guard let f = modifierFlag(m) else { fail("error: unknown modifier '\(m)' (use cmd, shift, opt, ctrl, fn)") }
        flags.insert(f)
    }
    guard let code = keyCodes[keyName] else { fail("error: unknown key '\(keyName)'") }
    tap(code: code, flags: flags)
    print("key \(args[0])")
}
