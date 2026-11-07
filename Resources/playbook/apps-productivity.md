# Productivity apps (AppleScript first)

Probe any app: `sdef /System/Applications/Notes.app | grep -E '<(command|class) name'`. System apps live in /System/Applications.
**Confirm with the user before sending anything (Mail, Messages, FaceTime calls) or deleting data.**

## Notes
```bash
osascript -e 'tell application "Notes" to get name of every note'                   # default account
osascript -e 'tell application "Notes" to get name of notes of folder "Notes"'
osascript -e 'tell application "Notes" to make new note at folder "Notes" with properties {name:"Title", body:"<h1>Title</h1><p>Body text</p>"}'   # body is HTML
osascript -e 'tell application "Notes" to get plaintext of note 1'
osascript -e 'tell application "Notes" to show note 1'
osascript -e 'tell application "Notes" to get name of every folder'
osascript -e 'tell application "Notes" to set body of note 1 to "<div>new</div>"'     # overwrites
osascript -e 'tell application "Notes" to delete note 1'                              # → Recently Deleted
```
Search: `(every note whose name contains "x")` or `whose plaintext contains "x"` (slow on big libs). First call may be slow; give 60s+.
## Reminders
```bash
osascript -e 'tell application "Reminders" to get name of every list'
osascript -e 'tell application "Reminders" to get name of (reminders of list "Reminders" whose completed is false)'
osascript -e 'tell application "Reminders" to make new reminder at end of list "Reminders" with properties {name:"Buy milk", body:"2L", due date:((current date) + 2 * hours)}'
osascript -e 'tell application "Reminders" to set completed of (first reminder whose name is "Buy milk") to true'
osascript -e 'tell application "Reminders" to make new reminder with properties {name:"X", remind me date:(current date) + 1 * days}'   # alert; 'due date' only sets due
osascript -e 'tell application "Reminders" to delete (first reminder whose name is "X")'
```
Priority: 0 none, 1 high, 5 medium, 9 low. Tomorrow 9am: `set d to (current date) + 1*days; set time of d to 9*hours`.
## Calendar
```bash
osascript -e 'tell application "Calendar" to get name of every calendar'
# Events today → tomorrow
osascript <<'EOF2'
set d1 to current date
set time of d1 to 0
set d2 to d1 + 1 * days
tell application "Calendar"
  set out to ""
  repeat with c in calendars
    repeat with e in (events of c whose start date ≥ d1 and start date < d2)
      set out to out & (summary of e) & " | " & (start date of e as string) & " | " & (name of c) & linefeed
    end repeat
  end repeat
  return out
end tell
EOF2
# Create event
osascript <<'EOF2'
set s to (current date) + 1 * days
set time of s to 15 * hours
tell application "Calendar"
  tell calendar "Home"
    make new event with properties {summary:"Meeting", start date:s, end date:s + 1 * hours, location:"Zoom", description:"notes", allday event:false}
  end tell
end tell
EOF2
```
Date gotchas: AppleScript date literals are locale-dependent (`date "Monday, 3 March 2025 at 15:00"`). Build dates relative to `current date` and set `year/month/day/time` components (`set month of d to March`, `set day of d to 3`, **set day to 1 before changing month**, `set time of d to 15*hours`). Calendar `events whose` over all calendars with long ranges is slow; narrow dates. Add alarm: `make new display alarm at end of events of e with properties {trigger interval:-15}`. Alternative faster read: `icalBuddy` (`brew install ical-buddy`; `icalBuddy eventsToday`). Open Calendar to a date/URL: `open "calshow:$(date -j -f %Y-%m-%d 2025-03-03 +%s)"`? (calshow takes seconds since 2001-01-01; unverified).
## Contacts
```bash
osascript -e 'tell application "Contacts" to get name of every person whose name contains "Ann"'
osascript -e 'tell application "Contacts" to get value of every phone of (first person whose name is "Ann Lee")'
osascript -e 'tell application "Contacts" to get value of every email of (first person whose name is "Ann Lee")'
osascript -e 'tell application "Contacts" to make new person with properties {first name:"A", last name:"B"}' -e 'tell application "Contacts" to save'
```
## Mail (CONFIRM BEFORE SEND)
```bash
# Draft only (visible compose window, not sent)
osascript <<'EOF2'
tell application "Mail"
  set m to make new outgoing message with properties {subject:"Hi", content:"Body" & linefeed, visible:true}
  tell m to make new to recipient with properties {address:"a@b.com"}
  tell m to make new attachment with properties {file name:(POSIX file "/path/f.pdf")} at after the last paragraph
  -- send m     ← only after explicit user OK
end tell
EOF2
osascript -e 'tell application "Mail" to get {subject, sender} of (messages 1 thru 10 of inbox)'
osascript -e 'tell application "Mail" to get count of (messages of inbox whose read status is false)'
osascript -e 'tell application "Mail" to check for new mail'
osascript -e 'tell application "Mail" to get content of message 1 of inbox'
open "mailto:a@b.com?subject=Hi&body=Hello"       # opens compose; user sends
```
## Messages (CONFIRM BEFORE SEND)
```bash
osascript <<'EOF2'
tell application "Messages"
  set s to 1st account whose service type = iMessage
  set b to participant "+15551234567" of s      # or email
  send "text" to b
end tell
EOF2
osascript -e 'tell application "Messages" to send "hi" to chat id "iMessage;-;+15551234567"'   # alt (unverified id form)
osascript -e 'tell application "Messages" to send POSIX file "/path/img.png" to buddy "+1555…" of (1st account whose service type = iMessage)'
open "sms:+15551234567&body=hello"                # opens compose
```
Reading messages: AppleScript can't. `sqlite3 ~/Library/Messages/chat.db "select text from message order by date desc limit 10"` needs Full Disk Access for MacPilot (and attributedBody on newer macOS hides text – unverified). Private data: only on request.
## FaceTime / calls
`open "facetime://+15551234567"` / `facetime-audio://…` / `tel://…` → shows confirm dialog; user must click Call (mpctl press "Call" if they ask: `mpctl press FaceTime Call`). Confirm before dialing.
## Shortcuts CLI (verified `shortcuts list`)
```bash
shortcuts list ; shortcuts list --folders
shortcuts run "Name" ; echo "input" | shortcuts run "Name" ; shortcuts run "Name" -i file.txt -o out.txt
shortcuts view "Name"       # opens editor
```
Great bridge for things lacking APIs (Focus, Low Power Mode, Wi-Fi toggles, Messages, HomeKit, "Set Appearance"). If a needed shortcut doesn't exist: tell user, or build via AX in Shortcuts app (slow). `open "shortcuts://run-shortcut?name=Name&input=text:hello"` also works.
## Preview / TextEdit
```bash
open -a Preview file.pdf          # Preview has weak AppleScript (open/close/windows)
osascript -e 'tell application "TextEdit" to make new document with properties {text:"hello"}'
osascript -e 'tell application "TextEdit" to save front document in POSIX file "/tmp/x.txt"'
osascript -e 'tell application "TextEdit" to get text of front document'
osascript -e 'tell application "TextEdit" to close front document saving no'
```
PDF tools: `sips -s format png in.jpg --out out.png`, `sips -Z 1024 img` (resize), `sips -g pixelWidth img`; `pdfunite`/`qpdf` if installed; `mdls` on pdf; `textutil -convert txt|html|docx f`; `afconvert`; `ffmpeg` if installed.
## Pages / Numbers / Keynote (iWork)
```bash
osascript -e 'tell application "Pages" to make new document'
osascript -e 'tell application "Pages" to tell front document to set body text to "Hello"'
osascript -e 'tell application "Pages" to export front document to POSIX file "/tmp/o.pdf" as PDF'     # also Microsoft Word
osascript -e 'tell application "Numbers" to tell active sheet of front document to tell table 1 to set value of cell "A1" to 42'
osascript -e 'tell application "Keynote" to get name of slides of front document'
osascript -e 'tell application "Keynote" to start front document'   # present;  stop front document / show next / show previous
```
Each has a rich dictionary: `sdef /Applications/Keynote.app`. Exports require a file path that doesn't exist yet. Microsoft Office apps: similar (`tell application "Microsoft Word"`), AppleScript works but slower.
## Terminal / iTerm
```bash
osascript -e 'tell application "Terminal" to do script "cd ~/proj && ls"'              # new window (add `in front window` for existing)
osascript -e 'tell application "Terminal" to get contents of selected tab of front window'   # scrollback text
osascript <<'EOF2'
tell application "iTerm"
  create window with default profile
  tell current session of current window to write text "echo hi"
end tell
EOF2
osascript -e 'tell application "iTerm" to tell current session of current window to get contents'
```
For just running commands, use Bash directly — only use Terminal/iTerm when user wants to *see* a window.
## Other
- Maps: `open "maps://?q=coffee"`, `open "http://maps.apple.com/?daddr=Cupertino&dirflg=d"`.
- Books/Podcasts: `open "podcasts://"`. App Store: see media-system.md.
- Photos: weak AppleScript (`import`, `export`); `osxphotos` (pip) for power use.
- Zoom: `open "zoommtg://zoom.us/join?confno=123456789"`; Slack: `open "slack://channel?team=T&id=C"`; Spotify: `open "spotify:search:term"`; VS Code: `open -a "Visual Studio Code" path` / `code path`.
- Weather/Stocks/Clock have no scripting → mpctl or web (curl wttr.in/City?format=3).
