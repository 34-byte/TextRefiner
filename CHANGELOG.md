# Changelog

All production releases of TextRefiner. Newest first.

---

## v1.5.0 — 2026-05-05

### What's New
- **Excluded Apps** — You can now choose which apps the typing indicator pill is hidden in. Go to Settings and add any app from your Mac. The hotkey still works in excluded apps — only the floating pill is suppressed.

---

## v1.4.0 — 2026-04-15

### What's New
- **Dock icon** — TextRefiner now appears in your Dock. Clicking it opens the menu, just like any standard Mac app. You can hide it in Settings if you prefer menu-bar-only.
- **Welcome screen** — First-time setup now opens with a quick intro: what TextRefiner does, how it works, and why your text never leaves your Mac — before asking for any permissions.

### Improvements
- **Faster HUD on first use** — The floating indicator no longer feels sluggish the first time you refine after launching the app, or after your Mac has been idle for a few hours.
- **Pill hides after refinement** — After a refinement completes, the pill disappears immediately. It only reappears when you start typing new content. Applies to all apps, including Slack and VS Code.

---

## v1.3.0 — 2026-04-14

### What's New
- **Smarter HUD** — The floating indicator now tracks your cursor and text field in real time. The progress animation appears exactly where you're working instead of a fixed corner of the screen.
- **Polished animations** — The HUD expands and collapses with smooth easing. The icon fades out before the shape morphs back, making the transition feel intentional rather than abrupt.
- **Inference timeout** — If the AI takes longer than 60 seconds, TextRefiner cancels automatically and shows an error instead of hanging indefinitely.
- **"No text selected" error** — Triggering the hotkey with nothing selected now shows an inline error in the HUD instead of a blocking alert dialog.
- **Pill stays visible** — After a refinement completes in a native app, the floating pill remains visible so you can refine again immediately without retyping.

### Improvements
- Typing indicator now works correctly inside Chrome and Electron-based apps (e.g. VS Code, Notion).
- Typing indicator no longer re-appears immediately after a refinement completes.
- TextRefiner now checks for updates every hour instead of once a day.
- Hotkey pill text is now correctly vertically centered.
- Minimum macOS version raised to Sequoia (15.0).

---

## v1.2.0 — 2026-04-12

### What's New
- **Faster cancel** — Pressing Escape now stops the AI mid-sentence. You get control back in 1–2 seconds instead of waiting for it to finish.
- **Safer paste** — If pasting fails for any reason, TextRefiner tells you the refined text is ready on your clipboard so you can paste it yourself.
- **Loading timeout** — If the AI model can't load, TextRefiner shows an error instead of spinning forever.

### Improvements
- The success checkmark and sound now land at the same moment your text changes on screen.
- Fixed a bug where pressing the hotkey twice very fast could load the AI model twice, doubling memory usage.
- Hotkey listener cleanup is more robust when changing shortcuts in Settings.

---

## v1.1.9 — 2026-04-08

### What's New
- **Audio feedback** — A subtle sound plays when refinement succeeds or fails, so you always know the result without looking at the screen.
- **Escape-to-cancel** — Press Escape while refinement is in progress to cancel instantly and restore your original text.
- **Input length safeguard** — TextRefiner caps inputs at 10,000 characters. Longer selections show a 5-second inline error instead of attempting to process.
- **Model integrity check** — TextRefiner verifies the AI model files haven't been tampered with before running inference. A corrupted or altered model triggers a clean re-download.

### Security
- Hardened against malicious clipboard content that could break the refinement prompt.

---

## v1.1.8 — 2026-04-06

### What's New
- **On-device AI** — TextRefiner no longer requires Ollama. The AI model (Llama 3.2 3B) runs fully on your Mac and is downloaded automatically on first launch (~1.8 GB).
- **Typing indicator** — A small floating pill appears near your text field when you've typed enough to refine (~7+ words), showing the active hotkey as a reminder.
- **Hardware compatibility check** — Onboarding now verifies your Mac meets the requirements (Apple Silicon, 8 GB RAM) before downloading the model.

### Improvements
- Configurable hotkey re-registers instantly without restarting the app.
- Onboarding no longer advances past the Accessibility step until the hotkey is confirmed working — prevents silent failures after setup.
- App now appears correctly in System Settings → Accessibility after every update.

---

## v1.1.0 — 2026-04-05

### What's New
- **Custom hotkey** — Configure your preferred shortcut in Settings (default: ⌘⇧R).
- **Refinement history** — View your last 10 refinements; click any entry to copy the refined text.
- **Prompt Settings** — Edit the AI instruction prompt, browse prompt history, and revert to any previous version.
- **Launch on login** — Toggle in Settings so TextRefiner starts automatically with your Mac.
- **In-app updates** — TextRefiner checks for updates in the background and lets you install from the menu bar.

---

## v1.0.x — Pre-release

Internal development builds. Not distributed publicly.
