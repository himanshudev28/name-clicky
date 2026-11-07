# MacPilot code review

Scope: `Sources/MacPilot/*.swift` (read in full). Nothing was built or run for this review; each finding comes from reading the code. Where a finding depends on macOS or CLI behaviour I couldn't check here, it says "verify". Ranked by severity.

## High

### 1. Stale output from a replaced or killed `claude` process leaks into the current chat
`ClaudeSession.swift:136-155, 171-177, 91-98, 218-246`

`ingest()` and `handle()` don't check which process an event came from. `stdoutBuffer` is only reset in `startProcess` (line 167), after `p.run()`. `stopProcess()` and `newChat()` set `process = nil`, but chunks already queued with `DispatchQueue.main.async` still run, and the dying process can flush more.

Failure scenario:
- The user clicks "New chat" (the button isn't disabled while busy) while Claude is streaming.
- A late `system/init` runs `setSession(oldId)`, which writes the old id back to `lastSessionId` and `sessionId`.
- The next message then `--resume`s the conversation the user just discarded.
- Late `assistant` and `stream_event` chunks also land as rows in the fresh chat.
- A late `result` sets `isBusy = false` while the new process is mid-turn.

The same thing happens on a settings-change restart, and after `stop()`, where text appears below "Stopped.".

Fix:
- Add `private var generation = 0` and bump it in `stopProcess()` and `startProcess()`.
- Capture `let gen = generation` in the three handlers.
- Drop the chunk when `gen != self.generation`: `DispatchQueue.main.async { MainActor.assumeIsolated { guard let self, gen == self.generation else { return }; self.ingest(chunk) } }`.
- Also clear `stdoutBuffer`, `streamingItemIndex`, `streamedMessageIds` and `currentMessageId` inside `stopProcess()`.

### 2. A dead `--resume` session id fails forever
`ClaudeSession.swift:43, 122, 179-196`

`lastSessionId` is persisted and passed as `--resume` on every spawn. If that session is gone (transcript cleaned up, never written because the process was killed before its first flush, or a different CLI profile), `claude` exits immediately with something like "No conversation found with session ID…".

Failure scenario:
- `processEnded` shows the error.
- `sessionId` is never cleared.
- Every later message restarts, fails the same way and shows the same error until the user finds "New chat".
- This is plausible at app launch, where the init text says "Continuing your last conversation".

Fix: in `processEnded`, if the process died and `sessionId != nil` and stderr matches `/no conversation found|session/i`, then:
- call `setSession`-style clearing (`sessionId = nil` and remove the UserDefaults key);
- append an info row ("Couldn't resume; starting a new conversation");
- optionally resend the last user text once.

### 3. Stop kills the process instead of interrupting the turn
`ClaudeSession.swift:82-89`

`stop()` sends SIGTERM and then `--resume`s on the next message.
- Every Stop costs a full CLI cold start on the next send.
- A kill mid-tool-call can leave a transcript with a `tool_use` and no `tool_result`. Depending on the CLI version, resuming that gives an API 400 ("tool_use ids … without tool_result"), and then finding 2 applies. Verify.
- Child processes of a running Bash tool can be orphaned.

Fix: write a control request to stdin and keep the process alive: `{"type":"control_request","request_id":"<uuid>","request":{"subtype":"interrupt"}}\n`. Wait for the resulting `result` event, which `handleResult` already handles. Fall back to `stopProcess()` after about 3 s if no `result` arrives. Verify the exact shape against the installed CLI's stream-json input.

### 4. The hotkey probably needs Input Monitoring, which the app never requests
`HotkeyMonitor.swift:41-47`, `Permissions.swift`, `SettingsView.swift:48, 173`

The tap is `.listenOnly` on `.keyDown` and `.flagsChanged`. On macOS 10.15 and later, listen-only keyboard taps are gated by Input Monitoring (`kTCCServiceListenEvent`). Active taps are the ones gated by Accessibility. The code, the Settings text and the permission rows all say "Accessibility". Verify on a clean user account.

Failure scenario:
- `tapCreate` returns nil, or a tap is created that never receives events.
- The poller (`AppDelegate.swift:47`) retries `start()` every 2 s forever.
- The user is never told what's missing, and the Permissions tab shows Accessibility as granted.

Fix:
- Add `Permissions.inputMonitoring` (`CGPreflightListenEventAccess()`) and `requestInputMonitoring()` (`CGRequestListenEventAccess()`, then open `Privacy_ListenEvent`).
- Add a row to the Permissions tab.
- Call `CGRequestListenEventAccess()` the first time `start()` fails.

### 5. The `.stream_event` handler ignores `parent_tool_use_id`, so sub-agent text appears as main-thread text
`ClaudeSession.swift:235-274` (`handleAssistant` filters at line 278; `handleStreamEvent` doesn't)

When Claude uses `Task`/`Agent`, the sub-agent's partial messages arrive as `stream_event`s carrying a non-null `parent_tool_use_id`.

Failure scenario:
- Sub-agent `message_start` overwrites `currentMessageId`.
- Sub-agent `text_delta`s are rendered as the assistant's reply.
- Because `streamedMessageIds` now contains the sub-agent's id, nothing is suppressed incorrectly, but the chat is full of helper chatter.
- When the main message's own deltas resume, `currentMessageId` can point at the wrong message (a new streaming row is created under a different key).

Fix: at the top of `handle(_:)` (or in the `stream_event` case), do `if let p = e["parent_tool_use_id"], !(p is NSNull) { return }`. Also do this for `user` tool_result events, to avoid resetting `statusText` from helper traffic.

## Medium

### 6. Two queued messages: the first `result` clears busy and Stop while the second is still running
`ChatView.swift:167` (`.onSubmit(submit)` stays active while busy), `ClaudeSession.swift:51-79, 314-317`

The TextField still submits when `isBusy` is true. The CLI accepts the second user message and runs two turns, so two `result` events arrive. After the first, `isBusy = false`, the Stop button disappears and the status says "Done" while the second turn runs. A late `finishRunningTools(as: .ok)` also mislabels live tools.

Fix: keep `private var pendingTurns = 0`.
- Increment it on a successful stdin write.
- Decrement it in `handleResult`.
- Set `isBusy = pendingTurns > 0`.
- Reset it in `stopProcess()`.

Alternatively, disable submit while busy.

### 7. `VoiceController.startListening` crashes on an invalid input format
`VoiceController.swift:48-53`

`input.outputFormat(forBus: 0)` has `sampleRate == 0` or `channelCount == 0` when there is no input device, mic access is denied/restricted, or a Bluetooth device is switching. `installTap` with that format raises an Objective-C exception ("IsFormatSampleRateAndChannelCountValid"), which Swift can't catch, so the app crashes.

Fix:
```swift
guard format.sampleRate > 0, format.channelCount > 0 else { lastError = "No microphone input available."; return }
```
Also call `engine.reset()` before reuse if the config changed. Optionally observe `.AVAudioEngineConfigurationChange` and stop cleanly.

### 8. Overlapping voice sessions: a stale recognizer callback cancels the new one
`VoiceController.swift:64-98`

After `stopListening`, `finalHandler` stays set until a result or the 1.5 s timeout. If the user triggers listening again within that window, `startListening` reassigns `request` and `task`, but the old task's callback and the old 1.5 s `asyncAfter` are still live.

Failure scenario:
- The old callback calls `deliverFinal()`.
- That hands session B's transcript to session A's handler, so it is sent as the message.
- It also runs `task?.cancel()` on B's task and nils `request`.
- B then silently produces nothing.

Fix:
- Give each session a token (`let session = UUID(); currentSession = session`) and ignore callbacks and timeouts where `session != currentSession`.
- In `startListening`, if `finalHandler != nil`, call `deliverFinal()` first so the old session is closed before the new one starts.

### 9. A recognizer error mid-listen leaves the UI in "Listening…" with a dead task
`VoiceController.swift:64-74`

When the task errors while the user is still recording (error 1110 "no speech", network, or a recognizer limit around 1 minute), `deliverFinal()` returns early because `finalHandler == nil`. `isListening` stays true, the engine keeps running and `task` is dead. The transcript silently stops growing.

Fix: in the callback, if `error != nil && isListening`, tear down the engine and tap, set `isListening = false`, set `lastError`, and (if `transcript` is non-empty) deliver it through the same path as release.

### 10. Hotkey state can stick after a disabled tap or a lost key-up
`HotkeyMonitor.swift:87-88`

On `.tapDisabledByTimeout` / `.tapDisabledByUserInput` the tap is re-enabled but state isn't reset. If the release `flagsChanged` was missed (screen lock, secure input, the tap being disabled while holding), then:
- `comboDown` and `holdActive` stay true;
- the mic stays open (`onHoldEnd` is never called) until some other modifier change happens.

Fix:
```swift
case .tapDisabledByTimeout, .tapDisabledByUserInput:
    if holdActive { onHoldEnd?() }
    reset()
    if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
```

### 11. Adding a third modifier after Ctrl+Option counts as a tap
`HotkeyMonitor.swift:106-112`

Pressing Ctrl+Option and then Shift or Cmd within 0.35 s with no `keyDown` makes `combo` false. That is treated as a clean release, so `onTap` toggles the panel. It happens when someone starts a modifier-only chord such as Ctrl+Opt+Cmd.

Fix: track "extra modifiers seen" — if `flags` contains cmd or shift while `comboDown`, set `otherKeyPressed = true`.

### 12. `startProcess` can race with `terminationHandler` data
`ClaudeSession.swift:152-155, 179-196`

The termination handler and the stdout drain are independent. If `claude` exits right after printing `result`, `processEnded` can run first, `isBusy` is still true, and the user sees "stopped unexpectedly" followed by the real answer.

Fix: in `processEnded`, wait one main-queue hop (`DispatchQueue.main.asyncAfter(deadline: .now() + 0.15)`) before deciding it was unexpected. Re-check `isBusy` and generation afterwards.

## Low / hardening

### 13. SIGPIPE can terminate the app
`ClaudeSession.swift:72`, `main.swift`

If `claude` died but `processEnded` hasn't run yet (or stdin was closed), `write(contentsOf:)` on the broken pipe raises SIGPIPE first. The default action kills MacPilot instead of reaching your `catch`. AppKit doesn't ignore it for you.

Fix: `signal(SIGPIPE, SIG_IGN)` at the top of `main.swift`.

### 14. The audio tap closure may inherit `@MainActor`
`VoiceController.swift:51`

The closure is created inside a `@MainActor` method and passed to a non-`Sendable` API, so it is inferred as main-actor-isolated while AVFoundation calls it on a realtime thread. It is fine today in Swift 5 mode (no runtime check), but it will trap if the package moves to Swift 6 mode.

Fix: build it in a `nonisolated static func makeTap(_ request:) -> AVAudioNodeTapBlock`.

### 15. `applicationWillTerminate` doesn't stop an idle `claude`
`AppDelegate.swift:66-68`, `ClaudeSession.swift:82-83`

`stop()` has `guard isBusy`, so quitting while idle leaves the process to exit on stdin EOF (works, slowly). Quitting while busy kills only the CLI, not its tool children.

Fix: add `func shutdown()` that calls `stopProcess()` unconditionally, and use it here.

### 16. `lastVoiceTurn` can stay true
`AppDelegate.swift:132, 31-35`

It is only reset in `onTurnFinished`, which isn't called for error results, a Stop, or an unexpected exit. The next typed reply is then spoken aloud.

Fix: reset it in `ClaudeSession` error and stop paths (add an `onTurnEnded` callback), or key it off the turn instead of a flag.

### 17. A screenshot send shows nothing for about a second
`AppDelegate.swift:72-90`

`draft` is cleared immediately, but the user row is only appended after `captureScreen()` finishes, so the message vanishes. A second submit in that window sends twice.

Fix: have `ClaudeSession.send` accept the screenshot path later, or append the user row and set `isBusy` first.

### 18. Cmd+W beeps on the panel
`AppDelegate.swift:199`, `PanelController.swift:6`

The panel is borderless with no `.closable`, so `performClose:` fails. Fix: handle `w` in `KeyablePanel.performKeyEquivalent` with `orderOut(nil)`.

### 19. Smaller items
- `SettingsView.swift:209` — `.id(tick)` rebuilds the whole Permissions form every 1.5 s, which resets scroll and any pressed state. Poll into `@State` booleans instead.
- `HotkeyMonitor.swift:99` — the hold `Timer` is scheduled in default run-loop mode, so it doesn't fire while a menu or the panel drag is tracking. Use `RunLoop.main.add(timer, forMode: .common)`.
- `ClaudeSession.swift:123` — `extraArgs.split(" ")` has no quote handling, so `--flag "a b"` is split wrongly.
- `ClaudeSession.swift:148` — stderr is decoded per chunk, so a chunk boundary inside a multi-byte character yields U+FFFD (cosmetic).
- `VoiceController.swift:86` — a fixed 1.5 s final-result timeout can cut off the last words with server-side recognition. Partial text is already kept, so the impact is small.

## Checked and fine
- Event shapes handled: `system/init` (session id), `stream_event` with `message_start`, `content_block_start` and `content_block_delta` `text_delta` (keyed by `msgId#index`), `assistant` blocks (text skipped if streamed, `tool_use` deduplicated), `user` `tool_result` with `is_error`, and `result` with `is_error`, `errors` and `subtype`. The newline framing and partial-line buffering in `ingest` are correct, and the `Data` slice is safe after `removeSubrange`.
- Pipe handlers are `@Sendable` and hop to main via `DispatchQueue.main` plus `assumeIsolated`, which is valid. The event-tap callback runs on the main run loop, so its `assumeIsolated` is valid. The overlay's coordinate conversion (CG top-left to AppKit bottom-left) and its ring centering are correct.
- `Info.plist` has the microphone, speech and Apple-events usage strings and `LSUIElement`.
- The process-replacement guard `proc === process` correctly ignores terminations of processes already replaced (but see finding 1 for the output side).
