# Hotkey Stress Test — Scenario Library

This file exists for one reason: **the hotkey is the entire product.** If it stops working, TextRefiner is useless. Every time we prepare a new release, we come back here, go through every scenario, and verify nothing is broken before we ship.

This is not a technical document. It is written in plain language so that anyone — developer or not — can understand what problem each scenario is describing and why it matters. As we discover new edge cases over time, we add them here.

---

## How to Use This File

Before every release, go through **every item marked as a shipping gate**. These are the scenarios most likely to break silently — meaning the app *looks* fine but the hotkey doesn't work. If you verify a scenario, note the version and date next to it.

Items marked as **monitor** are known risks that are unlikely to affect users today but should be watched if the codebase changes around them.

Items marked as **cleanup** are not causing problems — they're just untidy. Address them when convenient.

---

## Part 1 — Scenarios That Can Silently Break the Hotkey

These are the most dangerous findings. "Silently broken" means the user has no idea anything is wrong until they press the hotkey and nothing happens.

---

### S-01 — Changing the hotkey in Settings can break it without saying so
**Type:** Shipping gate
**Fixed in:** v1.1.7 — `onHotkeyChanged` now checks `hotkeyManager.start()` return value and calls `showHotkeyPermissionAlert()` on failure
**Last verified:** —

When you change a setting in any system, the system needs to apply that change and confirm it worked. The app was not confirming the change — it was telling macOS "use this new shortcut" and then assuming the instruction went through. If macOS quietly refused (because the Accessibility permission had lapsed while the app was open, which can happen), the app would show the new shortcut in the Settings screen as if everything was fine. Pressing the shortcut would do nothing.

The theory: **just because you issued an instruction doesn't mean it was carried out.** Any critical instruction needs a receipt.

---

### S-02 — Two parts of the app can both try to register the hotkey at the same time, and they cancel each other out
**Type:** Shipping gate
**Fixed in:** v1.1.7 — `startListening()` now invalidates `accessibilityPollTimer` at the very start, ensuring the background timer is always killed before a new tap is created
**Last verified:** —

Registering the hotkey is not an instant action — it involves setting something up, handing it to macOS, and waiting for confirmation. The app has two separate systems that can both decide to register the hotkey: the onboarding flow (when the user clicks "Next") and a background timer that periodically checks if Accessibility permission has been granted.

If both of them try to register at roughly the same time, the second one tears down what the first one built — because to register a new hotkey, you have to first unregister the current one. During that teardown, even if both attempts succeed, there is a brief window where no hotkey is registered at all. And if the second attempt fails, the user ends up on the tutorial screen with a working-looking app and a dead hotkey.

The theory: **two workers doing the same job without knowing about each other will eventually get in each other's way.**

---

### S-03 — Clicking "Next" twice quickly in onboarding can break the hotkey
**Type:** Shipping gate
**Fixed in:** v1.1.7 — `OnboardingSetupView` now has `@State private var isProcessingNext` that locks the button on first click; resets only on failure; stays locked on success
**Last verified:** —

The "Next" button in the onboarding screen is the moment the hotkey gets registered for the first time. The button has no protection against being clicked more than once — there is no "I'm already working" state. If a user clicks it twice in quick succession (which is natural behavior on a slow machine, or if there's a small lag), the registration happens twice. The second attempt cancels the first. If the second attempt fails for any reason, the user has moved past the setup screen with a broken hotkey.

The theory: **a door that can be opened twice simultaneously is not a safe door.** Any action that should only happen once needs a lock that prevents it from being triggered a second time while it's still happening.

---

### S-04 — Clicking "Later" when the hotkey fails leaves it broken with no recovery
**Type:** Shipping gate
**Fixed in:** v1.1.7 — "Later" now calls `startAccessibilityPolling()` instead of `break`; the app silently polls every 1.5s and self-heals when permission is granted
**Last verified:** —

When the hotkey fails to register, the app shows an alert with three buttons: open System Settings, retry, or "Later." The intended meaning of "Later" is "I'll deal with this soon." But the app interprets it as "never do anything about this again." No background retry. No reminder. No polling. The user clicks Later, goes back to their work, and the hotkey never works for the rest of that session.

Most users who click "Later" are not thinking "I permanently accept a broken app." They expect the app to keep trying in the background. The app doesn't.

The theory: **deferring something and abandoning something are not the same thing.** A good system that's asked to wait writes down a reminder. This one discards it.

---

### S-05 — Retrying after a failure can stack error dialogs on top of each other infinitely
**Type:** Shipping gate
**Fixed in:** v1.1.7 — "Retry" now checks `startListening()` return value; on continued failure it starts `startAccessibilityPolling()` instead of re-showing the alert
**Last verified:** —

When the hotkey fails to register, an error dialog appears with a "Retry" button. If the user clicks Retry and it fails again, another error dialog appears. If they click Retry in that one and it fails again, a third dialog appears — stacked on top of the second, which is stacked on top of the first. There is no limit to how many times this can happen.

The user would have to dismiss every single dialog in reverse order to get back to a normal state. On a machine with a genuine, persistent permission problem, clicking Retry repeatedly could stack dozens of dialogs.

The theory: **a loop that can fail needs a stop condition.** If every failed attempt triggers the same response, and that response can also fail, you need something that says "after N attempts, try a different approach."

---

### S-06 — Closing the setup window with the red X button leaves the app broken and silent
**Type:** Shipping gate
**Fixed in:** v1.1.7 — `OnboardingWindowController` now conforms to `NSWindowDelegate`; `windowWillClose` calls `onComplete` if hotkey was already registered (page 2), or `onDismissedEarly` which starts background polling (page 1)
**Last verified:** —

The onboarding window has a red close button in its top-left corner (as all macOS windows do). The app was only designed to complete setup when the user clicks the intended buttons — it assumed the user would always follow the intended path. If a user closes the window with the red X button at any point during setup, the app never records that setup happened. Nothing is registered. No error appears. The next time they launch the app, setup starts over.

More critically: if the user closes the window *before* granting Accessibility permission, the hotkey is never registered, no alert appears, and the app sits in the menu bar silently doing nothing.

The theory: **there are multiple ways to exit any flow, and not all of them are the intended one.** A robust system accounts for side exits, not just the front door.

---

### S-07 — The setup window can open twice at the same time
**Type:** Shipping gate
**Fixed in:** v1.1.7 — `showOnboarding()` now checks `onboardingController != nil` and calls `bringToFront()` on the existing window instead of spawning a second one
**Last verified:** —

Several things can trigger the setup window: first launch, detecting a new version, or a permission failure mid-use. The app was missing the check that asks "is the setup window already open?" before opening it again. It's possible — through a specific sequence of events — to end up with two setup windows on screen simultaneously, both trying to register the hotkey at the same time.

Two overlapping registration attempts will fight each other, and the result is unpredictable.

The theory: **some processes should only run one instance at a time.** A second instance starting without the first one finishing is almost always wrong.

---

### S-08 — If the version number is unreadable, an entire release cohort can get stuck with a broken hotkey
**Type:** Shipping gate
**Fixed in:** v1.1.7 — version fallback changed from `"0"` to `"missing-\(UUID().uuidString)"` in both `completeLaunchSetup()` and `onComplete`; an unreadable version always generates a new unique string that will never match a stored value, always triggering re-onboarding
**Last verified:** —

After every update, the app checks "what version am I now?" and compares it to "what version was I when I last set up?" If they differ, it resets the Accessibility permission and runs setup again — this is the core mechanism that handles the post-update hotkey re-registration.

The vulnerability: if the version number can't be read (due to a packaging error or build system failure), the app substitutes a placeholder value — the number zero. If the previous version *also* had an unreadable version number and stored zero, then zero equals zero, and the app concludes "nothing has changed." It skips the permission reset. Every user who installed that build ends up with a stale permission that doesn't match the new binary. The hotkey doesn't work. There is no error.

The theory: **a default placeholder value that looks like a real value is dangerous.** If your fallback is indistinguishable from a valid answer, the system cannot tell whether it has real information or is operating on a substitute.

---

## Part 2 — Scenarios That Cause Visible Problems (Not Silent)

These will present the user with an error, a frozen screen, or a confusing experience — but the user will at least *know* something is wrong.

---

### S-09 — The app's fallback permission check uses a method it already knows doesn't work reliably
**Type:** Shipping gate
**Fixed in:** v1.1.7 — `AccessibilityService.isTrusted()` fallback changed from `return AXIsProcessTrusted()` to `return false`; if the test tap can't be created, the answer is definitively "not trusted"
**Last verified:** —

The app checks Accessibility permission in a reliable way: by actually attempting to register the hotkey as a test. If that test itself fails for an unexpected reason, the app falls back to a different, older check — but the app's own documentation describes that older check as unreliable on recent versions of macOS. So in the one situation where the primary method fails and a fallback is most needed, the backup might give a wrong answer.

A wrong answer here means: the app might tell the user their permission is fine when it isn't (or vice versa), leading to the wrong recovery steps.

The theory: **your backup plan should not be something you already know is broken.** A fallback that behaves worse than no fallback creates false confidence.

---

### S-10 — A background permission timer keeps running into the onboarding screen
**Type:** Monitor
**Fixed in:** v1.1.7 — `showPermissionAlert()` now invalidates `accessibilityPollTimer` before calling `showOnboarding()`; `startListening()` also kills the timer at its start so any stale timer is always stopped before tap creation
**Last verified:** —

When the app needs to wait for the user to grant Accessibility permission, it starts a timer that checks every 1.5 seconds. The problem: this timer is not always stopped when it should be. If the user ends up in the setup screen through a different path (replaying tutorial, permission failure mid-session), the old timer is still running. Two timers checking the same thing, neither knowing about the other.

The main risk is the second timer calling the hotkey registration while the user is already registering it through the onboarding screen — causing the race condition described in S-02.

The theory: **a worker who hasn't been told the job is done will keep working.** Any background process that was started to solve a specific problem needs to be explicitly stopped when that problem is solved.

---

### S-11 — Running the app directly from the installation disk image causes a misleading error
**Type:** Monitor
**Last verified:** —

When you download a macOS app, it comes in a disk image (a `.dmg` file). The normal workflow is: open the disk image, drag the app to your Applications folder, then run it. But some users run the app directly from inside the disk image without moving it first.

A disk image is read-only — you can see the files but not modify them. The app needs to modify its own metadata on launch (to remove a security flag placed by the download). On a disk image, this modification silently fails. The security flag stays. The hotkey fails to register. The app then shows an error saying "Accessibility permission is missing" — which is the wrong message. The actual problem has nothing to do with permissions.

The theory: **an error message should describe the actual problem.** When a task fails silently and the failure causes a downstream error, the error message points to the symptom rather than the cause.

---

### S-12 — The app briefly freezes on launch while doing a cleanup task
**Type:** Monitor
**Fixed in:** v1.1.7 — `removeQuarantineFlag()` now runs on a background thread and calls a completion handler on the main thread when done; `completeLaunchSetup()` runs inside that handler so the main thread is never blocked
**Last verified:** —

Every time the app launches, it performs a cleanup task before doing anything else: removing a security flag from its own files. This cleanup runs synchronously — meaning everything else waits for it to finish before proceeding. On most machines with fast storage, this takes milliseconds. On slower hardware, network drives, or machines under load, it could take noticeably longer. During this pause, the menu bar icon appears but the app is frozen and unresponsive.

The theory: **startup tasks should not block the main process if they can be done in parallel.** If you need to take out the trash before guests arrive, don't do it while they're already waiting at the door.

---

## Part 3 — Architecture Risks (Won't Break Today, But Will If Code Changes)

These are not currently causing user-visible problems. They are design patterns that will become bugs if the code around them is changed in certain ways.

---

### S-13 — The "is the hotkey running?" check answers the wrong question
**Type:** Cleanup
**Fixed in:** v1.1.7 — `HotkeyManager.isRunning` now uses `CGEvent.tapIsEnabled(tap:)` instead of `eventTap != nil`; reflects whether the tap is actively receiving events, not just whether the object exists
**Last verified:** —

There is a property in the app that's supposed to answer "is the hotkey currently active?" It checks whether the hotkey *object* exists — not whether the hotkey is actually *working*. These are different things. The object can exist while the hotkey is temporarily paused (which can happen if the system is under load and macOS briefly suspends event monitoring).

The property is not currently read anywhere in the app, so this causes no real problems today. But if it ever gets used as a safety check, it would give the wrong answer.

The theory: **there is a difference between "exists" and "works."** A car in the driveway doesn't mean the engine is running.

---

### S-14 — Two separate timers both run the same permission check
**Type:** Monitor
**Last verified:** —

During onboarding, two independent timers both check whether Accessibility permission has been granted — one inside the setup screen itself, one managed by the main app. They run on the same schedule (every 1.5 seconds) but don't know about each other. Most of the time this is harmless redundancy. But it creates the conditions for the race condition in S-02, and it means every permission check happens twice simultaneously.

The theory: **two workers assigned to the same task without coordination will occasionally interfere with each other.** Redundancy is fine when the workers are aware of each other. Redundancy is risky when they aren't.

---

### S-15 — The app uses "wherever I am" instead of "the main place" when registering the hotkey
**Type:** Cleanup
**Fixed in:** v1.1.7 — Both `CFRunLoopGetCurrent()` calls in `HotkeyManager.start()` and `stop()` changed to `CFRunLoopGetMain()`; explicit and thread-safe regardless of which thread calls them
**Last verified:** —

When the hotkey is registered, it needs to be attached to a specific processing loop inside the app. There are two ways to reference that loop: "whatever loop I'm currently on" and "the main one." The app uses the first option. Right now, this is always the main loop — so it works. But if any future code change ever registers the hotkey from a background thread, "wherever I am" would point to the wrong place and the hotkey would be registered into a void.

The theory: **explicit is safer than contextual.** "The main loop" always means the same thing. "The current loop" means different things depending on context.

---

### S-16 — Stopping the hotkey doesn't fully close the underlying channel
**Type:** Cleanup
**Fixed in:** v1.1.7 — `HotkeyManager.stop()` now calls `CFMachPortInvalidate(tap)` immediately after disabling the tap, before removing the run loop source; fully closes the Mach port so in-flight events cannot arrive after teardown
**Last verified:** —

When the app stops the hotkey (before re-registering a new one), it tells macOS "stop delivering keypresses" — but it doesn't fully close the underlying connection. In theory, a keypress that was already in flight when the stop command was issued could still arrive at the now-dead handler.

In practice, the app's architecture makes this timing window nearly impossible to hit, and even if it were hit, the consequence is harmless. But the underlying channel should be fully closed during a stop, not just disabled.

The theory: **disabling is not the same as disconnecting.** Turning off a faucet prevents new water from flowing, but water already in the pipe can still come out.

---

### S-17 — Two parts of the app can read and write the same value at the same time from different threads
**Type:** Monitor
**Fixed in:** v1.1.7 — `reenableTap()` in the CGEvent callback is now dispatched to the main thread via `DispatchQueue.main.async`; eliminates the data race between the Mach port callback thread and the main thread
**Last verified:** —

The hotkey callback (which runs on a separate background thread managed by macOS) and the main app both have access to the same internal variable. Under normal conditions they don't touch it at the same time. But there is a theoretical moment — a keypress racing with a hotkey re-registration — where they could both read or write that variable simultaneously. This is called a data race, and the outcome is unpredictable.

In the current app structure this is extremely unlikely. But it is a real category of bug.

The theory: **shared resources need coordination.** If two people try to edit the same document at the same time without knowing about each other, one of their edits will be lost.

---

## Part 4 — Cleanup Items (No Bug, Just Untidy)

These have no user-facing impact today. They are clutter that should be removed to keep the codebase readable and to prevent future confusion.

---

### S-18 — A variable is declared but never assigned or used
**Type:** Cleanup
**Fixed in:** v1.1.7 — `pollingTimer` property and all its references removed from `OnboardingWindowController`

There is a variable in the setup controller called `pollingTimer` that was clearly left over from an older version of the code. It is declared, cleaned up when setup finishes... but never actually assigned a value. It is an empty shelf.

---

### S-19 — The app checks permission twice after already confirming it once
**Type:** Cleanup
**Fixed in:** v1.1.7 — `completeLaunchSetup()` now uses `startListening()` return value directly to decide whether to poll; the separate `AccessibilityService.isTrusted()` call that followed a successful `startListening()` has been removed

After successfully registering the hotkey (which is itself proof that permission works), the app immediately runs a separate permission check. This check creates and destroys a test object for no reason, since the preceding success already gave the same answer.

The theory: **locking the door and then going back to check if you locked it is harmless, but it's extra work.**

---

### S-20 — A timer might fire one extra time during a screen transition animation
**Type:** Cleanup

When the setup screen animates to the tutorial screen, there is a 0.3-second crossfade. During that crossfade, both screens technically exist in memory. A timer set for the setup screen might fire one last time while that screen is fading out. The extra firing does nothing harmful — but it's an edge case worth being aware of.

---

### S-21 — Two dialogs appear simultaneously when Accessibility permission was cleared
**Type:** Shipping gate
**Fixed in:** v1.1.7 — `startListening()` no longer shows alerts itself; it returns true/false with no UI side effects. Callers decide the response: `completeLaunchSetup()` polls silently (the system prompt handles user feedback), `onHotkeyChanged` shows the alert explicitly, onboarding shows its inline error.

When macOS's Accessibility TCC entry is cleared (dev build reset, manual revocation, or stale CDHash), the very first attempt to create a CGEvent tap triggers macOS's own system-level "Accessibility Access" prompt. If the app also shows its own custom alert at the same time, the user sees two dialogs about the same problem. One from the operating system, one from the app — overlapping, confusing, and competing for attention.

The theory: **when the system already provides feedback about a problem, adding your own feedback on top creates noise, not clarity.** The system prompt is authoritative and sufficient. The app's job in that moment is to wait quietly for the user to respond to it, then react to the outcome.

---

### S-22 — App stuck in invisible infinite poll when permission is cleared but build number unchanged
**Type:** Shipping gate
**Fixed in:** v1.1.7 — `completeLaunchSetup()` now checks `isTrusted()` first; if false, shows onboarding (which has "Grant Access" that triggers the system prompt). Only calls `startListening()` if already trusted.

When the Accessibility TCC entry is cleared (dev build reset, manual revocation) but the app's build number hasn't changed, the app skips onboarding (same version = no re-onboarding needed). It goes straight to `startListening()`, which fails because no permission exists. Then it starts polling — checking every 1.5 seconds if permission is granted. But the app never appears in the Accessibility settings panel because nothing ever triggered the macOS system prompt that adds it to the list. The polling runs forever. The user sees a menu bar icon and nothing else.

The theory: **a recovery loop that waits for a condition that can never become true without user action, but provides no way for the user to take that action, is an invisible deadlock.** The polling was waiting for the user to toggle a switch that didn't exist because the app was never added to the list.

---

## New Scenarios — Add Here

When a new edge case is discovered through testing, a bug report, or a future stress test session, add it below in the same format before moving it into the appropriate section above.

| Date | Version | Scenario description | Source |
|------|---------|---------------------|--------|
| — | — | — | — |

---

## Release Verification Checklist

Run through these before every release. Check the box and note the build number.

- [ ] **S-01** — Change the hotkey in Settings. Confirm the new hotkey works immediately after changing it.
- [ ] **S-02** — Complete onboarding normally. Confirm the hotkey works immediately after clicking "Next."
- [ ] **S-03** — Double-click "Next" in onboarding quickly. Confirm the app handles it without breaking.
- [ ] **S-04** — Simulate a failed tap (revoke Accessibility mid-session). Click "Later" on the error dialog. Verify the app still heals itself when you re-grant permission.
- [ ] **S-05** — Simulate a failed tap. Click "Retry" repeatedly. Confirm the app does not stack infinite dialogs.
- [ ] **S-06** — Close the onboarding window with the red X button. Relaunch. Confirm the app handles it gracefully (either restarts onboarding or resumes correctly).
- [ ] **S-07** — Trigger onboarding twice (e.g., replay tutorial from Settings while already in onboarding). Confirm only one window appears.
- [ ] **S-08** — Simulate a version change. Confirm the post-update re-grant flow fires and the hotkey works after completing it.
- [ ] **S-09** — Verify the primary permission check is being used, not the fallback, in normal operation.

---

*This file was created after a full adversarial stress test of the v1.1.6 hotkey guardrails. First stress test session: April 2026.*
