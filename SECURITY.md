# TextRefiner Security Audit
*Automated audit — run: 2026-04-14 04:30 UTC*

---

## Section 9: Recent-Change Additions (this run only)

**Pass 0 — Recent changes scanned:** Daily logs for 2026-04-13 and 2026-04-14.

Changes since last audit:
- **HUD pill animation rework** — `StreamingPanelController` deleted; all HUD states (spinner, checkmark, error) consolidated into `ReadyIndicatorController`. No new file parsing, network endpoints, XPC connections, or external data entry points introduced.
- **Inference timeout** — `withThrowingTaskGroup` racing inference against a 60s sleep. The timeout path throws `RefinementError.inferenceTimedOut` and cancels the detached inference task. No new attack surface beyond existing LLM inference handling.
- **Typing indicator improvements** — `AXWebArea` removed from text input role list; browser detection via bundle ID set; 500ms polling fallback for Electron/Chrome. AX observation scope changes are covered by Sections 6.2 and 6.5.
- **HUD position tracking** — 8ms background AX position poller + `CADisplayLink` vsync reader on main thread. No new external data entry points.
- **SMAC fix** — `teardownElementObserver()` called unconditionally on app switch. No security implications.

**No additions this run** — none of these changes introduce attack surfaces outside Sections 1–8.

---

## Section 1: Secrets & Credential Management

**1.1 — Hardcoded secrets** ✅ PASS

Searched all source files, plists, scripts, and entitlements for API keys, tokens, passwords, and private keys.
- `SUPublicEDKey` in `Info.plist`: `P9AXPluTwv6uB5JYvou3vFpB6d16Ov8zTbt5SHB9sEo=` — this is a **public** Ed25519 key (correct; the private key remains off-disk)
- `configIntegrityHash` in `LocalInferenceService.swift:25` — a SHA-256 digest used for integrity verification, not a credential
- `modelConfiguration` revision pin (`7f0dc925...`) — a git commit hash, not a credential
- No API keys, bearer tokens, AWS keys, HuggingFace tokens, JWTs, or private keys found anywhere

**1.2 — Keychain vs plaintext storage** ✅ PASS

- `history.json` — AES-GCM encrypted at rest; encryption key stored in macOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecUseDataProtectionKeychain: true`). Correct pattern.
- `prompts.json` — Plaintext JSON containing user-authored prompt templates and history. Not a credential. File permissions set to `0600` (`RefinementHistory.swift:190`, `PromptStorage.swift:146`). Prompt templates are user configuration, not secrets.
- `UserDefaults` — hotkey keyCode/modifierFlags, onboarding state, typing indicator toggle. None are sensitive.

**1.3 — Git history for secrets** ✅ PASS

Reviewed all 13 commits. Commits cover initial launch, v1.1.0–v1.2.0 releases, and daily security audits. No `.env` files, private keys, credentials, dSYM files, or build artifacts committed. The Sparkle public key was added in commit `698980b` — correctly, only the public key.

**1.4 — Logging and print statement leaks** ✅ PASS

All `print()` statements that could expose sensitive data are wrapped in `#if DEBUG`:
- `AccessibilityService.swift:71` — copy simulation failure
- `HotkeyManager.swift:47` — tap creation failure
- `TypingMonitor.swift` — all diagnostic prints including char counts and element roles
- `AppDelegate.swift:452` — hotkey configuration display
- `PromptStorage.swift:149` — file write errors
- `RefinementHistory.swift` — file write errors

Release builds produce zero stdout output. `NotificationManager.postFailure` surfaces `error.localizedDescription` in system notifications, but these are user-friendly strings without sensitive content.

**1.5 — Build artifact exposure** ✅ PASS

`.gitignore` explicitly covers:
- `TextRefiner/.build/` — Swift compiler artifacts
- `TextRefiner/TextRefiner.app/` — app bundle
- `TextRefiner/*.zip` — distribution archives

No dSYM files committed. No source maps or debug builds in the repository.

**1.6 — Info.plist secrets** ✅ PASS

`Info.plist`: contains only `SUPublicEDKey` (public key, expected) and `SUFeedURL` (HTTPS URL, not a secret). `Info-Dev.plist`: no Sparkle keys (dev builds skip Sparkle). No private keys in either file.

---

## Section 2: Code Signing & Distribution Security

**2.1 — Entitlements review** ✅ PASS

`TextRefiner.entitlements` contains a single key: `com.apple.security.app-sandbox = false`. No sandbox is required for this app's capabilities (Accessibility API, CGEvent tap, paste simulation). No unnecessary entitlements are present — the footprint is minimal. Network access for model downloads and Sparkle is gated by macOS's App Transport Security without explicit entitlements on ad-hoc signed builds.

**2.2 — Code signing method** ✅ PASS

Ad-hoc signing (`--sign -`) is documented as the intentional permanent distribution model (`build.sh:34`, CLAUDE.md). Known implications are handled:
- Gatekeeper blocking: quarantine removal at launch handles this (see 2.5)
- TCC CDHash invalidation: handled via per-build TCC reset in dev mode and re-onboarding flow in production
- No notarization: acceptable for ad-hoc distribution

**2.3 — Sparkle / update framework configuration** ✅ PASS

- `SUFeedURL`: `https://gist.githubusercontent.com/...` — HTTPS ✅
- `SUPublicEDKey`: present in `Info.plist` ✅
- EdDSA signing tool (`sign_update`) invoked in `build.sh:207` for release builds ✅
- `SUEnableAutomaticChecks: true`, `SUScheduledCheckInterval: 86400` (24h) ✅
- Dev builds skip Sparkle entirely (`UpdateManager.swift:13` — checks for `SUFeedURL`) ✅

**2.4 — Notarization status** ⚠️ PARTIAL

The app is not notarized (no Apple Developer account — intentional). Quarantine removal at launch handles Gatekeeper blocking. The concern is that users downloading via browser will see a Gatekeeper warning, and the recommended remediation (right-click → Open, or `xattr -d`) trains users to bypass Gatekeeper on downloaded binaries. This is inherent to the ad-hoc distribution model and not fixable without Developer ID signing, but is worth acknowledging.

**2.5 — Quarantine handling** ✅ PASS

`removeQuarantineFlag()` (`AppDelegate.swift:749`) scopes the `xattr -dr com.apple.quarantine` command to `Bundle.main.bundlePath` only — the app's own bundle. Arguments are passed as an array (not shell interpolation). No arbitrary path stripping.

**2.6 — Framework embedding** ⚠️ PARTIAL

`build.sh:178` signs `Sparkle.framework` before signing the app bundle. However, Sparkle ships internal XPC services and helper tools (`Autoupdate`, `Updater.app`) which have their own signing. The build script signs the top-level `Sparkle.framework` with ad-hoc (`--sign -`), but does not explicitly recurse into Sparkle's nested bundles first (Sparkle's own build process typically handles this, but it is not verified here). In practice, `codesign --force` on the top-level framework re-signs the whole tree, but this is implicit rather than verified.

---

## Section 3: Process & Shell Execution Security

**3.1 — Process/NSTask inventory** ✅ PASS

Three `Process` invocations in the codebase:

| Location | Command | Arguments | User-controlled input? |
|---|---|---|---|
| `AppDelegate.swift:723` | `/usr/bin/tccutil` | `["reset", "Accessibility", bundleID]` | No — `bundleID` from `Bundle.main.bundleIdentifier` |
| `AppDelegate.swift:753` | `/usr/bin/xattr` | `["-dr", "com.apple.quarantine", bundlePath]` | No — `bundlePath` from `Bundle.main.bundlePath` |
| `AppDelegate.swift:786` | `/bin/bash` | `[buildScript]` | No — `buildScript` derived from `Bundle.main.bundlePath` |

`build.sh` itself invokes: `swift`, `sips`, `iconutil`, `xcrun`, `codesign`, `PlistBuddy`, `ditto`, `tccutil`, `install_name_tool`, `sign_update`. None of these receive user-controlled input.

**3.2 — Shell command injection** ✅ PASS

No `Process` invocation uses `/bin/sh -c` or `/bin/bash -c` with string interpolation. All arguments are passed as arrays:
- `tccutil`: `["reset", "Accessibility", bundleID]`
- `xattr`: `["-dr", "com.apple.quarantine", bundlePath]`
- `bash buildScript`: `[buildScript]` (runs the script, not `-c` with a string)

In `build.sh`, `BUNDLE_ID` is read from `PlistBuddy` (the app's own Info.plist) and passed to `tccutil "$BUNDLE_ID"` — shell-quoted, not interpolated into `-c` strings.

**3.3 — Subprocess environment** ✅ PASS

All three `Process` invocations set explicit, minimal `process.environment`:
- `tccutil` and `xattr`: `["PATH": "/usr/bin:/bin"]`
- `bash buildScript`: `["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec", "HOME": <user home>]`

The `HOME` variable is passed to `build.sh` (required for Swift package resolution which writes to `~/.cache`). No sensitive environment variables (tokens, secrets) are in the app's environment to inherit.

**3.4 — Dynamic library loading** ✅ PASS

`install_name_tool -add_rpath @executable_path/../Frameworks` in `build.sh:63` — sets rpath to the app bundle's Frameworks directory, which is not world-writable. No `dlopen()` calls in Swift source. No `@loader_path` or absolute user-writable path rpaths.

**3.5 — tccutil and privilege-sensitive commands** ✅ PASS

- **Runtime** (`AppDelegate.swift:722`): `tccutil reset Accessibility bundleID` where `bundleID = Bundle.main.bundleIdentifier`. Scoped to the app's own bundle ID only. Guards against nil.
- **Build time** (`build.sh:239`): `tccutil reset Accessibility "$BUNDLE_ID"` where `BUNDLE_ID` is read from the app's own Info.plist via `PlistBuddy`. Dev-mode only (the `else` branch — `MODE != release`). Production builds never invoke `tccutil`.

---

## Section 4: Local Data Storage Security

**4.1 — UserDefaults for sensitive data** ✅ PASS

All UserDefaults keys:
- `com.textrefiner.onboardingCompleted` — boolean
- `com.textrefiner.lastOnboardedBuild` — build number string
- `com.textrefiner.hotkeyKeyCode` — integer (virtual key code)
- `com.textrefiner.hotkeyModifierFlags` — integer (modifier bitmask)
- `com.textrefiner.showTypingIndicator` — boolean

None are sensitive credentials. The hotkey configuration is a preference, not a secret.

**4.2 — Application Support files** ⚠️ PARTIAL

Two data files in `~/Library/Application Support/TextRefiner/`:

- **`history.json`** — Contains original and refined user text (up to 10 entries). AES-GCM encrypted. File permissions set to `0600`. Encryption key in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. This is well-implemented. *Gap*: without sandbox, any process running as the same user can query the Keychain service `com.textrefiner.app` / account `history-encryption-key` and retrieve the key (no app-specific ACL is enforced on ad-hoc signed, non-sandboxed apps in the Data Protection Keychain). Encryption still provides meaningful protection against disk forensics and processes running as other users.

- **`prompts.json`** — Contains user-authored prompt templates (plaintext). File permissions `0600`. Not a credential. However, a malicious same-user process could overwrite this file with an adversarial system prompt. Since the active prompt is read at inference time (`LocalInferenceService.swift:46`), tampered prompts take effect on the next refinement. The validation only checks for `{{USER_TEXT}}` presence. *This is LOW severity*: an attacker with write access to Application Support already has full user-level access.

**4.3 — Pasteboard handling** ⚠️ PARTIAL

The app reads the system pasteboard after simulating Cmd+C and writes the refined text before simulating Cmd+V. Two gaps:

1. **Original clipboard content is permanently lost** — The pre-Cmd+C clipboard content is not saved and not restored after the refinement. Users lose whatever was on their clipboard before triggering TextRefiner.

2. **Pasteboard exposure window** — There is a window where the original selected text (post-Cmd+C) and then the refined text (post-inference) sit on the system pasteboard. Any process monitoring `NSPasteboard.general` (pasteboard monitoring apps, clipboard managers) can silently read both. This is inherent to any clipboard-based text tool (Grammarly, iA Writer, etc.) and cannot be avoided without a different architectural approach (direct AX text write, which has its own trade-offs).

These are inherent design trade-offs, not bugs. The refined text intentionally remains on the clipboard as a fallback if Cmd+V paste simulation fails.

**4.4 — Temporary files** ⬚ N/A

No files are written to `NSTemporaryDirectory()` or `/tmp`. No caches in `~/Library/Caches/`. The `.build/` directory is build-time only and gitignored.

**4.5 — JSON/plist deserialization safety** ✅ PASS

- `prompts.json` deserialization: `try? JSONDecoder.withISO8601.decode(PromptData.self, from: jsonData)` — failure falls back to default prompt (`PromptStorage.swift:131`). No force-unwrap, no fatalError.
- `history.json` deserialization: decryption failure → `entries = []` (`RefinementHistory.swift:87`); plaintext fallback decode failure → `entries = []`. Graceful in all paths.
- Malformed JSON cannot crash the app; it silently resets to defaults.

---

## Section 5: Input Validation & Injection

**5.1 — LLM prompt injection** ✅ PASS

Three delimiter strings stripped from clipboard content before injection (`LocalInferenceService.swift:184-187`):
- `[TEXT_START]`
- `[TEXT_END]`
- `{{USER_TEXT}}`

10,000 character input cap enforced before inference (`RefinementCoordinator.swift:91`). Model output is used exclusively for clipboard paste — no code execution, URL navigation, file operations, or privileged actions are driven by the output. Prompt injection leading to unexpected pasted text is the worst-case outcome, not privilege escalation.

**5.2 — Model output sanitization** ✅ PASS

`cleanResponse()` (`LocalInferenceService.swift:231`) strips:
- Preamble phrases ("Here is the rewritten text:", "Sure,", "Certainly!", etc.)
- Leaked delimiters (`[TEXT_START]`, `[TEXT_END]`)
- Wrapping quotes
- Leading/trailing whitespace

Called after full token accumulation (not per-token) to avoid mid-word false positives. Output is only used for `NSPasteboard.setString` + Cmd+V — no control character concerns beyond normal text paste.

**5.3 — Pasteboard content validation** ✅ PASS

`NSPasteboard.general.string(forType: .string)` returns `nil` for non-string content types, which propagates as `nil` from `simulateCopyAndRead()`, causing `noTextSelected` error. 10,000 character cap prevents excessive memory allocation from large clipboard content. All handled gracefully.

**5.4 — Untrusted data deserialization** ⚠️ PARTIAL

- `history.json`: AES-GCM encrypted — a tampered file fails decryption and results in empty history. Safe.
- `prompts.json`: As noted in 4.2, a malicious same-user process could overwrite this file with an adversarial prompt template. The prompt validation only checks for `{{USER_TEXT}}`. A tampered prompt containing harmful instructions would be injected into every subsequent LLM call. *LOW severity* given same-user prerequisite.
- Model config.json: SHA-256 pinned (`configIntegrityHash = "c546925..."`) and verified before inference. If hash fails, model directory is deleted and an error is thrown (`LocalInferenceService.swift:76-82`). 
- Model weight files (.safetensors): **NOT individually SHA-256 verified**. Only `config.json` is checked. A malicious party who could replace weight files (requires Hugging Face compromise + specific revision, or post-download tampering with user-level access) could influence model behavior. HTTPS + pinned revision makes this extremely unlikely in practice.

---

## Section 6: Accessibility & System Integration Security

**6.1 — CGEvent tap scope** ✅ PASS

- Event mask: `1 << CGEventType.keyDown.rawValue` — keyDown events only (narrow) ✅
- Tap type: `.defaultTap` — required to consume the hotkey event ✅
- Non-matching events: returned unmodified (`Unmanaged.passRetained(event)`) ✅
- Escape only consumed when `onEscapePressed != nil` (set only during active processing) ✅
- Cleanup: `CFMachPortInvalidate(tap)` + `CFRunLoopRemoveSource(...)` in `stop()` (`HotkeyManager.swift:64`) ✅
- Tap disabled by macOS (timeout/user input protection): re-enabled via `reenableTap()`, dispatched to main thread to prevent data race ✅

**6.2 — Accessibility API usage patterns** ⚠️ PARTIAL

`TypingMonitor.readCharacterCount()` reads `kAXValueAttribute` (full text content) from focused text fields — used for (1) placeholder comparison and (2) string length fallback when `kAXNumberOfCharactersAttribute` is unavailable. The full text string is:
- Never logged in release builds ✅
- Never stored persistently (stack-local) ✅
- Never transmitted ✅

*Gap*: the full text of any text field in any frontmost app transiently passes through the TextRefiner process memory. A memory dump or a future code change (adding logging) could expose this content. This is inherent to the architecture of a character-count-based typing indicator. The primary fast path uses `kAXNumberOfCharactersAttribute` which doesn't require reading the text content.

Observers are properly cleaned up in `teardownAppObserver()` and `teardownElementObserver()`. Observation is scoped to the frontmost app's PID and focused element only.

**6.3 — TCC permission handling** ✅ PASS

- `NSAccessibilityUsageDescription` in both `Info.plist` and `Info-Dev.plist` ✅
- `requestPermission()` calls `AXIsProcessTrustedWithOptions` with prompt — shown once, then System Settings ✅
- Permission denied at hotkey time: `showPermissionAlert()` explains and offers re-onboarding ✅
- Permission revoked mid-session: detected by `isTrusted()` (CGEvent tap test), polling timer recovers ✅

**6.4 — Key simulation scope** ✅ PASS

Only two key combos are simulated:
- Cmd+C (`keyCode 0x08`, `CGEventFlags.maskCommand`) — read selected text
- Cmd+V (`keyCode 0x09`, `CGEventFlags.maskCommand`) — paste refined text

Both are gated behind user-initiated hotkey press in `startRefinement()`. `CGEventSource(.hidSystemState)` used (transparent simulation). No attacker-controlled key sequences are possible — the only paste is the LLM output string set via `NSPasteboard.setString`.

**6.5 — AXObserver scope** ⚠️ PARTIAL

AX observation is correctly scoped to the frontmost app and its focused element. Observers are torn down on app switch and focus change.

*Gap*: `isTextInputElement()` checks for `kAXTextFieldRole`, `kAXTextAreaRole`, `AXComboBox`, and `AXSearchField`. The role `kAXSecureTextFieldRole` (password fields) is not explicitly excluded. The settable-value fallback could also match some password field implementations. In practice:
- macOS prevents reading `kAXValueAttribute` from secure text fields (returns empty string)
- `kAXNumberOfCharactersAttribute` may still return a count, which could trigger the typing indicator while the user types a password

The actual password content is protected by macOS, but the indicator appearing in a password field is a UX/privacy concern. The typing indicator pill appearing while a user types a password could be surprising and confusing.

---

## Section 7: Network Security

**7.1 — HTTPS enforcement** ✅ PASS

All network connections use HTTPS:
- Sparkle appcast: `https://gist.githubusercontent.com/34-byte/6a5dacdb24a6bae85d003e906f5fa907/raw/appcast.xml`
- Model download: Hugging Face via `HubApi` (HTTPS enforced by the Hub library)
- No `NSAllowsArbitraryLoads` in `Info.plist` — default ATS strict mode applies

**7.2 — Certificate pinning** ⚠️ PARTIAL

- Sparkle: EdDSA signature verification enforces update integrity beyond TLS (correct) ✅
- Model downloads: No certificate pinning. Compensating control: SHA-256 integrity check on `config.json` post-download. Not pinned to a specific Hugging Face TLS certificate. A CA compromise (extremely unlikely) could enable MITM on model downloads, but the SHA-256 check on config.json would catch a tampered config.

**7.3 — Download integrity** ⚠️ PARTIAL

- Sparkle updates: EdDSA-signed by `sign_update` tool, verified by Sparkle before installation ✅
- Model weights: **Only `config.json` is SHA-256 verified** (`LocalInferenceService.swift:64-82`). The `.safetensors` weight files (~1.8 GB) are downloaded and loaded without individual file integrity checks. The pinned git revision (`7f0dc925...`) provides a strong compensating control — only files at that exact commit are fetched — but a post-download same-user tamper could replace weight files without detection.

**7.4 — Appcast feed security** ⚠️ PARTIAL

- HTTPS ✅
- EdDSA signing ✅
- Hosted on GitHub Gist (GitHub-controlled CDN) ✅
- `minimumSystemVersion` in the appcast XML: cannot be verified from source code alone — requires reading the live appcast. If absent, a downgrade attack (pushing an older vulnerable version) would not be blocked by Sparkle.

---

## Section 8: Dependency & Package Security

**8.1 — Swift Package Manager dependency audit** ✅ PASS

| Package | Version constraint | Source | Status |
|---|---|---|---|
| `Sparkle` | `from: "2.6.0"` | `github.com/sparkle-project/Sparkle` | Active, well-maintained |
| `mlx-swift-lm` | `from: "2.30.0"` | `github.com/ml-explore/mlx-swift-lm` | Apple-maintained |
| `mlx-swift` | `from: "0.31.3"` | `github.com/ml-explore/mlx-swift` | Apple-maintained |
| `swift-transformers` | `from: "1.2.0"` | `github.com/huggingface/swift-transformers` | Hugging Face-maintained |

All use `from:` (minimum version) constraints — not branch-based. All from trusted organizations. No known CVEs. All fetched over HTTPS from GitHub.

**8.2 — Package.resolved / lockfile committed** ✅ PASS

`TextRefiner/Package.resolved` exists in the repository (confirmed via file listing). Dependency versions are locked.

**8.3 — Unnecessary dependencies** ✅ PASS

All declared dependencies are actively used:
- `Sparkle` → `AppDelegate.swift`, `UpdateManager.swift`
- `MLXLLM`, `MLX`, `MLXRandom`, `MLXLMCommon` → `LocalInferenceService.swift`
- `Hub` → `LocalInferenceService.swift`

No unused packages.

**8.4 — Framework embedding security** ⚠️ PARTIAL

`build.sh:178` signs `Sparkle.framework` with `codesign --force --sign -` before the app bundle is signed. The `--force` flag re-signs the framework including nested bundles (Sparkle's XPC service `org.sparkle-project.Autoupdate`, helper tool). This is correct behavior in practice, but the build script does not explicitly enumerate and sign each nested component before the top-level sign — it relies on `codesign --force` cascading. No vulnerability here, but explicit enumeration would be more auditable.

@rpath is set to `@executable_path/../Frameworks` — non-world-writable, correct.

**8.5 — Build script dependencies** ⚠️ PARTIAL

Build tools (`swift`, `sips`, `iconutil`, `xcrun`, `codesign`, `PlistBuddy`, `ditto`, `tccutil`, `install_name_tool`) are resolved via `PATH` rather than absolute paths. In a local developer environment, `PATH` manipulation is generally low risk (an attacker with user-level access can do more directly). In a CI/CD environment, a compromised `PATH` entry could inject a malicious `xcrun` or `codesign`. For local ad-hoc development, this is acceptable; for hardened CI pipelines, absolute paths would be preferred.

No external resources are downloaded during the build. Build artifacts in `.build/` are gitignored and local.

---

## 1. Security Posture Rating

**🟡 ACCEPTABLE** — Minor issues, no immediate data exposure risk to a standard threat model.

TextRefiner has no CRITICAL or HIGH findings. The most security-relevant components — Sparkle update verification (EdDSA), history data encryption (AES-GCM + Keychain), prompt injection hardening (delimiter stripping), CGEvent tap scope (keyDown only, narrow event mask), and process isolation (minimal explicit environments) — are all correctly implemented. The primary gaps are informational: model weight files lack individual SHA-256 verification (compensated by HTTPS + pinned revision), the typing indicator does not explicitly exclude password fields (macOS protects the content itself), and the system pasteboard exposes refined text to other same-user processes (inherent to clipboard-based architecture). For a desktop app without network APIs, distributed ad-hoc, with no remote attack surface, the threat model is primarily local same-user process access — and the encryption, file permissions, and sandboxing trade-offs are handled appropriately.

---

## 2. Critical and High Findings

**None.** No CRITICAL or HIGH severity findings were identified in this audit.

---

## 3. Quick Wins

1. **Exclude `kAXSecureTextFieldRole` from `isTextInputElement()`** (~5 min) — Add an explicit check for the password field role to prevent the typing indicator from appearing in password fields. While macOS protects the content, the indicator appearance is a UX/privacy concern.

2. **Verify appcast `minimumSystemVersion`** (~10 min) — Read the live appcast XML and confirm it specifies `minimumSystemVersion` to prevent Sparkle from offering downgrade updates.

3. **Upgrade `kAXNumberOfCharactersAttribute` as primary in all code paths** (~15 min) — Audit all `readCharacterCount` paths to ensure the full `kAXValueAttribute` text read is only taken when the character count attribute is unavailable, minimizing how often full text content enters process memory.

---

## 4. Prioritized Remediation Plan

| # | Finding | Severity | Est. Effort |
|---|---|---|---|
| 1 | 6.5 — `kAXSecureTextFieldRole` not excluded from typing indicator | LOW | ~5 min |
| 2 | 4.3 — Original clipboard content not restored after refinement | LOW | ~30 min |
| 3 | 7.4 — Appcast `minimumSystemVersion` unverified | LOW | ~10 min |
| 4 | 7.3 — Model weight files (.safetensors) not SHA-256 verified post-download | LOW | ~2 hrs |
| 5 | 5.4 / 4.2 — `prompts.json` tamperability by same-user processes | LOW | N/A (inherent) |
| 6 | 4.2 — Keychain key for history.json has no app-specific ACL | LOW | ~1 hr |
| 7 | 2.4 — Quarantine removal trains users to bypass Gatekeeper | INFO | N/A (inherent) |
| 8 | 2.6 / 8.4 — Sparkle nested bundle signing implicit, not explicit | INFO | ~30 min |
| 9 | 8.5 — Build tools resolved via PATH, not absolute paths | INFO | ~15 min |
| 10 | 6.2 — Full text content transiently read via `kAXValueAttribute` | INFO | ~30 min |

---

## 5. What's Already Done Right

- **Sparkle EdDSA verification**: Update signatures enforced end-to-end (build script + Info.plist + HTTPS feed)
- **History data encryption**: AES-GCM with Keychain-stored key, `0600` file permissions, one-time migration from plaintext on first run
- **Prompt injection hardening**: Three delimiter strings stripped from clipboard content before LLM injection; output used only for paste, no downstream execution
- **CGEvent tap discipline**: Narrow `keyDown`-only event mask; non-matching events passed through; Escape consumed only during active processing; proper CFMachPort invalidation on stop
- **Process invocations hardened**: All three `Process` uses have explicit minimal environments, array-based arguments (no shell interpolation), and hardcoded executable paths
- **`tccutil` scoped to own bundle ID**: Runtime path reads `Bundle.main.bundleIdentifier`, not a user-supplied string
- **Quarantine removal scoped**: `xattr -dr` targets only `Bundle.main.bundlePath`, not arbitrary paths
- **Debug-only logging**: All potentially sensitive `print()` statements wrapped in `#if DEBUG`; zero stdout in release builds
- **Model integrity check**: `config.json` SHA-256 pinned to specific git revision; mismatch deletes model directory and forces re-download
- **Input length cap**: 10,000 character limit enforced before inference; graceful error HUD instead of blocking alert
- **Inference timeout**: 60-second timeout kills the detached MLX task explicitly (correct cancellation of `Task.detached` outside structured concurrency)
- **Package lockfile committed**: `Package.resolved` in repo — reproducible dependency resolution
- **File permissions**: Both `prompts.json` and `history.json` set to `0600` after write

---

## 6. Checklist Summary

```
1.1 ✅  1.2 ✅  1.3 ✅  1.4 ✅  1.5 ✅  1.6 ✅
2.1 ✅  2.2 ✅  2.3 ✅  2.4 ⚠️  2.5 ✅  2.6 ⚠️
3.1 ✅  3.2 ✅  3.3 ✅  3.4 ✅  3.5 ✅
4.1 ✅  4.2 ⚠️  4.3 ⚠️  4.4 ⬚  4.5 ✅
5.1 ✅  5.2 ✅  5.3 ✅  5.4 ⚠️
6.1 ✅  6.2 ⚠️  6.3 ✅  6.4 ✅  6.5 ⚠️
7.1 ✅  7.2 ⚠️  7.3 ⚠️  7.4 ⚠️
8.1 ✅  8.2 ✅  8.3 ✅  8.4 ⚠️  8.5 ⚠️
9   — No additions this run
```

**Summary**: 27 ✅ PASS · 10 ⚠️ PARTIAL · 0 ❌ FAIL · 1 ⬚ N/A
