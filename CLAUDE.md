# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Role

You are a senior macOS developer. The user is not a macOS expert — explain jargon, use plain language, and break complex concepts into clear steps. Code must be production-quality: correct entitlements, no hallucinated APIs, HIG-compliant. When unsure, ask rather than guess.

Minimum deployment target: **macOS 14 Sonoma** (set in Package.swift).
Target hardware: **M1 and above only** — no Intel legacy support.
Distribution: **Ad-hoc signed, outside App Store** — no sandbox. Updates via Sparkle.

---

## Preferences / Conventions

**Communication style — keep it simple and brief.**

Unless the user explicitly asks for a technical explanation, all responses must:
- Use plain, everyday language — no technical terms, code references, or file names unless specifically requested
- Explain any problem in two parts only: (1) what is happening, (2) why it matters to the user
- Stay under 300 words — if a complete answer cannot fit within that limit, stop and ask the user for clarification on what they need before continuing

**`PROBLEMS_AND_SOLUTIONS.md` is a non-technical bug log, not a developer reference.**

When a bug is reported or discovered, add an entry with: what the user observes (symptoms), and clear steps to reproduce it. Do NOT include root cause analysis, code-level explanations, or fix instructions. The file is for tracking reproducible issues — understanding how a bug surfaces, not how it was solved. Keep entries in plain language a non-developer could follow.

**Code quality standards.**

All code produced in this project must meet these standards:

- **Clean code first** — code must be readable, well-structured, and pass review by an experienced Swift/macOS developer. Naming, structure, and logic should be idiomatic for the language and platform.
- **Do it the right way** — don't just make it work; make it correct. Reuse and extend existing code where appropriate. Introduce new abstractions only when they're genuinely warranted.
- **Ask, don't guess** — if something is unclear, a requirement is ambiguous, or a decision could go multiple ways, stop and ask before writing code. Never assume or invent behavior.
- **No hallucination** — never reference APIs, flags, functions, or behaviors that haven't been verified to exist. If unsure whether something exists, say so and look it up or ask.

---

## Agent Capabilities

*This section declares what Claude can and cannot do autonomously in this project. It will grow over time as boundaries are established through collaboration. Nothing here yet.*

---

## Build & Run

All commands run from `TextRefiner/`:

```bash
# Dev build: .app bundle, ad-hoc sign, TCC reset, dev bundle ID
./build.sh

# Release build: .app bundle, ad-hoc sign, NO TCC reset, creates .zip + EdDSA signature
./build.sh release

# Run the built app
open TextRefiner.app

# Swift compile-check only (no .app bundle, no signing)
swift build -c release
```

Dev builds use `Info-Dev.plist` (bundle ID `com.textrefiner.app.dev`) and reset TCC on every build — Accessibility must be re-granted after each build.

Release builds use `Info.plist` (bundle ID `com.textrefiner.app`) with Sparkle config and do NOT reset TCC.

**Critical non-obvious step:** `build.sh` manually compiles all MLX `.metal` shader files into `mlx.metallib` and places it in `Contents/MacOS/`. SPM cannot do this. Without it the app crashes on launch. See `PROBLEMS_AND_SOLUTIONS.md` #11 for full detail.

There are no tests and no linter configured.

---

## Architecture

The app is a pure AppKit menu bar agent (`LSUIElement = true`, no Dock icon). No SwiftUI app lifecycle — it uses `main.swift` + `NSApplicationDelegate`.

**Data flow for a refinement:**
```
HotkeyManager (CGEvent tap)
  -> RefinementCoordinator.startRefinement()
    -> AccessibilityService.simulateCopyAndRead()   // Cmd+C + pasteboard poll
    -> LocalInferenceService.streamRewrite()         // MLX on-device inference (Task.detached)
    -> AccessibilityService.pasteText()              // write clipboard + Cmd+V
  -> AppDelegate callbacks (onProcessingStarted / onRefinementComplete / onProcessingFinished / onRefinementCancelled / onError)
    -> StreamingPanelController (HUD: spinner -> checkmark -> dismiss, or 5s error HUD for inputTooLong)
    -> menu bar NSProgressIndicator (spinner)
  Escape key during processing -> HotkeyManager.onEscapePressed -> RefinementCoordinator.cancelRefinement() -> onRefinementCancelled
```

---

## Key Locked Decisions (don't revisit without discussion)

- **Default hotkey: Cmd+Shift+R** (keyCode 15). Changed from Cmd+Shift+E — confirmed to not conflict with common apps.
- **No sandbox** — Accessibility API + paste simulation requires it. Distributing as ad-hoc signed app.
- **No Dock icon** — `LSUIElement = true` in Info.plist.
- **Prompt template** — must contain `{{USER_TEXT}}`; uses `[TEXT_START]`/`[TEXT_END]` delimiters for injection protection. The active default is in `PromptStorage.defaultPrompt`. Don't change the structure without validating against the target model.
- **Single model: `mlx-community/Llama-3.2-3B-Instruct-4bit`** — embedded MLX inference, no Ollama dependency. Model download on first launch; stored in `~/Library/Application Support/TextRefiner/models/`.
- **Ad-hoc signing** — no Apple Developer account. TCC resets after every update; handled by post-update re-grant flow. This is the permanent distribution model — do not suggest Apple Developer ID as a solution.

---

## Critical Implementation Details

**Accessibility permission check** — `AXIsProcessTrusted()` is unreliable on macOS Ventura+ after rebuilds. `AccessibilityService.isTrusted()` creates a throwaway CGEvent tap as the ground truth test. Don't replace this with `AXIsProcessTrusted()`.

**CGEvent tap vs NSEvent monitor** — `HotkeyManager` uses `CGEvent.tapCreate` with `.defaultTap` (not `NSEvent.addGlobalMonitorForEvents`) so the hotkey event is consumed and never reaches the frontmost app. `NSEvent` monitors cannot suppress events.

**MLX inference off main thread** — `RefinementCoordinator` runs inference inside `Task.detached` (not `Task { @MainActor in }`) to keep it off the main thread. On Apple Silicon with shared memory, running inference on main blocks the entire system. Do not move this to main.

**HUD panel** — `StreamingPanelController` uses `NSPanel` with `.nonactivatingPanel`. This is essential — an `NSWindow` would steal keyboard focus from the app the user is writing in.

**Pasteboard polling** — `simulateCopyAndRead()` polls `NSPasteboard.general.changeCount` for up to 500ms (10x50ms). The target app needs time to process the Cmd+C event before the pasteboard updates. Do not remove this poll.

**Post-processing** — `LocalInferenceService.cleanResponse()` strips leaked prompt artifacts (closing anchor echo, delimiter leakage, preamble phrases, wrapping quotes). Called after full accumulation, not per-token.

**Prompt injection sanitization** — `LocalInferenceService.streamRewrite()` strips `[TEXT_START]`, `[TEXT_END]`, and `{{USER_TEXT}}` from the clipboard text before injection. This prevents crafted clipboard content from breaking the prompt structure or echoing delimiters into the output.

**Escape-to-cancel** — `HotkeyManager.onEscapePressed` is `nil` by default so Escape passes through to the frontmost app. `AppDelegate.wireCoordinator()` sets it to `coordinator.cancelRefinement()` only when `onProcessingStarted` fires, and clears it to `nil` in `onProcessingFinished`, `onRefinementCancelled`, and `onError`. `RefinementCoordinator` stores the active `Task` as `refinementTask` and calls `.cancel()` on it; the task checks `Task.checkCancellation()` at each async boundary. Do not intercept Escape globally — only during active processing.

**Input length limit** — `RefinementCoordinator.maxInputCharacters = 10_000`. Inputs over this limit throw `RefinementError.inputTooLong`, which `AppDelegate` routes to `StreamingPanelController.showInputLimitError()` (a 200×80 error HUD with a 5s countdown bar) rather than an `NSAlert`. `TypingMonitor.checkAndNotify()` uses this same constant as an upper bound — the ready pill is hidden when the character count exceeds the limit.

**Debug-only logging** — All `print` statements in `TypingMonitor` are wrapped in `#if DEBUG` so release builds produce no stdout spam. Dev builds still emit full diagnostic output to Terminal.

**The active prompt** (`PromptStorage.shared.activePrompt`) and **model ID** (`ModelManager.shared.selectedModelID`) are read at call time inside `LocalInferenceService`, so changes in Prompt Settings take effect on the next refinement without restarting.

**Configurable hotkey** — `HotkeyManager` reads keyCode and modifiers from `HotkeyConfiguration.shared` on every event (not cached at tap creation). When the user saves a new hotkey in Settings, `AppDelegate` calls `hotkeyManager.stop()` then `hotkeyManager.start()` to re-register the CGEvent tap. No app restart needed. `ReadyIndicatorController.updateHotkey()` is also called so the pill label reflects the new shortcut immediately.

**Typing indicator** — `TypingMonitor` uses two layers of observation: (1) `NSWorkspace.didActivateApplicationNotification` for app switches, (2) a per-app `AXObserver` (created with the frontmost app's actual PID) watching `kAXFocusedUIElementChangedNotification`, plus (3) a per-element `AXObserver` watching `kAXValueChangedNotification`. Character count is read via `kAXNumberOfCharactersAttribute` with fallback to `kAXValueAttribute` string length. The indicator shows immediately when count >= 40 chars (~7 words) and hides the moment the hotkey fires. Togglable via Settings (`com.textrefiner.showTypingIndicator`, defaults to `true`).

**Developer rebuild button** — `SettingsWindowController` has a "Rebuild & Relaunch" button that runs `build.sh` via `Process`, then launches the new `TextRefiner.app` and terminates the current instance. This is a dev convenience — `build.sh` still resets TCC, so Accessibility must be re-granted after each rebuild.

---

## Pre-Release Checklist

**The hotkey is the entire product. Never ship an update without verifying it works.**

Before every release (`./build.sh release`), run through this checklist on the dev build:

1. **Build dev** — `./build.sh` (TCC is reset automatically)
2. **Re-grant Accessibility** — System Settings → Privacy & Security → Accessibility → toggle TextRefiner ON
3. **Verify the hotkey fires** — open TextEdit, type a sentence, select it, press the configured hotkey. Confirm the spinner appears and text is refined.
4. **Verify the onboarding tap gate** — simulate a fresh user: `tccutil reset Accessibility com.textrefiner.app.dev`, relaunch, go through onboarding page 1. The "Next" button must not enable until Accessibility is granted AND the CGEvent tap is successfully created. If it lets you click "Next" without a working tap, something is broken.
5. **Update `CHANGELOG.md`** — add an entry for the new version before building. User-facing language only; no code or technical detail.
6. **Only then** bump the version and run `./build.sh release`.

**Why this matters:** The CGEvent tap is the only mechanism that makes the hotkey work. Every ad-hoc build produces a new CDHash, which invalidates the TCC entry. If the tap silently fails and no one catches it before release, every user who updates will have a broken hotkey.

---

## Current State (v1.1.8)

**v1.1 complete:**
- Settings window with hotkey configuration, launch on login, and developer rebuild button
- Custom hotkey configuration (key-capture control, live CGEvent tap re-registration)
- Launch on login toggle (SMAppService)
- Refinement history panel (last 10 entries, persisted, click-to-copy)
- Prompt Settings window with history and revert
- In-app auto-updates via Sparkle (Check for Updates menu item + 24h background checks)
- Dev/release build modes with separate bundle IDs
- Typing indicator — floating hotkey pill appears near focused text field when ~7+ words are typed; works in Chrome/Electron via 500ms polling fallback; togglable in Settings
- **Embedded MLX inference** — on-device Llama 3.2 3B via Apple MLX; no Ollama dependency; model auto-download on first launch; hardware compatibility gate in onboarding
- **Hotkey guardrails** — onboarding blocks on page 1 until the real CGEvent tap is confirmed created; any tap failure at any launch shows an immediate actionable alert
- **Comprehensive hotkey hardening (v1.1.7)** — 21 stress-test scenarios fixed; all documented in `HOTKEY_STRESS_TEST.md`
- **Accessibility registration fix (v1.1.8)** — proactive `AXIsProcessTrustedWithOptions` call ensures the app appears in Accessibility settings after every update

**In progress (post-v1.1.8, not yet released):**
- **Escape-to-cancel** — Escape key during processing cancels inference and restores the app to idle state; no text is pasted
- **Input length limit** — 10,000 character cap enforced before inference; over-limit selections show a 5s error HUD (not an alert)
- **Prompt injection hardening** — clipboard content stripped of delimiter strings before template injection

**v1.2 roadmap:** Tone-Adaptive Refinement (system prompt auto-detects text tone, no manual mode selection), polished HUD animations, instant paste, audio feedback, privacy messaging ("100% local"), performance optimization for M1/8GB baseline. Full specs in `TextRefiner_PRD_V2.txt`.

---

## Key Resources

- **Appcast Gist:** `gh gist edit 6a5dacdb24a6bae85d003e906f5fa907` — live Sparkle update feed
- **UserDefaults keys:** `com.textrefiner.onboardingCompleted`, `com.textrefiner.lastOnboardedBuild`, `com.textrefiner.hotkeyKeyCode`, `com.textrefiner.hotkeyModifierFlags`, `com.textrefiner.showTypingIndicator`
- **Data on disk:** prompt history → `prompts.json`, refinement history → `history.json`, model weights → `models/` — all under `~/Library/Application Support/TextRefiner/`
- **Security audit:** `SECURITY.md` (repo root) — latest automated audit results (overwritten each run by the daily scheduled task)

---

## Knowledge Base (memory-compiler)

A compiled knowledge base lives in `memory-compiler/`. It captures decisions, lessons, and project direction across sessions.

**Structure:**
- `memory-compiler/daily/` — raw session logs (append-only, one file per day)
- `memory-compiler/knowledge/` — compiled articles (concepts, connections, Q&A)
- `memory-compiler/knowledge/index.md` — master catalog, read by SessionStart hook
- `memory-compiler/AGENTS.md` — full schema for article formats, tag conventions, compile rules
- `memory-compiler/COMMANDS.md` — all available commands (in-chat and terminal)

**Workflow (all manual except SessionStart):**
- **SessionStart hook** — automatic. Injects KB index, file paths, and daily log format into every session.
- **Daily log** — user says "update the daily log." Claude appends a structured entry to `memory-compiler/daily/YYYY-MM-DD.md`.
- **Compile** — user says "compile." Claude runs `~/.local/bin/uv run --directory memory-compiler python scripts/compile.py` to turn daily logs into knowledge articles.
- **Query** — `~/.local/bin/uv run --directory memory-compiler python scripts/query.py "question"` to ask the KB directly.
- **Lint** — `~/.local/bin/uv run --directory memory-compiler python scripts/lint.py --structural-only` to health-check the KB.

**Key rules:**
- Daily logs capture decisions, lessons, and discoveries — not routine edits or build output
- CLAUDE.md is the operational reference (build, architecture, what not to break). The KB is the project memory (what happened, why, what's planned).
- Don't duplicate between CLAUDE.md and the KB — they serve different purposes.

---

## Problems & Solutions

> A living record of what broke and how it was fixed lives in `PROBLEMS_AND_SOLUTIONS.md`.
> Check it before implementing any feature or fix to avoid repeating past mistakes.
> Add new entries there when a non-obvious problem is diagnosed and resolved.
