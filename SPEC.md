# MacPilot — build spec

A macOS menu bar AI assistant. It runs the user's logged-in Claude Code CLI
(`claude -p`, stream-json in/out) as its brain, so no API key is used. Claude
controls the Mac through its normal tools (Bash, AppleScript via `osascript`,
shell commands) plus the bundled helper CLI `mpctl`.

Target: macOS 14+, Apple Silicon, built with SwiftPM (no Xcode). Swift 6 toolchain,
package uses tools-version 5.10 (Swift 5 language mode).

## Layout

```
MacPilot/
  Package.swift              two executable targets: MacPilot, mpctl
  Sources/MacPilot/          the app (SwiftUI + AppKit)
  Sources/mpctl/             helper CLI (Foundation, AppKit, ApplicationServices, CoreGraphics)
  Resources/Info.plist       bundle plist (LSUIElement, usage strings)
  Resources/playbook/        Markdown recipes for controlling each app/area of macOS
  scripts/build-app.sh       builds release + assembles build/MacPilot.app + codesigns
```

Bundle layout produced by the build script:

```
MacPilot.app/Contents/MacOS/MacPilot
MacPilot.app/Contents/MacOS/mpctl
MacPilot.app/Contents/Resources/playbook/*.md
MacPilot.app/Contents/Info.plist
```

Bundle id: `com.macpilot.app`.

## Control philosophy (important)

Do the work **behind the scenes**, fastest reliable method first:

1. Shell / CLI tools (`open`, `defaults`, `networksetup`, `pmset`, `osascript`, `shortcuts`, `mdfind`, `pbcopy`, ...).
2. AppleScript / JXA scripting dictionaries (Finder, Chrome, Safari, Music, Mail, Notes, Calendar, Reminders, Messages, System Events).
3. Accessibility API through `mpctl` (`menu`, `find`, `press`, `set`): works on background windows, no mouse movement.
4. Only as a last resort: `mpctl screenshot` + `mpctl click x y` / `mpctl type`.

## mpctl contract

Every command prints concise plain text (one item per line) and exits 0 on
success; errors go to stderr with exit code 1. `<app>` accepts an app name
("Safari"), a bundle id ("com.apple.Safari") or `front` (frontmost app).
Coordinates are global **points**, top-left origin of the main display
(CoreGraphics space) — the same space that `screenshot` output uses.

| Command | What it does |
|---|---|
| `mpctl help` | usage |
| `mpctl perms` | prints `accessibility: yes/no`, `screen-recording: yes/no` |
| `mpctl apps` | running regular apps: `name \| bundleId \| pid \| frontmost` |
| `mpctl front` | frontmost app name, bundle id, focused window title |
| `mpctl activate <app>` | bring app to front (launch if needed) |
| `mpctl windows [<app>]` | windows: `app \| title \| x,y,w,h \| minimized` |
| `mpctl ui <app> [--depth N] [--max N]` | AX tree of the app's focused window (default depth 12, max 300 lines). Each line: indent + `[id] AXRole "title/description" value="..." @x,y,w,h actions=AXPress,...`. `id` is a dotted child-index path from the window, e.g. `0.3.1`. Use `--window N` to choose a window index, `--menubar` to dump the menu bar instead. |
| `mpctl find <app> <text> [--role AXButton]` | case-insensitive search over title/description/value/identifier/help; prints matching lines in the same format as `ui` (searches all windows, ids prefixed with window index `w0:` when >1 window) |
| `mpctl press <app> <id\|text>` | perform AXPress on element (by id path, or first `find` match for text). Background, no mouse. |
| `mpctl set <app> <id\|text> <value>` | set AXValue (text fields, sliders; for checkboxes "1"/"0") |
| `mpctl focus <app> <id\|text>` | set AXFocused = true |
| `mpctl action <app> <id\|text> <AXAction>` | perform any AX action (AXShowMenu, AXIncrement, AXConfirm, ...) |
| `mpctl menu <app> "File > New Window"` | click a menu-bar item by path via AX (no mouse). `mpctl menu <app> --list [Top]` lists items. |
| `mpctl click <x> <y> [--right] [--double]` | mouse click via CGEvent |
| `mpctl move <x> <y>` | move pointer |
| `mpctl drag <x1> <y1> <x2> <y2>` | drag |
| `mpctl scroll <dy> [<dx>]` | scroll wheel (lines; negative = down) |
| `mpctl type <text>` | type unicode text via CGEvent (works with any layout) |
| `mpctl key <combo>` | key combo: `cmd+shift+t`, `return`, `esc`, `tab`, `space`, `delete`, `up/down/left/right`, `f1..f12`, letters/digits, `cmd+option+esc` ... |
| `mpctl screenshot [--display N] [--app <app>] [--out path]` | capture (via `/usr/sbin/screencapture -x`), **downscale to point size** so pixel coords == click coords, save JPEG, print the path (default `$TMPDIR/macpilot-shot-<ts>.jpg`). `--app` crops to that app's front window frame. |
| `mpctl point <x> <y> [label]` | ask the MacPilot app to flash a highlight ring at x,y |
| `mpctl clipboard get` / `mpctl clipboard set <text>` | read/write pasteboard |

`click`, `drag`, `press` (when frame known) and `point` post a distributed
notification so the app can draw feedback:

```
name:     "com.macpilot.point"
userInfo: ["x": Double, "y": Double, "label": String]   // CG global points
```

## App ↔ Claude

The app spawns (absolute path to `claude`, cwd = home):

```
claude -p --input-format stream-json --output-format stream-json --verbose
       --include-partial-messages
       --permission-mode bypassPermissions|auto
       --model <alias> --effort <low|medium|high|xhigh|max>
       --append-system-prompt <MacPilot system prompt>
       --add-dir <bundle Resources dir>
       [--resume <session_id>] [--chrome]
```

Stdin lines: `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"..."}, {"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"..."}}]},"parent_tool_use_id":null}`

Environment: inherit, but force a sane PATH (`~/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`),
add the bundle's `Contents/MacOS` to PATH (so `mpctl` resolves), and remove `ANTHROPIC_API_KEY`, `CLAUDECODE`.

Permissions are granted to MacPilot.app (Accessibility, Screen Recording,
Microphone, Speech, Automation); child processes (`claude` → `osascript`/`mpctl`)
are attributed to MacPilot as the responsible process.
