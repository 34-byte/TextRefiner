# TextRefiner Security Audit
*Automated audit — run: 2026-04-11 08:02 UTC*

---

## 1. Security Posture Rating

**🟡 ACCEPTABLE — Minor issues, no immediate data exposure risk to a standard threat model.**

TextRefiner's security posture is solid for a desktop utility in its threat model. No hardcoded secrets, no shell injection, no sensitive plaintext storage, and history encryption via AES-GCM with a Keychain-backed key. All subprocess invocations use explicit argument arrays with minimal environments. The primary finding is that the `verifyConfigIntegrity()` function — the model integrity check — is defined but never called anywhere in the codebase, making it dead code. The comment in `LocalInferenceService.swift` says "tampering is caught by verifyConfigIntegrity() before inference runs" but this claim is false: the function is never invoked. The practical risk is low (requires local file system write access or a MITM on model download HTTPS), but the stated defense is not in place. The secondary finding is an unavoidable pasteboard exposure window: the user's selected text sits on the system clipboard for 2–9 seconds during inference, readable by any app running as the same user. This is architectural and cannot be easily eliminated, but it is worth documenting. All other findings are informational.

---

## 2. Critical and High Findings

None.

---

## 3. Quick Wins

- **Call `verifyConfigIntegrity()` from `streamRewrite()` before `loadModel()`** — ~5 minutes. The function is already correct; it just needs to be wired in.
- **Add `*.dSYM` to `.gitignore`** — ~1 minute.

---

## 4. Prioritized Remediation Plan

1. **[MEDIUM] Dead integrity check — wire `verifyConfigIntegrity()` into `streamRewrite()`** — ~5 min
2. **[LOW] Pasteboard exposure window** — document in privacy FAQ — ~30 min (writing only)
3. **[INFORMATIONAL] `.gitignore` missing `*.dSYM`** — ~1 min

---

## 5. What's Already Done Right

- All `print()` statements wrapped in `#if DEBUG` — zero stdout in release builds
- AES-GCM encryption for `history.json`; key stored in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- Keychain service string fixed to `"com.textrefiner.app"` (not `Bundle.main.bundleIdentifier`) so dev/release builds share one key
- Prompt injection sanitization: clipboard text stripped of `[TEXT_START]`, `[TEXT_END]`, `{{USER_TEXT}}` before template injection
- Input length cap (10,000 chars) enforced before inference — protects against memory exhaustion
- All subprocess invocations use argument arrays (not shell string interpolation) and explicit minimal environments
- CGEvent tap event mask is narrow (`.keyDown` only); non-matching events passed through; tap cleaned up correctly on `stop()`
- `tccutil reset` scoped to `Bundle.main.bundleIdentifier` only — cannot affect other apps
- `xattr -dr` scoped to `Bundle.main.bundlePath` only
- Sparkle 2.9.1 with EdDSA (`SUPublicEDKey`) — update integrity guaranteed even if appcast host is compromised
- Appcast URL is HTTPS; no `NSAllowsArbitraryLoads` in Info.plist
- `Package.resolved` committed — dependency versions are locked
- `prompts.json` and `history.json` both written with `options: .atomic` and `posixPermissions: 0o600`
- `@rpath` set to `@executable_path/../Frameworks` only — no world-writable injection paths
- Sparkle.framework signed before app bundle is signed in `build.sh`
- `AXObserver` scoped to frontmost app's PID; torn down correctly on app switch; only character count read (not text content)
- No sensitive data in UserDefaults (hotkey keycodes and modifier flags are non-sensitive)

---

## 6. Checklist Summary

```
1.1 ✅  1.2 ✅  1.3 ✅  1.4 ✅  1.5 ⚠️  1.6 ✅
2.1 ✅  2.2 ✅  2.3 ✅  2.4 ⬚  2.5 ✅  2.6 ✅
3.1 ✅  3.2 ✅  3.3 ✅  3.4 ✅  3.5 ✅
4.1 ✅  4.2 ✅  4.3 ⚠️  4.4 ✅  4.5 ✅
5.1 ✅  5.2 ✅  5.3 ✅  5.4 ❌
6.1 ✅  6.2 ✅  6.3 ✅  6.4 ✅  6.5 ✅
7.1 ✅  7.2 ✅  7.3 ⚠️  7.4 ✅
8.1 ✅  8.2 ✅  8.3 ✅  8.4 ✅  8.5 ✅
9   — No additions this run
```

---

## Section-by-Section Results

---

### Section 1: Secrets & Credential Management

**1.1 — Hardcoded secrets** ✅ PASS
No API keys, tokens, passwords, or private keys in source code, plists, or scripts. `SUPublicEDKey` in `Info.plist` is a Sparkle EdDSA *public* verification key — expected and safe. `configIntegrityHash` in `LocalInferenceService.swift:25` is a SHA-256 hash of `config.json`, not a secret. No 32+ character alphanumeric credential strings found.

**1.2 — Keychain vs plaintext storage** ✅ PASS
The AES-GCM history encryption key is stored in the macOS Keychain (`RefinementHistory.swift:92–156`) with service `"com.textrefiner.app"`, account `"history-encryption-key"`, and accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. UserDefaults contains only: onboarding state (bool), build version string (non-sensitive), hotkey keycode (integer, non-sensitive), hotkey modifier flags (integer, non-sensitive), typing indicator toggle (bool). No sensitive data in UserDefaults.

**1.3 — Git history for secrets** ✅ PASS
9 commits total. No `.env` files, no private keys, no credential files in any commit. A previous version of `RefinementHistory.swift` used a `.history-key` plaintext file but this was migrated to Keychain before the initial repository commit. No secrets were ever committed.

**1.4 — Logging and print statement leaks** ✅ PASS
All `print()` statements in every source file are inside `#if DEBUG` blocks. Confirmed file by file: `AppDelegate.swift` (lines 241, 395, 645, 668), `HotkeyManager.swift` (line 49), `TypingMonitor.swift` (all 17 print statements), `AccessibilityService.swift` (line 72), `PromptStorage.swift` (line 148), `RefinementHistory.swift` (lines 112, 178). Clipboard content and user text are never logged anywhere in the codebase.

**1.5 — Build artifact exposure** ⚠️ PARTIAL
`.gitignore` covers `TextRefiner/.build/`, `TextRefiner/TextRefiner.app/`, and `TextRefiner/*.zip`. Since SPM writes dSYM files inside `.build/`, they are covered in practice. However, `*.dSYM` is not explicitly listed. If a developer generates a dSYM outside `.build/` (e.g., via a custom Xcode scheme), it would not be excluded. Risk is low but the explicit exclusion is a one-line fix.

**1.6 — Info.plist secrets** ✅ PASS
`Info.plist` contains `SUPublicEDKey` (public key, expected for Sparkle EdDSA verification). No private keys, tokens, or credentials. `Info-Dev.plist` has no Sparkle config at all — correct.

---

### Section 2: Code Signing & Distribution Security

**2.1 — Entitlements review** ✅ PASS
`TextRefiner.entitlements` contains a single key: `com.apple.security.app-sandbox = false`. No unnecessary entitlements. The absence of sandbox is required and intentional — Accessibility API and CGEvent tap creation require it for this distribution model. No temporary exceptions, no unrestricted network entitlements, no file system access entitlements beyond what the OS provides by default.

**2.2 — Code signing method** ✅ PASS
Ad-hoc signing (`codesign --sign -`) is the documented, intentional, permanent distribution model. All implications are handled: Gatekeeper bypass via quarantine removal on launch, TCC invalidation on every rebuild handled by `tccutil reset` (dev) and post-update re-onboarding flow (production), user documentation in CLAUDE.md.

**2.3 — Sparkle / update framework configuration** ✅ PASS
- `SUFeedURL`: `https://gist.githubusercontent.com/34-byte/6a5dacdb24a6bae85d003e906f5fa907/raw/appcast.xml` — HTTPS ✅
- `SUPublicEDKey`: present — EdDSA signature verification enabled ✅
- `SUEnableAutomaticChecks = true`, `SUScheduledCheckInterval = 86400` ✅
- Sparkle 2.9.1 — current, actively maintained, security-audited ✅
- Dev builds have no `SUFeedURL` (Info-Dev.plist omits it); `UpdateManager.init()` checks for `SUFeedURL` presence and skips Sparkle initialization if absent ✅

**2.4 — Notarization status** ⬚ N/A
Ad-hoc signing is mutually exclusive with notarization (notarization requires Apple Developer ID). This is the permanent distribution model by design. Not applicable.

**2.5 — Quarantine handling** ✅ PASS
`AppDelegate.removeQuarantineFlag()` runs `xattr -dr com.apple.quarantine Bundle.main.bundlePath` — scoped to the app's own bundle path only. The path comes from `Bundle.main.bundlePath` (trusted OS API), not user input. Runs on a background thread to avoid blocking main at launch.

**2.6 — Framework embedding** ✅ PASS
`build.sh` signs Sparkle.framework (`codesign --force --sign - "$FRAMEWORKS_DIR/Sparkle.framework"`) before signing the app bundle. `install_name_tool -add_rpath @executable_path/../Frameworks` sets the correct relative rpath. No world-writable or user-writable paths in rpath configuration.

---

### Section 3: Process & Shell Execution Security

**3.1 — Process/NSTask inventory** ✅ PASS
Four subprocess invocations in total:

| Location | Executable | Purpose | Arguments source |
|---|---|---|---|
| `AppDelegate.swift:657–665` | `/usr/bin/tccutil` | Reset Accessibility TCC after update | Static array + `Bundle.main.bundleIdentifier` (trusted) |
| `AppDelegate.swift:688–691` | `/usr/bin/xattr` | Strip quarantine flag | Static array + `Bundle.main.bundlePath` (trusted) |
| `AppDelegate.swift:721–750` | `/bin/bash` | Rebuild & Relaunch (dev only) | `[buildScript]` derived from `Bundle.main.bundlePath` (trusted) |
| `AppDelegate.swift:746–749` | `/usr/bin/open` | Launch rebuilt app | `[appBundleURL.path]` derived from bundle path (trusted) |

Identical subprocess pattern in `SettingsWindowController.swift:346–382` — same security properties.

**3.2 — Shell command injection** ✅ PASS
No invocation uses `/bin/bash -c "string"` (string interpolation). The "Rebuild & Relaunch" bash invocation uses `process.arguments = [buildScript]` where `buildScript` is a file path derived from `Bundle.main.bundlePath` — no user input reaches the argument list. All other invocations use static argument arrays.

**3.3 — Subprocess environment** ✅ PASS
All subprocesses set `process.environment` explicitly:
- `tccutil`, `xattr`, `open`: `["PATH": "/usr/bin:/bin"]` (minimal)
- `bash build.sh`: `["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec", "HOME": ProcessInfo.processInfo.environment["HOME"] ?? ""]` (HOME forwarded because `swift build` needs it for package cache resolution)

Parent process environment is not inherited by any subprocess.

**3.4 — Dynamic library loading** ✅ PASS
`@rpath` set to `@executable_path/../Frameworks` only. No `@loader_path`, no absolute paths, no user-writable directories in rpath. `install_name_tool -add_rpath` used correctly in `build.sh`.

**3.5 — tccutil and privilege-sensitive commands** ✅ PASS
`tccutil reset Accessibility bundleID` where `bundleID = Bundle.main.bundleIdentifier`. Scoped to the app's own bundle ID. Cannot affect other apps' Accessibility entries. Called only when `needsReOnboarding` is true (post-update flow where the binary's CDHash has changed), not on every launch.

---

### Section 4: Local Data Storage Security

**4.1 — UserDefaults for sensitive data** ✅ PASS
UserDefaults stores: `com.textrefiner.onboardingCompleted` (bool), `com.textrefiner.lastOnboardedBuild` (build version string), `com.textrefiner.hotkeyKeyCode` (integer), `com.textrefiner.hotkeyModifierFlags` (integer), `com.textrefiner.showTypingIndicator` (bool). None of these are sensitive. No passwords, tokens, API keys, or user content in UserDefaults.

**4.2 — Application Support files** ✅ PASS
Three items under `~/Library/Application Support/TextRefiner/`:

| File | Content | Encryption | Permissions |
|---|---|---|---|
| `history.json` | Last 10 refinement pairs | AES-GCM (Keychain key) | 0600 (set on every write) |
| `prompts.json` | Active prompt template + 20-entry history | None (not credentials) | 0600 (set on every write) |
| `models/` | Model weights (~1.8 GB, public data) | None | Default directory permissions |

Both JSON files use `Data.write(to:options:.atomic)` + explicit `setAttributes([.posixPermissions: 0o600])` on every persist call.

**4.3 — Pasteboard handling** ⚠️ PARTIAL
The user's selected text sits on `NSPasteboard.general` from `simulateCopyAndRead()` through the end of `pasteText()` — a window of roughly 2–9 seconds (depending on model load state). During this window, any app running as the same user can read the clipboard. This is:
- **Unavoidable** given the architecture (clipboard is the only cross-app text exchange mechanism available without sandbox)
- **Known** and consistent with every tool in this category (Grammarly, WritingTools, etc.)

The refined text also permanently replaces the previous clipboard contents. No action required from a security standpoint, but this should be disclosed in privacy documentation.

**4.4 — Temporary files and caches** ✅ PASS
No `NSTemporaryDirectory()` or `/tmp` usage in source code. The build script creates `$BUILD_DIR/mlx_air/*.air` temp files during Metal shader compilation and explicitly `rm -rf "$AIR_DIR"` after `metallib` is built. No app-created temp files at runtime.

**4.5 — JSON/plist deserialization safety** ✅ PASS
Both `PromptStorage` and `RefinementHistory` use `try?` for deserialization with explicit fallback to defaults on failure. No `fatalError`, no force-unwrap on external data. A crafted `prompts.json` could substitute a malicious prompt template, but the template is used only as input to a local LLM (no remote execution, no command interpretation).

---

### Section 5: Input Validation & Injection

**5.1 — LLM prompt injection** ✅ PASS
`LocalInferenceService.streamRewrite()` strips `[TEXT_START]`, `[TEXT_END]`, and `{{USER_TEXT}}` from clipboard content before injection (`LocalInferenceService.swift:184–187`). Model output is used only for text replacement — not code execution, file operations, or URL navigation.

**5.2 — Model output sanitization** ✅ PASS
`cleanResponse()` strips leaked prompt artifacts: closing anchors, preamble phrases, delimiter leakage, and wrapping quotes. Output is pasted as plain text via the clipboard. No mechanism exists for model output to inject keystrokes or shell commands.

**5.3 — Pasteboard content validation** ✅ PASS
`RefinementCoordinator.maxInputCharacters = 10_000` enforced before inference. Inputs over this limit throw `RefinementError.inputTooLong` and show a 5-second error HUD. Non-string pasteboard types handled by `NSPasteboard.string(forType: .string)` returning `nil`, caught by the guard at `RefinementCoordinator.swift:79–81`.

**5.4 — Untrusted data deserialization** ❌ FAIL

┌─────────────────────────────────────────────────────────┐
│ FINDING #1                                              │
├──────────┬──────────────────────────────────────────────┤
│ Severity │ MEDIUM                                       │
│ Category │ Dead Code / Missing Integrity Verification   │
│ Location │ LocalInferenceService.swift:64 (definition)  │
│          │ LocalInferenceService.swift:18 (false claim) │
│ CWE      │ CWE-345 (Insufficient Verification of Data   │
│          │ Authenticity)                                │
├──────────┴──────────────────────────────────────────────┤
│ What's wrong:                                           │
│ `verifyConfigIntegrity()` is defined at line 64 and     │
│ correctly computes SHA-256 of config.json, comparing    │
│ it against `configIntegrityHash`. However, it is        │
│ never called anywhere in the codebase. The comment      │
│ at line 18 states "tampering is caught by               │
│ verifyConfigIntegrity() before inference runs" —        │
│ this claim is false. The function is dead code.         │
│                                                         │
│ Additionally, even if called, the check only covers     │
│ config.json. The model weights (.safetensors files)     │
│ that actually execute on the Metal GPU are not          │
│ verified by any code path.                              │
│                                                         │
│ Why it matters:                                         │
│ A local process with write access to                    │
│ ~/Library/Application Support/TextRefiner/models/       │
│ could replace model files without detection.            │
│ Exploitation requires same-user local access.           │
│ For a model that processes all text the user writes,    │
│ a substituted model could silently alter output.        │
│                                                         │
│ The vulnerable code:                                    │
│ ```swift                                                │
│ // LocalInferenceService.swift:170–175                  │
│ if self.modelContainer == nil {                         │
│     guard self.isModelDownloaded() else {               │
│         throw InferenceError.modelNotDownloaded         │
│     }                                                   │
│     try await self.loadModel()  // no integrity check   │
│ }                                                       │
│ ```                                                     │
│                                                         │
│ The fix:                                                │
│ ```swift                                                │
│ if self.modelContainer == nil {                         │
│     guard self.isModelDownloaded() else {               │
│         throw InferenceError.modelNotDownloaded         │
│     }                                                   │
│     try verifyConfigIntegrity()  // ← add this line     │
│     try await self.loadModel()                          │
│ }                                                       │
│ ```                                                     │
│                                                         │
│ Effort: ~5 minutes                                      │
└─────────────────────────────────────────────────────────┘

---

### Section 6: Accessibility & System Integration Security

**6.1 — CGEvent tap scope** ✅ PASS
Event mask: `1 << CGEventType.keyDown.rawValue` — keyDown only. Tap type: `.defaultTap` — correct for consuming the hotkey. Non-matching events: returned via `Unmanaged.passRetained(event)`. Cleanup: `CFMachPortInvalidate(tap)` + `CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)` in `HotkeyManager.stop()`. Re-enable on timeout dispatched to main thread to avoid data race.

**6.2 — Accessibility API usage patterns** ✅ PASS
`TypingMonitor` reads character count (`kAXNumberOfCharactersAttribute`, falling back to string length), placeholder text (for comparison only), element role, and element frame. Actual text content is never stored, logged, or transmitted. In release builds, no diagnostic information about other apps is emitted.

**6.3 — TCC permission handling** ✅ PASS
`NSAccessibilityUsageDescription` present in both Info.plist files. `AccessibilityService.isTrusted()` uses a test CGEvent tap as ground truth (not unreliable `AXIsProcessTrusted()`). Graceful recovery via polling when permission is missing. App shows onboarding and polls for permission when it detects missing access.

**6.4 — Key simulation scope** ✅ PASS
Only two keycodes ever simulated: `0x08` (Cmd+C — copy) and `0x09` (Cmd+V — paste), both only within the user-initiated hotkey flow. CGEventSource state: `.hidSystemState`. No code path converts attacker-controlled strings into simulated keystrokes — the paste path writes to `NSPasteboard` and posts a single Cmd+V event.

**6.5 — AXObserver scope** ✅ PASS
`attachToFrontmostApp()` creates an `AXObserver` on the frontmost app's PID only. Observers torn down on every app switch via `teardownAppObserver()` + `teardownElementObserver()`. Self-app observation excluded via `pid == ProcessInfo.processInfo.processIdentifier` guard. No text content from other apps is read — only character count and element frame.

---

### Section 7: Network Security

**7.1 — HTTPS enforcement** ✅ PASS
All network URLs use HTTPS: Sparkle appcast, HuggingFace Hub model download, all SPM package URLs. No `NSAppTransportSecurity` / `NSAllowsArbitraryLoads` keys in either Info.plist. App Transport Security is in default enforced state.

**7.2 — Certificate pinning** ✅ PASS
Sparkle 2.x enforces EdDSA signature verification on every downloaded update before installation — stronger than certificate pinning for the update path. Model downloads from HuggingFace use standard TLS (no pinning) — acceptable for a public model with no secret content.

**7.3 — Download integrity** ⚠️ PARTIAL
Sparkle updates are EdDSA-signed — integrity guaranteed. Model downloads are verified only at the `config.json` level via `verifyConfigIntegrity()` — and as noted in §5.4, that function is never called. Model weight files (`.safetensors`) have no integrity verification. The revision pin in `ModelConfiguration` prevents silent server-side model swaps, but on-disk file tampering goes undetected.

**7.4 — Appcast feed security** ✅ PASS
Appcast served over HTTPS from GitHub Gist. EdDSA signing means a compromised appcast host cannot deliver a malicious update without the private key. Gist is developer-controlled.

---

### Section 8: Dependency & Package Security

**8.1 — Swift Package Manager dependency audit** ✅ PASS

| Package | Resolved Version | Constraint | Maintainer |
|---|---|---|---|
| Sparkle | 2.9.1 | `from: "2.6.0"` | Sparkle Project |
| mlx-swift | 0.31.3 | `from: "0.31.3"` | Apple/ml-explore |
| mlx-swift-lm | 2.31.3 | `from: "2.30.0"` | Apple/ml-explore |
| swift-transformers | 1.2.1 | `from: "1.2.0"` | HuggingFace |

All packages use minimum-version constraints (not branch-pinned). All actively maintained by credible organizations. No known CVEs. All fetched over HTTPS from GitHub.

**8.2 — Package.resolved committed** ✅ PASS
`Package.resolved` is committed with exact revision hashes for all 15 direct and transitive dependencies.

**8.3 — Unnecessary dependencies** ✅ PASS
All four declared packages are actively used: `Sparkle` in `UpdateManager.swift` and `AppDelegate.swift`; `MLXLLM`, `MLXLMCommon`, `MLXRandom`, `MLX` in `LocalInferenceService.swift`; `Hub` (swift-transformers) in `LocalInferenceService.swift`.

**8.4 — Framework embedding security** ✅ PASS
`build.sh` signs `Sparkle.framework` with `codesign --force --sign -` before signing the app bundle. `@rpath` set to `@executable_path/../Frameworks`. Sparkle's embedded XPC services are signed as part of the framework signing step.

**8.5 — Build script dependencies** ✅ PASS
All external tools invoked via full absolute paths or `xcrun`. No tools resolved via unqualified `PATH` lookup. No resources downloaded during build. The `.air` Metal intermediate files are written to `$BUILD_DIR/mlx_air/` and cleaned up with `rm -rf "$AIR_DIR"` after `metallib` is built.

---

### Section 9: Recent-Change Additions (this run only)

The most recent daily log (2026-04-11) documents a SMAC brainstorm research session — no code changes. The 2026-04-10 log documents four security fixes now present in the codebase (Keychain access class, service string consolidation, `#if DEBUG` guards, subprocess environment hardening). No new features, URL scheme handlers, XPC services, file parsers, or network endpoints were added since the last audit.

**No additions this run.**
