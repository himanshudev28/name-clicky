import AppKit
import ApplicationServices

// MARK: - Low-level attribute helpers

func ensureTrusted() {
    if !AXIsProcessTrusted() {
        fail("Accessibility permission missing: grant MacPilot in System Settings > Privacy & Security > Accessibility")
    }
}

/// App-level AX element with a short messaging timeout so hung apps cannot block us.
func appElement(_ app: NSRunningApplication) -> AXUIElement {
    ensureTrusted()
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(el, 2)
    return el
}

func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func axString(_ el: AXUIElement, _ name: String) -> String? {
    axAttr(el, name) as? String
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    axAttr(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

private func unpackPoint(_ v: CFTypeRef?) -> CGPoint? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
}

private func unpackSize(_ v: CFTypeRef?) -> CGSize? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = unpackPoint(axAttr(el, kAXPositionAttribute)),
          let s = unpackSize(axAttr(el, kAXSizeAttribute)) else { return nil }
    return CGRect(origin: p, size: s)
}

func frameText(_ r: CGRect) -> String {
    "\(Int(r.origin.x.rounded())),\(Int(r.origin.y.rounded())),\(Int(r.size.width.rounded())),\(Int(r.size.height.rounded()))"
}

func axValueText(_ el: AXUIElement) -> String? {
    guard let v = axAttr(el, kAXValueAttribute) else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    if let u = v as? URL { return u.absoluteString }
    return nil
}

func axActions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

func axErrorName(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegal argument"
    case .invalidUIElement: return "invalid element (UI changed?)"
    case .cannotComplete: return "cannot complete (app busy or not responding)"
    case .attributeUnsupported: return "attribute unsupported"
    case .actionUnsupported: return "action unsupported"
    case .notImplemented: return "not implemented"
    case .apiDisabled: return "accessibility API disabled"
    case .noValue: return "no value"
    default: return "AXError \(e.rawValue)"
    }
}

/// Escapes newlines and truncates for one-line display.
func clean(_ s: String, limit: Int = 80) -> String {
    var t = s.replacingOccurrences(of: "\r\n", with: "\\n")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t")
    if t.count > limit { t = String(t.prefix(limit)) + "…" }
    return t
}

// MARK: - Element description

struct ElInfo {
    var role = ""
    var title = ""
    var desc = ""
    var value = ""
    var ident = ""
    var help = ""
    var frame: CGRect?
    var actions: [String] = []

    var isNoise: Bool {
        (role == "AXGroup" || role == "AXUnknown")
            && title.isEmpty && desc.isEmpty && value.isEmpty && ident.isEmpty && help.isEmpty
    }
}

func elInfo(_ el: AXUIElement, actions: Bool = true) -> ElInfo {
    var i = ElInfo()
    i.role = axString(el, kAXRoleAttribute) ?? "AXUnknown"
    i.title = axString(el, kAXTitleAttribute) ?? ""
    i.desc = axString(el, kAXDescriptionAttribute) ?? ""
    i.value = axValueText(el) ?? ""
    i.ident = axString(el, kAXIdentifierAttribute) ?? ""
    i.help = axString(el, kAXHelpAttribute) ?? ""
    i.frame = axFrame(el)
    if actions { i.actions = axActions(el).filter { $0 != "AXScrollToVisible" } }
    return i
}

func formatLine(_ i: ElInfo, id: String, depth: Int = 0) -> String {
    var s = String(repeating: "  ", count: min(depth, 24)) + "[\(id)] \(i.role)"
    let label = i.title.isEmpty ? i.desc : i.title
    if !label.isEmpty { s += " \"\(clean(label))\"" }
    if !i.title.isEmpty, !i.desc.isEmpty, i.title != i.desc { s += " desc=\"\(clean(i.desc, limit: 50))\"" }
    if !i.value.isEmpty { s += " value=\"\(clean(i.value))\"" }
    if !i.ident.isEmpty { s += " ident=\"\(clean(i.ident, limit: 40))\"" }
    if let f = i.frame { s += " @\(frameText(f))" }
    if !i.actions.isEmpty { s += " actions=" + i.actions.joined(separator: ",") }
    return s
}

// MARK: - Windows & traversal

struct WindowContext {
    let app: NSRunningApplication
    let ax: AXUIElement
    let windows: [AXUIElement]
    /// Index of the focused window (what `ui` shows by default and what unprefixed ids resolve against).
    let defaultIndex: Int
}

func windowContext(_ query: String) -> WindowContext {
    let app = requireApp(query)
    let ax = appElement(app)
    var wins = axAttr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
    let focused = axAttr(ax, kAXFocusedWindowAttribute)
    if wins.isEmpty, let f = focused { wins = [f as! AXUIElement] }
    guard !wins.isEmpty else { fail("error: \(app.localizedName ?? query) has no accessible windows") }
    var idx = 0
    if let f = focused, let i = wins.firstIndex(where: { CFEqual($0, f) }) { idx = i }
    return WindowContext(app: app, ax: ax, windows: wins, defaultIndex: idx)
}

/// Depth-first walk over descendants of `el` (not `el` itself). Child indices are real, so paths stay valid.
/// `visit` returns false to stop the whole walk. Returns false if stopped.
@discardableResult
func walk(_ el: AXUIElement, path: [Int] = [], depth: Int = 0, maxDepth: Int,
          visit: (AXUIElement, [Int], Int) -> Bool) -> Bool {
    for (i, child) in axChildren(el).enumerated() {
        let p = path + [i]
        if !visit(child, p, depth) { return false }
        if depth + 1 < maxDepth, !walk(child, path: p, depth: depth + 1, maxDepth: maxDepth, visit: visit) {
            return false
        }
    }
    return true
}

func pathText(_ p: [Int]) -> String { p.map(String.init).joined(separator: ".") }

// MARK: - ui

func cmdUI(_ rawArgs: [String]) {
    var args = rawArgs
    let depth = takeInt("--depth", &args, default: 12)
    let maxLines = takeInt("--max", &args, default: 300)
    let windowOpt = takeOption("--window", &args)
    let menubar = takeFlag("--menubar", &args)
    guard args.count == 1 else { usage("ui <app> [--depth N] [--max N] [--window N] [--menubar]") }

    let app = requireApp(args[0])
    let root: AXUIElement
    var prefix = ""
    if menubar {
        let ax = appElement(app)
        guard let mb = axAttr(ax, kAXMenuBarAttribute) else { fail("error: no menu bar for \(app.localizedName ?? args[0])") }
        root = mb as! AXUIElement
        prefix = "m:"
        print("# \(app.localizedName ?? args[0]) menu bar")
    } else {
        let ctx = windowContext(args[0])
        var index = ctx.defaultIndex
        if let w = windowOpt {
            guard let n = Int(w), n >= 0, n < ctx.windows.count else {
                fail("error: --window must be 0..\(ctx.windows.count - 1)")
            }
            index = n
        }
        root = ctx.windows[index]
        if index != ctx.defaultIndex { prefix = "w\(index):" }
        let wi = elInfo(root, actions: false)
        print("# \(ctx.app.localizedName ?? args[0]) window \(index)/\(ctx.windows.count) \"\(clean(wi.title))\"" + (wi.frame.map { " @\(frameText($0))" } ?? ""))
    }

    var printed = 0
    var truncated = false
    walk(root, maxDepth: max(depth, 1)) { el, path, d in
        var i = elInfo(el, actions: false)
        if i.isNoise { return true }
        if printed >= maxLines { truncated = true; return false }
        i.actions = axActions(el).filter { $0 != "AXScrollToVisible" }
        print(formatLine(i, id: prefix + pathText(path), depth: d))
        printed += 1
        return true
    }
    if truncated { print("... truncated at \(maxLines) lines (raise --max or lower --depth, or use `find`)") }
}

// MARK: - find / target resolution

struct Match {
    let el: AXUIElement
    let id: String
    let info: ElInfo
}

private func normalizedRole(_ r: String) -> String {
    r.lowercased().hasPrefix("ax") ? r.lowercased() : "ax" + r.lowercased()
}

func collectMatches(_ ctx: WindowContext, text: String, role: String?, limit: Int) -> [Match] {
    let needle = text.lowercased()
    let wantRole = role.map(normalizedRole)
    var found: [Match] = []
    var visited = 0
    for (wi, win) in ctx.windows.enumerated() {
        let prefix = ctx.windows.count > 1 ? "w\(wi):" : ""
        let keepGoing = walk(win, maxDepth: 40) { el, path, _ in
            visited += 1
            if visited > 8000 { return false }
            let i = elInfo(el, actions: false)
            if let r = wantRole, i.role.lowercased() != r { return true }
            let hit = needle.isEmpty
                || [i.title, i.desc, i.value, i.ident, i.help].contains { $0.lowercased().contains(needle) }
            if hit {
                var full = i
                full.actions = axActions(el).filter { $0 != "AXScrollToVisible" }
                found.append(Match(el: el, id: prefix + pathText(path), info: full))
                if found.count >= limit { return false }
            }
            return true
        }
        if !keepGoing { break }
    }
    return found
}

func cmdFind(_ rawArgs: [String]) {
    var args = rawArgs
    let role = takeOption("--role", &args)
    guard args.count >= 2 else { usage("find <app> <text> [--role AXButton]") }
    let ctx = windowContext(args[0])
    let matches = collectMatches(ctx, text: args.dropFirst().joined(separator: " "), role: role, limit: 60)
    if matches.isEmpty { print("(no matches)"); return }
    for m in matches { print(formatLine(m.info, id: m.id)) }
}

private let idPattern = try! NSRegularExpression(pattern: #"^(w\d+:|m:)?\d+(\.\d+)*$"#)

func isIdPath(_ s: String) -> Bool {
    idPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

func resolveId(_ ctx: WindowContext, _ id: String) -> AXUIElement? {
    var rest = Substring(id)
    var root: AXUIElement
    if rest.hasPrefix("m:") {
        rest = rest.dropFirst(2)
        guard let mb = axAttr(ctx.ax, kAXMenuBarAttribute) else { return nil }
        root = mb as! AXUIElement
    } else if rest.hasPrefix("w"), let colon = rest.firstIndex(of: ":") {
        guard let n = Int(rest[rest.index(after: rest.startIndex)..<colon]), n < ctx.windows.count else { return nil }
        root = ctx.windows[n]
        rest = rest[rest.index(after: colon)...]
    } else {
        root = ctx.windows[ctx.defaultIndex]
    }
    for part in rest.split(separator: ".") {
        guard let i = Int(part) else { return nil }
        let kids = axChildren(root)
        guard i < kids.count else { return nil }
        root = kids[i]
    }
    return root
}

enum Need {
    case press
    case settable
    case focus
    case action(String)
}

private func satisfies(_ m: Match, _ need: Need) -> Bool {
    switch need {
    case .press: return m.info.actions.contains("AXPress")
    case .action(let a): return m.info.actions.contains(a)
    case .settable:
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(m.el, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    case .focus:
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(m.el, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue
    }
}

/// Resolves `<id|text>` to an element, preferring text matches that support the needed action.
func resolveTarget(_ ctx: WindowContext, spec: String, need: Need) -> Match {
    if isIdPath(spec) {
        guard let el = resolveId(ctx, spec) else { fail("error: no element at id '\(spec)' (UI may have changed; re-run `find`/`ui`)") }
        return Match(el: el, id: spec, info: elInfo(el))
    }
    let matches = collectMatches(ctx, text: spec, role: nil, limit: 200)
    guard let first = matches.first else { fail("error: no element matching '\(spec)'") }
    if let good = matches.first(where: { satisfies($0, need) }) { return good }
    // A label inside a button usually matches instead of the button itself: try ancestors.
    if case .press = need {
        var cur = first.el
        for _ in 0..<4 {
            guard let p = axAttr(cur, kAXParentAttribute) else { break }
            let parent = p as! AXUIElement
            let info = elInfo(parent)
            if info.actions.contains("AXPress") { return Match(el: parent, id: first.id + "^", info: info) }
            cur = parent
        }
    }
    return first
}

// MARK: - press / set / focus / action

/// Points MacPilot's virtual cursor at an element before acting on it.
func announce(_ info: ElInfo, verb: String) {
    guard let f = info.frame else { return }
    let name = [info.title, info.desc, info.value].first { !$0.isEmpty } ?? ""
    let label = name.isEmpty ? verb : "\(verb) “\(name.prefix(40))”"
    postPoint(x: Double(f.midX), y: Double(f.midY), label: label)
}

private func targetArgs(_ args: [String], min: Int, usageText: String) -> (WindowContext, String) {
    guard args.count >= min else { usage(usageText) }
    return (windowContext(args[0]), args[1])
}

func cmdPress(_ args: [String]) {
    let (ctx, spec) = targetArgs(args, min: 2, usageText: "press <app> <id|text>")
    let m = resolveTarget(ctx, spec: spec, need: .press)
    announce(m.info, verb: "Press")
    let err = AXUIElementPerformAction(m.el, kAXPressAction as CFString)
    guard err == .success else { fail("error: press failed on \(formatLine(m.info, id: m.id)): \(axErrorName(err))") }
    print("pressed " + formatLine(m.info, id: m.id))
}

func cmdSet(_ args: [String]) {
    guard args.count >= 3 else { usage("set <app> <id|text> <value>") }
    let ctx = windowContext(args[0])
    let value = args.dropFirst(2).joined(separator: " ")
    let m = resolveTarget(ctx, spec: args[1], need: .settable)
    announce(m.info, verb: "Set")

    // Keep the attribute's native type: numbers for sliders/checkboxes, strings otherwise.
    var newValue: CFTypeRef = value as CFString
    if axAttr(m.el, kAXValueAttribute) is NSNumber, let d = Double(value) {
        newValue = (d == d.rounded() ? NSNumber(value: Int(d)) : NSNumber(value: d))
    }
    let err = AXUIElementSetAttributeValue(m.el, kAXValueAttribute as CFString, newValue)
    guard err == .success else { fail("error: set failed on \(formatLine(m.info, id: m.id)): \(axErrorName(err))") }
    print("set " + formatLine(m.info, id: m.id) + " = \"\(clean(value))\"")
}

func cmdFocus(_ args: [String]) {
    let (ctx, spec) = targetArgs(args, min: 2, usageText: "focus <app> <id|text>")
    let m = resolveTarget(ctx, spec: spec, need: .focus)
    announce(m.info, verb: "Focus")
    let err = AXUIElementSetAttributeValue(m.el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard err == .success else { fail("error: focus failed on \(formatLine(m.info, id: m.id)): \(axErrorName(err))") }
    print("focused " + formatLine(m.info, id: m.id))
}

func cmdAction(_ args: [String]) {
    guard args.count == 3 else { usage("action <app> <id|text> <AXAction>") }
    let ctx = windowContext(args[0])
    let name = args[2].hasPrefix("AX") ? args[2] : "AX" + args[2]
    let m = resolveTarget(ctx, spec: args[1], need: .action(name))
    announce(m.info, verb: name.replacingOccurrences(of: "AX", with: ""))
    let err = AXUIElementPerformAction(m.el, name as CFString)
    guard err == .success else { fail("error: \(name) failed on \(formatLine(m.info, id: m.id)): \(axErrorName(err))") }
    print("\(name) " + formatLine(m.info, id: m.id))
}

// MARK: - menu

private func menuTitle(_ el: AXUIElement) -> String {
    axString(el, kAXTitleAttribute) ?? ""
}

private func normalizeMenuTitle(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespaces).lowercased()
    for suffix in ["…", "..."] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
    return t.trimmingCharacters(in: .whitespaces)
}

/// Items of the AXMenu hanging off a menu-bar item / menu item (empty if none).
private func submenuItems(_ item: AXUIElement) -> [AXUIElement] {
    guard let menu = axChildren(item).first(where: { axString($0, kAXRoleAttribute) == "AXMenu" }) else { return [] }
    return axChildren(menu)
}

private func pickMenuItem(_ items: [AXUIElement], _ name: String) -> AXUIElement? {
    let want = normalizeMenuTitle(name)
    let titled = items.filter { !menuTitle($0).isEmpty }
    return titled.first { menuTitle($0).lowercased() == name.lowercased() }
        ?? titled.first { normalizeMenuTitle(menuTitle($0)) == want }
        ?? titled.first { normalizeMenuTitle(menuTitle($0)).hasPrefix(want) }
}

private func resolveMenuPath(_ menubar: AXUIElement, _ parts: [String]) -> AXUIElement {
    var items = axChildren(menubar)
    var current = menubar
    for (k, part) in parts.enumerated() {
        guard let hit = pickMenuItem(items, part) else {
            let avail = items.map(menuTitle).filter { !$0.isEmpty }.joined(separator: ", ")
            fail("error: menu item '\(part)' not found. Available: \(avail.isEmpty ? "(none)" : avail)")
        }
        current = hit
        if k < parts.count - 1 { items = submenuItems(hit) }
    }
    return current
}

private func shortcutText(_ item: AXUIElement) -> String? {
    guard let ch = axString(item, "AXMenuItemCmdChar"), !ch.isEmpty else { return nil }
    let mods = (axAttr(item, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue ?? 0
    var s = ""
    if mods & 4 != 0 { s += "ctrl+" }
    if mods & 2 != 0 { s += "opt+" }
    if mods & 1 != 0 { s += "shift+" }
    if mods & 8 == 0 { s += "cmd+" }
    return s + ch.lowercased()
}

func cmdMenu(_ rawArgs: [String]) {
    var args = rawArgs
    let list = takeFlag("--list", &args)
    guard let appName = args.first else { usage("menu <app> \"File > New Window\" | menu <app> --list [Top]") }
    let app = requireApp(appName)
    let ax = appElement(app)
    guard let mbRef = axAttr(ax, kAXMenuBarAttribute) else { fail("error: \(app.localizedName ?? appName) has no accessible menu bar") }
    let menubar = mbRef as! AXUIElement
    let parts = args.dropFirst().joined(separator: " ").split(separator: ">")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

    if list {
        let items = parts.isEmpty ? axChildren(menubar) : submenuItems(resolveMenuPath(menubar, parts))
        for item in items {
            let title = menuTitle(item)
            if title.isEmpty { continue }
            var line = title
            if !submenuItems(item).isEmpty && axString(item, kAXRoleAttribute) == "AXMenuItem" { line += "  >" }
            if let sc = shortcutText(item) { line += "  [\(sc)]" }
            if (axAttr(item, kAXEnabledAttribute) as? Bool) == false { line += "  (disabled)" }
            print(line)
        }
        return
    }

    guard !parts.isEmpty else { usage("menu <app> \"File > New Window\" | menu <app> --list [Top]") }
    let target = resolveMenuPath(menubar, parts)
    if (axAttr(target, kAXEnabledAttribute) as? Bool) == false {
        fail("error: menu item '\(parts.joined(separator: " > "))' is disabled")
    }
    // Point the virtual cursor at the top-level menu (submenu items have no on-screen frame yet).
    if let top = pickMenuItem(axChildren(menubar), parts[0]) {
        var info = elInfo(top, actions: false)
        info.title = parts.joined(separator: " › ")
        announce(info, verb: "Menu")
    }
    let err = AXUIElementPerformAction(target, kAXPressAction as CFString)
    guard err == .success else { fail("error: menu press failed: \(axErrorName(err))") }
    print("clicked " + parts.joined(separator: " > "))
}
