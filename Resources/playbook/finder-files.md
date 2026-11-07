# Finder & files

## Finder AppleScript (verified: front window path, name)
```bash
# front window folder path
osascript -e 'tell application "Finder" to get POSIX path of (target of front window as alias)'
# open folder in new window / reveal file / select
open ~/Downloads                         # opens (Finder window)
open -R /path/to/file                    # reveal & select in Finder
osascript -e 'tell application "Finder" to make new Finder window to (POSIX file "/Users/me/Documents" as alias)'
osascript -e 'tell application "Finder" to set target of front window to (POSIX file "/tmp" as alias)'
osascript -e 'tell application "Finder" to select (POSIX file "/path/file" as alias)'
osascript -e 'tell application "Finder" to activate'
# current selection (POSIX paths, one per line)
osascript -e 'tell application "Finder" to set sel to selection as alias list' -e 'set out to ""' -e 'repeat with f in sel' -e 'set out to out & POSIX path of f & linefeed' -e 'end repeat' -e 'return out'
osascript -e 'tell application "Finder" to get name of every window'
osascript -e 'tell application "Finder" to close every window'
osascript -e 'tell application "Finder" to set current view of front window to list view'   # icon/list/column/flow view
osascript -e 'tell application "Finder" to get bounds of window of desktop'   # screen size
```
- No windows open → `front window` errors (-1728); check `count of windows` or use `desktop` selection / `insertion location`: `get POSIX path of (insertion location as alias)`.
- Desktop selection counts as selection too.

## Trash safely (recoverable) — prefer over `rm`
```bash
osascript -e 'tell application "Finder" to delete (POSIX file "/path/file" as alias)'
osascript -e 'tell application "Finder" to delete {POSIX file "/a" as alias, POSIX file "/b" as alias}'
osascript -e 'tell application "Finder" to empty the trash'      # IRREVERSIBLE; confirm with user
osascript -e 'tell application "Finder" to get count of items of trash'
```
`brew install trash` → `trash file…` (faster, Finder-free). `rm -rf` only for scratch/temp you created. Always `ls` the target before deleting.

## Get Info / metadata
```bash
osascript -e 'tell application "Finder" to open information window of (POSIX file "/path" as alias)'
stat -f '%z bytes %Sm' file ; du -sh path ; mdls file ; file file
mdls -name kMDItemWhereFroms file                 # download origin
xattr -l file ; xattr -d com.apple.quarantine file   # remove quarantine (user-approved)
GetFileInfo / SetFile not installed w/o Xcode CLT
```
## Tags & comments
```bash
mdls -name kMDItemUserTags file
xattr -w com.apple.metadata:_kMDItemUserTags '<?xml ...plist array...>' file     # painful; prefer:
brew install tag ; tag --add Red,Work file ; tag --list file ; tag --match Work /Users/me   # (tag not installed by default)
osascript -e 'tell application "Finder" to set comment of (POSIX file "/path" as alias) to "note"'
osascript -e 'tell application "Finder" to set label index of (POSIX file "/path" as alias) to 6'   # 0 none,1 orange,2 red,3 yellow,4 blue,5 purple,6 green,7 gray
```
## Shell file ops
```bash
mv a b ; cp -R src dst ; ditto src dst        # ditto preserves metadata/resource forks
mkdir -p ~/Projects/new ; touch f
cp -c file clone                               # APFS clone (instant)
ditto -c -k --sequesterRsrc --keepParent folder out.zip   # Finder-style zip
zip -r out.zip folder -x '*.DS_Store' ; unzip -q x.zip -d dest
tar -czf out.tgz folder ; tar -xzf x.tgz -C dest
hdiutil create -srcfolder dir out.dmg ; hdiutil attach x.dmg ; hdiutil detach /Volumes/X
ln -s target link
find ~/Downloads -type f -mtime +30 -maxdepth 1       # older than 30 days
find . -name '.DS_Store' -delete
du -sh * | sort -h | tail ; du -hd1 ~ | sort -h | tail
open -a Finder .   ;  open -a "Visual Studio Code" file ; open -a Preview x.pdf ; open -b com.apple.TextEdit f.txt
open -t file (default text editor);  open -e file (TextEdit)
```
## Spotlight (mdfind)
```bash
mdfind "invoice"                                  # content+name
mdfind -name "report.pdf"                         # name only
mdfind -onlyin ~/Documents "kMDItemKind == 'PDF Document'"
mdfind "kMDItemFSContentChangeDate >= \$time.today(-1)"   # modified in last day
mdfind "kMDItemContentTypeTree == 'public.image' && kMDItemFSSize > 5000000"
mdfind -0 -name x | xargs -0 ls -l
mdfind 'kMDItemLastUsedDate >= $time.this_week'
```
Spotlight disabled/not indexed (external vols) → `find`. Rebuild index: `sudo mdutil -E /` (admin).
## Quick Look / open
```bash
qlmanage -p file >/dev/null 2>&1 &     # preview window; kill with: killall qlmanage
qlmanage -t -s 512 -o /tmp file         # thumbnail PNG
osascript -e 'tell application "Finder" to open (POSIX file "/path" as alias)'   # open with default app
open -a "Google Chrome" https://x ; open -a Preview a.png b.png
```
## Common cleanup patterns
```bash
# Organize Downloads by extension (dry run first: echo mv)
cd ~/Downloads; for f in *.*; do [ -f "$f" ] || continue; e="${f##*.}"; mkdir -p "$e"; echo mv -n "$f" "$e/"; done
# Old installers
ls ~/Downloads/*.dmg ~/Downloads/*.pkg 2>/dev/null
# Big files
find ~ -type f -size +500M -not -path '*/Library/*' 2>/dev/null | head
# Clean up Desktop screenshots → folder
mkdir -p ~/Pictures/Screenshots; mv -n ~/Desktop/Screenshot*.png ~/Pictures/Screenshots/
# Caches (safe to regenerate): ~/Library/Caches ; brew cleanup ; npm cache clean --force
```
Always show the user the list before moving/deleting many files; use `mv -n` (no clobber); trash rather than rm.
## Disks
```bash
diskutil list ; diskutil info /Volumes/X
diskutil eject /Volumes/X                         # or: diskutil unmount /Volumes/X
osascript -e 'tell application "Finder" to eject disk "X"'
osascript -e 'tell application "Finder" to eject (every disk whose ejectable is true)'
ls /Volumes ; df -h
```
## iCloud / network
`ls ~/Library/Mobile\ Documents/com~apple~CloudDocs` = iCloud Drive. `brctl download file` forces download (unverified); `brctl evict`. SMB: `open smb://host/share`, `mount_smbfs`.
## AirDrop
No CLI/AppleScript API. Share file via UI: `open -R file` then `mpctl menu Finder "File > Share"` / Share button via `mpctl find Finder "Share"`; AirDrop window: `mpctl key cmd+shift+r` in Finder (opens AirDrop). Or Services: `open -a AirDrop`-style isn't available. Recipient must be picked by AX/click (last resort). Sharing via `shortcuts` "Share" action is possible if user has a shortcut.
## Smart folders/Show hidden
`defaults write com.apple.finder AppleShowAllFiles -bool true; killall Finder`. Finder toggles: `mpctl key cmd+shift+.` (frontmost Finder).
