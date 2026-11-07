# MacPilot playbook index

Grep this folder first: `grep -ril "<keyword>" "$(dirname "$0")"` or `grep -rn "wifi" <playbook dir>`.

| File | Covers |
|---|---|
| system-settings.md | System Settings panes (URLs), dark mode, volume, Wi-Fi, Bluetooth, Focus, Dock/Finder defaults, power, lock/sleep/restart, wallpaper |
| finder-files.md | Finder AppleScript, file ops, Spotlight, Quick Look, trash, disks, tags |
| chrome.md | Chrome (+ Safari, Arc/Brave/Edge): tabs, JS, forms, profiles |
| apps-productivity.md | Notes, Reminders, Calendar, Contacts, Mail, Messages, FaceTime, Shortcuts, Preview, TextEdit, iWork, Terminal/iTerm |
| media-system.md | Music/Spotify, app launch/quit, windows, Spaces, clipboard, notifications, say, system info, brew/mas |
| ui-automation.md | mpctl AX workflow, System Events UI scripting, key combos, screenshot→click |

## Decision order (always)
1. **CLI / URL scheme / defaults** (`open`, `defaults`, `networksetup`, `pmset`, `shortcuts`, `mdfind`, `x-apple.systempreferences:`).
2. **AppleScript / JXA** dictionary of the app.
3. **mpctl AX** (`menu`, `find`, `press`, `set`) – background, no mouse.
4. **Screenshot + click** – last resort.
Never jump to 4 if 1–3 might work. Try the cheapest option first, check result by reading state back.

## Discovering scriptability
```bash
sdef /Applications/Foo.app | less            # full dictionary (XML)
sdef /Applications/Foo.app | grep -E '<(command|class|property) name' | head -80
osascript -e 'tell application "Foo" to get name of every window'   # quick probe
mdfind "kMDItemKind == 'Application' && kMDItemDisplayName == '*Foo*'"   # find app path
osascript -e 'id of app "Foo"'                # bundle id
mdls -name kMDItemCFBundleIdentifier /Applications/Foo.app
defaults read com.foo.app                     # app prefs (often controls behavior)
```
- App not scriptable (no dictionary; error -1728/-10000 or `sdef` fails) → System Events UI scripting / mpctl.
- First AppleScript to an app triggers an Automation permission prompt for MacPilot; error `-1743` = Automation denied → tell user to enable in Privacy & Security > Automation.
- Error `-25211`/"not allowed assistive access" → Accessibility not granted to MacPilot.

## osascript tips
```bash
osascript -e 'tell application "Finder" to get name of front window'
osascript <<'EOF2'                 # multi-line: use quoted heredoc, no bash interpolation
tell application "Notes"
  get name of every note
end tell
EOF2
osascript -l JavaScript -e 'Application("Finder").name()'   # JXA
osascript - "arg1" "arg2" <<'EOF2'  # pass args safely
on run argv
  return item 1 of argv
end run
EOF2
```
- Quoting: wrap AppleScript in single quotes; inside use double quotes. For a single quote inside: use heredoc. For shell var in script, pass via `argv` (safe) instead of string splicing.
- Escape `"` inside AppleScript strings as `\"`; `\` as `\\`.
- Slow/hanging scripts: `timeout 20 osascript ...` (macOS has no `timeout` by default; use `perl -e 'alarm 20; exec @ARGV' osascript ...` or `gtimeout` if coreutils). In AppleScript: `with timeout of 10 seconds ... end timeout` (default 120s, error -1712).
- `osascript` output of lists is comma separated; use `-ss` for source-style; use `return` with `linefeed` joins for line output: `set AppleScript's text item delimiters to linefeed`.
- Apps asked via `tell` are launched if not running (use `if application "X" is running then` to avoid).
- Run privileged: `osascript -e 'do shell script "CMD" with administrator privileges'` → pops password dialog for user. Prefer telling the user, or avoid sudo.

## General tips
- Verify after acting (read state back). Prefer idempotent commands.
- `open -a "App" file`, `open -b com.bundle.id`, `open -g` (don't bring to front), `open -j` (hidden).
- Don't steal focus: `open -g`, AX press, AppleScript without `activate`.
- Confirm with user before: sending mail/messages, deleting files, sudo, quitting apps with unsaved work, purchases.
- Destructive deletes: Finder trash (recoverable) over `rm`.
- Paths with spaces: always quote. `~` not expanded in AppleScript; use `POSIX file "/Users/x/..."` or `(POSIX path of (path to home folder))`.
- URL-encode for URL schemes: `python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "text"`.
