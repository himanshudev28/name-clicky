# Chrome (and Safari, Chromium siblings)

## Chrome AppleScript basics (verified: `active tab` title/URL works)
```bash
# Active tab title+URL
osascript -e 'tell application "Google Chrome" to get {title, URL} of active tab of front window'
# All windows/tabs (window index, tab index, title, URL)
osascript <<'EOF2'
tell application "Google Chrome"
  set out to ""
  repeat with w from 1 to (count of windows)
    repeat with t from 1 to (count of tabs of window w)
      set tb to tab t of window w
      set out to out & w & "." & t & " | " & (title of tb) & " | " & (URL of tb) & linefeed
    end repeat
  end repeat
  return out
end tell
EOF2
# Open URL
osascript -e 'tell application "Google Chrome" to open location "https://example.com"'          # new tab in front window
osascript -e 'tell application "Google Chrome" to tell front window to make new tab with properties {URL:"https://example.com"}'
osascript -e 'tell application "Google Chrome" to make new window'
osascript -e 'tell application "Google Chrome" to make new window with properties {mode:"incognito"}'
osascript -e 'tell application "Google Chrome" to set URL of active tab of front window to "https://example.com"'
open -a "Google Chrome" "https://example.com"       # simplest; may focus Chrome. -g keeps in background
# Switch tab (1-based) / bring window front
osascript -e 'tell application "Google Chrome" to set active tab index of front window to 3'
osascript -e 'tell application "Google Chrome" to set index of window 2 to 1'
# Close / reload / navigate
osascript -e 'tell application "Google Chrome" to close active tab of front window'
osascript -e 'tell application "Google Chrome" to close tab 2 of window 1'
osascript -e 'tell application "Google Chrome" to reload active tab of front window'
osascript -e 'tell application "Google Chrome" to tell active tab of front window to go back'   # go forward / stop / print / view source / save also exist
```
- Close tabs by pattern: loop **backwards** (`repeat with t from n to 1 by -1`) and test `URL of tab t of window w contains "x"`.
- Find a tab and focus it: loop, then `set active tab index of window w to t` + `set index of window w to 1` + `activate`.
- Titles/URLs property: `loading`, `id`, `mode` (normal/incognito), `bounds`, `minimized`.
- Window by-id is stable: `id of window 1`; tab `id of tab`.
- Check running first to avoid launching: `if application "Google Chrome" is running then`.

## Run JavaScript in a tab
Requires **View > Developer > Allow JavaScript from Apple Events** (one-time, per profile). Enable via AX (no mouse):
```bash
mpctl menu "Google Chrome" "View > Developer > Allow JavaScript from Apple Events"
mpctl menu "Google Chrome" --list "View"      # lists items/[shortcut]/(disabled) but NOT check state (items may show (disabled) if Chrome has no window/isn't frontmost)
```
Error text when off: "Executing JavaScript through AppleScript is turned off". The menu click toggles, and check state is not visible via mpctl → first try the JS; only if that errors, run the menu click once, then retry the JS.
```bash
osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript "document.title"'
# page text
osascript -e 'tell application "Google Chrome" to execute active tab of front window javascript "document.body.innerText.slice(0,5000)"'
# selected text / links
... javascript "window.getSelection().toString()"
... javascript "JSON.stringify([...document.links].slice(0,50).map(a=>[a.innerText.trim(),a.href]))"
# click / fill
... javascript "document.querySelector('button[type=submit]').click()"
... javascript "(()=>{const e=document.querySelector('input[name=q]');e.focus();e.value='hello';e.dispatchEvent(new Event('input',{bubbles:true}));e.form&&e.form.submit();})()"
# scroll
... javascript "window.scrollTo(0,document.body.scrollHeight)"
```
Tips: result is the last expression value; return strings (use JSON.stringify for objects). Use a heredoc/file for long JS: `JS=$(cat file.js); osascript - "$JS" <<'EOF2' ... on run argv ... javascript (item 1 of argv)`. React/Vue inputs need `input`/`change` events (native setter trick: `Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,v)`). Doesn't run on chrome:// pages or the Web Store. Runs in logged-in profile context → can read user's authenticated pages (be careful with secrets). Async: wrap in sync code only; for fetch use `await`-less pattern: store result on `window.__r` then poll in a 2nd call.
Download page as text/markdown quickly w/o browser: `curl -sL url | …` (use WebFetch where possible).

## Other Chrome tasks
```bash
# Profiles
ls ~/Library/Application\ Support/Google/Chrome | grep -E '^(Default|Profile)'
grep -o '"name":"[^"]*"' ~/Library/Application\ Support/Google/Chrome/"Local State" | head      # (profile names; unverified format)
open -na "Google Chrome" --args --profile-directory="Profile 1" "https://example.com"
open -na "Google Chrome" --args --incognito "https://example.com"
open -na "Google Chrome" --args --new-window URL
# Bookmarks (read-only JSON): ~/Library/Application Support/Google/Chrome/Default/Bookmarks
python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/Library/Application Support/Google/Chrome/Default/Bookmarks')));print([c['name'] for c in d['roots']['bookmark_bar']['children']])"
# Bookmark current page / other UI via menus:
mpctl menu "Google Chrome" "Bookmarks > Bookmark This Tab…"      # or mpctl key cmd+d
mpctl menu "Google Chrome" "Window > Task Manager"
mpctl menu "Google Chrome" "History > Show Full History"
mpctl menu "Google Chrome" "Chrome > Settings…"                  # or open chrome://settings via open location
mpctl menu "Google Chrome" "View > Developer > Developer Tools"
# Chrome with remote debugging (full CDP control, no UI): quits current instance, needs separate user-data-dir for non-default
open -na "Google Chrome" --args --remote-debugging-port=9222 --user-data-dir=/tmp/chrome-mp   # then curl localhost:9222/json
# Print to PDF headless
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu --print-to-pdf=/tmp/o.pdf URL
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --screenshot=/tmp/s.png --window-size=1280,800 URL
```
- `chrome://` URLs: `osascript -e 'tell application "Google Chrome" to open location "chrome://settings"'`.
- Downloads land in ~/Downloads; list newest: `ls -t ~/Downloads | head`.
- Extensions: `chrome://extensions`. Passwords/autofill: don't extract.
- File upload dialogs / native prompts: use mpctl/System Events (Cmd+Shift+G in file chooser then type path: `mpctl key cmd+shift+g; mpctl type "/path"; mpctl key return; mpctl key return`).

## Claude Code `--chrome` integration
If the "Claude in Chrome" extension is installed and the CLI was started with `--chrome`, Claude has `mcp__claude-in-chrome__*` tools (tabs, navigate, read_page, find, form_input, javascript_tool, screenshots). They drive the user's real logged-in Chrome – use them for multi-step page work (forms, scraping SPAs) when AppleScript JS is too clumsy. Load the tools via ToolSearch first; call `tabs_context_mcp` before anything; open a new tab rather than reusing the user's; close tabs you opened. If tools are missing → fall back to AppleScript above.

## Safari
```bash
osascript -e 'tell application "Safari" to get {name, URL} of current tab of front window'
osascript -e 'tell application "Safari" to set URL of current tab of front window to "https://example.com"'
osascript -e 'tell application "Safari" to tell front window to set current tab to tab 2'
osascript -e 'tell application "Safari" to tell front window to make new tab with properties {URL:"https://example.com"}'
osascript -e 'tell application "Safari" to make new document with properties {URL:"https://example.com"}'
osascript -e 'tell application "Safari" to close current tab of front window'
osascript -e 'tell application "Safari" to get URL of every tab of every window'
osascript -e 'tell application "Safari" to do JavaScript "document.title" in current tab of front window'
osascript -e 'tell application "Safari" to get text of current tab of front window'     # page text, no JS needed
osascript -e 'tell application "Safari" to get source of current tab of front window'
```
`do JavaScript` needs **Develop > Allow JavaScript from Apple Events** (Develop menu must be enabled: Safari Settings > Advanced > Show features for web developers). `mpctl menu Safari "Develop > Allow JavaScript from Apple Events"`. Or: `defaults write com.apple.Safari IncludeDevelopMenu -bool true` (sandboxed container; may not take effect – unverified, use `defaults write com.apple.Safari.SandboxBroker ...` unverified).
Safari reading list/private window: `mpctl menu Safari "File > New Private Window"`.

## Arc / Brave / Edge / Vivaldi (Chromium)
Use the **same dictionary as Chrome**; change app name: `tell application "Brave Browser"`, `"Microsoft Edge"`, `"Vivaldi"`, `"Chromium"`. Arc: supports `tell application "Arc"` with windows/tabs (`URL`, `title`, `make new tab`), JS via `execute javascript` (also needs its JS-from-Apple-Events toggle; menu "Tools > Developer"), spaces/other features limited (unverified). JS toggle path in others: `View > Developer > Allow JavaScript from Apple Events` (Brave, Edge); Edge: `View > Developer`.
Profiles: `--profile-directory`. 
