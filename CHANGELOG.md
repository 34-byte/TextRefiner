# Changelog

All production releases of TextRefiner. Newest first.

---

## v1.1.9 — 2026-04-08

### What's New
- **Escape-to-cancel** — Press Escape while refinement is in progress to cancel instantly and restore your original text.
- **Input length safeguard** — TextRefiner now caps inputs at 10,000 characters. Longer selections show a 5-second error message instead of processing.
- **Hardened prompt injection defense** — Internal delimiter protection to prevent malicious text in your clipboard from breaking the refinement prompt.

### Improvements
- Refinement history no longer loses entries when the app updates.
- Performance tracking now persists across sessions (stats JSONL format, privacy-safe).

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
