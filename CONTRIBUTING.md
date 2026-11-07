# Contributing

Contributions are welcome — bug fixes, new playbook recipes, new `mpctl` commands, UI polish.

1. Fork and create a branch: `git checkout -b feat/my-change`
2. Build: `swift build` (app + `mpctl`) or `scripts/build-app.sh`
3. Keep changes focused; test on macOS 14+ (Apple Silicon).
4. Playbook recipes (`Resources/playbook/*.md`): prefer shell/AppleScript first, `mpctl` AX second, screenshots last. Mark anything unverified.
5. Open a pull request describing what and why.

**Never commit** API keys, tokens, Claude login data, personal paths or screenshots of your screen.
By contributing you agree your work is released under the MIT License.
