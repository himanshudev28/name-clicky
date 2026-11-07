# System Settings (macOS 13–15)

## Open panes (URL scheme, background-safe)
`open "x-apple.systempreferences:<id>"`  (add `?<anchor>` for sub-section where known). (`open -g` does not keep System Settings in background.)
```
Wi-Fi             com.apple.wifi-settings-extension
Bluetooth         com.apple.BluetoothSettings
Network           com.apple.Network-Settings.extension
VPN               com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension  (unverified)
Notifications     com.apple.Notifications-Settings.extension
Sound             com.apple.Sound-Settings.extension
Focus             com.apple.Focus-Settings.extension
Screen Time       com.apple.Screen-Time-Settings.extension
General           com.apple.systempreferences.GeneralSettings
 Software Update  com.apple.Software-Update-Settings.extension
 Storage          com.apple.settings.Storage
 About            com.apple.SystemProfiler.AboutExtension
 Login Items      com.apple.LoginItems-Settings.extension
 AirDrop&Handoff  com.apple.AirDrop-Handoff-Settings.extension
 Date & Time      com.apple.Date-Time-Settings.extension
 Language&Region  com.apple.Localization-Settings.extension  (unverified)
 Sharing          com.apple.Sharing-Settings.extension
 Time Machine     com.apple.Time-Machine-Settings.extension
Appearance        com.apple.Appearance-Settings.extension
Accessibility     com.apple.Accessibility-Settings.extension
Control Center    com.apple.ControlCenter-Settings.extension
Siri              com.apple.Siri-Settings.extension
Spotlight         com.apple.Spotlight-Settings.extension
Desktop & Dock    com.apple.Desktop-Settings.extension
Displays          com.apple.Displays-Settings.extension
Wallpaper         com.apple.Wallpaper-Settings.extension
Screen Saver      com.apple.ScreenSaver-Settings.extension
Battery           com.apple.Battery-Settings.extension
Lock Screen       com.apple.Lock-Screen-Settings.extension
Touch ID&Password com.apple.Touch-ID-Settings.extension
Users & Groups    com.apple.Users-Groups-Settings.extension
Passwords         com.apple.Passwords-Settings.extension
Internet Accounts com.apple.Internet-Accounts-Settings.extension
Game Center       com.apple.Game-Center-Settings.extension
Wallet            com.apple.WalletSettingsExtension
Keyboard          com.apple.Keyboard-Settings.extension
Mouse             com.apple.Mouse-Settings.extension
Trackpad          com.apple.Trackpad-Settings.extension
Printers&Scanners com.apple.Print-Scan-Settings.extension
Privacy & Security com.apple.settings.PrivacySecurity.extension
```
Privacy sub-panes (legacy form that still works on 15):
```
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
...?Privacy_ScreenCapture   ...?Privacy_AllFiles (Full Disk Access)
...?Privacy_Microphone  ...?Privacy_Camera  ...?Privacy_Automation
...?Privacy_ListenEvent (Input Monitoring)  ...?Privacy_LocationServices
...?Privacy_Contacts ...?Privacy_Calendars ...?Privacy_Reminders ...?Privacy_Photos
...?Privacy_SpeechRecognition  ...?Privacy_DevTools  ...?Privacy_Bluetooth
Security (FileVault/firewall/etc): ...com.apple.settings.PrivacySecurity.extension?Security
```
Fallback if an ID doesn't open: `open -a "System Settings"` then `mpctl find "System Settings" "<pane name>"` + `mpctl press` (see ui-automation.md). List ids: `ls /System/Library/ExtensionKit/Extensions | grep -i settings`, and `/System/Library/PreferencePanes`.
Granting permissions can't be scripted (TCC protected) → open the pane and tell user to toggle.

## Direct changes (no UI)
### Dark / light mode
```bash
osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true'   # false = light
osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to not dark mode'  # toggle
osascript -e 'tell application "System Events" to get dark mode of appearance preferences'   # verified read
```
### Volume / mute
```bash
osascript -e 'set volume output volume 40'        # 0-100
osascript -e 'set volume output muted true'       # false to unmute
osascript -e 'output volume of (get volume settings)'
osascript -e 'set volume input volume 70'
osascript -e 'set volume output volume ((output volume of (get volume settings)) + 10)'
```
### Brightness
No built-in CLI. Options: `brew install brightness` (`brightness 0.6`, Intel-era; may not work on Apple Silicon built-in display – unverified); key codes via System Events: `osascript -e 'tell application "System Events" to key code 144'` (up) / `145` (down) per step (works on many Macs, unverified for 15); or open Displays pane and `mpctl set "System Settings" "Brightness" 0.7`.
### Wi-Fi
```bash
networksetup -listallhardwareports            # find Wi-Fi device (usually en0)
networksetup -getairportpower en0
networksetup -setairportpower en0 off|on      # no sudo needed normally
networksetup -getairportnetwork en0           # current SSID (may say "not associated"/redacted on 14+)
networksetup -setairportnetwork en0 "SSID" "password"   # join; omit password for saved/open networks
networksetup -listpreferredwirelessnetworks en0
networksetup -getdnsservers Wi-Fi ; networksetup -setdnsservers Wi-Fi 1.1.1.1 8.8.8.8   # may need admin
networksetup -listallnetworkservices
networksetup -setwebproxy Wi-Fi host port  ; networksetup -setwebproxystate Wi-Fi off   # admin
```
Scan: `/System/Library/PrivateFrameworks/Apple80211.framework/.../airport` was removed in 14.4+; use `system_profiler SPAirPortDataType`.
### Bluetooth
```bash
which blueutil || brew install blueutil        # not installed by default
blueutil -p 0|1            # power off/on
blueutil --paired ; blueutil --connect <addr> ; blueutil --disconnect <addr>
```
Without blueutil: `open "x-apple.systempreferences:com.apple.BluetoothSettings"` then `mpctl find "System Settings" "Bluetooth"`, `mpctl press`. Or Control Center menu: `mpctl ui "ControlCenter"`. `system_profiler SPBluetoothDataType` reads status.
### Do Not Disturb / Focus
No stable CLI. Use Shortcuts: user creates shortcuts "DND On"/"DND Off" (action *Set Focus*), then `shortcuts run "DND On"`. Check available: `shortcuts list | grep -i focus`. Fallback: Control Center AX: `mpctl find ControlCenter "Focus"` / `mpctl press ControlCenter "Focus"`; or `open x-apple.systempreferences:com.apple.Focus-Settings.extension`.
### Dock (defaults + restart Dock)
```bash
defaults write com.apple.dock autohide -bool true; killall Dock
defaults write com.apple.dock tilesize -int 48; killall Dock
defaults write com.apple.dock orientation -string left|bottom|right; killall Dock
defaults write com.apple.dock magnification -bool true; defaults write com.apple.dock largesize -int 80
defaults write com.apple.dock show-recents -bool false
defaults write com.apple.dock autohide-delay -float 0; defaults write com.apple.dock autohide-time-modifier -float 0.3
defaults write com.apple.dock mru-spaces -bool false      # don't auto-rearrange Spaces
defaults write com.apple.dock persistent-apps -array       # clears pinned apps (destructive!)
defaults read com.apple.dock autohide
```
### Hot corners
`defaults write com.apple.dock wvous-tl-corner -int 5; defaults write com.apple.dock wvous-tl-modifier -int 0; killall Dock`
Values: 0 none, 2 Mission Control, 3 App Windows, 4 Desktop, 5 Screen Saver, 6 Disable Screen Saver, 10 Display Sleep, 11 Launchpad, 12 Notification Center, 13 Lock Screen, 14 Quick Note. Corners: tl tr bl br.
### Finder prefs
```bash
defaults write com.apple.finder AppleShowAllFiles -bool true; killall Finder     # hidden files (also cmd+shift+.)
defaults write NSGlobalDomain AppleShowAllExtensions -bool true; killall Finder
defaults write com.apple.finder ShowPathbar -bool true
defaults write com.apple.finder ShowStatusBar -bool true
defaults write com.apple.finder FXPreferredViewStyle -string Nlsv   # icnv clmv Flwv
defaults write com.apple.finder _FXSortFoldersFirst -bool true
defaults write com.apple.finder FXDefaultSearchScope -string SCcf   # search current folder
defaults write com.apple.finder NewWindowTarget -string PfHm        # home (PfDe desktop)
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false
```
### Screenshots
```bash
defaults write com.apple.screencapture location ~/Pictures/Screenshots; killall SystemUIServer
defaults write com.apple.screencapture type -string png|jpg
defaults write com.apple.screencapture disable-shadow -bool true
defaults write com.apple.screencapture show-thumbnail -bool false
screencapture -x out.png        # silent full screen;  -R x,y,w,h region; -l <windowid>; -i interactive
mkdir -p ~/Pictures/Screenshots
```
### Keyboard
```bash
defaults write NSGlobalDomain KeyRepeat -int 2              # lower=faster (min 1; UI min 2)
defaults write NSGlobalDomain InitialKeyRepeat -int 15      # lower=shorter delay (UI min 15)
defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false   # key repeat instead of accents (re-login/restart apps)
defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
defaults write NSGlobalDomain com.apple.keyboard.fnState -bool true     # F-keys as standard
```
Apps must be relaunched to pick up NSGlobalDomain changes; some need logout.
### Trackpad / mouse
`defaults write com.apple.AppleMultitouchTrackpad Clicking -bool true` (tap to click; also `defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1`); natural scroll: `defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false` (needs logout/ unverified live). Tracking speed: `defaults write NSGlobalDomain com.apple.trackpad.scaling -float 1.5`.
### Night Shift / True Tone
No public CLI. Use Displays pane via mpctl, or CoreBrightness private tool `nightlight` (`brew install smudge/smudge/nightlight`; unverified).
### Menu bar clock etc.
`defaults write com.apple.menuextra.clock ShowSeconds -bool true; killall SystemUIServer`; `defaults write com.apple.menuextra.clock Show24Hour -bool true` (unverified on 15 – clock moved to Control Center: `com.apple.controlcenter`).
### Power / sleep
```bash
pmset -g batt ; pmset -g ; pmset -g assertions            # read (verified)
caffeinate -d -t 3600 &                  # keep display awake 1h (background; kill with killall caffeinate)
caffeinate -i command...                 # no idle sleep while command runs
pmset displaysleepnow                    # sleep display (no sudo)
pmset sleepnow                           # sleep Mac (no sudo)
sudo pmset -a displaysleep 10 | sleep 30 | lowpowermode 1 | powernap 0     # ADMIN
sudo pmset -b ...  (battery)   -c ... (charger)
osascript -e 'do shell script "pmset -a lowpowermode 1" with administrator privileges'   # prompts password
```
### Lock screen, sleep, restart, shutdown
```bash
pmset displaysleepnow                                   # locks if "require password immediately"
osascript -e 'tell application "System Events" to keystroke "q" using {control down, command down}'   # lock screen
osascript -e 'tell application "System Events" to sleep'
osascript -e 'tell application "System Events" to log out'           # asks confirm
osascript -e 'tell application "System Events" to restart'           # CONFIRM WITH USER FIRST
osascript -e 'tell application "System Events" to shut down'         # CONFIRM FIRST
osascript -e 'tell application "Finder" to restart'
open -a ScreenSaverEngine                                # start screensaver
```
### Wallpaper
```bash
osascript -e 'tell application "System Events" to tell every desktop to set picture to "/Users/me/Pictures/x.jpg"'
osascript -e 'tell application "Finder" to set desktop picture to POSIX file "/Users/me/Pictures/x.jpg"'
```
(System Events form covers all displays; both reasonably reliable on 14/15; Finder form may only set current Space. Unverified on 15 for per-Space.) Read: `osascript -e 'tell application "System Events" to get picture of every desktop'`.
### Default browser / apps
No supported CLI. `brew install defaultbrowser` → `defaultbrowser chrome` (triggers a confirm dialog the user/AX must accept: `mpctl press` the "Use <browser>" button in CoreServicesUIAgent). Or General > Desktop & Dock > Default web browser via AX. Per-file-type: `brew install duti`; `duti -s com.google.Chrome public.html all`.
### Misc
- Computer name: `scutil --get ComputerName`; `sudo scutil --set ComputerName X` (admin).
- Time zone: `sudo systemsetup -settimezone America/New_York` (admin). 
- Show/hide desktop icons: `defaults write com.apple.finder CreateDesktop -bool false; killall Finder`.
- Reduce motion/transparency: `defaults write com.apple.universalaccess reduceMotion -bool true` (SIP/TCC may block – unverified).
- Flush DNS: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`.
- Software update list: `softwareupdate -l`; install requires admin: `sudo softwareupdate -i -a`.

## Needs admin / sudo
`sudo pmset`, `systemsetup`, `softwareupdate -i`, `scutil --set`, DNS flush, some `networksetup` setters (DNS/proxy), `dscl`, `launchctl` system domain, writing /Library. Handle: tell the user, or use `osascript -e 'do shell script "…" with administrator privileges'` (dialog asks for password; never ask the user to paste it in chat; never store it).
