<div align="center">

# ✨ MacPilot

**Talk to your Mac. It does the work — behind the scenes.**

A macOS menu-bar AI assistant powered by **your own Claude Code login** — no API key needed.

![platform](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![swift](https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white)
![license](https://img.shields.io/badge/license-MIT-blue)
![PRs](https://img.shields.io/badge/PRs-welcome-brightgreen)

*Inspired by [farzaa/clicky](https://github.com/farzaa/clicky).*

</div>

---

## 🪄 What it does

Say or type what you want:

> *"Turn on dark mode"* · *"Move my Downloads screenshots into a folder"* ·
> *"Close all YouTube tabs in Chrome"* · *"Set volume to 20%"* · *"What's on my calendar today?"*

MacPilot hands the request to Claude Code, which controls your Mac the **fastest reliable way** and tells you what it did.

## 🧠 How it works

```
MacPilot.app ──spawns──▶ claude -p  (stream-json, your login)
                              │
                              ├─ 1. shell · osascript · defaults · open …   fast, invisible
                              ├─ 2. mpctl menu | find | press | set          Accessibility, no mouse
                              └─ 3. mpctl screenshot + click / type          last resort
```

| Layer | Where | Purpose |
|---|---|---|
| App | `Sources/MacPilot/` | Floating chat panel, settings, hotkey, voice, click overlay |
| `mpctl` | `Sources/mpctl/` | Helper CLI for Accessibility, input & screenshots (`mpctl help`) |
| Playbook | `Resources/playbook/` | Recipes Claude reads for System Settings, Finder, Chrome, Notes, Music… |

## 🚀 Features

- **Hotkey** — tap **⌃⌥** for chat; **hold** it for voice with a live waveform.
- **Voice in** — offline Whisper (whisper.cpp), Groq Whisper, or Apple Speech.
- **Voice out** — answers spoken only when useful.
- **Background control** — Accessibility actions work on windows you aren't looking at.
- **Visual feedback** — a highlight ring shows where it acts.
- **Screenshot attach** — 📷 sends your screen with a message (optional).
- **Private** — runs `claude` in its own workspace so transcripts never mix with yours.

## 📦 Install & build

Requires macOS 14+, Apple Silicon, Swift toolchain (Command Line Tools are enough), and [Claude Code](https://claude.com/claude-code) logged in.

```bash
git clone https://github.com/himanshudev28/name-clicky.git
cd name-clicky
scripts/build-app.sh              # → build/MacPilot.app
scripts/build-app.sh --install    # also copy to /Applications and launch
scripts/create-signing-identity.sh   # optional: keeps permissions across rebuilds
```

Grant permissions when asked: Accessibility, Screen Recording, Microphone, Speech, Automation.

### Optional offline voice

```bash
brew install whisper-cpp
mkdir -p ~/Library/Application\ Support/MacPilot/Models
curl -L -o ~/Library/Application\ Support/MacPilot/Models/ggml-small-q5_1.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin
```

## ⚙️ Settings

General · Claude (model, effort, safety mode, Chrome extension, max steps, custom instructions) · Voice · Permissions · Storage (clear screenshots & history).

## 🔐 Privacy & safety

- No API key is stored for Claude — it uses your local `claude` login. Optional keys (e.g. Groq) live in the macOS **Keychain**, never in the repo.
- "Full control" runs commands without asking (like `--dangerously-skip-permissions`). Switch to **Auto-check risky actions** in Settings › Claude for a safety check.
- Use it for your own Mac with your own login; don't build a service that routes other people through one account.

## 🤝 Contributing

PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Great first contributions: new playbook recipes, `mpctl` improvements, bug fixes.

## 📄 License

[MIT](LICENSE) — free to use, modify and share.
