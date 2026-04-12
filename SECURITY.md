# TextRefiner Security Audit
*Automated audit — run: 2026-04-12 04:15 UTC*

---

## 1. Security Posture Rating

🟡 **ACCEPTABLE** — Minor issues, no immediate data exposure risk to a standard threat model.

TextRefiner is a well-hardened local desktop app for its distribution model (ad-hoc signed, no sandbox, outside App Store). The codebase demonstrates consistent attention to macOS security: subprocess environments are explicitly minimised, all sensitive data is encrypted or properly permissioned, debug logging is gated behind `#if DEBUG` throughout, Keychain is used correctly for the AES-GCM history key, and the CGEvent tap is narrowly scoped. The primary threat model is other apps running as the same user, supply chain compromise, and local physical access — not remote network attackers. The only finding above LOW severity is a dead code path: `verifyConfigIntegrity()` is defined and correctly implemented but is never called, meaning a tampered model config would load silently without the detection mechanism that the comments claim is in place. All other findings are low-severity architectural trade-offs inherent to how the app works or require same-user write access to exploit.

---

## 2. Critical and High Findings

None. No CRITICAL or HIGH severity findings this run.

---

## 3. Quick Wins

| # | Finding | Fix | Effort |
|---|---------|-----|--------|
| 1 | `verifyConfigIntegrity()` is never called | Call it in `loadModel()` before `loadContainer()` | ~10 min |
| 2 | Build script uses PATH lookup for security-critical tools | Use full paths (`/usr/bin/codesign`, `/usr/bin/xcrun`) | ~10 min |

---

## 4. Prioritized Remediation Plan

1. **[MEDIUM] Call `verifyConfigIntegrity()` at model load time** — `LocalInferenceService.loadModel()`:line 99 — ~10 min
2. **[LOW] Build script PATH-based tool resolution** — `build.sh` throughout — use explicit full paths for `xcrun`, `codesign`, `tccutil`, etc. — ~10 min
3. **[LOW] Document pasteboard exposure window** — `AccessibilityService.pasteText()` — architectural; document as accepted risk
4. **[LOW] Document TypingMonitor text-content read scope** — `TypingMonitor.readCharacterCount()`:line 309 — add inline comment acknowledging read scope
5. **[INFO] prompts.json prompt-injection via file tampering** — inherent to architecture; within same-user threat model — document as accepted risk

---

## 5. What's Already Done Right

- **All print/logging guarded by `#if DEBUG`** — no user data leaks to Console.app in release builds (`TypingMonitor`, `AccessibilityService`, `HotkeyManager`, `AppDelegate`, `PromptStorage`, `RefinementHistory`)
- **AES-GCM history encryption** — `history.json` encrypted with a 256-bit key stored in the Data Protection Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecUseDataProtectionKeychain: true`); legacy `.history-key` file migration path included
- **File permissions on sensitive data** — both `prompts.json` and `history.json` set to `0600` after every write
- **Subprocess environment minimisation** — all `Process` invocations explicitly set `environment` to a minimal PATH; `HOME` is the only parent environment variable passed through (needed by build toolchain)
- **CGEvent tap narrowly scoped** — mask is `keyDown` only; non-matching events passed through; tap properly invalidated with `CFMachPortInvalidate` + `CFRunLoopRemoveSource` on `stop()`
- **Prompt injection sanitisation** — clipboard text has `[TEXT_START]`, `[TEXT_END]`, and `{{USER_TEXT}}` stripped before template injection; cleaned again in `cleanResponse()` on output
- **Input length limit** — 10,000-character hard cap enforced before inference; error shown via HUD, not `NSAlert`
- **No hardcoded secrets** — only a public EdDSA key (`SUPublicEDKey`) and a SHA-256 hash for model integrity; no API tokens, passwords, or private keys anywhere
- **tccutil scoped to app's own bundle ID** — `Bundle.main.bundleIdentifier` only; never called with broad categories or other apps' identifiers
- **Quarantine removal scoped to bundle path** — `Bundle.main.bundlePath` only; never operates on user-supplied paths
- **Sparkle EdDSA signing enforced** — `SUPublicEDKey` in Info.plist; `sign_update` tool invoked in build.sh; appcast over HTTPS
- **Package.resolved committed** — all transitive dependency hashes locked; no branch-based dependencies
- **Escape-to-cancel safely scoped** — `onEscapePressed` is nil by default; set only for the duration of active processing; cleared in all terminal states
- **Model config revision pinned** — `LocalInferenceService.modelConfiguration` pins to a specific Hugging Face commit hash, preventing silent model updates

---

## 6. Checklist Summary

```
1.1 ✅  1.2 ✅  1.3 ⚠️  1.4 ✅  1.5 ✅  1.6 ✅
2.1 ✅  2.2 ✅  2.3 ✅  2.4 ⬚  2.5 ✅  2.6 ✅
3.1 ✅  3.2 ✅  3.3 ✅  3.4 ✅  3.5 ✅
4.1 ✅  4.2 ✅  4.3 ⚠️  4.4 ✅  4.5 ⚠️
5.1 ✅  5.2 ✅  5.3 ✅  5.4 ❌
6.1 ✅  6.2 ⚠️  6.3 ✅  6.4 ✅  6.5 ✅
7.1 ✅  7.2 ✅  7.3 ⚠️  7.4 ✅
8.1 ✅  8.2 ✅  8.3 ✅  8.4 ✅  8.5 ⚠️
9   — No additions this run
```

---

## Section-by-Section Results

### Section 1: Secrets & Credential Management

**1.1 — Hardcoded secrets** ✅ PASS
No API keys, tokens, passwords, signing keys, or credentials in source, plists, scripts, or config. `SUPublicEDKey` in `Info.plist` is the Sparkle EdDSA *public* key — expected by design. `configIntegrityHash` in `LocalInferenceService.swift:25` is a SHA-256 digest of a model file — not a secret.

**1.2 — Keychain vs plaintext storage** ✅ PASS
History encryption key stored in the Data Protection Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and `kSecUseDataProtectionKeychain: true` (`RefinementHistory.swift:165–173`). `history.json` is AES-GCM encrypted at rest. `prompts.json` contains only user-crafted prompt templates (not credentials) and is set to `0600`. All UserDefaults keys store non-sensitive UI/feature state (hotkey code, onboarding flags, indicator toggle).

**1.3 — Git history for secrets** ⚠️ PARTIAL
Cannot fully scan git history using available tools. Visual inspection of `.gitignore` confirms `.build/`, `TextRefiner.app`, and `*.zip` are excluded. No `.env` files or credential files present in the working tree. Manual git history scan is recommended to confirm no prior secret commits.

**1.4 — Logging and print statement leaks** ✅ PASS
All `print()` calls throughout the codebase are wrapped in `#if DEBUG` blocks. Verified in: `TypingMonitor.swift` (all instances), `AccessibilityService.swift:72`, `HotkeyManager.swift:49`, `AppDelegate.swift:394–396`, `AppDelegate.swift:644–647`, `AppDelegate.swift:668–670`, `PromptStorage.swift:149`, `RefinementHistory.swift:113`, `RefinementHistory.swift:193`. No clipboard content, user text, or credentials appear in any log statement.

**1.5 — Build artifact exposure** ✅ PASS
`.gitignore` excludes `TextRefiner/.build/`, `TextRefiner/TextRefiner.app/`, and `TextRefiner/*.zip`. Release builds compile with `swift build -c release` (no debug symbols in binary). No `.dSYM` files or debug artifacts found in tracked files.

**1.6 — Info.plist secrets** ✅ PASS
`Info.plist` contains only `SUPublicEDKey` (EdDSA public key — expected) and `SUFeedURL` (HTTPS public URL). `Info-Dev.plist` has neither (Sparkle is disabled in dev builds). No private keys, API secrets, or credentials.

---

### Section 2: Code Signing & Distribution Security

**2.1 — Entitlements review** ✅ PASS
`TextRefiner.entitlements` contains only `com.apple.security.app-sandbox: false`. No unnecessary entitlements. No `com.apple.security.temporary-exception.*` entries. Sandbox disabled is correct for this app's requirements (Accessibility API, CGEvent tap, paste simulation — all incompatible with sandbox).

**2.2 — Code signing method** ✅ PASS
Ad-hoc signing (`codesign --force --sign -`) documented and correctly handled. TCC entries are invalidated on every rebuild; the post-update re-onboarding flow handles this. Build script resets TCC in dev mode only. Known limitations are mitigated.

**2.3 — Sparkle / update framework configuration** ✅ PASS
`SUFeedURL` uses HTTPS (`https://gist.githubusercontent.com/...`). `SUPublicEDKey` is set (EdDSA). `build.sh` invokes `sign_update` to sign the `.zip` archive. `SUEnableAutomaticChecks: true`. `SUScheduledCheckInterval: 86400`. Sparkle 2.9.1 resolved.

**2.4 — Notarization status** ⬚ N/A
App uses ad-hoc signing without an Apple Developer account. Notarization requires a Developer ID certificate, which is explicitly out of scope per the project's distribution model. The quarantine removal flow in `AppDelegate.removeQuarantineFlag()` compensates for Gatekeeper blocks.

**2.5 — Quarantine handling** ✅ PASS
`removeQuarantineFlag()` at `AppDelegate.swift:685` runs `xattr -dr com.apple.quarantine bundlePath` where `bundlePath = Bundle.main.bundlePath`. Path is the app's own bundle — not user-supplied. Argument array used (no shell interpolation). Runs asynchronously on a background thread.

**2.6 — Framework embedding** ✅ PASS
`build.sh:175` signs Sparkle before signing the app bundle: `codesign --force --sign - "$FRAMEWORKS_DIR/Sparkle.framework"`. `@rpath` set via `install_name_tool -add_rpath @executable_path/../Frameworks` — not a user-writable path. `mlx.metallib` signed before app bundle signing.

---

### Section 3: Process & Shell Execution Security

**3.1 — Process/NSTask inventory** ✅ PASS

| Location | Command | Args source | Shell? |
|----------|---------|-------------|--------|
| `AppDelegate.swift:659` | `/usr/bin/tccutil reset Accessibility $bundleID` | `Bundle.main.bundleIdentifier` | No — array |
| `AppDelegate.swift:689` | `/usr/bin/xattr -dr com.apple.quarantine $path` | `Bundle.main.bundlePath` | No — array |
| `AppDelegate.swift:722` | `/bin/bash build.sh` | derived from `Bundle.main.bundlePath` | Script file, no interpolation |
| `AppDelegate.swift:747` | `/usr/bin/open $appBundleURL` | derived from `Bundle.main.bundlePath` | No — array |

All use `executableURL`. All arguments are arrays. None accept user-supplied input.

**3.2 — Shell command injection** ✅ PASS
No `/bin/bash -c "...string..."` pattern exists. The build.sh invocation passes the script path as an argument array element, not as shell string interpolation. The buildScript path is derived from `Bundle.main.bundlePath` — not user input.

**3.3 — Subprocess environment** ✅ PASS
All subprocesses set `process.environment` explicitly:
- `tccutil`: `["PATH": "/usr/bin:/bin"]`
- `xattr`: `["PATH": "/usr/bin:/bin"]`
- `build.sh`: `["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec", "HOME": ProcessInfo.processInfo.environment["HOME"] ?? ""]`
- `open`: `["PATH": "/usr/bin:/bin"]`

`HOME` is explicitly passed to build.sh because the Swift toolchain requires it to locate packages. This is acceptable — HOME is a known system value, not sensitive data.

**3.4 — Dynamic library loading** ✅ PASS
No `dlopen()` calls. `@rpath` set to `@executable_path/../Frameworks` — not user-writable. `mlx.metallib` is placed in `Contents/MacOS/` alongside the binary and signed before the app bundle is signed.

**3.5 — tccutil and privilege-sensitive commands** ✅ PASS
`tccutil` called with `Bundle.main.bundleIdentifier` only (`AppDelegate.swift:663`). Called only during the `needsReOnboarding` path (version mismatch). Also called in `build.sh:236` for dev builds only, scoped to the bundle ID from `Info.plist`. Never called with broad categories or other apps' identifiers.

---

### Section 4: Local Data Storage Security

**4.1 — UserDefaults for sensitive data** ✅ PASS
UserDefaults stores only non-sensitive preferences:
- `com.textrefiner.onboardingCompleted` — boolean
- `com.textrefiner.lastOnboardedBuild` — version string
- `com.textrefiner.hotkeyKeyCode` — integer
- `com.textrefiner.hotkeyModifierFlags` — integer
- `com.textrefiner.showTypingIndicator` — boolean

No passwords, tokens, keys, or user content stored in UserDefaults.

**4.2 — Application Support files** ✅ PASS
- `prompts.json` — user prompt templates, not credentials, set to `0600` (`PromptStorage.swift:145`)
- `history.json` — AES-GCM encrypted, set to `0600` (`RefinementHistory.swift:190`)
- `models/` — MLX model weights, not sensitive, no special permissions needed

**4.3 — Pasteboard handling** ⚠️ PARTIAL
The app's core function requires placing user text on the system pasteboard. During the ~2–5 second inference window, the user's selected text (potentially sensitive) sits on the pasteboard, readable by any app running as the same user. The original pasteboard content is not restored — the refined text replaces it (by design). This is an architectural trade-off inherent to using the system pasteboard for inter-app text transfer; it cannot be eliminated without a fundamentally different paste mechanism. Document as accepted risk.

**4.4 — Temporary files and caches** ✅ PASS
No use of `NSTemporaryDirectory()`, `/tmp`, or `~/Library/Caches/` in source code. Build script cleans up `.air` intermediate Metal files with `rm -rf "$AIR_DIR"` after metallib compilation.

**4.5 — JSON/plist deserialization safety** ⚠️ PARTIAL
`prompts.json` and `history.json` loaded with `try?` throughout — malformed data falls back to defaults safely. However, a same-user attacker with write access to `~/Library/Application Support/TextRefiner/prompts.json` could inject an arbitrary prompt template. The app validates only that `{{USER_TEXT}}` is present. Worst case is manipulated LLM output, not code execution. Requires same-user write access — within the local threat model for an unsandboxed app. Document as accepted risk.

---

### Section 5: Input Validation & Injection

**5.1 — LLM prompt injection** ✅ PASS
Delimiter strings `[TEXT_START]`, `[TEXT_END]`, and `{{USER_TEXT}}` are stripped from clipboard content before injection (`LocalInferenceService.swift:184–187`). Stripped again from model output in `cleanResponse()`. Model output is pasted as plain text — not executed or passed to a shell. Breaking out of delimiter isolation would at worst produce unexpected model output, not a security escalation.

**5.2 — Model output sanitization** ✅ PASS
`cleanResponse()` strips preamble phrases, leaked delimiters, and wrapping quotes. Output pasted via `NSPasteboard + Cmd+V` — received as plain text by the target app. No code path converts model output to simulated keystrokes, shell commands, or URL navigations.

**5.3 — Pasteboard content validation** ✅ PASS
10,000-character hard limit enforced in `RefinementCoordinator.startRefinement()` (`RefinementCoordinator.swift:86`). Non-string pasteboard types: `NSPasteboard.general.string(forType: .string)` returns nil, propagating to `RefinementError.noTextSelected`. No memory exhaustion possible.

**5.4 — Untrusted data deserialization** ❌ FAIL

┌─────────────────────────────────────────────────────────┐
│ FINDING #1                                              │
├──────────┬──────────────────────────────────────────────┤
│ Severity │ MEDIUM                                       │
│ Category │ Dead Code / Missing Integrity Verification   │
│ Location │ LocalInferenceService.swift:64–82            │
│ CWE      │ CWE-354 (Improper Validation of Integrity    │
│          │ Check Value)                                 │
├──────────┴──────────────────────────────────────────────┤
│ What's wrong:                                           │
│ `verifyConfigIntegrity()` is implemented correctly —    │
│ it computes SHA-256 of config.json and compares it to   │
│ the pinned hash `configIntegrityHash`. But it is never  │
│ called anywhere in the codebase. Comments imply         │
│ tampering is caught before inference runs, but the      │
│ verification is entirely dead code.                     │
│                                                         │
│ Why it matters:                                         │
│ A supply chain attacker who could tamper with the       │
│ Hugging Face repo at the pinned revision, or a          │
│ same-user attacker with write access to                 │
│ ~/Library/Application Support/TextRefiner/models/,      │
│ could replace config.json with a tampered version that  │
│ alters model loading behaviour. The declared defence    │
│ (SHA-256 check) never fires, so the tampered config     │
│ loads silently.                                         │
│                                                         │
│ The vulnerable code:                                    │
│ ```swift                                                │
│ // loadModel() — integrity check is NEVER invoked       │
│ func loadModel() async throws {                         │
│     if modelContainer != nil { return }                 │
│     // loads model directly with no integrity check     │
│     let task: Task<Void, Error> = lock.withLock { ... } │
│ }                                                       │
│                                                         │
│ // Defined but has zero call sites:                     │
│ func verifyConfigIntegrity() throws { ... }             │
│ ```                                                     │
│                                                         │
│ The fix:                                                │
│ ```swift                                                │
│ func loadModel() async throws {                         │
│     if modelContainer != nil { return }                 │
│     // Verify config.json integrity before loading      │
│     try verifyConfigIntegrity()                         │
│     let task: Task<Void, Error> = lock.withLock { ... } │
│ }                                                       │
│ ```                                                     │
│                                                         │
│ Effort: ~10 minutes                                     │
└─────────────────────────────────────────────────────────┘

---

### Section 6: Accessibility & System Integration Security

**6.1 — CGEvent tap scope** ✅ PASS
Event mask: `(1 << CGEventType.keyDown.rawValue)` — keyDown only. Options: `.defaultTap`. Non-matching events: `return Unmanaged.passRetained(event)` — passed through. Cleanup: `CGEvent.tapEnable(tap, enable: false)` + `CFMachPortInvalidate(tap)` + `CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)` on `stop()`. `tapDisabledByTimeout`/`tapDisabledByUserInput` handled by dispatching `reenableTap()` to main thread.

**6.2 — Accessibility API usage patterns** ⚠️ PARTIAL
`TypingMonitor.readCharacterCount()` (`TypingMonitor.swift:309`) reads the full text content of the focused element via `kAXValueAttribute` as a fallback when `kAXNumberOfCharactersAttribute` is unavailable (common in Chrome/Electron). The string is used only for `.count` — never stored, logged, or transmitted. This is inherent to cross-app typing indicator functionality. Access requires the Accessibility permission the user explicitly grants. Observation scoped to frontmost app and focused element; observers torn down on app switch and focus change. Document as accepted scope.

**6.3 — TCC permission handling** ✅ PASS
`NSAccessibilityUsageDescription` present in both `Info.plist` and `Info-Dev.plist`. Permission denial handled via `isTrusted()` → `onPermissionDenied` → re-onboarding or alert. Recovery via `startAccessibilityPolling()` (1.5s timer). App never repeatedly prompts after denial.

**6.4 — Key simulation scope** ✅ PASS
Only `Cmd+C` (keyCode `0x08`) and `Cmd+V` (keyCode `0x09`) are simulated. Simulation triggered exclusively by the user's hotkey press. `CGEventSource(.hidSystemState)` used. Text paste is via pasteboard, not keystroke simulation of individual characters — no path exists where attacker-controlled text becomes simulated keystrokes.

**6.5 — AXObserver scope** ✅ PASS
Per-app observer: scoped to `frontmostApp.processIdentifier` only. Per-element observer: scoped to the focused element. Both torn down in `teardownAppObserver()` and `teardownElementObserver()` on focus change or app switch. No global observation. Self excluded: `if pid == ProcessInfo.processInfo.processIdentifier { return }`.

---

### Section 7: Network Security

**7.1 — HTTPS enforcement** ✅ PASS
`SUFeedURL`: `https://gist.githubusercontent.com/...` ✅. Model downloads via `HubApi` (Hugging Face Hub): all connections HTTPS ✅. No HTTP URLs in source or plists. No `NSAllowsArbitraryLoads` in either Info.plist.

**7.2 — Certificate pinning** ✅ PASS
Sparkle: EdDSA (Ed25519) signature verification via `SUPublicEDKey` — effective substitute for certificate pinning for update delivery. Model downloads: no pinning, but HTTPS enforced. Appropriate for this desktop app threat model.

**7.3 — Download integrity** ⚠️ PARTIAL
Sparkle update downloads: EdDSA-signed ✅. Model download: `verifyConfigIntegrity()` exists to check SHA-256 of config.json but is never called (see Finding #1). Model weight files (`.safetensors`) have no integrity check at all — only the presence of at least one `.safetensors` file is verified by `isModelDownloaded()`. The pinned revision hash in `modelConfiguration` is used by the Hugging Face Hub client but not independently verified by the app.

**7.4 — Appcast feed security** ✅ PASS
Appcast at HTTPS URL. EdDSA signatures enforced by Sparkle 2.9.1. GitHub Gist is under the developer's control. A compromised Gist cannot push a malicious update because EdDSA signing prevents it. `LSMinimumSystemVersion: 13.0` in Info.plist.

---

### Section 8: Dependency & Package Security

**8.1 — Swift Package Manager dependency audit** ✅ PASS

| Package | Resolved version | Maintainer | Notes |
|---------|-----------------|------------|-------|
| Sparkle | 2.9.1 | Open source | Well-known, actively maintained |
| mlx-swift-lm | 2.31.3 | Apple/ML Explore | Actively maintained |
| mlx-swift | 0.31.3 | Apple/ML Explore | Actively maintained |
| swift-transformers | 1.2.1 | Hugging Face | Actively maintained |
| swift-crypto | 4.3.1 | Apple | Well-known |
| swift-nio | 2.97.1 | Apple | Well-known |
| swift-asn1 | 1.6.0 | Apple | Well-known |
| swift-atomics | 1.3.0 | Apple | Well-known |
| swift-collections | 1.4.1 | Apple | Well-known |
| swift-numerics | 1.1.1 | Apple | Well-known |
| swift-system | 1.6.4 | Apple | Well-known |
| swift-huggingface | 0.9.0 | Hugging Face | Early version; watch for updates |
| swift-jinja | 2.3.5 | Hugging Face | Actively maintained |
| yyjson | 0.12.0 | ibireme | C JSON library, well-regarded |
| EventSource | 1.4.1 | mattt | Lower-profile; no known CVEs |

No known CVEs for any pinned dependency. All fetched from HTTPS GitHub repos.

**8.2 — Package.resolved / lockfile committed** ✅ PASS
`Package.resolved` is committed and contains exact `revision` hashes for all 15 dependencies. Version 2 format. Guarantees reproducible builds.

**8.3 — Unnecessary dependencies** ✅ PASS
All declared dependencies are actively used: Sparkle (`UpdateManager`, `AppDelegate`), MLXLLM/MLX/MLXRandom/MLXLMCommon/Hub (`LocalInferenceService`). No orphaned imports found.

**8.4 — Framework embedding security** ✅ PASS
`build.sh:175`: `codesign --force --sign - "$FRAMEWORKS_DIR/Sparkle.framework"` — Sparkle signed before app bundle. `@rpath` points to `@executable_path/../Frameworks` — not user-writable. `mlx.metallib` signed before app bundle signing. Sparkle's internal XPC services carry their own signatures.

**8.5 — Build script dependencies** ⚠️ PARTIAL
`build.sh` invokes `xcrun`, `codesign`, `install_name_tool`, `sips`, `iconutil`, `PlistBuddy`, `tccutil`, `ditto`, and `metallib` via PATH lookup rather than full absolute paths. A compromised `PATH` on the developer's machine at build time could redirect these to malicious tools. This is a developer machine threat, not an end-user threat, and risk is low for a single-developer project without CI/CD. Mitigation: use full paths for security-critical tools (`/usr/bin/codesign`, `/usr/bin/xcrun`). No external resources are downloaded during build. Intermediate Metal `.air` files are cleaned up after compilation.

---

## Section 9: Recent-Change Additions (this run only)

Changes since last audit (from daily log 2026-04-11, session 14:01):

1. **Prompt output suppression line** — added `"Only return the refined text, nothing else."` to `PromptStorage.defaultPrompt` before `[TEXT_START]`. Static string addition to an in-memory constant. No new attack surface.
2. **Multi-monitor HUD fix** — replaced `NSScreen.main` with `NSEvent.mouseLocation` + `NSScreen.screens` lookup in `StreamingPanelController.show()` and `showInputLimitError()`. Read-only system state query. No new attack surface.

**No additions this run.**
