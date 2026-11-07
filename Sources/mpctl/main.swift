import AppKit
import ApplicationServices
import Foundation

// MARK: - Shared helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Removes `--name value` from args and returns the value.
func takeOption(_ name: String, _ args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("error: \(name) needs a value") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

/// Removes a bare `--name` switch from args and reports whether it was present.
func takeFlag(_ name: String, _ args: inout [String]) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func takeInt(_ name: String, _ args: inout [String], default def: Int) -> Int {
    guard let s = takeOption(name, &args) else { return def }
    guard let n = Int(s) else { fail("error: \(name) expects an integer, got '\(s)'") }
    return n
}

func usage(_ text: String) -> Never { fail("usage: mpctl " + text) }

func number(_ s: String, _ what: String) -> Double {
    guard let d = Double(s) else { fail("error: \(what) must be a number, got '\(s)'") }
    return d
}

// MARK: - Help

let helpText = """
mpctl — Mac control helper. <app> = name ("Safari"), bundle id, or "front".
Coordinates: global points, top-left origin (same space as `screenshot` output).
Order of preference: shell/AppleScript > menu/find/press/set (AX, background) > click/type (last resort).

Inspect
  perms                          accessibility / screen-recording status
  apps                           running apps: name | bundleId | pid | frontmost
  front                          frontmost app | bundleId | focused window title
  windows [<app>]                app | title | x,y,w,h | minimized
  ui <app> [--depth N] [--max N] [--window N] [--menubar]
                                 AX tree: [id] AXRole "title" value="..." @x,y,w,h actions=...
  find <app> <text> [--role AXButton]   search title/desc/value/id/help in all windows
  screenshot [--display N] [--app <app>] [--out path]   prints JPEG path (scaled to points)
                                 with --app/--display>1 a 2nd line gives offset: add it to image coords before click

Act via Accessibility (no mouse, works in background)
  activate <app>                 bring to front, launching if needed
  press <app> <id|text>          AXPress    e.g. mpctl press Safari "Reload"  /  press Notes 0.3.1
  set <app> <id|text> <value>    set AXValue (checkbox: 1/0)
  focus <app> <id|text>          set AXFocused
  action <app> <id|text> <AXAction>   e.g. AXShowMenu, AXIncrement, AXConfirm
  menu <app> "File > New Window" click menu-bar item;  menu <app> --list [Top]  list menus/items

Raw input (CGEvent)
  click <x> <y> [--right] [--double]
  move <x> <y>
  drag <x1> <y1> <x2> <y2>
  scroll <dy> [<dx>]             lines; negative = down
  type <text>                    unicode text (newline = Return)
  key <combo>                    cmd+shift+t, return, esc, tab, space, delete, up, f5, cmd+option+esc
  point <x> <y> [label]          flash a highlight ring in the MacPilot overlay

Misc
  clipboard get | clipboard set <text>
  help

Ids: dotted child-index path from the window (0.3.1); "w1:0.3" picks window 1; find prints ready-to-use ids.
Errors go to stderr, exit 1.
"""

// MARK: - Small commands

func cmdPerms() {
    print("accessibility: " + (AXIsProcessTrusted() ? "yes" : "no"))
    print("screen-recording: " + (CGPreflightScreenCaptureAccess() ? "yes" : "no"))
}

func cmdClipboard(_ args: [String]) {
    let pb = NSPasteboard.general
    switch args.first {
    case "get":
        print(pb.string(forType: .string) ?? "", terminator: "")
        if let s = pb.string(forType: .string), !s.hasSuffix("\n") { print("") }
    case "set":
        guard args.count >= 2 else { usage("clipboard set <text>") }
        pb.clearContents()
        pb.setString(args.dropFirst().joined(separator: " "), forType: .string)
        print("ok")
    default:
        usage("clipboard get | clipboard set <text>")
    }
}

// MARK: - Dispatch

var argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    print(helpText)
    exit(0)
}
argv.removeFirst()

switch command {
case "help", "--help", "-h":
    print(helpText)
case "perms":
    cmdPerms()
case "apps":
    cmdApps()
case "front":
    cmdFront()
case "activate":
    guard argv.count == 1 else { usage("activate <app>") }
    cmdActivate(argv[0])
case "windows":
    cmdWindows(argv)
case "ui":
    cmdUI(argv)
case "find":
    cmdFind(argv)
case "press":
    cmdPress(argv)
case "set":
    cmdSet(argv)
case "focus":
    cmdFocus(argv)
case "action":
    cmdAction(argv)
case "menu":
    cmdMenu(argv)
case "click":
    cmdClick(argv)
case "move":
    cmdMove(argv)
case "drag":
    cmdDrag(argv)
case "scroll":
    cmdScroll(argv)
case "type":
    cmdType(argv)
case "key":
    cmdKey(argv)
case "point":
    cmdPoint(argv)
case "screenshot":
    cmdScreenshot(argv)
case "clipboard":
    cmdClipboard(argv)
default:
    fail("error: unknown command '\(command)'. Run `mpctl help`.")
}
