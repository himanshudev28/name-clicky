# mpctl report

Files: main.swift (dispatch, help, perms, clipboard, arg helpers), AX.swift (tree/find/press/set/focus/action/menu), Input.swift (CGEvent mouse/keys/type, `com.macpilot.point` post), Screenshot.swift, Apps.swift (app resolution, apps/front/windows/activate).

Build: `swift build --product mpctl` OK (one deprecation warning: activateIgnoringOtherApps).
Tested (read-only): help, perms, apps, front, windows, `ui Finder --depth 4`, `find Finder Desktop`, `menu Finder --list File`, `clipboard get`, arg-error paths for click/key, menu-not-found error. All behave. click/type/key/press/set/screenshot NOT executed.

Deviations / extras:
- `ui` prints a `# app window i/n "title" @frame` header line first. Ids get a `wN:` prefix only when the chosen window isn't the focused one; `find` prefixes when >1 window. `ui --menubar` ids use `m:` prefix (accepted by press/action too).
- `apps` frontmost column is `yes`/`no`. `find` with no hits prints `(no matches)` (exit 0), caps at 60.
- `press` by text falls back to an ancestor with AXPress if the matched label has none.
- `menu --list` shows `[shortcut]`, `>` for submenus, `(disabled)`. Menu titles match case-insensitively, ignoring trailing "…", with prefix fallback.
- `screenshot` prints the path; with --app or --display>1 it adds a 2nd line `size: WxH offset: x,y` (add offset to image coords to get click coords).
- `type`: newline -> Return key, tab -> Tab key.

Limitations: Electron/Chromium apps expose little AX unless their accessibility is enabled; `windows` uses AX so only windows on the current Space; screenshot warns (doesn't fail) without Screen Recording; `set` on checkbox keeps numeric type.
