# TextRefiner Security Audit
*Automated audit — run: 2026-04-10 08:34 UTC*

---

## Pass 0 — Recent Changes Scan

Recent daily log reviewed: `memory-compiler/daily/2026-04-09.md`

Changes since last audit (2026-04-09) that have security relevance:

1. **Cancellation hardening** — `continuation.onTermination` now propagates cancel to the producer Task in `LocalInferenceService.streamRewrite()`. Reduces the window during which an in-flight inference holds sensitive clipboard text.
2. **`pasteText()` converted to `async throws`** — paste failure is now catchable; `simulateKeyCombo()` throws on CGEvent failure. No new attack surface, but improves error handling around the write-to-clipboard path.
3. **Model load deduplication** — `NSLock` + `loadingTask` prevents duplicate concurrent model loads. No new attack surface.
4. **Model unload after refinement** — `unloadModel()` nils `modelContainer` 2 seconds after refinement completes. Reduces the window during which model weights occupy RAM; no security impact but reduces data-in-memory exposure.
5. **`showModelDownloadPrompt()`** — new download path triggered by `InferenceError.modelNotDownloaded`. Downloads from Hugging Face via the `mlx-swift-lm` Hub library. No new URL handlers or XPC services.
6. **Test automation research** — planning only; no code shipped. Noted that `StreamingPanelController` panels lack AXIdentifiers (deferred).

**Section 9 additions from recent changes:** None. No new URL scheme handlers, XPC services, file format parsers, network endpoints beyond the existing Hugging Face download path, or system API changes. The model download path was already present in onboarding; the new flow reuses the same code. No additional checklist items warranted.

---

## Pass 1 — Architecture Overview

TextRefiner is a pure AppKit menu bar agent (`LSUIElement = true`). Architecture:

- **Entry points for external data:** (1) System pasteboard (`NSPasteboard.general`) — reads selected text from other apps; (2) `prompts.json` in Application Support — user-editable prompt template; (3) `history.json` — encrypted AES-GCM; (4) Sparkle appcast feed — HTTPS, EdDSA-signed; (5) Hugging Face model download — HTTPS via `swift-transformers` Hub library; (6) UserDefaults — hotkey config, feature flags; (7) AX notifications from other apps (TypingMonitor).
- **Data flow:** HotkeyManager CGEvent tap → RefinementCoordinator → AccessibilityService (Cmd+C, pasteboard poll) → LocalInferenceService (MLX on-device inference, `Task.detached`) → AccessibilityService (write pasteboard + Cmd+V) → UI callbacks.
- **Subprocess invocations:** `xattr -dr` (quarantine removal), `tccutil reset` (dev builds only), `/usr/bin/open` (relaunch), `/bin/bash build.sh` (dev Rebuild button).
- **Distribution:** Ad-hoc signed, outside App Store, no notarization. Sparkle for updates.
- **Sensitive data stored:** Refinement history (last 10 entries) encrypted with AES-GCM-256; key stored as `.history-key` (0600); prompt history in plaintext `prompts.json`; hotkey config in UserDefaults.

---

## Pass 2 — Systematic Audit

---

### Section 1: Secrets & Credential Management

**1.1 — Hardcoded secrets**

✅ PASS — No API keys, tokens, bearer credentials, JWT prefixes, GitHub PATs, AWS keys, or Hugging Face tokens found in any Swift source file, plist, shell script, or Package.swift. `SUPublicEDKey` in `Info.plist` (`P9AXPluTwv6uB5JYvou3vFpB6d16Ov8zTbt5SHB9sEo=`) is a **public** Ed25519 key — that is its intended location. The configIntegrityHash in `LocalInferenceService.swift` (SHA-256 of a model config file) is a verification hash, not a secret. No credential-like strings found.

**1.2 — Keychain vs plaintext storage**

⚠️ PARTIAL — History is correctly encrypted (AES-GCM-256) with the symmetric key stored in `.history-key` at 0600 permissions. However, the encryption key file (`~/.../TextRefiner/.history-key`) is stored as a plain file in Application Support rather than in the macOS Keychain. Any process running as the same user can read it. The encrypted `history.json` and its key are co-located in the same directory — defeating the purpose of encryption against same-user processes.

The prompt history (`prompts.json`) is stored in plaintext in Application Support. Prompt templates are not obviously sensitive (they're user-crafted instructions), but a custom prompt could contain sensitive business context that a same-user process could read. This is low severity.

Hotkey configuration is in UserDefaults — not sensitive, acceptable.

**1.3 — Git history for secrets**

✅ PASS — Git history contains 8 commits. No `.env` files, private keys, dSYM archives, credential exports, or Keychain dump files found in history. The `698980b` commit added the Sparkle public key and appcast URL to `Info.plist` — correct placement for a public key. No secrets have been added and removed (which would still leave them in history).

**1.4 — Logging and print statement leaks**

⚠️ PARTIAL — `TypingMonitor` has extensive `print()` statements (e.g., `print("[TypingMonitor] checkAndNotify: count=\(count)...")`). The CLAUDE.md states these are wrapped in `#if DEBUG`, but the actual source file does NOT contain `#if DEBUG` guards. All TypingMonitor print statements will appear in release builds' unified logs, readable by any process running as the same user via `log stream`.

The data logged includes character counts of text fields in other apps, field geometry, and app names. This is low-severity ambient information (no actual clipboard content or text values are logged), but it represents unnecessary information leakage.

Other `print()` calls throughout the codebase (e.g., `[TextRefiner] Hotkey tap created:`, `[TextRefiner] Reset Accessibility TCC for...`) are similarly unguarded in release builds. Notably, `AccessibilityService.swift:73` prints `[TextRefiner] Copy simulation failed: \(error)` which could include error details.

**1.5 — Build artifact exposure**

✅ PASS — `.gitignore` covers `TextRefiner/.build/`, `TextRefiner/TextRefiner.app/`, and `TextRefiner/*.zip`. No dSYM files, compiled binaries, or distribution archives are tracked in git. Source maps are not applicable (native compiled app).

**1.6 — Info.plist secrets**

✅ PASS — `Info.plist` contains only: bundle metadata, `SUFeedURL` (HTTPS appcast URL, appropriate), `SUPublicEDKey` (public verification key — correct location), and `SUEnableAutomaticChecks`/`SUScheduledCheckInterval` (non-sensitive). `Info-Dev.plist` contains no Sparkle keys at all. No private keys, API secrets, or credentials in either plist.

---

### Section 2: Code Signing & Distribution Security

**2.1 — Entitlements review**

✅ PASS — `TextRefiner.entitlements` contains only `com.apple.security.app-sandbox: false`. This is the correct setting for an ad-hoc distributed app that requires Accessibility API access (sandboxed apps cannot use CGEvent tap with `.defaultTap`). No unnecessary entitlements are present (no `com.apple.security.temporary-exception.*`, no unrestricted network, no file system access entitlements). The absence of sandbox is a known and documented architectural decision — not a gap.

**2.2 — Code signing method**

✅ PASS (documented) — Ad-hoc signing (`--sign -`) is used throughout `build.sh`. This is the permanent distribution model per `CLAUDE.md`. Documented implications: Gatekeeper will quarantine downloaded binaries (handled by `xattr -dr` at launch), TCC entries are tied to CDHash (invalidated on every rebuild, handled by `tccutil reset` in dev + re-onboarding in release), notarization is not available. These tradeoffs are understood and handled. No Developer ID certificate management to audit.

**2.3 — Sparkle update framework configuration**

✅ PASS — `SUFeedURL` uses HTTPS (`https://gist.githubusercontent.com/...`). `SUPublicEDKey` is present in `Info.plist` — Sparkle 2.x uses Ed25519 signing. `build.sh` uses the Sparkle `sign_update` tool to produce EdDSA signatures for release zips. `SUEnableAutomaticChecks: true` with a 24h interval. Dev builds have no `SUFeedURL` and `UpdateManager` skips Sparkle initialization when the key is missing — correctly guarded. Package.resolved pins Sparkle at 2.9.1 (a stable release).

**2.4 — Notarization status**

⬚ N/A — App is intentionally not notarized (ad-hoc distribution, no Apple Developer account). This is a permanent architectural decision documented in `CLAUDE.md`. Users must manually strip quarantine or allow via Gatekeeper prompt. The app handles this by stripping quarantine itself at launch (see 2.5).

**2.5 — Quarantine handling**

✅ PASS — `removeQuarantineFlag()` in `AppDelegate.swift:680` strips quarantine from `Bundle.main.bundlePath` only — not from arbitrary paths. Uses `xattr -dr com.apple.quarantine` with the app's own bundle path hardcoded from `Bundle.main.bundlePath`. Runs asynchronously on a background thread to avoid blocking the main thread. This is correctly scoped.

**2.6 — Framework embedding**

✅ PASS — `build.sh:175` signs Sparkle.framework with `codesign --force --sign -` before the app bundle is signed. `build.sh:141` signs `mlx.metallib`. `install_name_tool -add_rpath @executable_path/../Frameworks` sets the rpath correctly — not `@loader_path` or an absolute path. The app bundle is then signed as a whole at line 182. Correct signing order: frameworks → app bundle.

---

### Section 3: Process & Shell Execution Security

**3.1 — Process/NSTask inventory**

All subprocess invocations identified:

1. **`xattr -dr com.apple.quarantine <bundlePath>`** — `AppDelegate.swift:681-685`. Path from `Bundle.main.bundlePath` (not user input).
2. **`tccutil reset Accessibility <bundleID>`** — `AppDelegate.swift:653-658`. Bundle ID from `Bundle.main.bundleIdentifier` (not user input).
3. **`/usr/bin/open <appBundleURL>`** — `AppDelegate.swift:733` and `SettingsWindowController.swift:380`. Path derived from `Bundle.main.bundlePath` + `"TextRefiner.app"`.
4. **`/bin/bash <buildScript>`** — `AppDelegate.swift:715` and `SettingsWindowController.swift:348`. Path derived from `Bundle.main.bundlePath`.
5. **`codesign --force --sign - <paths>`** and other build tools in `build.sh` — run during development builds only, not at runtime.
6. **`/usr/bin/open <systemPrefsURL>`** — `AppDelegate.swift:495`. Uses a hard-coded `x-apple.systempreferences:` URL string, not user input.

**3.2 — Shell command injection**

✅ PASS — No Process invocations use `/bin/bash -c` with string interpolation. The `/bin/bash` invocation in the Rebuild button uses `process.arguments = [buildScript]` where `buildScript` is a fixed path derived from the bundle path, not user-controlled data. All other processes use explicit argument arrays. No shell injection vectors identified.

**3.3 — Subprocess environment**

⚠️ PARTIAL — None of the subprocess invocations explicitly set `process.environment`. This means subprocesses inherit the parent app's environment. For a menu bar app, the environment is the user's login session environment — not expected to contain sensitive secrets. The risk is low in practice, but setting an explicit minimal environment for `xattr` and `tccutil` would be better practice. This is informational.

**3.4 — Dynamic library loading**

✅ PASS — No `dlopen()` calls found in any Swift source file. `install_name_tool -add_rpath @executable_path/../Frameworks` sets rpath to the standard frameworks location only. No user-writable absolute paths in rpath.

**3.5 — tccutil and privilege-sensitive commands**

✅ PASS — `tccutil reset Accessibility \(bundleID)` in `AppDelegate.swift:655-658` uses `Bundle.main.bundleIdentifier` — the app's own bundle ID only. It never targets other apps' bundle IDs. This code path is only executed in production during post-update re-onboarding (when `needsReOnboarding` is true), not on every launch. In `build.sh`, `tccutil reset Accessibility "$BUNDLE_ID"` likewise uses the app's own bundle ID.

---

### Section 4: Local Data Storage Security

**4.1 — UserDefaults for sensitive data**

✅ PASS — UserDefaults stores only: `com.textrefiner.onboardingCompleted` (bool), `com.textrefiner.lastOnboardedBuild` (build string), `com.textrefiner.hotkeyKeyCode` (int), `com.textrefiner.hotkeyModifierFlags` (int), `com.textrefiner.showTypingIndicator` (bool). None of these are sensitive. No API keys, tokens, license keys, user content, or personal data stored in UserDefaults.

**4.2 — Application Support files**

⚠️ PARTIAL — Three file types in `~/Library/Application Support/TextRefiner/`:

- **`history.json`**: AES-GCM-256 encrypted. Set to 0600 permissions (`RefinementHistory.swift:115`). Contains original and refined text from past refinements — potentially sensitive user content. Encryption is implemented correctly (CryptoKit AES.GCM). File permissions are correctly restricted.
- **`.history-key`**: The AES-GCM symmetric key. Set to 0600 permissions (`RefinementHistory.swift:101`). As noted in 1.2, storing the key adjacent to the ciphertext in the same directory means a same-user process can read both. Against a same-user attacker, this encryption provides no protection. Against other users or physical access scenarios, the 0600 permissions provide OS-level protection and the encryption provides defense-in-depth.
- **`prompts.json`**: Plaintext. Contains the user's custom prompt templates. Not explicitly set to restricted permissions — defaults to system umask (typically 0644, world-readable). Low sensitivity (contains instructions, not data), but worth noting.
- **`models/`**: Model weights (~1.8 GB). Not sensitive. Read-only after download.

**4.3 — Pasteboard handling**

⚠️ PARTIAL — The app reads from and writes to `NSPasteboard.general.string(forType: .string)` in `AccessibilityService`. Two concerns:

1. **No pasteboard restoration**: When the user's hotkey fires, the app writes selected text via Cmd+C (changing the pasteboard) then later overwrites the pasteboard with the refined text. The user's prior pasteboard content is permanently lost. This is a UX issue and also means whatever the user had on the clipboard (potentially sensitive) gets replaced. Other apps monitoring the pasteboard can see both the selected text and the refined output during the processing window.
2. **Pasteboard exposure window**: The selected text sits on `NSPasteboard.general` from the time Cmd+C fires until Cmd+V completes (~50ms + inference time of 2-5 seconds). During this window, any process running as the same user can read the clipboard. For a text refiner, this is inherent to the design — the text must be on the pasteboard to be pasted. This is a known and unavoidable tradeoff of the copy-paste mechanism.
3. **Non-string type handling**: `NSPasteboard.general.string(forType: .string)` returns `nil` for non-string content — correctly handled (nil triggers `noTextSelected` error).

**4.4 — Temporary files and caches**

✅ PASS — No writes to `NSTemporaryDirectory()`, `/tmp`, or `FileManager.default.temporaryDirectory` found in any Swift source file. No cache directories in `~/Library/Caches/` are written to by the app. The Metal AIR files built during compilation are created in `.build/mlx_air/` and cleaned up by `build.sh:139` (`rm -rf "$AIR_DIR"`).

**4.5 — JSON/plist deserialization safety**

✅ PASS — All JSON deserialization uses `try?` with fallback to defaults rather than force-unwrapping or `fatalError`:

- `PromptStorage.swift:128-134`: `try? Data(contentsOf:)` → `try? JSONDecoder.decode()` → fallback to `PromptData(activePrompt: Self.defaultPrompt, history: [])`.
- `RefinementHistory.swift:72-88`: `try? Data(contentsOf:)` → encrypted decode → plaintext decode fallback → `self.entries = []`. Graceful migration from old unencrypted format.
- Crafted `prompts.json` could inject a malicious prompt template. This is addressed by the `{{USER_TEXT}}` validation in `saveCurrentPrompt()`, but a direct file edit bypasses that validation. The impact is limited: a tampered prompt template can only alter how the local model is instructed — it cannot cause code execution, network calls, or privilege escalation.

---

### Section 5: Input Validation & Injection

**5.1 — LLM prompt injection**

✅ PASS — `LocalInferenceService.streamRewrite()` strips `[TEXT_START]`, `[TEXT_END]`, and `{{USER_TEXT}}` from clipboard content before injecting into the template (`LocalInferenceService.swift:184-188`). The delimiter-based isolation is present. Model output is not used to drive downstream actions (no code execution, no file operations, no URL navigation from model output) — it is only pasted as text. Prompt templates loaded from `prompts.json` must contain `{{USER_TEXT}}` (validated by `PromptStorage.saveCurrentPrompt()`, though a direct file edit bypasses this).

**5.2 — Model output sanitization**

✅ PASS — `cleanResponse()` strips leaked prompt artifacts: closing anchors, delimiter leakage (`[TEXT_START]`, `[TEXT_END]`), preamble phrases, and wrapping quotes. Called after full accumulation. Model output is pasted as plain text via Cmd+V — no interpretation of the output as code, shell commands, or keystrokes occurs. Control characters in model output would be pasted as literal characters into whatever app has focus. This is acceptable — the user has explicitly initiated the action.

**5.3 — Pasteboard content validation**

✅ PASS — `RefinementCoordinator.maxInputCharacters = 10_000` enforces a hard limit on clipboard content size before inference. Inputs over 10,000 characters throw `inputTooLong` and show an error HUD — inference never runs. Non-string pasteboard types return `nil` from `NSPasteboard.general.string(forType: .string)` and are handled as `noTextSelected`.

**5.4 — Untrusted data deserialization**

✅ PASS — See 4.5 above. The one additional concern: `prompts.json` can be edited by the user to contain a prompt without `{{USER_TEXT}}`. If this happens, `promptTemplate.replacingOccurrences(of: "{{USER_TEXT}}", with: sanitizedText)` returns the template unchanged (no replacement, no crash). The model would receive the template without user text — producing a confused or empty output, not a security violation. The app gracefully handles malformed prompt data at runtime even if the validation is bypassed via direct file edit.

---

### Section 6: Accessibility & System Integration Security

**6.1 — CGEvent tap scope**

✅ PASS — `HotkeyManager.start()` creates a tap with event mask `(1 << CGEventType.keyDown.rawValue)` — only `keyDown` events, the narrowest useful mask. Uses `.defaultTap` (required to consume events — prevents the hotkey from reaching the frontmost app). Events that don't match the configured hotkey or Escape (when active) are returned via `Unmanaged.passRetained(event)` — passed through, not consumed. Tap is cleaned up with `CFMachPortInvalidate` + `CFRunLoopRemoveSource` in `stop()`. `AccessibilityService.isTrusted()` creates a test tap for permission verification, properly cleans it up with `CFMachPortInvalidate`.

**6.2 — Accessibility API usage patterns**

⚠️ PARTIAL — `TypingMonitor` reads from other apps via AX:

- **What is read**: Character count (`kAXNumberOfCharactersAttribute`), field frame (position/size), role, placeholder, and value string (as fallback for character counting). The value string is read but only its `.count` is used — the text content is not logged, stored, or transmitted.
- **Is data logged**: `print("[TypingMonitor] checkAndNotify: count=\(count)...")` logs character counts. No actual text content is logged.
- **Observation scope**: `AXObserver` is scoped to the frontmost app only (`attachToFrontmostApp()` uses the frontmost app's PID). Observers are torn down in `teardownAppObserver()` and `teardownElementObserver()` when the app or element changes.
- **Gap**: `attachToFocusedElement()` falls back to checking `AXUIElementIsAttributeSettable` on the focused element, which touches a wider range of elements (any settable-value element, including `AXWebArea`). This is broad but limited to the currently focused element only.

**6.3 — TCC permission handling**

✅ PASS — Accessibility permission denial is handled gracefully at multiple levels: `AccessibilityService.requestPermission()` calls `AXIsProcessTrustedWithOptions` with the system prompt option (adds app to Accessibility list). `showOnboarding()` provides clear explanation. Background polling (`startAccessibilityPolling()`) self-heals when permission is re-granted. `showPermissionAlert()` gives actionable instructions. `NSAccessibilityUsageDescription` is present in both `Info.plist` and `Info-Dev.plist`. The app does not repeatedly prompt after denial — it polls silently until granted.

**6.4 — Key simulation scope**

✅ PASS — `AccessibilityService.simulateCopyAndRead()` simulates only keyCode `0x08` (C) with `.maskCommand`. `pasteText()` simulates only keyCode `0x09` (V) with `.maskCommand`. No other keycodes are simulated. Both are gated behind user-initiated hotkey press → `RefinementCoordinator.startRefinement()`. No path exists for attacker-controlled strings to be converted into arbitrary keystrokes. Uses `.hidSystemState` source, which is transparent to the target app — correct for transparent paste simulation.

**6.5 — AXObserver scope**

✅ PASS — Per-app observer (`appObserver`) watches only `kAXFocusedUIElementChangedNotification` on the frontmost app. Per-element observer (`elementObserver`) watches `kAXValueChangedNotification` and `kAXSelectedTextChangedNotification` on the focused element only. Both observers are torn down in `teardownAppObserver()` and `teardownElementObserver()` respectively when focus changes. The character count read (`kAXNumberOfCharactersAttribute`) is not stored beyond the immediate comparison — only the decision to show/hide the indicator is stored.

---

### Section 7: Network Security

**7.1 — HTTPS enforcement**

✅ PASS — All network connections use HTTPS:
- Sparkle appcast: `https://gist.githubusercontent.com/34-byte/6a5dacdb24a6bae85d003e906f5fa907/raw/appcast.xml`
- Model downloads: handled by `HubApi` from `swift-transformers`, which fetches from `https://huggingface.co/`
- No `NSAllowsArbitraryLoads` or `NSAppTransportSecurity` exceptions in either `Info.plist` or `Info-Dev.plist`
- No HTTP-only URLs found in any source file

**7.2 — Certificate pinning**

⬚ N/A — Certificate pinning is not implemented. For this threat model (desktop app, ad-hoc distribution, no remote authentication), certificate pinning for the Sparkle appcast would add complexity without meaningful protection beyond HTTPS + EdDSA signature verification. Sparkle's EdDSA verification is the primary integrity control — a compromised appcast host cannot push a malicious update without the private signing key. For the Hugging Face model download, the config integrity check (SHA-256) provides content verification independent of TLS.

**7.3 — Download integrity**

✅ PASS — Model config integrity is verified via SHA-256 (`LocalInferenceService.verifyConfigIntegrity()`) against a hash embedded in the app binary. The hash was captured at a pinned git revision (`7f0dc925...`). If the hash doesn't match, the model directory is deleted and `integrityCheckFailed` is thrown — no fallback to using unverified content. Sparkle update integrity is covered by EdDSA signatures (see 2.3). Model weight files (`.safetensors`) are not individually hashed — only `config.json` is verified. This is a partial gap for the model weights, but exploiting it would require MITM of the Hugging Face HTTPS connection while simultaneously the SHA-256 check passes for config.json.

**7.4 — Appcast feed security**

✅ PASS — Appcast URL is HTTPS. EdDSA signing prevents a compromised appcast host from pushing malicious updates (the attacker would need the private signing key). `minimumSystemVersion` is set via `LSMinimumSystemVersion: 13.0` in `Info.plist` (Ventura minimum). The appcast is hosted on GitHub Gist — a GitHub-controlled CDN, which is trusted infrastructure. The download URL in the appcast itself should also use HTTPS (not auditable without fetching the live appcast, but the Sparkle build tooling enforces this).

---

### Section 8: Dependency & Package Security

**8.1 — Swift Package Manager dependency audit**

Direct dependencies from `Package.swift`:

| Package | Version Constraint | Resolved | Notes |
|---|---|---|---|
| `sparkle-project/Sparkle` | `>= 2.6.0` | 2.9.1 | Well-maintained, actively developed. No known CVEs at 2.9.1. |
| `ml-explore/mlx-swift-lm` | `>= 2.30.0` | 2.31.3 | Apple MLX project. Actively maintained. |
| `ml-explore/mlx-swift` | `>= 0.31.3` | 0.31.3 | Apple MLX project. Actively maintained. |
| `huggingface/swift-transformers` | `>= 1.2.0` | 1.2.1 | Maintained by Hugging Face. Includes networking for model downloads. |

All resolved over HTTPS from trusted sources. Range-based version constraints (`>=`) could in theory resolve to a future compromised version — but `Package.resolved` locks the currently resolved versions, protecting builds that use the lockfile.

Transitive dependencies: `swift-asn1`, `swift-atomics`, `swift-collections`, `swift-crypto`, `swift-huggingface`, `swift-jinja`, `swift-nio`, `swift-numerics`, `swift-system`, `swift-transformers`, `yyjson`, `eventsource` — all Apple, Hugging Face, or well-known open source packages with pinned revisions in `Package.resolved`.

**8.2 — Package.resolved committed**

✅ PASS — `Package.resolved` is committed to the repository and contains exact revision hashes for all 15 dependencies. This prevents `swift package resolve` from pulling different versions on different machines.

**8.3 — Unnecessary dependencies**

✅ PASS — All four declared dependencies are actively used:
- `Sparkle` → `UpdateManager.swift`, `AppDelegate.swift` (import)
- `MLXLLM`, `MLX`, `MLXRandom` → `LocalInferenceService.swift`
- `Hub` (swift-transformers) → `LocalInferenceService.swift`
- `MLXLMCommon` → `LocalInferenceService.swift`

No unused imports or unreferenced packages found.

**8.4 — Framework embedding security**

✅ PASS — `build.sh:175`: `codesign --force --sign - "$FRAMEWORKS_DIR/Sparkle.framework"` signs Sparkle before the app bundle is signed. Ad-hoc signing means the framework and app share the same signing identity (empty), which is correct for ad-hoc distribution. `@rpath` is set to `@executable_path/../Frameworks` only. An attacker with write access to a distributed `.app` bundle could replace the framework, but ad-hoc signing means any modification would invalidate the ad-hoc signature (though Gatekeeper doesn't enforce signatures on ad-hoc apps — this remains an inherent limitation of ad-hoc distribution).

**8.5 — Build script dependencies**

⚠️ PARTIAL — `build.sh` invokes: `swift build`, `find`, `xcrun metal`, `xcrun metallib`, `codesign`, `install_name_tool`, `sips`, `iconutil`, `/usr/libexec/PlistBuddy`, `ditto` — most via `PATH` lookup rather than absolute paths. If an attacker could inject a malicious `swift`, `codesign`, or `xcrun` into a directory earlier in `$PATH`, the build script would use it. This is a development environment concern rather than a runtime concern (build.sh is never executed at runtime, only during development/release-build). Low severity for this distribution model.

Temporary build artifacts (`$AIR_DIR` containing `.air` files) are cleaned up on line 139 (`rm -rf "$AIR_DIR"`). The `.build/` directory is excluded from git.

---

### Section 9: Recent-Change Additions (this run only)

No additions this run. No new attack surfaces introduced by recent changes. All recent work (cancellation hardening, async throws for paste, model load deduplication, model unload, download prompt) operates on existing code paths and does not add new entry points, network endpoints, subprocess invocations, or file formats.

---

## 1. Security Posture Rating

**🟡 ACCEPTABLE — Minor issues, no immediate data exposure risk to a standard threat model.**

TextRefiner's primary threat model is other apps running as the same user and supply chain attacks via dependencies or updates. Against same-user processes: the encryption key for `history.json` is co-located with the ciphertext (defeating same-user protection); `prompts.json` is world-readable; and TypingMonitor logs character counts to the unified log (minor ambient leakage). Against supply chain attacks: Sparkle EdDSA signing, pinned Package.resolved, and model config integrity checking provide strong controls. The quarantine-removal and tccutil invocations are tightly scoped to the app's own bundle. No hardcoded secrets, no shell injection vectors, and no unsafe subprocess calls were found. The most actionable improvement is moving the `.history-key` to the macOS Keychain, which would make the history encryption meaningful against same-user attackers.

---

## 2. Critical and High Findings

No CRITICAL or HIGH severity findings this run.

---

## 3. Quick Wins

1. **Wrap TypingMonitor print statements in `#if DEBUG`** — ~5 minutes. CLAUDE.md states this is already done, but the source file does not contain the guards. Add `#if DEBUG` / `#endif` around all `print()` calls in `TypingMonitor.swift`. (Relates to 1.4)

2. **Restrict `prompts.json` permissions to 0600** — ~2 minutes. Add `try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)` in `PromptStorage.persist()`. Consistency with the history file pattern. (Relates to 4.2)

3. **Move `.history-key` to the macOS Keychain** — ~20 minutes. Replaces the file-based key storage with `SecItemAdd`/`SecItemCopyMatching`. Makes the encryption meaningful against same-user attackers. (Relates to 1.2, 4.2)

4. **Set `process.environment` explicitly on subprocesses** — ~15 minutes. Prevents parent environment from leaking into subprocess scope. Low priority but technically correct. (Relates to 3.3)

---

## 4. Prioritized Remediation Plan

1. **Move `.history-key` to Keychain** — MEDIUM severity, ~20 min. Encrypting user text without protecting the key is security theater against same-user processes. (1.2, 4.2)
2. **Add `#if DEBUG` guards to TypingMonitor print statements** — LOW severity, ~5 min. CLAUDE.md says they exist; the source file shows they don't. (1.4)
3. **Restrict `prompts.json` to 0600 permissions** — LOW severity, ~2 min. Consistency with history file pattern. (4.2)
4. **Set explicit subprocess environment** — LOW severity (informational), ~15 min. Best practice hygiene. (3.3)
5. **Add per-file integrity hashes for model `.safetensors` files** — LOW severity (theoretical), high effort. Only relevant if Hugging Face CDN is compromised and TLS fails simultaneously. Deprioritize. (7.3)

---

## 5. What's Already Done Right

- **Prompt injection hardening**: Delimiter stripping before injection and post-processing artifact removal are both in place and correct.
- **Input length limit**: 10,000 character cap with user-friendly error HUD — prevents memory and inference abuse.
- **Escape-to-cancel**: Properly scoped (only active during inference), uses Swift structured concurrency cancellation correctly wired through `continuation.onTermination`.
- **CGEvent tap scoping**: Narrowest useful event mask (keyDown only), non-matching events are passed through, tap is properly cleaned up on stop.
- **Sparkle EdDSA signing**: Ed25519 public key in Info.plist, sign_update tool used in release builds, HTTPS-only appcast.
- **Model config integrity**: SHA-256 verification against a pinned hash embedded in the binary, with automatic re-download on mismatch.
- **History encryption**: AES-GCM-256 with CryptoKit, 0600 file permissions on both key and ciphertext.
- **No hardcoded secrets**: Clean search across all source files and git history.
- **Package lockfile committed**: `Package.resolved` pins all 15 dependencies to exact revisions.
- **Quarantine scoped to own bundle**: `xattr -dr` targets only `Bundle.main.bundlePath`.
- **tccutil scoped to own bundle ID**: Never resets other apps' TCC entries.
- **Accessibility permission handling**: Robust polling, graceful degradation, clear user guidance.
- **No unnecessary entitlements**: Minimal entitlements file, no over-permissioning.
- **JSON deserialization with fallbacks**: All decode calls use `try?` with safe defaults, no force-unwraps on external data.
- **Model unloaded after refinement**: 2-second delayed unload reduces the window sensitive data occupies RAM.

---

## 6. Checklist Summary

```
1.1 ✅  1.2 ⚠️  1.3 ✅  1.4 ⚠️  1.5 ✅  1.6 ✅
2.1 ✅  2.2 ✅  2.3 ✅  2.4 ⬚  2.5 ✅  2.6 ✅
3.1 ✅  3.2 ✅  3.3 ⚠️  3.4 ✅  3.5 ✅
4.1 ✅  4.2 ⚠️  4.3 ⚠️  4.4 ✅  4.5 ✅
5.1 ✅  5.2 ✅  5.3 ✅  5.4 ✅
6.1 ✅  6.2 ⚠️  6.3 ✅  6.4 ✅  6.5 ✅
7.1 ✅  7.2 ⬚  7.3 ✅  7.4 ✅
8.1 ✅  8.2 ✅  8.3 ✅  8.4 ✅  8.5 ⚠️
9   — No additions this run
```

**Legend:** ✅ PASS  ⚠️ PARTIAL  ❌ FAIL  ⬚ N/A

**FAIL count: 0 | PARTIAL count: 7 | N/A count: 2**
