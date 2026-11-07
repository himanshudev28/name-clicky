# Media & system utilities

## Music (Apple Music app)
```bash
osascript -e 'tell application "Music" to playpause'      # play / pause / next track / previous track / stop
osascript -e 'tell application "Music" to next track'
osascript -e 'tell application "Music" to get {name, artist, album} of current track'
osascript -e 'tell application "Music" to get player state'       # playing/paused/stopped
osascript -e 'tell application "Music" to set sound volume to 50'   # app volume 0-100
osascript -e 'tell application "Music" to set shuffle enabled to true'   # song repeat: off|one|all
osascript -e 'tell application "Music" to play playlist "Chill"'
osascript -e 'tell application "Music" to get name of every playlist'
osascript -e 'tell application "Music" to play (first track of library playlist 1 whose name contains "love")'
osascript -e 'tell application "Music" to set rating of current track to 100'   # 0-100, 20/star
osascript -e 'tell application "Music" to get player position'
```
Library-only (local/synced songs). Apple Music catalog search/play isn't scriptable: `open "music://music.apple.com/search?term=Daft%20Punk"` then AX. Player state check *before* playpause to avoid toggling wrongly. Don't start playback unless asked.
## Spotify
```bash
osascript -e 'tell application "Spotify" to playpause'      # next track / previous track / pause / play
osascript -e 'tell application "Spotify" to get {name, artist, album} of current track'
osascript -e 'tell application "Spotify" to set sound volume to 40'
osascript -e 'tell application "Spotify" to play track "spotify:track:6rqhFgbbKwnb9MLmUQDhG6"'    # also spotify:playlist:/album:
osascript -e 'tell application "Spotify" to get player state'
open "spotify:search:daft punk"       # opens search; then AX press first result: mpctl find Spotify "Play"
```
No AppleScript text search; use `open spotify:search:` + `mpctl`, or Web API (needs token). Spotify must be running (`open -a Spotify`).
## Now playing (any app)
`nowplaying-cli get title artist` (`brew install nowplaying-cli`). Media keys: `osascript -e 'tell application "System Events" to key code 16 using {command down, option down}'`? not reliable; prefer app-specific dictionaries. IINA/VLC: `open -a IINA file`; VLC has AppleScript.
## Volume
See system-settings.md (`set volume output volume N`, `output muted`). Audio devices: `brew install switchaudio-osx` → `SwitchAudioSource -a`, `-s "AirPods"`; otherwise Sound pane via mpctl.
## Launch / quit / hide apps
```bash
open -a "Safari"           ; open -b com.apple.Safari ; open -ga "App"        # -g background; -j hidden; -n new instance
osascript -e 'quit app "Safari"'                       # graceful (unsaved docs prompt)
osascript -e 'tell application "Safari" to quit saving no'  # discards unsaved; confirm
osascript -e 'tell application "System Events" to set visible of process "Safari" to false'   # hide
osascript -e 'tell application "Safari" to activate'   ; mpctl activate Safari
pkill -x Safari           # SIGTERM; killall -9 "App"  only for hung apps (confirm; data loss)
osascript -e 'tell application "System Events" to get name of every process whose background only is false'   # running GUI apps (or: mpctl apps)
osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'
pgrep -x "Google Chrome" ; ps aux | grep -i "[s]lack"
```
Force Quit dialog equivalent: `kill -9 <pid>`. Restart an app: `osascript -e 'quit app "X"'; sleep 1; open -a X`.
## Window management (System Events; needs Accessibility)
```bash
# List all windows of an app: name, position, size
osascript -e 'tell application "System Events" to tell process "Finder" to get {name, position, size} of every window'
# Move / resize
osascript -e 'tell application "System Events" to tell process "Safari" to set position of window 1 to {0, 25}'
osascript -e 'tell application "System Events" to tell process "Safari" to set size of window 1 to {1200, 800}'
# Minimize / un-minimize / fullscreen / close
osascript -e 'tell application "System Events" to tell process "Safari" to set value of attribute "AXMinimized" of window 1 to true'
osascript -e 'tell application "System Events" to tell process "Safari" to set value of attribute "AXFullScreen" of window 1 to true'
osascript -e 'tell application "System Events" to tell process "Safari" to click button 1 of window 1'     # button 1 = close; 2 = minimize; 3 = zoom (usually)
# Screen size
osascript -e 'tell application "Finder" to get bounds of window of desktop'
# Split-screen: left half
osascript -e 'tell application "Finder" to set b to bounds of window of desktop' -e 'set {x1,y1,x2,y2} to b' \
  -e 'tell application "System Events" to tell process "Safari" to set {position, size} of window 1 to {{0, 25}, {x2/2, y2-25}}'
```
Scriptable apps also have `bounds` (`set bounds of front window to {x1,y1,x2,y2}`) – Finder, Safari, Chrome, Terminal, TextEdit. Window menu items: `mpctl menu X "Window > Zoom"`, `"Window > Move & Resize > Left"` (macOS 15). Third-party managers (Rectangle) have URL schemes: `open -g "rectangle://execute-action?name=left-half"`. Menu bar offset ≈ 25–38pt on notched screens.
## Spaces / Mission Control
```bash
open -a "Mission Control"
osascript -e 'tell application "System Events" to key code 126 using control down'    # ctrl+up  Mission Control
osascript -e 'tell application "System Events" to key code 124 using control down'    # ctrl+right next Space
osascript -e 'tell application "System Events" to key code 123 using control down'    # ctrl+left  prev Space
osascript -e 'tell application "System Events" to key code 18 using control down'     # ctrl+1 → Desktop 1 (shortcuts must be enabled in Keyboard > Shortcuts > Mission Control)
osascript -e 'tell application "System Events" to key code 103'    # F11 show desktop
```
Or `mpctl key ctrl+right`. Keyboard shortcuts must be enabled in System Settings, otherwise nothing happens. Assigning a window to a Space has no API (right-click Dock icon > Options). 
## Clipboard
```bash
pbcopy < file ; echo -n "text" | pbcopy ; pbpaste ; pbpaste | wc -c
osascript -e 'set the clipboard to "text"' ; osascript -e 'the clipboard'
osascript -e 'set the clipboard to (read (POSIX file "/tmp/x.png") as «class PNGf»)'    # image to clipboard
osascript -e 'clipboard info'
mpctl clipboard get ; mpctl clipboard set "text"
# paste into frontmost app
osascript -e 'tell application "System Events" to keystroke "v" using command down'
```
## Notifications, speech, sounds
```bash
osascript -e 'display notification "Body" with title "Title" subtitle "Sub" sound name "Glass"'
osascript -e 'display dialog "Question?" buttons {"No","Yes"} default button "Yes" giving up after 30'   # blocks until answered
osascript -e 'text returned of (display dialog "Name?" default answer "")'
osascript -e 'choose from list {"a","b"}' ; osascript -e 'POSIX path of (choose file)'
say "Hello" ; say -v Samantha -r 180 "hi" ; say -v '?' | head ; say -o /tmp/o.aiff "text"
afplay /System/Library/Sounds/Glass.aiff    # sounds: Basso Blow Bottle Frog Funk Glass Hero Morse Ping Pop Purr Sosumi Submarine Tink
osascript -e 'beep 2'
```
Notification uses the invoking process's identity (may be attributed to Script Editor/MacPilot; may not show if notifications off for it).
## Timers / alarms
```bash
( sleep 600 && osascript -e 'display notification "Time is up" with title "Timer" sound name "Glass"' && say "Time is up" ) >/dev/null 2>&1 &
disown
# at a clock time: launchd or `at` (disabled by default). Calendar/Reminders alert is the durable way:
osascript -e 'tell application "Reminders" to make new reminder with properties {name:"Call", remind me date:(current date)+30*minutes}'
caffeinate -t 600      # blocks 10 min (keep Mac awake) – not a timer notifier
```
Background jobs die if MacPilot's Bash session ends → use `nohup … &` or `launchctl`; for reliability prefer Reminders.
## System info
```bash
sw_vers ; uname -m ; sysctl -n machdep.cpu.brand_string ; sysctl -n hw.memsize
system_profiler SPHardwareDataType SPDisplaysDataType SPPowerDataType -detailLevel mini
system_profiler SPBluetoothDataType | head -30 ; system_profiler SPAirPortDataType | head -30 ; system_profiler SPUSBDataType
pmset -g batt                         # verified: "Now drawing from 'Battery Power' / 66%; discharging; 7:14 remaining"
ioreg -rc AppleSmartBattery | grep -E 'CycleCount|MaxCapacity|DesignCapacity'
df -h / ; du -sh ~/* 2>/dev/null | sort -h | tail
top -l 1 -n 10 -o cpu -stats pid,command,cpu,mem | head -25 ; ps -Arco pid,%cpu,%mem,comm | head -10   # top processes (ps -r = by CPU, -m by mem)
vm_stat | head ; memory_pressure | tail -3 ; uptime ; who
ifconfig en0 | grep inet ; ipconfig getifaddr en0 ; curl -s ifconfig.me ; networksetup -getinfo Wi-Fi
scutil --get ComputerName ; whoami ; date
lsof -iTCP -sTCP:LISTEN -n -P ; lsof -ti :3000 | xargs kill   # port owner (confirm kill)
ping -c3 1.1.1.1 ; networkQuality -s     # speed test (~30s)
```
## Installing apps
```bash
brew search X ; brew install X ; brew install --cask X ; brew upgrade ; brew list ; brew uninstall --cask X ; brew cleanup
/opt/homebrew/bin/brew ...   # use abs path if PATH lacks it
brew install mas && mas search "Name" ; mas install <id> ; mas list ; mas upgrade    # needs user signed into App Store (mas not installed by default)
open "macappstore://apps.apple.com/app/id497799835"        # App Store page (Xcode example)
open "https://apps.apple.com/app/id497799835"
open ~/Downloads/App.dmg → ditto "/Volumes/App/App.app" /Applications/App.app ; hdiutil detach /Volumes/App
xattr -dr com.apple.quarantine /Applications/App.app      # only if user trusts
softwareupdate -l
```
Cask installs may prompt for sudo (tell user / use `with administrator privileges`). App Store purchases: user confirms (Touch ID). Uninstall: Finder trash the .app (+ `brew uninstall --cask --zap`).
