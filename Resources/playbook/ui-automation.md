# UI automation (when no CLI / dictionary exists)

Order: **mpctl AX (background)** → System Events UI scripting → keyboard shortcuts → screenshot+click (last).
`mpctl` accepts app name, bundle id, or `front`.

## 0. Preflight
```bash
mpctl perms                       # accessibility: yes / screen-recording: yes
mpctl front                       # frontmost app, bundle id, window title
mpctl apps ; mpctl windows "System Settings"
mpctl activate "System Settings"  # only if the window must be frontmost (some apps ignore AX unless active)
```
If `accessibility: no` → tell user to enable MacPilot in Privacy & Security > Accessibility (`open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`).

## 1. mpctl workflow
```bash
mpctl ui "System Settings" --depth 8 --max 200      # first line "# app window i/n \"title\" @frame", then [id] AXRole "title" value="…" @x,y,w,h actions=…
mpctl find "System Settings" "Wi-Fi"                # case-insens. search title/desc/value/identifier/help
mpctl find "System Settings" "" --role AXCheckBox   # empty text + --role lists all of that role (max 60); no hits prints "(no matches)", exit 0
# find prints ready-to-use ids, e.g. "[w0:0.0.1.1] AXButton …" – the "w0:" prefix appears when >1 window; pass it as-is to press/set/action
mpctl press "System Settings" "0.3.1.2"             # press by id path (stable within a snapshot) – or by text:
mpctl press Safari "Reload"                         # first match of text
mpctl set  Notes "0.2.0" "new text"                 # set AXValue (text fields, sliders; checkbox 1/0)
mpctl focus Safari "Address"                        # AXFocused
mpctl action Finder "Documents" AXShowMenu          # any AX action (AXIncrement, AXConfirm, AXRaise, AXShowMenu…)
mpctl menu Safari "File > New Private Window"       # menu bar by path, background, no mouse
mpctl menu Safari --list ; mpctl menu Safari --list View    # items with [shortcut], ">" = submenu, "(disabled)"; no checkmark state
# menu titles match case-insensitively, ignore trailing "…", prefix match ok
mpctl ui front --menubar                            # menu bar dump; ids look like [m:2] / [m:2.0]; press/action accept the "m:" ids
# `ui --window N` picks another window; its ids then get a "wN:" prefix (e.g. w1:0.3) – use them verbatim
```
Procedure:
1. Open/navigate through URL/CLI first (e.g. `open "x-apple.systempreferences:…"`); `sleep 1` for window to appear.
2. `mpctl ui <app>` once to learn structure; then `mpctl find` with specific text/role.
3. Act with `press`/`set`/`menu`; **re-run `find`/`ui` to verify the new state** (value changes, sheet appears).
4. IDs are index paths: they shift after UI changes → re-find rather than reuse stale ids.
Gotchas: Prefer `--role AXCheckBox|AXButton|AXPopUpButton|AXTextField|AXRadioButton|AXMenuItem`. Many labels live in `AXStaticText` siblings, not on the control: find label, then look at the neighbor line/`@x,y` row in `ui` output. Menus/popups: press the popup → `mpctl ui` again (menu appears as new children) → press item. SwiftUI (System Settings) lists are often nested 10+ levels: raise `--depth`, `--max`. Value of switches: `value="1"`/`"0"`. Sheets/alerts: `find <app> "OK"`. Web content in Chrome/Safari is exposed too but very noisy → use JS instead (chrome.md).

## 2. Worked example: toggle a System Settings switch without the mouse
Goal: turn Bluetooth off (works the same for any pane switch).
```bash
open "x-apple.systempreferences:com.apple.BluetoothSettings"; sleep 1.5
mpctl find "System Settings" "Bluetooth" --role AXCheckBox
#  → e.g. [0.2.0.1.0.0.0.0 ...] AXCheckBox "Bluetooth" value="1" @700,160,38,22 actions=AXPress
mpctl press "System Settings" "0.2.0.1.0.0.0.0"       # use the exact id printed above (illustrative)
sleep 0.5
mpctl find "System Settings" "Bluetooth" --role AXCheckBox     # confirm value="0"
osascript -e 'quit app "System Settings"'                      # close when done (if you opened it)
```
Fallback within AX: `mpctl set "System Settings" <id> 0`; or `mpctl action … AXPress`. If the control's role is AXSwitch/AXCheckBox but not found by title, `mpctl ui "System Settings"` and pick the checkbox on the same row y as the label text.

## 3. System Events UI scripting (same idea, AppleScript)
```bash
osascript <<'EOF2'
tell application "System Events"
  tell process "System Settings"
    set frontmost to true                               -- sometimes required; drop to stay background
    click button "Update Now" of group 1 of scroll area 1 of group 1 of group 2 of splitter group 1 of group 1 of window 1   -- hierarchy differs per pane: discover with `entire contents`
    click checkbox "Show in menu bar" of window 1
    click menu item "Dark" of menu 1 of pop up button 1 of window 1
    set value of text field 1 of window 1 to "text"
    keystroke "x" using {command down}        -- keystroke goes to FRONT app only
    key code 36                               -- return;  53 esc; 48 tab; 49 space; 51 delete; 123-126 ←→↓↑; 116/121 pgup/pgdn
    click menu item "New Window" of menu "File" of menu bar 1
  end tell
end tell
EOF2
osascript -e 'tell application "System Events" to tell process "Finder" to get entire contents of window 1'       # discovery (slow; print names: `name of every UI element of window 1`)
osascript -e 'tell application "System Events" to tell process "Safari" to get name of every button of window 1'
```
Modifier syntax: `using {command down, shift down, option down, control down}`. Prefer `mpctl menu` for menus (faster, nicer path syntax). Menu bar extras (Wi-Fi/Control Center): `tell process "ControlCenter" to click menu bar item "Wi-Fi" of menu bar 1`.
Pitfalls: error -1719 (invalid index – UI hierarchy differs; redump), -1728 (element not found), -25211 (no accessibility). Add `delay 0.5` after UI-changing actions. UI scripting of System Settings moves between macOS versions – re-discover each time.

## 4. Keyboard shortcuts
```bash
mpctl key cmd+space ; mpctl key cmd+shift+4 ; mpctl key ctrl+cmd+q (lock) ; mpctl key return ; mpctl key esc ; mpctl key cmd+tab
mpctl key cmd+shift+g       # Go to folder in Open/Save panels or Finder, then: mpctl type "/path" ; mpctl key return
mpctl type "hello world"    # unicode typing into the focused field (newline → Return key, tab → Tab key)
```
Keys go to the **frontmost** app → `mpctl activate <app>` first, and verify with `mpctl front`. Prefer `mpctl menu` over a shortcut (shortcuts vary/user-remapped). Spotlight launch: `mpctl key cmd+space; mpctl type "Safari"; mpctl key return` — but `open -a Safari` is better. Save dialog: `mpctl key cmd+shift+g` → path → return → then `return` to Save. Common: cmd+, (Settings/Prefs), cmd+w close, cmd+q quit, cmd+n new, cmd+t new tab, cmd+l address bar, cmd+f find, cmd+a/c/v/x/z, cmd+shift+. (hidden files in Finder), cmd+option+esc (Force Quit), cmd+ctrl+f (fullscreen), cmd+h hide, cmd+m minimize.

## 5. Screenshot → click (LAST RESORT)
```bash
mpctl screenshot --app "System Settings" --out /tmp/s.jpg    # or no --app for full screen (--display N)
# then Read /tmp/s.jpg with the Read tool (image). Coordinates in image == global points (already downscaled)
mpctl point 640 380 "here"        # optional: flash ring to show the user
mpctl click 640 380 ; mpctl click 640 380 --double ; mpctl click 640 380 --right
mpctl drag 100 100 400 100 ; mpctl scroll -5 ; mpctl type "text"
```
- `mpctl screenshot` prints the path; with `--app` or `--display N>1` it prints a 2nd line `size: WxH offset: x,y`. **Add that offset to image coordinates** to get click coordinates (full main-display shots have no offset line = offset 0,0). Images are already scaled to points.
- Screenshot only when you need to look; re-screenshot after each click to verify. Needs Screen Recording permission.
- Clicks move the real mouse and need the target window visible and frontmost (`mpctl activate`). Retina is handled (points not pixels).
- Prefer `mpctl find` coordinates (`@x,y,w,h`) → click the center `(x+w/2, y+h/2)` instead of guessing from pixels.
- Drag & drop, sliders: `mpctl drag` from thumb center; or `mpctl set … <value>` / `mpctl action … AXIncrement` first.
- Canvas/games/Electron apps with poor AX: enable AX in Electron/Chromium by launching with `--force-renderer-accessibility` or `open -a "App" --args --force-renderer-accessibility` (restart app).
