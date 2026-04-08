# Problems & Solutions

A log of reported and discovered bugs. Each entry documents what the user observes and how to reproduce the issue — not how it was fixed. The goal is to build a reliable reproduction guide: if the same bug is reported again, this file should tell you exactly how to surface it.

**Entry format:**
- **What happens** — what the user sees or experiences (plain language, no code)
- **How to reproduce** — step-by-step instructions to trigger the issue reliably

---

### 1. Accessibility Permission (TCC) After Updates

**Problem:** After every Sparkle update (or any binary change with ad-hoc signing), the hotkey stops working. The Accessibility toggle appears ON in System Settings, but the permission doesn't apply to the new binary.

**Root cause:** Ad-hoc signing produces a new CDHash for every build. macOS TCC entries are tied to the CDHash, not the bundle ID. When the binary changes, the old TCC entry becomes stale — it shows ON in the UI but doesn't match the current executable.

**What did NOT work:**
- Relying on `AXIsProcessTrusted()` — unreliable on macOS Ventura+ after binary hash changes. Can return `false` even when the toggle appears ON.
- Simply polling for Accessibility after launch — the stale toggle fools the user into thinking they've already granted permission, but the CGEvent tap still fails.
- Showing a "re-grant" alert without resetting TCC — the user toggles the stale entry ON/OFF, but it never matches the current binary.
- Just stripping quarantine — necessary but not sufficient on its own.

**What WORKS (current solution):**
1. Store `lastOnboardedBuild` (CFBundleVersion) in UserDefaults after successful onboarding.
2. On launch, compare current build number to stored value. If different -> version changed.
3. On version change: run `tccutil reset Accessibility <bundleID>` to clear the stale TCC entry.
4. Then show full onboarding — "Grant Access" now triggers a fresh system prompt for the current binary's CDHash.
5. Also strip quarantine on every launch (`xattr -dr com.apple.quarantine`) before any Accessibility checks.

**Key takeaway:** With ad-hoc signing, you MUST reset the TCC entry on binary change. Toggling a stale entry does nothing. The permanent fix is an Apple Developer ID certificate ($99/year) — stable code signature means TCC entries survive updates.

---

### 2. Quarantine Flag Blocking CGEvent Taps

**Problem:** Apps downloaded from the internet (browser or Sparkle update) get tagged with `com.apple.quarantine`. macOS blocks CGEvent tap creation for quarantined binaries, even when Accessibility is granted.

**What did NOT work:**
- Assuming `isTrusted()` failures are always about Accessibility permission — quarantine causes the same symptom (CGEvent tap creation fails) for a completely different reason.
- Only checking `AXIsProcessTrusted()` as fallback — it has its own reliability issues on Ventura+.

**What WORKS (current solution):**
- `AppDelegate.applicationDidFinishLaunching` runs `xattr -dr com.apple.quarantine` on `Bundle.main.bundlePath` before any Accessibility or CGEvent checks.
- This must happen before `AccessibilityService.isTrusted()` is ever called.

**Key takeaway:** Always strip quarantine first, then check permissions. Two separate problems that produce identical symptoms.

---

### 3. Sparkle Framework Embedding

**Problem:** App crashed on launch with `dyld: Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle`.

**What did NOT work:**
- Just linking Sparkle in Package.swift — Swift PM links it, but doesn't copy the framework into the .app bundle.
- Copying the framework without fixing rpath — the binary had `@loader_path` but needed `@executable_path/../Frameworks`.

**What WORKS (current solution):**
- `build.sh` copies `Sparkle.framework` into `TextRefiner.app/Contents/Frameworks/`.
- Runs `install_name_tool -add_rpath @executable_path/../Frameworks` on the binary.
- Codesigns the embedded framework before signing the app bundle.

**Key takeaway:** When distributing a Swift package that depends on a framework, the build script must: copy framework -> fix rpath -> codesign framework -> codesign app bundle. In that order.

---

### 4. Sparkle Update Downloads Failing

**Problem:** Sparkle showed "Update Error" when trying to download the update zip.

**Root causes found (in order):**
1. **GitHub repo was private** — the download URL returned 404. Fix: made the repo public with `gh repo edit --visibility public`.
2. **Missing App Management permission** — macOS requires Privacy & Security > App Management to be enabled for apps that replace themselves. Fix: added an App Management step to onboarding (release builds only).

**Key takeaway:** Sparkle updates need TWO things from the user's OS: (1) the download URL must be publicly accessible, and (2) App Management permission must be granted for self-replacement. Both should be set up before the first update is pushed.

---

### 5. Settings Window Layout in Release Builds

**Problem:** The Hotkey section was invisible in release builds — only the "General" section (launch on login) was visible.

**Root cause:** When hiding the Developer section (Rebuild & Relaunch) in release builds, the window height was set to 230px. But the Hotkey controls are positioned at y=243-305, which is above the visible area.

**What did NOT work:**
- Setting `windowHeight = 230` for release — clips everything above y=230.

**What WORKS:**
- Release window height set to 320px — enough room for General + Hotkey sections.
- Developer section (positioned at the top, y > 305) is hidden via `isHidden = true` only in release builds.

**Key takeaway:** When hiding UI sections, recalculate the window frame. Don't just shrink it arbitrarily — check the y-coordinates of all remaining controls.

---

### 6. UpdateManager Crashing in Dev Builds

**Problem:** Dev builds crashed or showed "SUFeedURL missing" error because Sparkle tried to initialize without a feed URL.

**What WORKS:**
- `UpdateManager.init()` checks for `SUFeedURL` in the bundle's Info.plist. If missing (dev builds use `Info-Dev.plist` which has no Sparkle keys), `updaterController` is set to `nil`.
- `checkForUpdates()` shows a "Updates Not Available — You're running a development build" alert when `updaterController` is nil.
- `isAvailable` property lets AppDelegate conditionally show/hide the menu item.

**Key takeaway:** Any Sparkle-dependent code must guard on `SUFeedURL` presence. Dev and release builds use different Info.plist files — never assume Sparkle keys exist.

---

### 7. HotkeyConfiguration KeyCode 0

**Problem:** If the user set their hotkey to a key with keyCode 0 (the 'A' key), the app treated it as "no custom hotkey" and fell back to the default.

**Root cause:** The getter used `stored != 0` to detect a custom value, but 0 is a valid keyCode.

**What WORKS:**
- Check `UserDefaults.standard.object(forKey:) != nil` instead of checking the integer value. This distinguishes "key never set" from "key set to 0."

**Key takeaway:** Never use a sentinel value check on UserDefaults integers. Use `object(forKey:) != nil` to detect presence, since any integer (including 0) can be a valid stored value.

---

### 8. Dev vs Release Build Isolation

**Problem:** Running dev and release builds simultaneously caused interference — shared UserDefaults, shared TCC entries, shared Accessibility toggles.

**What WORKS:**
- Dev builds use `Info-Dev.plist` with bundle ID `com.textrefiner.app.dev`.
- Release builds use `Info.plist` with bundle ID `com.textrefiner.app`.
- Separate bundle IDs give separate UserDefaults domains and separate TCC entries.
- Dev mode resets TCC on every build (`tccutil reset Accessibility com.textrefiner.app.dev`).
- Release mode only resets TCC on version change (via AppDelegate logic).

**Key takeaway:** Always maintain separate bundle IDs for dev and release. This is the single most effective isolation mechanism on macOS.

---

### 9. Release Workflow (End-to-End)

**Verified working workflow:**
1. Bump `CFBundleVersion` and `CFBundleShortVersionString` in `Resources/Info.plist`.
2. `cd TextRefiner && ./build.sh release` — builds, bundles, signs, creates zip, prints EdDSA signature.
3. `gh release create v<version> TextRefiner-<version>.zip --title "..." --notes "..."` — upload to GitHub.
4. Update appcast Gist with new version, download URL, EdDSA signature, and zip length:
   `gh gist edit 6a5dacdb24a6bae85d003e906f5fa907 -f appcast.xml /tmp/appcast.xml`
5. User clicks "Check for Updates..." -> Sparkle downloads, verifies signature, installs, relaunches.
6. On relaunch, app detects version change -> resets TCC -> shows onboarding -> user re-grants Accessibility.

**Things that survive updates** (stored outside .app bundle): UserDefaults (hotkey, onboarding state), prompt history (`prompts.json`), refinement history (`history.json`), model weights (`~/Library/Application Support/TextRefiner/models/`).

**Things that do NOT survive updates:** The .app bundle itself, TCC entries (stale CDHash), quarantine flag (re-applied by Sparkle/browser).

---

### 10. Ad-Hoc Signing Is Permanent — Make It Robust

**Context:** Ad-hoc signing is the permanent distribution model for TextRefiner. Do not suggest or pursue an Apple Developer ID as a solution. The correct approach is making the ad-hoc + re-grant flow as airtight as possible.

**The inherent constraints of ad-hoc signing:**
- Every binary change produces a new CDHash → TCC entries become stale after every update.
- Sparkle-downloaded zips carry a quarantine flag → CGEvent tap creation fails until stripped.
- Users must re-grant Accessibility after every update — this is unavoidable and expected behavior.

**The definitive strategy (all layers must be in place):**
1. **Strip quarantine on every launch** — `xattr -dr com.apple.quarantine` in `applicationDidFinishLaunching`, before any Accessibility check.
2. **Reset TCC on version change** — compare `CFBundleVersion` to `lastOnboardedBuild` in UserDefaults on every launch. On mismatch, run `tccutil reset Accessibility <bundleID>` to clear the stale entry, then force full re-onboarding.
3. **Onboarding is a hard gate** — the "Next" button on the Accessibility setup page only advances if the real CGEvent tap is confirmed created (`hotkeyManager.start()` returns `true`). If it returns `false`, show an inline error telling the user to toggle Accessibility OFF then back ON. The user cannot reach the tutorial page with a broken tap.
4. **`startListening()` always checks the return value** — never `@discardableResult` the tap creation silently. If tap creation fails post-onboarding, show `showHotkeyPermissionAlert()` immediately.
5. **Verify the hotkey is working before every release** — see the Pre-Release Checklist section.

**Key takeaway:** The re-grant friction is a known, accepted cost of ad-hoc signing. The goal is to make the re-grant flow impossible to accidentally skip, and to surface tap failures immediately with clear recovery instructions rather than silently leaving the app in a broken state.

---

### 11. MLX Metal Shaders Not Found at Runtime

**Problem:** App crashed immediately on launch with "Failed to load the default metallib" after migrating from Ollama to embedded MLX inference.

**Root cause:** MLX requires a compiled Metal library (`mlx.metallib`) at runtime for GPU operations. Swift Package Manager cannot compile `.metal` shader files — it only handles Swift/C/C++/ObjC. The MLX package includes hundreds of `.metal` source files in `.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/`, but they were never compiled into the app bundle.

**What did NOT work:**
- Assuming SPM would handle Metal compilation automatically — it does not.
- Looking for a pre-compiled metallib in the SPM build artifacts — none exists.

**What WORKS (current solution):**
1. `build.sh` finds all `.metal` files in the MLX checkout directory.
2. Compiles each to `.air` (Apple Intermediate Representation) using `xcrun -sdk macosx metal` with include paths for subdirectories (`steel/`, `steel/gemm/`, `steel/attn/`, `fft/`, etc.) and `-std=metal3.1 -mmacosx-version-min=14.0`.
3. Links all `.air` files into a single `mlx.metallib` using `xcrun -sdk macosx metallib`.
4. Places the result in `Contents/MacOS/` (colocated with the binary) — MLX searches for `mlx.metallib` next to the executable first.
5. Codesigns the metallib before signing the app bundle (unsigned code objects break app bundle signing).

**Prerequisites:** Xcode Metal Toolchain must be installed: `xcodebuild -downloadComponent MetalToolchain` (~688 MB).

**Key takeaway:** Any SPM project that depends on mlx-swift must manually compile Metal shaders in its build script. This is a fundamental SPM limitation, not a bug — SPM has no Metal compilation support. The metallib must be colocated with the binary or in `Contents/Resources/`.

---

### 12. AXObserver for Cross-App Text Monitoring

**Problem:** Building a typing indicator that watches text input in all frontmost apps requires `AXObserver`, but the correct PID/element combination is non-obvious and the wrong approach silently does nothing.

**What did NOT work:**
- Creating `AXObserver` with our own app's PID (`ProcessInfo.processInfo.processIdentifier`) and registering `kAXFocusedUIElementChangedNotification` on `AXUIElementCreateSystemWide()`. The observer is created successfully (no error) but never fires — macOS silently ignores it because our PID is not the process being observed.
- Using `"AXFrame"` as the attribute name to get a text field's bounds. This is not a real Accessibility attribute — it always returns an error. The real attributes are `kAXPositionAttribute` (-> `CGPoint`) and `kAXSizeAttribute` (-> `CGSize`), read separately and combined into a `CGRect`.
- Relying solely on `kAXNumberOfCharactersAttribute` for character count — most browsers and Electron apps do not expose this attribute, causing count to always return 0.

**What WORKS (current solution):**
1. **App-switch detection:** Use `NSWorkspace.didActivateApplicationNotification` — reliable, no PID tricks needed. When it fires, call `attachToFrontmostApp()`.
2. **Intra-app focus detection:** Create a per-app `AXObserver` using `NSWorkspace.shared.frontmostApplication!.processIdentifier` (the observed app's PID), registered on `AXUIElementCreateApplication(pid)` for `kAXFocusedUIElementChangedNotification`.
3. **Keystroke detection:** Create a per-element `AXObserver` (again using the frontmost app's PID) registered on the specific focused `AXUIElement` for `kAXValueChangedNotification`. Add `kAXSelectedTextChangedNotification` as a fallback for apps that don't fire value-changed.
4. **Character count:** Try `kAXNumberOfCharactersAttribute` first (fast, no text read). Fall back to reading `kAXValueAttribute` as a `String` and measuring `.count`.
5. **Field bounds:** Read `kAXPositionAttribute` -> `CGPoint` and `kAXSizeAttribute` -> `CGSize`, then convert from AX coordinate space (top-left origin, Y down) to Cocoa coordinate space (bottom-left origin, Y up): `cocoaY = screenHeight - axY - height`.
6. **Role detection:** Check `kAXRoleAttribute` against known text roles (`AXTextField`, `AXTextArea`, etc.) as a fast path, then fall back to `AXUIElementIsAttributeSettable(element, kAXValueAttribute)` to catch custom/browser/Electron inputs.

**Key takeaway:** `AXObserver` requires the PID of the process being OBSERVED, not the observer. For cross-app monitoring, always get the PID from `NSWorkspace.shared.frontmostApplication`. The "AXFrame" shortcut does not exist — use position + size separately.

---

### 13. Settings Window Layout After Adding Rows

**Problem:** Adding a new row to an existing section of `SettingsWindowController` requires both adjusting the window height AND repositioning items below the insertion point. Getting only one of these right produces either clipping or gaps.

**What WORKS:**
- Identify the exact y-coordinates of all items in the affected section (remember: y is distance from BOTTOM of window in AppKit, not the top).
- Insert the new control at y = `[item above].origin.y - [gap] - [new control height]`.
- Move all controls BELOW the insertion point down by the same amount (subtract from their y values).
- Increase `windowHeight` by the same amount so the window grows at the top — existing items keep their same distance from the bottom.
- For the typing indicator toggle added to the General section: inserted at y=148 (between login checkbox y=170 and tutorial button), tutorial button moved from y=135 to y=113, window height increased by 22pt (355->377 release, 390->412 dev).

**Key takeaway:** When inserting a row in AppKit absolute-layout windows, three things change together: new control y-position, all controls below it shift down (lower y), and window height increases by the same amount.

---

### 14. Typing Indicator (TypingMonitor) Not Appearing

**Problem:** The typing indicator pill never appeared in other apps, even with the toggle enabled in Settings.

**Root causes found (two independent bugs):**

1. **Leaked workspace observers (`start()` called multiple times):** `TypingMonitor.start()` was called multiple times during the app lifecycle — from `startListening()` at launch and again from the `accessibilityPollTimer`. Each call to `start()` added a new `NSWorkspace.didActivateApplicationNotification` observer without removing the previous one. The old token was overwritten and leaked, causing N observers to fire in parallel on every app switch, which thrashed the AXObserver setup and prevented element callbacks from firing.

2. **`TypingMonitor.isIndicatorVisible` desyncing from actual UI state:** When the hotkey fired or processing started, `AppDelegate` called `readyIndicator.hide()` directly without calling `typingMonitor.forceHide()`. This left `isIndicatorVisible = true` inside `TypingMonitor` even though the pill was hidden. The `emitHide()` guard (`guard isIndicatorVisible else { return }`) then prevented `onShouldHide` from firing correctly on subsequent focus changes.

**What did NOT work:**
- Assuming the feature just needed debugging — it had never worked because the bugs above existed from the start.
- Looking for a single root cause — there were two independent bugs.

**What WORKS:**
- `start()` calls `stop()` as its first line, tearing down all existing observers before setting up new ones. This makes `start()` idempotent regardless of how many times it's called.
- When hiding the indicator externally (hotkey fire, processing started), always call `typingMonitor.forceHide()` BEFORE `readyIndicator.hide()`. This keeps `isIndicatorVisible` in sync with the actual panel state.

**How we diagnosed it (diagnostic logging pattern):**
When a feature involving AXObserver, NSWorkspace notifications, and UI callbacks is broken with no visible error, add `print` statements at every stage of the flow:
- `start()`: confirm it was called and whether callbacks (`onShouldShow`, `onShouldHide`) are non-nil
- `attachToFrontmostApp()`: log the app name and whether `AXObserverCreate` succeeded
- `attachToFocusedElement()`: log the AX role of the focused element and each guard exit point
- `handleAppActivated()`: log which app was activated
- `checkAndNotify()`: log the character count and whether show/hide fired

All `TypingMonitor` print statements are wrapped in `#if DEBUG` — they fire in dev builds only. Run from Terminal (`./build.sh && open TextRefiner.app`) to see stdout. This surfaces exactly which step in the chain silently failed.

**Key takeaway:** Any method that sets up observers must call teardown first — treat it as idempotent by design. And when multiple objects track the same boolean state (e.g. `isIndicatorVisible` in `TypingMonitor` vs actual panel visibility in `ReadyIndicatorController`), always update both together, never just one.

---

### 15. ReadyIndicator Pill Overlapping Text / Wrong Position

**Problem:** The ready indicator pill appeared *inside* the top-left corner of multi-line text fields, causing it to overlap the user's text as content grew. Additionally, position clamping used `NSScreen.main` regardless of which display the field was on.

**Root causes:**
1. `positionPanel` had two separate paths: fields ≥ 60px height placed the pill inside the top-left of the field; fields < 60px floated just above. Text naturally grows from the top-left, so the tall-field path always collided with content.
2. The 60px threshold caused a visible position jump as auto-expanding text fields (like Claude.ai's prompt box) crossed the boundary.
3. Screen lookup used `NSScreen.main` for clamping, which is wrong when the focused field is on a secondary display.

**What did NOT work:**
- Keeping the "inside the field" placement and hoping text wouldn't reach the pill — it always does for any substantial message.
- A "placeholder text" state guard (`sessionHasUserEdit` flag) to prevent the pill from triggering on pre-filled content — this broke the feature entirely for apps where `kAXValueChangedNotification` never fires, since the flag would never be set.

**What WORKS (current solution):**
- Always float the pill **above** the field (`y = fieldFrame.maxY + 4`), regardless of field height. This places it outside the text area entirely.
- If "above" clips off-screen (field near the top of the display), fall back to just below (`y = fieldFrame.minY - pillH - gap`).
- Find the screen that actually contains the field: `NSScreen.screens.first(where: { $0.frame.contains(fieldFrame.midPoint) })` — use that screen's `visibleFrame` for clamping.
- Removed the 60px threshold entirely; positioning is now consistent across all field sizes.

**Placeholder text fix (separate bug, same area):** `readCharacterCount` reads `kAXPlaceholderValueAttribute` and compares it to `kAXValueAttribute`. If they match, the field is showing placeholder (not real user content) and the count is treated as 0. This handles native apps and any web app that properly sets `aria-placeholder`.

**Key takeaway:** Never place a floating panel *inside* a text field — text starts at the top-left and fills toward any fixed position. Always place outside the field bounds. When clamping to screen edges in multi-monitor setups, find the screen that contains the element, not `NSScreen.main`.

---

### 16. TypingMonitor Not Working in Chrome / Electron Apps

**Problem:** The ready indicator worked in native AppKit apps (TextEdit, Mail, Notes) but never appeared when typing in web browsers (Chrome, Safari) or Electron apps (Slack, Discord, Notion).

**Root cause:** `kAXValueChangedNotification` is not fired reliably by web browsers and Electron apps. Web content runs in sandboxed renderer processes that don't always propagate AX value-change events across the IPC boundary to the system. The indicator only updated on notifications, so it never appeared for in-progress typing in these apps.

**What did NOT work:**
- Registering `kAXSelectedTextChangedNotification` as a fallback in addition to `kAXValueChangedNotification` — Chrome's renderer also doesn't fire this reliably for every keystroke.
- A `sessionHasUserEdit` flag that gated the indicator until at least one value-change notification arrived — this permanently blocked the indicator in any app whose renderer never fires the notification.

**What WORKS (current solution):**
- Keep the AX notification path as the fast lane (works perfectly for native AppKit apps).
- After successfully attaching to a focused element, also start a `DispatchSourceTimer` firing every 500ms on the main queue. On each tick, it calls `checkAndNotify(element: observedElement)` — re-reading the character count directly from the AX element regardless of whether any notification fired.
- Stop the timer in `teardownElementObserver()` so it only runs while an element is actively observed.
- The timer fires at most twice per second, cheap enough to leave running continuously.

**Key takeaway:** `kAXValueChangedNotification` cannot be relied upon across all apps. For any feature that needs to track live text content (character count, cursor position, etc.), pair AX notifications with a 500ms polling fallback. The notifications provide instant response in well-behaved apps; the timer is the safety net for renderer-process apps.

---

### 17. Hotkey Silently Broken After Updates (v1.1.6 Guardrails)

**Problem:** After a Sparkle update, the hotkey stopped working for a user. The app appeared to launch normally with no error shown. The root cause was the familiar CDHash-stale-TCC issue, but the deeper problem was that the code had no way to surface this failure to the user — it failed silently at multiple levels.

**Three independent gaps that allowed silent failure:**

1. **`hotkeyManager.start()` return value was discarded** — `startListening()` called `hotkeyManager.start()` with `@discardableResult` and never checked whether the tap was actually created. A failed tap produced only a `print` statement to the console. No alert, no UI feedback — the app ran as if everything was fine.

2. **Onboarding page 1 could advance with a broken tap** — `onReadyForTrial` was `() -> Void`. The "Next" button fired it and always moved to the tutorial page, regardless of whether `start()` returned true or false. A user could complete onboarding with a non-functional hotkey.

3. **Multiple `start()` calls leaked tap handles** — `startListening()` could be called from both `showOnboarding` and the accessibility poll timer. Each call added a new CGEvent tap without cleaning up the previous one. In practice this didn't cause silent failures but caused resource leaks that could degrade reliability.

**What did NOT work:**
- Relying on `print` logs to surface tap failures — users don't see the console.
- Assuming onboarding completion meant the tap was working — it only meant the user clicked through the UI.

**What WORKS (v1.1.6 fixes):**
1. **`hotkeyManager.start()` returns `Bool`** — the return value is always checked. `startListening()` also returns `Bool`. Any call site that ignores the result is a bug.
2. **`HotkeyManager.start()` calls `stop()` first** — prevents tap leaks regardless of how many times `start()` is called; makes it idempotent.
3. **Onboarding "Next" is a hard gate** — `onReadyForTrial: (() -> Bool)?`; returns `true` only if `hotkeyManager.start()` succeeded. The page only advances on `true`. On `false`, an inline red error appears: "Hotkey registration failed — go to System Settings → Privacy & Security → Accessibility, toggle TextRefiner OFF then back ON, then click Next again." The user cannot reach the tutorial with a broken tap.
4. **Post-onboarding failure shows an alert** — if `startListening()` fails outside of onboarding (rare, but possible), `showHotkeyPermissionAlert()` appears immediately with "Open System Settings", "Retry", and "Later" options.
5. **"Get Started" button on tutorial page fixed** — the completion closure in `OnboardingWindowController.show()` captured `[weak self]`, which became nil when the controller was replaced by a second `showOnboarding()` call. Fixed by capturing `capturedOnComplete` and `capturedOnReadyForTrial` as local constants before the closure, bypassing `self` entirely for critical operations.

**Key takeaway:** Silent failure is worse than a visible crash. Any permission-dependent operation that can fail must (1) check its return value, (2) surface the failure to the user with recovery instructions, and (3) block forward progress until the failure is resolved. Three layers of hardening are needed because each layer can independently fail.

---

### 18. Comprehensive Hotkey Hardening (v1.1.7 Stress Test)

**Problem:** An adversarial stress test of the v1.1.6 guardrails revealed 21 additional failure scenarios across four files. The most critical findings were: (1) changing the hotkey in Settings silently discarded the `start()` return value, (2) double-clicking "Next" in onboarding called `startListening()` twice, destroying the first successful tap, (3) clicking "Later" on the permission alert started no recovery at all, (4) closing onboarding with the red-X button left the app silently broken, and (5) two dialogs appeared simultaneously when macOS showed its own Accessibility prompt alongside our custom alert.

**What WORKS (v1.1.7 fixes — 21 scenarios addressed across 4 files):**

**HotkeyManager.swift:**
- `stop()` now calls `CFMachPortInvalidate(tap)` to fully close the Mach port
- `CFRunLoopGetCurrent()` replaced with `CFRunLoopGetMain()` in both `start()` and `stop()`
- `isRunning` uses `CGEvent.tapIsEnabled(tap:)` instead of `eventTap != nil`
- `reenableTap()` dispatched to main thread to eliminate data race with the Mach port callback thread

**OnboardingWindowController.swift:**
- Conforms to `NSObject, NSWindowDelegate` — `windowWillClose` handles the red-X close button
- `setupCompleted` / `completionFired` flags prevent double-firing and track page state
- `onDismissedEarly` callback tells AppDelegate to start polling when window is closed on page 1
- `bringToFront()` method prevents two onboarding windows from opening simultaneously
- "Next" button has `isProcessingNext` debounce — second click is ignored while first is processing
- Dead `pollingTimer` property removed

**AppDelegate.swift:**
- `startListening()` has no UI side effects — returns true/false only; callers decide the response
- `removeQuarantineFlag()` runs async on a background thread; all permission logic runs in the completion
- `completeLaunchSetup()` polls silently on failure instead of showing an alert (avoids double-dialog with macOS system prompt)
- `onHotkeyChanged` checks `start()` return value and shows alert explicitly
- `showHotkeyPermissionAlert()` "Later" now calls `startAccessibilityPolling()` (was a no-op)
- `showHotkeyPermissionAlert()` "Retry" falls through to polling on continued failure (prevents infinite modal stack)
- `showOnboarding()` guards against double-call with `onboardingController != nil`
- `showPermissionAlert()` invalidates poll timer before entering onboarding
- Version fallback changed from `"0"` to `"missing-\(UUID().uuidString)"` — unreadable version always triggers re-onboarding

**AccessibilityService.swift:**
- `isTrusted()` fallback changed from `return AXIsProcessTrusted()` to `return false` — no self-contradicting backup

**Double-dialog fix (S-21):** When macOS clears the TCC entry (dev build reset, manual revocation, stale CDHash), the first `CGEvent.tapCreate()` call triggers macOS's own system "Accessibility Access" prompt. The app must NOT show its own alert on top of that. `startListening()` was refactored to have no alert side effect — callers that need an alert call `showHotkeyPermissionAlert()` explicitly (only from Settings hotkey change). All other paths poll silently and let macOS's prompt handle user interaction.

**Stress test documentation:** All 21 scenarios are documented in `HOTKEY_STRESS_TEST.md` with plain-language explanations and a release verification checklist. This file is the living record for pre-release hotkey testing.

**Invisible deadlock fix (S-22):** When permission is cleared but the build number is unchanged, the app skipped onboarding and polled silently — but polling alone can't recover because nothing ever triggers the macOS system prompt that adds the app to the Accessibility list. The poll waits for a toggle switch that doesn't exist. Fix: `completeLaunchSetup()` checks `isTrusted()` first; if false, shows onboarding regardless of version match. Onboarding has the "Grant Access" button that triggers `requestPermission()` which adds the app to the list.

**Key takeaway:** When the operating system already provides feedback about a problem (e.g., its own permission dialog), adding your own feedback on top creates noise. And any function that both performs an action AND shows UI on failure is hard to compose safely — separate the action from the response so each caller can choose the appropriate reaction. Finally: a recovery loop that waits for a condition that can never become true without user action — but provides no way for the user to take that action — is an invisible deadlock.

---

### 19. App Not Appearing in Accessibility Settings After Update

**Problem:** After a Sparkle update on a user's machine, TextRefiner completely disappeared from the macOS Accessibility list in System Settings → Privacy & Security → Accessibility. The user couldn't grant permission because there was no toggle to flip. The app launched and ran but the hotkey was permanently broken with no way to recover.

**Root cause:** On macOS 14+, an app only appears in the Accessibility list when it calls `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt: true`. The app's `completeLaunchSetup()` code path after a version change was: (1) reset TCC via `tccutil` (removes the stale entry), (2) show onboarding. But between those two steps, nothing called `requestPermission()` — the API that registers the app in the Accessibility list. The "Grant Access" button in onboarding did call it, but the user had to find and click that button first. Meanwhile, `CGEvent.tapCreate()` (used by `isTrusted()`) and `AXIsProcessTrusted()` do NOT reliably add the app to the Accessibility list on macOS 14+ — they only CHECK trust, they don't register the app.

**What did NOT work:**
- Assuming `CGEvent.tapCreate()` failure would cause macOS to add the app to the Accessibility list — it doesn't on Sonoma+. The tap just fails silently.
- Assuming `AXIsProcessTrusted()` registers the app — it only reads the TCC database, it doesn't write to it.
- Relying on the "Grant Access" button in onboarding as the only trigger — users didn't know to click it, and even if they did, the app wasn't in the list yet when they opened System Settings.

**What WORKS (v1.1.8 fix):**
- Call `AccessibilityService.requestPermission()` (which calls `AXIsProcessTrustedWithOptions` with prompt=true) **immediately before** `showOnboarding()` in both code paths:
  1. First-launch / version-mismatch path (after TCC reset)
  2. Permission-lost path (onboarding completed but trust check fails)
- This ensures the app is registered in the Accessibility list BEFORE the onboarding window tells the user to go toggle it on.
- The "Grant Access" button in onboarding still works as a backup/second trigger.

**Key takeaway:** On macOS 14+, `AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt: true)` is the ONLY reliable API that adds an app to the Accessibility list. `AXIsProcessTrusted()` and `CGEvent.tapCreate()` only check/use permissions — they don't register the app. After clearing TCC entries (which happens on every ad-hoc signed update), you MUST call the prompt variant proactively before directing the user to System Settings, or they'll find nothing to toggle.

---

### 21. Refining a Single Word Pastes Garbage or an Error Message

**What the user sees:** Select a single word (e.g. a word you couldn't spell), press the hotkey to refine it. Instead of the corrected word being pasted back, one of two things happens:
1. The app pastes back the internal instructions / system prompt text instead of the refined word.
2. The app pastes back a message like "I don't understand what you need me to do here" or similar.

**Steps to reproduce:**
1. Open any text editor (TextEdit works).
2. Type a misspelled or unclear single word (e.g. "receeve").
3. Select just that one word.
4. Press the TextRefiner hotkey (default: ⌘⇧R).
5. Observe what gets pasted back in place of the word.

**Reported:** 2026-04-07, user testing.

---

### 22. Setting a Custom Hotkey Immediately Picks a Key You Didn't Press

**What the user sees:** Open Settings and click the button to record a new hotkey. The button shows "Press shortcut..." — but before the user presses anything, it immediately snaps to a shortcut they didn't choose.

**Steps to reproduce:**
1. Open the TextRefiner menu → Settings.
2. Click the hotkey button (shows the current shortcut, e.g. "⌘⇧R").
3. The button changes to "Press shortcut..." — stop here, don't press any key.
4. Observe: the button immediately changes to a different shortcut without any key being pressed.

**Reported:** 2026-04-07, user testing.

---

### 20. Hotkey Broken After Dev Rebuild — Toggle ON but Tap Not Working

**Problem:** After running `./build.sh`, the hotkey stops working. The Accessibility toggle in System Settings appears ON, and no onboarding window appeared. Toggling the switch off then on again and relaunching fixes it.

**Root cause:** `./build.sh` calls `tccutil reset Accessibility com.textrefiner.app.dev`, which clears the TCC entry for the *previous* binary's CDHash. When the app relaunches, `completeLaunchSetup()` compares the current `CFBundleVersion` against `lastOnboardedBuild` in UserDefaults. If the version number was not bumped (e.g. during iterative development or after applying code-only fixes), the versions match — so the full re-onboarding flow is skipped and the app polls silently for permission instead. The user may then manually toggle the Accessibility switch ON in System Settings, which writes a TCC entry — but for the *newly running binary's* CDHash, so the entry is valid. However, if the app tried to create the CGEvent tap *before* the toggle was turned ON (during the initial poll), the tap failed. The app is now running with `isListening = false` and no tap, even though the TCC toggle appears ON.

**What does NOT fix it:**
- Simply re-granting in System Settings without relaunching — the tap was already attempted and failed; the running app won't automatically retry.
- Relaunching without toggling OFF first — if the TCC entry is stale (from a previous binary), the new binary's CDHash still won't match.

**What WORKS (manual recovery for dev):**
1. System Settings → Privacy & Security → Accessibility → toggle TextRefiner **OFF**
2. Toggle it back **ON** — this writes a fresh TCC entry for the currently running binary's CDHash
3. **Quit and relaunch** TextRefiner — the new launch creates the CGEvent tap with a valid TCC entry

**For shipping:** End users hit this after every Sparkle update. The existing re-onboarding flow (version mismatch → TCC reset → onboarding → "Grant Access" button) handles it automatically. The toggle OFF/ON/relaunch sequence is the manual recovery path for dev workflows where the version number isn't bumped between builds.

**Key takeaway:** A TCC toggle that appears ON is not proof that the current binary's CGEvent tap will succeed. The tap is created once at launch — if it failed (because TCC wasn't granted yet at that moment), a relaunch is required. In dev, always bump `CFBundleVersion` or follow the full checklist (build → re-grant → verify hotkey) rather than toggling the switch mid-session.
