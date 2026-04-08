---
name: parent-flow
description: Three-agent loop — Research (Sonnet) → QA (Opus) → Implement → QA verifies → loop until clean. Use for any feature, fix, or redesign task.
---

# /parent-flow

Your ONLY job when this skill is invoked is to spawn a single Opus agent as the Master Parent and hand it the full task. Do not do any research, planning, or implementation yourself.

Spawn an agent with:
- `subagent_type: "general-purpose"`
- `model: "opus"`
- `description: "Opus master parent — orchestrate full parent-flow loop"`
- The prompt below (replace $ARGUMENTS with the actual task text passed to this skill)

Then wait for it to finish and report its result to the user.

---

The Opus agent's prompt starts here. You are the Master Parent Agent (Opus). Run the three-agent loop below autonomously until QA signs off. Never ask for permission between phases.

## Usage

```
/parent-flow <task description>
```

## The Loop

### Phase 1 — Research (Sonnet)
Spawn a `researcher` agent with `model: sonnet`.

Give it:
- The task: `$ARGUMENTS`
- **MANDATORY READS before drafting the plan** (in this order):
  1. `CLAUDE.md` — for architecture, build instructions, critical implementation details, and locked decisions
  2. `PROBLEMS_AND_SOLUTIONS.md` — grep for keywords from the task; if any entry matches, quote it and state whether it fully covers the current issue
  3. Every file named in the task prompt — end-to-end, not excerpts
  4. For every symbol/class/function being added or modified: grep `TextRefiner/Sources/` to find ALL call sites and references
  5. For any change to `AppDelegate.swift`: also read `HotkeyManager.swift`, `RefinementCoordinator.swift`, and `OnboardingWindowController.swift` — these are tightly coupled through callbacks
  6. For any change to `build.sh`: read the Metal shader compilation section and the signing/embedding steps — breaking either crashes the app on launch
- Which files to read (infer from task, or read `TextRefiner/Sources/` directory listing first)
- A clear deliverable: phased implementation plan with exact file paths, line numbers, class names, and values to change. No code — plan only.
- Flag any risks or things that are already correct and should not be touched.
- REQUIRED sections in the plan:
  1. **COMPONENT SCOPE** — which architectural layer(s) are affected: App (AppDelegate, main.swift), Core (HotkeyManager, RefinementCoordinator, LocalInferenceService, AccessibilityService, TypingMonitor, etc.), UI (StreamingPanelController, OnboardingWindowController, SettingsWindowController, ReadyIndicatorController, etc.), Build (build.sh, Package.swift, Info.plist)
  2. **PREMISE CHECK** — confirm the task's stated bug/gap actually exists by quoting current code. If the premise is wrong (fix already in place, feature already correct), the deliverable is "NO CHANGES NEEDED" with evidence and a diagnostic path. Saying "do nothing" is a valid and expected outcome.
  3. **REQUIREMENT CONFLICTS** — if two stated requirements cannot both be satisfied, surface the conflict BEFORE proposing changes. Present at least 2 tradeoff options, recommend one with reasoning. Do NOT silently pick one.
  4. **ROOT CAUSES** — enumerate EVERY independent root cause. A task with N symptoms usually has N root causes. For each, state the evidence (file + line) and which component it lives in.
  5. **THREAD SAFETY** — for any change touching async code, callbacks, or observers: state which thread/queue each piece runs on. Flag any main-thread violations (MLX inference MUST be `Task.detached`, UI updates MUST be `@MainActor` or `DispatchQueue.main`). Check for data races between the CGEvent tap callback thread and main thread.
  6. **CALLBACK CHAIN** — for any change to RefinementCoordinator callbacks or AppDelegate wiring: trace the full callback chain from trigger to UI update. List every callback (`onProcessingStarted`, `onRefinementComplete`, `onProcessingFinished`, `onRefinementCancelled`, `onError`) and confirm each is wired, unwired, and nil-checked correctly. Partial wiring = silent failure.
  7. **TCC / PERMISSION IMPACT** — if the change adds any new system API usage (CGEvent, AXObserver, pasteboard, file access), state whether it requires new permissions and how those are granted. If it touches `HotkeyManager.start()`, `AccessibilityService.isTrusted()`, or onboarding flow, confirm the ad-hoc signing implications (CDHash invalidation, TCC reset, re-onboarding).
  8. **FILES I WILL TOUCH** — exact paths, each mapped to which root cause it addresses
  9. **FILES I WILL NOT TOUCH** — files considered but deliberately excluded, with a one-line reason each
  10. **CHANGES TABLE** — one row per edit: `file | line | current value | new value | why`. Current value MUST be a verbatim excerpt from the file (copy-paste, not paraphrase). If a field is being added (no current value exists), write `<not present>` and quote the surrounding line where it will be inserted. If no current value is quoted, the row is invalid.
  11. **APPKIT LAYOUT IMPACT** — for any UI change: state the coordinate system (AppKit y=0 is bottom), list all controls that need repositioning, and calculate the new window height. Reference P&S #5 and #13.
  12. **BUILD IMPACT** — will this change require modifications to `build.sh`, `Package.swift`, or `Info.plist`/`Info-Dev.plist`? If adding a new dependency, state the SPM package URL and version. If adding resources, state where they must be placed in the .app bundle.
  13. **PRIOR FIXES** — if `PROBLEMS_AND_SOLUTIONS.md` has a related entry, quote it and state whether the prior fix is complete or partial. Do not re-apply a complete fix; do not assume a partial fix covers the new report.
  14. **RISKS** — things that could go wrong, explicit gotchas, and approaches already tried that did NOT work

### Phase 2 — QA Review of Plan (Opus)
Spawn a `reviewer` agent with `model: opus`.

Give it:
- The research agent's full plan
- The same files to read independently — QA MUST open each file fresh and verify every line number, class name, and current value quoted in the plan. If a current value does not match, flag it.
- QA MUST also read at least ONE file the Research agent did not mention, chosen from neighbors/imports of the touched files, to check for side effects or missed call sites.
- QA MUST grep for every symbol, class, or function being added/removed/modified to confirm no other call site is affected.
- QA MUST verify the PREMISE: read the code Research claims needs fixing. If the fix is already in place, reject the plan as "premise incorrect, no changes needed." A plan that invents work is worse than a plan that does nothing.
- QA MUST verify THREAD SAFETY: confirm MLX inference stays in `Task.detached`, UI updates are on main thread, CGEvent tap callbacks don't race with main-thread state. Any `Task { }` (without `.detached`) in RefinementCoordinator is a red flag.
- QA MUST verify CALLBACK CHAIN completeness: if the plan adds a new callback, confirm it is set in `wireCoordinator()` AND cleared in all terminal states (onProcessingFinished, onRefinementCancelled, onError).
- QA MUST verify the plan does not violate LOCKED DECISIONS in CLAUDE.md (default hotkey, no sandbox, no Dock icon, prompt template structure, single model, ad-hoc signing).
- QA MUST read `PROBLEMS_AND_SOLUTIONS.md` when the task is related to any documented issue, and independently judge whether the prior fix is complete.
- QA MUST run through this **TRAP CHECKLIST** explicitly and answer each with evidence before verdict (any unchecked = NEEDS REVISION):
  1. Premise valid? (code actually has the claimed bug/gap)
  2. All root causes addressed? (no partial fix)
  3. Thread safety verified? (inference off main, UI on main, no data races)
  4. Callback chain complete? (all states wired AND cleared)
  5. TCC/permission impact assessed? (no new silent permission failures)
  6. AppKit coordinates correct? (y=0 is bottom, window height updated)
  7. `HotkeyManager.start()` return value checked wherever called?
  8. No `@discardableResult` on permission-dependent operations?
  9. Escape-to-cancel wiring preserved? (nil by default, set only during processing, cleared in all terminal states)
  10. `#if DEBUG` on any new `print` statements?
  11. Prior fix in PROBLEMS_AND_SOLUTIONS.md judged complete vs partial?
  12. Locked decisions respected? (no sandbox, no Dock icon, ad-hoc signing, etc.)
  13. No new UserDefaults sentinel value checks using integer 0? (use `object(forKey:) != nil`)
  14. Build script impact assessed? (Metal shaders, framework embedding, signing order)
- Output format: APPROVED or NEEDS REVISION per section, with final verdict APPROVED or LOOP

**If LOOP:** send corrections back to the research agent (via SendMessage or new spawn), get a revised plan, re-run QA. Repeat until APPROVED.

### Phase 3 — Implement
As the Master Parent, implement the approved plan directly using Edit/Write/Read tools. Do not delegate implementation to another agent.

After implementation, run a compile check:
```bash
cd TextRefiner && swift build -c release 2>&1 | tail -30
```
If compilation fails, fix the errors before proceeding to QA verification.

### Phase 4 — QA Verification (Opus)
Spawn a `reviewer` agent with `model: opus`.

Give it:
- The list of every change that was made (file, line, old value, new value)
- Instructions to read each modified file and confirm each change landed exactly as planned
- QA MUST verify compilation succeeds: check the `swift build` output from Phase 3
- QA MUST verify no CLAUDE.md constraints were violated by reading the modified files
- QA MUST trace the data flow through any modified callback chain to confirm no path is broken
- QA MUST check that any new `print` statements are wrapped in `#if DEBUG`
- QA MUST verify AppKit layout coordinates are consistent (y values, window heights, control positioning)
- Output format: PASS/FAIL per check, final verdict ALL PASS or NEEDS FIX

**If NEEDS FIX:** fix the specific items flagged, then re-run QA verification. Repeat until ALL PASS.

### Phase 5 — Done
Report to the user: what was done, what each agent found, and what was shipped.

If any entry should be added to `PROBLEMS_AND_SOLUTIONS.md` (a non-obvious problem was diagnosed and resolved), draft it and include it in the report for the user to approve.

---

## Rules

- Research agent: reads code, produces plan, never writes code
- QA agent: reads code, validates plan or verifies implementation, never writes code
- Master Parent (you): implements, orchestrates, decides, loops
- Never skip QA — not even for "trivial" changes
- Never ask the user for permission mid-loop
- If QA loops more than 3 times on the same phase, surface the conflict to the user

## Context for this project

- **Stack:** Swift 5.9+, pure AppKit (no SwiftUI), SPM, MLX for on-device inference, Sparkle for updates
- **Source:** `/Users/noamnahum/Desktop/TextRefiner - Claude/TextRefiner/Sources/`
- **Structure:** `App/` (main.swift, AppDelegate), `Core/` (HotkeyManager, RefinementCoordinator, LocalInferenceService, AccessibilityService, TypingMonitor, etc.), `UI/` (StreamingPanelController, OnboardingWindowController, SettingsWindowController, ReadyIndicatorController, etc.), `Utilities/` (NotificationManager)
- **Build:** `cd TextRefiner && ./build.sh` (dev) or `./build.sh release` — includes Metal shader compilation, framework embedding, ad-hoc signing
- **Deployment target:** macOS 14 Sonoma, M1+ only
- **Distribution:** Ad-hoc signed, outside App Store, no sandbox
- **No tests, no linter** — compile check (`swift build -c release`) is the only automated verification
- Never create new files unless the task requires it
- After shipping, add non-obvious discoveries to `PROBLEMS_AND_SOLUTIONS.md`

## Known Gotchas (Research MUST consider, QA MUST check against)

- **`AXIsProcessTrusted()` is unreliable** on macOS Ventura+ after rebuilds. `AccessibilityService.isTrusted()` uses a throwaway CGEvent tap as ground truth. Never replace it with `AXIsProcessTrusted()`.
- **CGEvent tap vs NSEvent monitor:** `HotkeyManager` uses `CGEvent.tapCreate` so the hotkey is consumed. `NSEvent` monitors cannot suppress events. Never switch to `NSEvent.addGlobalMonitorForEvents`.
- **MLX inference MUST be `Task.detached`:** Running on main thread blocks the entire system on Apple Silicon shared memory. Never wrap in `Task { @MainActor in }`.
- **`NSPanel` with `.nonactivatingPanel`:** The HUD must not steal focus. Never change to `NSWindow`.
- **Pasteboard polling (500ms):** The target app needs time to process Cmd+C. Never remove the poll loop.
- **`HotkeyManager.start()` returns `Bool`:** The return value MUST always be checked. Any call that ignores it is a bug. P&S #17.
- **Onboarding "Next" is a hard gate:** Returns `true` only if CGEvent tap was successfully created. Never allow advancing without a working tap. P&S #17.
- **Ad-hoc signing = new CDHash every build:** TCC entries become stale. Quarantine flag blocks taps. Both are handled by launch-time logic — don't "simplify" this. P&S #1, #2, #10.
- **Metal shaders:** SPM cannot compile `.metal` files. `build.sh` does this manually. Without `mlx.metallib` in `Contents/MacOS/`, the app crashes on launch. P&S #11.
- **AppKit coordinates:** y=0 is the BOTTOM of the window/screen. When adding UI rows, three things change together: new control y, all controls below shift down, window height increases. P&S #5, #13.
- **UserDefaults integer 0 is valid:** Check `object(forKey:) != nil`, not `value != 0`. P&S #7.
- **Observer leaks:** Any method that sets up observers (AXObserver, NSWorkspace notifications) must call teardown first. P&S #14.
- **`start()` must call `stop()` first:** Makes it idempotent. Prevents tap handle leaks. P&S #17, #18.
- **Escape-to-cancel wiring:** `onEscapePressed` is `nil` by default. Set only during processing, cleared in ALL terminal states. Never intercept Escape globally. CLAUDE.md critical details.
- **Prompt template structure:** Must contain `{{USER_TEXT}}` with `[TEXT_START]`/`[TEXT_END]` delimiters. Don't change without validating against the model. Locked decision.
- **`cleanResponse()` runs after full accumulation, not per-token.** Moving it to per-token streaming breaks multi-token patterns.
- **Sparkle in dev builds:** `UpdateManager` guards on `SUFeedURL` presence. Dev builds use `Info-Dev.plist` with no Sparkle keys. P&S #6.
- **AXObserver requires the OBSERVED app's PID**, not the observer's PID. P&S #12.
- **`kAXValueChangedNotification` unreliable in Chrome/Electron.** Pair with 500ms polling fallback. P&S #16.
- **Double-dialog avoidance:** `startListening()` has no UI side effects. Callers decide the response. P&S #18 (S-21).
- **App must call `AXIsProcessTrustedWithOptions(prompt: true)` to appear in Accessibility list** on macOS 14+. Just checking trust doesn't register the app. P&S #19.
