# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Role

You are a senior macOS developer. The user is not a macOS expert — explain jargon, use plain language, and break complex concepts into clear steps. Code must be production-quality: correct entitlements, no hallucinated APIs, HIG-compliant. When unsure, ask rather than guess.

Minimum deployment target: **macOS 14 Sonoma** (set in Package.swift).
Target hardware: **M1 and above only** — no Intel legacy support.
Distribution: **Ad-hoc signed DMG, outside App Store** — no sandbox.

---

## Build & Run

All commands run from `TextRefiner/`:

```bash
# Build release .app bundle, generate AppIcon.icns, sign ad-hoc, reset TCC
./build.sh

# Run the built app
open TextRefiner.app

# Swift compile-check only (no .app bundle, no signing)
swift build -c release
```

`build.sh` resets Accessibility permission via `tccutil reset Accessibility com.textrefiner.app` on every build. This is intentional — ad-hoc signing produces a new binary hash each time, which macOS TCC treats as a new app identity. After running, the user must re-grant Accessibility in System Settings before the app will work.

There are no tests and no linter configured.

---

## Architecture

The app is a pure AppKit menu bar agent (`LSUIElement = true`, no Dock icon). No SwiftUI app lifecycle — it uses `main.swift` + `NSApplicationDelegate`.

**Data flow for a refinement:**
```
HotkeyManager (CGEvent tap)
  → RefinementCoordinator.startRefinement()
    → AccessibilityService.simulateCopyAndRead()   // Cmd+C + pasteboard poll
    → OllamaService.streamRewrite()                // POST /api/generate, NDJSON stream
    → AccessibilityService.pasteText()             // write clipboard + Cmd+V
  → AppDelegate callbacks (onProcessingStarted / onRefinementComplete / onProcessingFinished / onError)
    → StreamingPanelController (HUD: spinner → checkmark → dismiss)
    → menu bar NSProgressIndicator (spinner)
```

**Component responsibilities:**

| File | Role |
|---|---|
| `App/AppDelegate.swift` | Wires all components; owns menu bar item, spinner state, model submenu (build/refresh/select/download/delete), and all `NSAlert`s |
| `Core/RefinementCoordinator.swift` | Orchestrates the 5-step refinement flow; exposes callbacks to AppDelegate; owns `isProcessing` guard |
| `Core/AccessibilityService.swift` | Permission check (CGEvent tap as ground truth, not `AXIsProcessTrusted`); simulates Cmd+C and Cmd+V via `CGEvent` at HID level |
| `Core/HotkeyManager.swift` | Global CGEvent tap for configurable hotkey (default ⌘⇧R); reads keyCode/modifiers from `HotkeyConfiguration`; consumes the event; handles `tapDisabledByTimeout` |
| `Core/OllamaService.swift` | All Ollama REST calls (`/api/generate`, `/api/tags`, `/api/pull`, `/api/delete`); prompt injection via `{{USER_TEXT}}`; `cleanResponse()` post-processing |
| `Core/ModelManager.swift` | Curated list of 8 recommended models; persists selected model in `UserDefaults`; `fetchDownloadedModels()` queries Ollama live |
| `Core/PromptStorage.swift` | Active prompt + history (max 20 entries); persists to `~/Library/Application Support/TextRefiner/prompts.json` |
| `UI/OnboardingWindowController.swift` | First-launch setup: Accessibility grant (1.5s poll), auto-installs Ollama.app, auto-pulls model |
| `UI/StreamingPanelController.swift` | Frosted 56×56 `NSPanel` (.nonactivatingPanel — no focus steal); spinner → checkmark states |
| `UI/PromptSettingsWindowController.swift` | Prompt editor with history/revert UI |
| `UI/SettingsWindowController.swift` | Hotkey capture, launch-on-login toggle (SMAppService), developer rebuild-and-relaunch button |
| `UI/HistoryWindowController.swift` | Scrollable card UI for last 10 refinements; click-to-copy refined text |
| `Core/HotkeyConfiguration.swift` | Persists custom hotkey (keyCode + modifiers) in UserDefaults; validation, display formatting, conflict warnings |
| `Core/RefinementHistory.swift` | Singleton storing last 10 refinements (original, refined, model, timestamp); persists to `history.json` |
| `Utilities/NotificationManager.swift` | Wraps `UNUserNotificationCenter` |

---

## Critical Implementation Details

**Accessibility permission check** — `AXIsProcessTrusted()` is unreliable on macOS Ventura+ after rebuilds. `AccessibilityService.isTrusted()` creates a throwaway CGEvent tap as the ground truth test. Don't replace this with `AXIsProcessTrusted()`.

**CGEvent tap vs NSEvent monitor** — `HotkeyManager` uses `CGEvent.tapCreate` with `.defaultTap` (not `NSEvent.addGlobalMonitorForEvents`) so the hotkey event is consumed and never reaches the frontmost app. `NSEvent` monitors cannot suppress events.

**Ollama inference on main thread** — `RefinementCoordinator` runs the Ollama stream inside `Task.detached` (not `Task { @MainActor in }`) to keep inference off the main thread. On Apple Silicon with shared memory, running inference on main blocks the entire system. Do not move this to main.

**HUD panel** — `StreamingPanelController` uses `NSPanel` with `.nonactivatingPanel`. This is essential — an `NSWindow` would steal keyboard focus from the app the user is writing in.

**Pasteboard polling** — `simulateCopyAndRead()` polls `NSPasteboard.general.changeCount` for up to 500ms (10×50ms). The target app needs time to process the Cmd+C event before the pasteboard updates. Do not remove this poll.

**Post-processing** — `OllamaService.cleanResponse()` strips leaked prompt artifacts (closing anchor echo, delimiter leakage, preamble phrases, wrapping quotes). Called after full accumulation, not per-token.

**The active prompt** (`PromptStorage.shared.activePrompt`) and **selected model** (`ModelManager.shared.selectedModelID`) are read at call time inside `OllamaService`, so changes in Prompt Settings or the model submenu take effect on the next refinement without restarting.

**Model submenu refresh** — `AppDelegate` implements `NSMenuDelegate.menuWillOpen` to refresh download status each time the Model submenu opens. It rebuilds from a cached `downloadedModels: Set<String>`, then fires an async Ollama query to update the cache. This avoids blocking the UI on a network call.

**Configurable hotkey** — `HotkeyManager` reads keyCode and modifiers from `HotkeyConfiguration.shared` on every event (not cached at tap creation). When the user saves a new hotkey in Settings, `AppDelegate` calls `hotkeyManager.stop()` then `hotkeyManager.start()` to re-register the CGEvent tap. No app restart needed.

**Developer rebuild button** — `SettingsWindowController` has a "Rebuild & Relaunch" button that runs `build.sh` via `Process`, then launches the new `TextRefiner.app` and terminates the current instance. This is a dev convenience — `build.sh` still resets TCC, so Accessibility must be re-granted after each rebuild.

---

## Key Locked Decisions (don't revisit without discussion)

- **Default hotkey: ⌘⇧R** (keyCode 15). Changed from ⌘⇧E — ⌘⇧R confirmed to not conflict with common apps. Note: `TextRefiner_PRD_V2.txt` documents the reverse — that's stale; the code is the source of truth.
- **No sandbox** — Accessibility API + paste simulation requires it. Distributing as ad-hoc DMG.
- **No Dock icon** — `LSUIElement = true` in Info.plist.
- **Prompt template** — must contain `{{USER_TEXT}}`; uses `[TEXT_START]`/`[TEXT_END]` delimiters for injection protection. The active default is in `PromptStorage.defaultPrompt`. Don't change the structure without validating against the target model.
- **Default model: `llama3.2:3b`** — balance of speed and quality. Full curated list in `ModelManager.recommendedModels` (8 models, 1B to 20B).

---

## Current State (v1.1 in progress)

**v1.1 complete:**
- Settings window with hotkey configuration, launch on login, and developer rebuild button
- Custom hotkey configuration (key-capture control, live CGEvent tap re-registration)
- Launch on login toggle (SMAppService)
- Refinement history panel (last 10 entries, persisted, click-to-copy)
- Model submenu with download, select, and delete per model
- Prompt Settings window with history and revert

**v1.1 remaining:**
- Refinement Levels (Level 1: grammar fix, Level 2: restructure, Level 3: full rewrite)
- Cloud LLM fallback (OpenAI / Anthropic)
- Onboarding revamp (5-step walkthrough with interactive demo)

Full v1.1 specs are in `TextRefiner_PRD_V2.txt` under `SUGGESTED V1.1 ADDITIONS`.

---

## Resources & Persistence

- `Resources/Info.plist` — bundle ID `com.textrefiner.app`, `LSUIElement = true`
- `Resources/TextRefiner.entitlements` — no sandbox; Accessibility entitlement
- `Resources/AppIcon.png` — source icon; `build.sh` converts to `AppIcon.icns` via `sips` + `iconutil`
- `UserDefaults` keys: `com.textrefiner.onboardingCompleted`, `com.textrefiner.selectedModel`, `com.textrefiner.hotkeyKeyCode`, `com.textrefiner.hotkeyModifierFlags`
- Prompt history: `~/Library/Application Support/TextRefiner/prompts.json`
- Refinement history: `~/Library/Application Support/TextRefiner/history.json`
