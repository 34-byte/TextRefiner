# TextRefiner Security Audit
*Automated audit — run: 2026-04-15 04:30 UTC*

---

## 1. Security Posture Rating

🟡 **ACCEPTABLE** — Minor issues, no immediate data exposure risk to a standard threat model.

TextRefiner is a well-secured local macOS application. Refinement history is encrypted at rest with AES-GCM using a Keychain-stored key. Prompt injection is hardened with delimiter sanitization. All Process invocations use argument arrays with restricted environments (never shell -c with user data). The CGEvent tap is correctly scoped to keyDown-only events with proper cleanup. AXObservers are properly scoped per frontmost app and torn down on app switch. All network connections use HTTPS; Sparkle update downloads are EdDSA-signed. Sensitive debug output is uniformly wrapped in `#if DEBUG`.

The primary gaps are: (1) model weight files from Hugging Face are not individually integrity-checked — only `config.json` has a pinned SHA-256 hash; (2) the previous clipboard content is not restored after use, exposing briefly-refined text to other clipboard-reading apps; (3) the `SettingsWindowController.rebuildAndRelaunch` subprocess inherits the full parent environment rather than a restricted one (dev-only, low risk). None of these are immediately exploitable by a remote attacker — the threat model for this app is local: other processes running as the same user, supply chain attacks, and physical access.

---

## 2. Critical and High Findings

None.

---

## 3. Quick Wins

1. **Restrict SettingsWindowController.rebuildAndRelaunch environment** to match AppDelegate.rebuildAndRelaunch (`PATH`, `HOME` only). One line change. Estimated: ~2 minutes.
2. **Add `<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>` to appcast.xml** for the v1.3 release entry when it is published. Estimated: ~2 minutes.
3. **Add individual safetensors integrity hash checks** (or use the Hub library's built-in hash field) so that model weights are verified alongside config.json. Estimated: ~30 minutes.

---

## 4. Prioritized Remediation Plan

| # | Severity | Finding | Estimated Fix |
|---|----------|---------|---------------|
| 1 | MEDIUM | Model weight files lack integrity verification (7.3) | ~30 min |
| 2 | LOW | SettingsWindowController subprocess inherits full parent environment (3.3) | ~2 min |
| 3 | LOW | appcast minimumSystemVersion not yet set for v1.3 (7.4) | ~2 min |
| 4 | INFO | Pasteboard content not restored after use (4.3) | Design decision |

---

## 5. What's Already Done Right

- **AES-GCM encryption for history data** — `history.json` encrypted at rest; key stored in Data Protection Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- **Prompt injection hardening** — `[TEXT_START]`, `[TEXT_END]`, and `{{USER_TEXT}}` stripped from clipboard text before injection in `LocalInferenceService.streamRewrite()`.
- **Model config integrity check** — SHA-256 of `config.json` is pinned at a specific Hugging Face revision; mismatch deletes the model directory and forces a clean re-download.
- **Argument-array Process invocations** — All subprocess calls use `process.arguments = [...]` with no shell interpolation of user data.
- **Restricted subprocess environments** — `xattr` and `tccutil` invocations explicitly set `process.environment = ["PATH": "/usr/bin:/bin"]`.
- **CGEvent tap scoped to keyDown only** — Event mask is `1 << CGEventType.keyDown.rawValue`, not a broad mask. Non-matching events are returned, not dropped.
- **Correct CGEvent tap cleanup** — `CFMachPortInvalidate` + `CFRunLoopRemoveSource` called on `stop()`. Test tap in `isTrusted()` also immediately cleaned up.
- **AXObserver scope** — Per-app observer tears down on app switch. Per-element observer tears down on focus change. Own PID excluded. Browsers excluded entirely.
- **Escape intercepted only during processing** — `onEscapePressed` is nil by default; set only between `onProcessingStarted` and `onProcessingFinished`/`onError`.
- **0o600 file permissions** on `prompts.json` and `history.json`.
- **Atomic writes** (`.atomic` option) on both Application Support files.
- **Debug-only logging** — All `print` statements wrapped in `#if DEBUG`; no clipboard content ever logged.
- **Sparkle EdDSA signing** — `SUPublicEDKey` present, appcast served over HTTPS.
- **tccutil scoped to own bundle ID** — `resetAccessibilityPermission()` resets only `Bundle.main.bundleIdentifier`.
- **HTTPS everywhere** — No HTTP URLs. ATS defaults apply (no `NSAllowsArbitraryLoads`).
- **Package.resolved committed** — Lockfile prevents version drift across machines.
- **No hardcoded secrets** — Only `SUPublicEDKey` (public key, correct) and `configIntegrityHash` (public hash, correct) appear as embedded fixed values.

---

## 6. Checklist Summary

```
1.1 ✅  1.2 ✅  1.3 ✅  1.4 ✅  1.5 ✅  1.6 ✅
2.1 ✅  2.2 ✅  2.3 ✅  2.4 ✅  2.5 ✅  2.6 ✅
3.1 ✅  3.2 ✅  3.3 ⚠️  3.4 ✅  3.5 ✅
4.1 ✅  4.2 ✅  4.3 ⚠️  4.4 ✅  4.5 ✅
5.1 ✅  5.2 ✅  5.3 ✅  5.4 ✅
6.1 ✅  6.2 ✅  6.3 ✅  6.4 ✅  6.5 ✅
7.1 ✅  7.2 ✅  7.3 ⚠️  7.4 ⚠️
8.1 ✅  8.2 ✅  8.3 ✅  8.4 ✅  8.5 ✅
9   — No additions this run
```

---

## Section-by-Section Results

### Section 1: Secrets & Credential Management

**1.1 Hardcoded secrets** ✅ PASS
No API keys, tokens, passwords, or private keys found in any source file, plist, script, or config. `SUPublicEDKey` (`P9AXPluTwv6uB5JYvou3vFpB6d16Ov8zTbt5SHB9sEo=`) in `Info.plist` is the Ed25519 public verification key for Sparkle — correct and expected. `configIntegrityHash` in `LocalInferenceService.swift:25` is a public SHA-256 hash of a public model file.

**1.2 Keychain vs plaintext storage** ✅ PASS
Refinement history encryption key stored in Keychain (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecUseDataProtectionKeychain: true`). UserDefaults stores only non-sensitive preferences (hotkey keyCode/modifiers, typing indicator toggle, onboarding state). No credentials, tokens, or personal data in UserDefaults or plaintext files.

**1.3 Git history for secrets** ✅ PASS
16 commits on main. Searched for `.env`, `.key`, `.pem`, `.p12`, `.cer`, `sk_`, `ghp_`, `AKIA`, `hf_`, `Bearer`, `eyJ`, `-----BEGIN`. No secrets found. Commit `698980b Configure Sparkle appcast URL and EdDSA public key` added the public key only.

**1.4 Logging and print statement leaks** ✅ PASS
All `print` calls are wrapped in `#if DEBUG`. No clipboard text content, model output, or user text is ever logged. `TypingMonitor` logs character counts (not content) and element roles in DEBUG only.

**1.5 Build artifact exposure** ✅ PASS
`.gitignore` covers `TextRefiner/.build/`, `TextRefiner/TextRefiner.app/`, `TextRefiner/*.zip`. All SPM output (including dSYM files) lives under `.build/`. No build artifacts present in the repository.

**1.6 Info.plist secrets** ✅ PASS
`Info.plist` and `Info-Dev.plist` contain only standard bundle metadata, Sparkle configuration, and `SUPublicEDKey` (public key). No private keys, API secrets, or credentials.

---

### Section 2: Code Signing & Distribution Security

**2.1 Entitlements review** ✅ PASS
`TextRefiner.entitlements` contains only `com.apple.security.app-sandbox = false`. No unnecessary entitlements. The sandbox is intentionally disabled — required for CGEvent tap (`.defaultTap`), Accessibility API, and `tccutil` execution.

**2.2 Code signing method** ✅ PASS
Ad-hoc signing (`--sign -`) is intentional and correctly documented. The app handles all consequences: quarantine removal at launch, TCC re-grant on every update via onboarding re-flow. The `removeQuarantineFlag` → `completeLaunchSetup` sequencing in `AppDelegate.swift:46-48` ensures quarantine is cleared before any CGEvent tap attempt.

**2.3 Sparkle/update framework configuration** ✅ PASS
`SUFeedURL`: HTTPS (`https://gist.githubusercontent.com/...`). `SUPublicEDKey`: present (`Info.plist:34`). `SUScheduledCheckInterval`: 3600s (minimum Sparkle 2.x allows). Sparkle 2.9.1 pinned in `Package.resolved`.

**2.4 Notarization status** ✅ PASS
App is not notarized — intentional permanent distribution model. The quarantine removal in `AppDelegate` handles the Gatekeeper consequence correctly.

**2.5 Quarantine handling** ✅ PASS
`removeQuarantineFlag` (`AppDelegate.swift:778`) runs `/usr/bin/xattr -dr com.apple.quarantine <bundlePath>` where `bundlePath` is `Bundle.main.bundlePath` — the app's own bundle only. Restricted environment. Background thread.

**2.6 Framework embedding** ✅ PASS
`build.sh:178` codesigns `Sparkle.framework` before codesigning the app bundle. `install_name_tool -add_rpath @executable_path/../Frameworks` sets the correct rpath. No world-writable paths.

---

### Section 3: Process & Shell Execution Security

**3.1 Process/NSTask inventory** ✅ PASS
Five subprocess calls identified. None use `/bin/bash -c "string"` with user data.

| Command | Source | User input in args? |
|---------|--------|---------------------|
| `/usr/bin/xattr -dr com.apple.quarantine <bundlePath>` | `AppDelegate.swift:781` | No — from `Bundle.main` |
| `/usr/bin/tccutil reset Accessibility <bundleID>` | `AppDelegate.swift:752` | No — from `Bundle.main` |
| `/bin/bash <buildScript>` | `AppDelegate.swift:816` (dev only) | No — path from `Bundle.main` |
| `/bin/bash <buildScript>` | `SettingsWindowController.swift:366` (dev only) | No — path from `Bundle.main` |
| `/usr/bin/open [-n, <appBundleURL>]` | `AppDelegate.swift:842` (dev only) | No — from `Bundle.main` |

**3.2 Shell command injection** ✅ PASS
No `/bin/bash -c "...string..."` pattern found. All subprocess arguments are hardcoded or derived from `Bundle.main`, never from user input, clipboard content, or deserialized data.

**3.3 Subprocess environment** ⚠️ PARTIAL

`AppDelegate.removeQuarantineFlag` and `resetAccessibilityPermission` both set `process.environment = ["PATH": "/usr/bin:/bin"]` — correctly restricted. `AppDelegate.rebuildAndRelaunch` sets `["PATH": ..., "HOME": ...]` — correctly restricted. However, `SettingsWindowController.rebuildAndRelaunch` (`SettingsWindowController.swift:363`) does **not** set `process.environment`, inheriting the full parent environment.

┌─────────────────────────────────────────────────────────┐
│ FINDING #1                                              │
├──────────┬──────────────────────────────────────────────┤
│ Severity │ LOW                                          │
│ Category │ Subprocess Environment Inheritance           │
│ Location │ TextRefiner/Sources/UI/SettingsWindowController.swift:363 │
│ CWE      │ CWE-526 (Environment Variable Exposure)      │
├──────────┴──────────────────────────────────────────────┤
│ What's wrong:                                           │
│ SettingsWindowController.rebuildAndRelaunch creates a   │
│ Process() for /bin/bash without setting                 │
│ process.environment. The subprocess inherits the full   │
│ parent environment, including any secrets the developer │
│ may have in their shell (e.g. AWS keys, GitHub tokens). │
│                                                         │
│ Why it matters:                                         │
│ If build.sh is ever modified to echo output or a        │
│ compromised build dependency reads env vars, developer  │
│ credentials could be exposed. Inconsistent with the     │
│ AppDelegate version which correctly restricts the env.  │
│ Dev-only, so risk is low.                               │
│                                                         │
│ The vulnerable code:                                    │
│ ```                                                     │
│ let process = Process()                                 │
│ process.executableURL = URL(fileURLWithPath: "/bin/bash")│
│ process.arguments = [buildScript]                       │
│ // No process.environment set — inherits everything     │
│ ```                                                     │
│                                                         │
│ The fix:                                                │
│ ```                                                     │
│ process.environment = [                                 │
│     "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec",│
│     "HOME": ProcessInfo.processInfo.environment["HOME"] │
│         ?? "",                                          │
│ ]                                                       │
│ ```                                                     │
│                                                         │
│ Effort: ~2 minutes                                      │
└─────────────────────────────────────────────────────────┘

**3.4 Dynamic library loading** ✅ PASS
No `dlopen()` calls. `@rpath` set to `@executable_path/../Frameworks` only. The Frameworks directory is inside the signed app bundle and not world-writable.

**3.5 tccutil and privilege-sensitive commands** ✅ PASS
`resetAccessibilityPermission()` runs `tccutil reset Accessibility <bundleID>` where `bundleID` is always `Bundle.main.bundleIdentifier`. Only the app's own TCC entry is reset. Never resets other apps or broad service categories.

---

### Section 4: Local Data Storage Security

**4.1 UserDefaults for sensitive data** ✅ PASS
UserDefaults keys: hotkey config (Int), typing indicator toggle (Bool), onboarding state (Bool/String). None contain credentials, tokens, personal data, or user-refined content.

**4.2 Application Support files** ✅ PASS
`prompts.json`: Plaintext JSON, permissions `0o600`, atomic write. Contains user prompt templates — not sensitive credentials or PII.
`history.json`: AES-GCM encrypted, permissions `0o600`, atomic write. Encryption key in Data Protection Keychain.
`models/`: Public LLM weights from Hugging Face. Not sensitive.

**4.3 Pasteboard handling** ⚠️ PARTIAL

The refinement flow overwrites `NSPasteboard.general` twice (Cmd+C → Cmd+V), permanently replacing the previous clipboard content. The refined text remains on the pasteboard after paste. During inference (~5-60s), the original selected text is readable by any app with clipboard access. On macOS 14+, clipboard access requires user permission, which reduces exposure. This is an inherent design constraint of the clipboard-based cross-app mechanism — no alternative exists for universal app compatibility.

**4.4 Temporary files and caches** ✅ PASS
No `NSTemporaryDirectory()` or `/tmp` usage. No caches with sensitive data. All persistent storage goes through tracked Application Support paths.

**4.5 JSON/plist deserialization safety** ✅ PASS
All JSON loads use `try?` with graceful fallback to defaults. No force-unwraps on deserialized data. Atomic writes prevent partial file states. A crafted `prompts.json` could alter the prompt template, but since the model runs locally and output is pasted locally, there is no network exfiltration path.

---

### Section 5: Input Validation & Injection

**5.1 LLM prompt injection** ✅ PASS
`LocalInferenceService.streamRewrite()` strips `[TEXT_START]`, `[TEXT_END]`, and `{{USER_TEXT}}` from clipboard text before injection (`LocalInferenceService.swift:184-187`). Prompt uses `[TEXT_START]`/`[TEXT_END]` delimiters. Model runs locally — output is pasted as text with no downstream code execution, file operations, or URL navigation.

**5.2 Model output sanitization** ✅ PASS
`cleanResponse()` strips preamble phrases, leaked delimiters, and wrapping quotes. Output is pasted as plain text only. No special sequences in model output can trigger privileged actions in TextRefiner.

**5.3 Pasteboard content validation** ✅ PASS
Input capped at `maxInputCharacters = 10,000` characters — graceful error HUD for oversized inputs. Non-string pasteboard types handled: `NSPasteboard.general.string(forType: .string)` returns nil, treated as "no text selected."

**5.4 Untrusted data deserialization** ✅ PASS
Model `config.json`: SHA-256 verified against pinned hash before inference. All JSON files use graceful `try?` with fallbacks. No TOCTOU issues.

---

### Section 6: Accessibility & System Integration Security

**6.1 CGEvent tap scope** ✅ PASS
Event mask: `1 << CGEventType.keyDown.rawValue` — keyDown only. Tap type: `.defaultTap`. Non-matching events pass through (`return Unmanaged.passRetained(event)` at `HotkeyManager.swift:145`). Proper cleanup: `CFMachPortInvalidate` + `CFRunLoopRemoveSource` in `stop()`.

**6.2 Accessibility API usage patterns** ✅ PASS
`TypingMonitor` reads character counts, field frames, element roles, and placeholder values. The full text string is read via `kAXValueAttribute` for character counting and placeholder comparison, but is never logged (character count only logged in `#if DEBUG`), never stored to disk, and never transmitted. Reading from focused elements is within the Accessibility permission scope explicitly granted by the user.

**6.3 TCC permission handling** ✅ PASS
`NSAccessibilityUsageDescription` present in both plists. Permission check uses CGEvent tap creation (ground truth on Ventura+). Graceful revocation recovery via poll timer and onboarding re-flow. No repeated system prompts after denial.

**6.4 Key simulation scope** ✅ PASS
Only Cmd+C (`0x08`) and Cmd+V (`0x09`) simulated — both hardcoded at `AccessibilityService.swift:69,97`. Never constructed from user input. Both gated behind user hotkey trigger. CGEventSource: `.hidSystemState`.

**6.5 AXObserver scope** ✅ PASS
Per-app observer: frontmost app only, `kAXFocusedUIElementChangedNotification` only. Per-element observer: focused element only. Own PID excluded. All known browsers excluded. Both observers torn down on every app switch and focus change. Poll timer cancelled with element observer.

---

### Section 7: Network Security

**7.1 HTTPS enforcement** ✅ PASS
`SUFeedURL`: HTTPS. Hugging Face model download via `HubApi` — HTTPS. No HTTP URLs in source, plists, or scripts. No `NSAllowsArbitraryLoads` in Info.plist.

**7.2 Certificate pinning** ✅ PASS
Sparkle verifies update archives via EdDSA signature (`SUPublicEDKey`) — stronger than certificate pinning since it verifies content regardless of TLS. Model `config.json` integrity is verified by SHA-256 pinned to a specific Hugging Face revision.

**7.3 Download integrity** ⚠️ PARTIAL

Sparkle update archives: EdDSA-signed ✅. Model `config.json`: SHA-256 pinned to revision `7f0dc925e0d0afb0322d96f9255cfddf2ba5636e` at `LocalInferenceService.swift:22-25` ✅. However, model weight files (`.safetensors`) are **not individually hash-checked**. A MITM attacker who compromised the HTTPS connection to Hugging Face could serve modified weights that pass the config.json check but alter model behavior.

Exploitation requires compromising Hugging Face's HTTPS infrastructure or CDN — outside the stated local threat model. Risk is low in practice, but the gap is real.

**7.4 Appcast feed security** ⚠️ PARTIAL

Appcast served over HTTPS ✅. EdDSA signing configured ✅. Appcast hosted on GitHub Gist (developer-controlled) ✅. The appcast does not yet include `<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>` for the upcoming v1.3 release — recorded as a pending action item in the 2026-04-14 daily log. Without this, Sparkle may offer the v1.3 update to macOS 14.x users who cannot run it.

---

### Section 8: Dependency & Package Security

**8.1 Swift Package Manager dependency audit** ✅ PASS

| Package | Pinned Version | Source | Status |
|---------|---------------|--------|--------|
| `Sparkle` | 2.9.1 | sparkle-project/Sparkle | Well-maintained, HTTPS |
| `mlx-swift-lm` | 2.31.3 | ml-explore/mlx-swift-lm | Apple MLX project, HTTPS |
| `mlx-swift` | 0.31.3 | ml-explore/mlx-swift | Apple MLX project, HTTPS |
| `swift-transformers` | 1.2.1 | huggingface/swift-transformers | HF official, HTTPS |

All dependencies use semver ranges (not branch-based). All transitive dependencies from reputable sources (Apple, Hugging Face). No known CVEs at pinned versions.

**8.2 Package.resolved committed** ✅ PASS
`Package.resolved` present in repository with all 15 dependencies pinned to exact revision hashes.

**8.3 Unnecessary dependencies** ✅ PASS
All four direct dependencies are actively used: Sparkle (updates), MLXLLM + MLX (inference), Hub (model download). No unused packages.

**8.4 Framework embedding security** ✅ PASS
`Sparkle.framework` codesigned before app bundle signing (`build.sh:178`). `@executable_path/../Frameworks` rpath set correctly. No world-writable rpath entries.

**8.5 Build script dependencies** ✅ PASS
All external tools are standard macOS system tools (no third-party build tools fetched at build time). Temporary metal air files in `.build/mlx_air/` are cleaned up after metallib compilation.

---

### Section 9: Recent-Change Additions (this run only)

From the 2026-04-14 daily log, changes since the previous audit include: 500ms AX polling fallback in TypingMonitor, HUD animation timing tokens, macOS 15 deployment target bump, "no text selected" inline error routing, browser pill split behavior, Sparkle interval change (86400→3600), Electron placeholder change-detection, post-refinement pill state, and delete-to-baseline latch fix.

None of these introduce new attack surfaces not already covered by Sections 1–8.

**No additions this run.**
