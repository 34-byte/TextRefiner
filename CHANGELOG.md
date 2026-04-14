# Changelog

All production releases of TextRefiner. Newest first.

---

## v1.3.0 — 2026-04-14

### What's New
- **Smarter HUD** — The floating indicator now tracks your text field in real time, so the progress animation appears exactly where you're working instead of a fixed position on screen.
- **Polished animations** — The HUD expands and collapses with smooth easing. The checkmark and spinner fade in with a staggered timing that feels noticeably more refined.
- **Inference timeout** — If the AI takes longer than 60 seconds, TextRefiner cancels and shows an error instead of hanging indefinitely.

### Improvements
- Typing indicator now works correctly inside web pages in Chrome and other browsers.
- Typing indicator no longer flickers or re-appears immediately after a refinement completes.
- TextRefiner now checks for updates every hour instead of once a day, so you get fixes sooner.

---

## v1.2.0 — 2026-04-12

### What's New
- **Faster cancel** — Pressing Escape now stops the AI mid-sentence instead of waiting for it to finish. You get control back in 1–2 seconds.
- **Safer paste** — If pasting fails for any reason, TextRefiner tells you the text is ready on your clipboard so you can paste it yourself.
- **Loading timeout** — If the AI model can't load (bad connection, corrupted files), TextRefiner shows an error instead of spinning forever.

### Improvements
- The success checkmark and sound now feel simultaneous with your text changing on screen. Previously there was a brief moment where you'd see "done" before anything changed in your document.
- Fixed a bug where pressing the hotkey twice very fast could load the AI model twice, doubling memory usage.
- Hotkey listener cleanup is now more robust when changing shortcuts in Settings.
- Instant paste — removed a leftover delay between refinement and the success checkmark.

---

## v1.1.9 — 2026-04-08

### What's New
- **Audio feedback** — A subtle sound plays when refinement succeeds or fails, so you always know the result without looking at the screen.
- **Escape-to-cancel** — Press Escape while refinement is in progress to cancel instantly and restore your original text.
- **Input length safeguard** — TextRefiner now caps inputs at 10,000 characters. Longer selections show a 5-second error message instead of processing.
- **Encrypted refinement history** — Your history is now stored encrypted on disk. Existing history migrates automatically on first launch.
- **Model integrity verification** — TextRefiner now verifies the AI model files haven't been tampered with before running inference. A corrupted or substituted model triggers a clean re-download.

### Security
- Hardened prompt injection defense to prevent malicious clipboard content from breaking the refinement prompt.

---

## v1.1.8 — 2026-04-06

### What's New
- **On-device AI inference** — TextRefiner no longer requires Ollama. The AI model (Llama 3.2 3B) runs fully on your Mac. Downloaded automatically on first launch (~1.8 GB).
- **Typing indicator** — a small floating pill appears near your text field when you've typed enough to refine (~7+ words), showing the active hotkey as a reminder.
- **Hardware compatibility check** — onboarding now verifies your Mac meets the requirements (Apple Silicon + 8 GB RAM) before attempting to download the model.

### Improvements
- Configurable hotkey now re-registers instantly without restarting the app.
- Launch on login and refinement history panel added to Settings.
- Onboarding no longer advances past the Accessibility step until the hotkey is confirmed working — prevents silent failures after setup.
- App now appears correctly in System Settings → Accessibility after every Sparkle update.
- Hotkey tap is protected against a range of edge cases: window close during processing, double-trigger prevention, tap leak after rapid settings changes, and more.

---

## v1.1.0 — 2026-04-05

### What's New
- **Custom hotkey** — configure your preferred shortcut in Settings (default: ⌘⇧R).
- **Refinement history** — view your last 10 refinements; click any entry to copy the refined text.
- **Prompt Settings** — edit the AI instruction prompt, browse prompt history, and revert to any previous version.
- **Launch on login** — toggle in Settings so TextRefiner starts automatically with your Mac.
- **In-app updates** — TextRefiner checks for updates in the background and lets you install them from the menu bar without visiting a website.

---

## v1.0.x — Pre-release

Internal development builds. Not distributed publicly.
