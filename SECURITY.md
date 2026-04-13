# TextRefiner Security Audit
*Automated audit — run: 2026-04-13 06:35 UTC*

---

## Section 9: Recent-Change Additions (this run only)

Two changes shipped since the last audit (from 2026-04-13 daily log):

1. **HUD Pill Animation Rework** — `StreamingPanelController.swift` deleted; all HUD states moved into `ReadyIndicatorController`. Position tracking via a background thread that polls AX `kAXPositionAttribute`/`kAXSizeAttribute`, caches the result, and a `CADisplayLink` on the main thread reads the cache at vsync cadence. Data accessed is screen coordinates only (CGRect) — no text content.

2. **Inference Timeout** — `RefinementCoordinator` now races inference against a 60-second `withThrowingTaskGroup` timeout. Timeout routes to a "timed out" HUD error via the existing `showError()` path. No new data handling.

Neither change introduces a new attack surface not already covered by Sections 1–8.

**No additions this run.**

---

## Section 1: Secrets & Credential Management

### 1.1 — Hardcoded secrets
✅ **PASS**
No API keys, tokens, JWTs, AWS keys, Hugging Face tokens, or private keys found in any source file, plist, shell script, or config. `SUPublicEDKey` in `Info.plist` (`P9AXPluTwv6uB5JYvou3vFpB6d16Ov8zTbt5SHB9sEo=`) is the **public** EdDSA key for Sparkle signature verification — not a secret, expected to be in the plist. `configIntegrityHash` in `LocalInferenceService.swift:25` is a public SHA-256 integrity reference, not a credential.

### 1.2 — Keychain vs plaintext storage
✅ **PASS**
The only cryptographic secret in the app — the AES-GCM history encryption key — is stored in the macOS Data Protection Keychain using `kSecClassGenericPassword` with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and `kSecUseDataProtectionKeychain: true` (`RefinementHistory.swift:165–173`). `kSecAttrSynchronizable` is not set, preventing iCloud sync. UserDefaults stores only non-sensitive preferences: hotkey key code, hotkey modifiers, onboarding completion flag, build number, and typing indicator toggle — none are credentials or personal data.

### 1.3 — Git history for secrets
✅ **PASS**
Git history grep for common secret patterns (`sk_live_`, `Bearer`, `eyJ`, `ghp_`, `AKIA`, `hf_`, `private_key`, `password`, `secret`) found no matches in tracked Swift, shell, or plist files. No deleted `.env`, `.key`, `.pem`, `.p12`, or `.secret` files in history.

### 1.4 — Logging and print statement leaks
✅ **PASS**
Every `print()` statement in the codebase that touches operational state is wrapped in `#if DEBUG`. Confirmed across all files: `TypingMonitor.swift` (all prints guarded), `AccessibilityService.swift:74`, `HotkeyManager.swift:48`, `RefinementHistory.swift:195`, `PromptStorage.swift:149`, `AppDelegate.swift:254,686`. No clipboard content, user text, or error messages containing sensitive data reach release build logs.

### 1.5 — Build artifact exposure
✅ **PASS**
`.gitignore` covers `TextRefiner/.build/`, `TextRefiner/TextRefiner.app/`, `TextRefiner/*.zip`. No dSYM files, build artifacts, or binary distributions committed to the repository.

### 1.6 — Info.plist secrets
✅ **PASS**
`Info.plist` contains: `SUFeedURL` (public HTTPS URL), `SUPublicEDKey` (public key — correct), `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`, and standard bundle metadata. `Info-Dev.plist` contains no Sparkle config at all. No private keys or credentials in either plist.

---

## Section 2: Code Signing & Distribution Security

### 2.1 — Entitlements review
✅ **PASS**
`TextRefiner.entitlements` contains a single entry: `com.apple.security.app-sandbox: false`. The absence of sandbox is documented and required — `CGEvent.tapCreate` with `.defaultTap` and `NSPasteboard` write access cannot function inside the App Sandbox. No unnecessary entitlements: no `com.apple.security.temporary-exception.*`, no unrestricted network access, no file system access beyond what Application Support provides by default.

### 2.2 — Code signing method
✅ **PASS** (documented limitation)
Ad-hoc signing (`--sign -`) is the intentional, documented distribution model. Implications are acknowledged in `CLAUDE.md` and `build.sh`: Gatekeeper blocks the app on first launch, TCC entries are CDHash-bound and invalidated on every rebuild/update, the app cannot be notarized, and Sparkle updates trigger a TCC re-grant flow. The re-onboarding flow after updates correctly handles the stale TCC entry via `resetAccessibilityPermission()`.

### 2.3 — Sparkle / update framework configuration
✅ **PASS**
- `SUFeedURL`: `https://gist.githubusercontent.com/34-byte/6a5dacdb24a6bae85d003e906f5fa907/raw/appcast.xml` — HTTPS ✅
- `SUPublicEDKey` present — EdDSA (Ed25519) signature verification configured ✅
- `SUEnableAutomaticChecks: true`, 24-hour check interval ✅
- `build.sh` generates EdDSA signatures via Sparkle's `sign_update` tool ✅
- Appcast hosted on GitHub Gist (developer-controlled) ✅

### 2.4 — Notarization status
⚠️ **PARTIAL**
The app is not notarized (no Apple Developer ID, ad-hoc signing). This is an intentional design constraint documented in `CLAUDE.md`. The practical effect: users must clear quarantine manually or the app does it automatically via `removeQuarantineFlag()`. The app's self-clearing approach is scoped correctly (own bundle path only) and runs before any CGEvent tap is attempted. No code fix needed — this is a distribution-model limitation, not a vulnerability.

### 2.5 — Quarantine handling
✅ **PASS**
`AppDelegate.removeQuarantineFlag()` (`AppDelegate.swift:702–714`):
```swift
process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
process.arguments = ["-dr", "com.apple.quarantine", bundlePath]
```
`bundlePath` is `Bundle.main.bundlePath` — the app's own bundle, not an arbitrary path. Uses argument array (not shell string interpolation). Runs on a background thread via `DispatchQueue.global(qos: .userInitiated)`. All permission-dependent setup runs in the completion handler, guaranteeing the flag is cleared before any CGEvent tap is attempted.

### 2.6 — Framework embedding
✅ **PASS**
`build.sh` signs Sparkle.framework before signing the app bundle:
```bash
codesign --force --sign "$SIGN_ID" "$FRAMEWORKS_DIR/Sparkle.framework"
codesign --force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
```
rpath is set to `@executable_path/../Frameworks` via `install_name_tool`. No absolute paths or user-writable paths in rpath. MLX `metallib` is also signed before the app bundle is signed.

---

## Section 3: Process & Shell Execution Security

### 3.1 — Process/NSTask inventory
✅ **PASS**

Four `Process` invocations in the codebase:

| Location | Command | Argument source | Shell? |
|---|---|---|---|
| `AppDelegate.resetAccessibilityPermission()` | `/usr/bin/tccutil reset Accessibility <bundleID>` | `Bundle.main.bundleIdentifier` | No |
| `AppDelegate.removeQuarantineFlag()` | `/usr/bin/xattr -dr com.apple.quarantine <bundlePath>` | `Bundle.main.bundlePath` | No |
| `AppDelegate.rebuildAndRelaunch()` | `/bin/bash <buildScript>` | Derived from `Bundle.main.bundlePath` | Yes, but runs static file |
| `AppDelegate.rebuildAndRelaunch()` (relaunch) | `/usr/bin/open -n <appBundleURL>` | Derived from `Bundle.main.bundlePath` | No |

All argument sources are internal (bundle metadata), not user input. All use argument arrays. The `rebuildAndRelaunch` method is gated behind `Bundle.main.bundleIdentifier == "com.textrefiner.app.dev"` and only appears in the menu in dev builds.

### 3.2 — Shell command injection
✅ **PASS**
No `Process` invocation uses `/bin/bash -c "string with interpolation"`. The one invocation that uses `/bin/bash` passes a static file path (`[buildScript]`) — bash interprets the file, not a constructed command string. No user input flows into any Process argument.

### 3.3 — Subprocess environment
✅ **PASS**
All three Process invocations explicitly set a minimal environment:
```swift
process.environment = ["PATH": "/usr/bin:/bin"]
```
Subprocesses do not inherit the parent's full environment, preventing any sensitive environment variables (if present) from leaking to child processes.

### 3.4 — Dynamic library loading
✅ **PASS**
No `dlopen()` calls found. rpath is set to `@executable_path/../Frameworks` only — no absolute paths, no `@loader_path`, no user-writable paths in rpath.

### 3.5 — tccutil and privilege-sensitive commands
✅ **PASS**
`tccutil reset Accessibility bundleID` in `resetAccessibilityPermission()` is scoped to the app's own bundle ID, fetched from `Bundle.main.bundleIdentifier`. This is called only when the app detects a version change (stale TCC entry). In `build.sh`, the `tccutil reset` also uses the bundle ID from the app's own Info.plist. No path resets arbitrary bundle IDs or broad permission categories.

---

## Section 4: Local Data Storage Security

### 4.1 — UserDefaults for sensitive data
✅ **PASS**
UserDefaults keys used: `com.textrefiner.onboardingCompleted` (bool), `com.textrefiner.lastOnboardedBuild` (build string), `com.textrefiner.hotkeyKeyCode` (integer), `com.textrefiner.hotkeyModifierFlags` (integer), `com.textrefiner.showTypingIndicator` (bool). None are credentials, tokens, or personal data. Hotkey configuration (key code + modifiers) is not sensitive — it is a UI preference.

### 4.2 — Application Support files
⚠️ **PARTIAL**
Files in `~/Library/Application Support/TextRefiner/`:

| File | Contents | Sensitive? | Permissions | Encrypted |
|---|---|---|---|---|
| `history.json` | User text (original + refined) | Yes | `0o600` ✅ | AES-GCM ✅ |
| `prompts.json` | User-authored prompt templates | Low | `0o600` ✅ | No |
| `models/` | ML model weights (~1.8GB) | No | Inherited from Hub API | No |

`history.json` and `prompts.json` both have `0o600` set explicitly after each write (`FileManager.setAttributes([.posixPermissions: 0o600])`). The model directory does not have explicit permissions set — files created by the Hub API inherit the default umask (typically `0o644`). Since model weights are public files downloadable by anyone from Hugging Face, their world-readability is not a security issue, but the inconsistency is worth noting.

### 4.3 — Pasteboard handling
⚠️ **PARTIAL**
The app simulates Cmd+C (putting the user's selected text on the clipboard) and Cmd+V (putting the refined text on the clipboard). Two design limitations:

1. **Original clipboard not restored**: Whatever the user had on the clipboard before triggering the hotkey is overwritten by the simulated Cmd+C.
2. **Clipboard residue**: The refined text (which may contain sensitive content) stays on the clipboard indefinitely, readable by any process running as the same user.

These are intentional design constraints — clipboard residue is by design (so users can Cmd+V manually if auto-paste fails). For the standard threat model (local same-user processes), any app can already read the clipboard. TextRefiner does not introduce a meaningfully new exposure vector beyond standard macOS clipboard behavior. No fix recommended unless clipboard privacy becomes a stated requirement.

### 4.4 — Temporary files and caches
✅ **PASS**
No `NSTemporaryDirectory()`, `FileManager.default.temporaryDirectory`, or `/tmp` usage found. No `~/Library/Caches/` writes observed. Model files are cached in Application Support (appropriate location for persistent data).

### 4.5 — JSON/plist deserialization safety
✅ **PASS**
- `PromptStorage.init()`: `try? Data(contentsOf:)` + `try? JSONDecoder.decode()` — malformed file falls back to default prompt without crashing (`PromptStorage.swift:130–136`) ✅
- `RefinementHistory.init()`: AES-GCM decryption failure falls back to plaintext migration attempt, then empty array (`RefinementHistory.swift:71–87`) ✅
- `LocalInferenceService.verifyConfigIntegrity()`: missing or malformed `config.json` returns early (allows re-download), hash mismatch deletes and forces re-download (`LocalInferenceService.swift:64–82`) ✅
- All deserialized data is typed (Codable structs) — no dynamic key access that could alter security-relevant behavior ✅

---

## Section 5: Input Validation & Injection

### 5.1 — LLM prompt injection
✅ **PASS**
Delimiter strings are stripped from clipboard content before template injection (`LocalInferenceService.swift:184–187`):
```swift
let sanitizedText = text
    .replacingOccurrences(of: "[TEXT_START]", with: "")
    .replacingOccurrences(of: "[TEXT_END]", with: "")
    .replacingOccurrences(of: "{{USER_TEXT}}", with: "")
```
The model is local (no network call with user data). Even if prompt injection succeeded, the worst outcome is unexpected text being pasted — the model output drives no system actions (no code execution, no file operations, no URL navigation).

### 5.2 — Model output sanitization
⚠️ **PARTIAL**
`cleanResponse()` strips prompt artifacts, leaked delimiters, preambles, and wrapping quotes (`LocalInferenceService.swift:231–272`). The refined text is pasted as plain text via `NSPasteboard.general.setString(text, forType: .string)`. Plain text paste is interpreted literally by most apps.

One edge case: control characters (`\t`, `\n`, `\r` are acceptable; others such as `\x01`–`\x08`, `\x0B`–`\x1F`) in the model output are not filtered. In most apps (text editors, browsers, messaging apps) this is benign. In terminal emulators, pasting text containing certain control characters can execute commands. This requires: (1) a malicious/jailbroken local model returning control chars, and (2) the user having a terminal window focused when they trigger the hotkey. Risk is LOW given the fully local threat model and the impracticality of this scenario.

### 5.3 — Pasteboard content validation
✅ **PASS**
Input is capped at `maxInputCharacters = 10_000` characters before inference (`RefinementCoordinator.swift:91–93`). Non-string pasteboard types: `NSPasteboard.general.string(forType: .string)` returns nil for non-string content, handled by the `guard let selectedText` check. The character limit also serves as a memory bound for inference input.

### 5.4 — Untrusted data deserialization
✅ **PASS**
All deserialization uses typed Codable structs with `try?` fallbacks. The only place where deserialized data could alter security-relevant behavior is `prompts.json` → prompt template, but the prompt template only affects model instruction text and does not drive system actions. `config.json` is hash-verified before model loading. No TOCTOU window identified for critical paths.

---

## Section 6: Accessibility & System Integration Security

### 6.1 — CGEvent tap scope
✅ **PASS**
`HotkeyManager.start()` (`HotkeyManager.swift:36`):
```swift
let eventMask = (1 << CGEventType.keyDown.rawValue)
```
Only `keyDown` events are intercepted — not all events. `.defaultTap` is required to consume the hotkey and Escape events. All non-matching events are returned unmodified (`return Unmanaged.passRetained(event)`). The test tap in `AccessibilityService.isTrusted()` is invalidated immediately after creation (`CFMachPortInvalidate(tap)`, `AccessibilityService.swift:38`). `stop()` performs full cleanup: `tapEnable(false)` → `CFMachPortInvalidate` → nil → `CFRunLoopRemoveSource`.

### 6.2 — Accessibility API usage patterns
✅ **PASS**
`TypingMonitor` reads: character count (`kAXNumberOfCharactersAttribute` or string length), field frame (`kAXPositionAttribute`, `kAXSizeAttribute`), placeholder text (for false-positive suppression), and element role. Text **content** is never read or stored. All debug prints are `#if DEBUG` gated. Observations are limited to the three notifications needed (`kAXFocusedUIElementChangedNotification`, `kAXValueChangedNotification`, `kAXSelectedTextChangedNotification`). AXObservers are torn down on app switch and on `stop()`.

### 6.3 — TCC permission handling
✅ **PASS**
`NSAccessibilityUsageDescription` is present in both `Info.plist` and `Info-Dev.plist`. Permission denial routes to onboarding (`showOnboarding()`) or an alert with clear instructions. Recovery polling starts automatically after denial. `AXIsProcessTrustedWithOptions` is called proactively to ensure the app appears in System Settings before the user needs to find it.

### 6.4 — Key simulation scope
✅ **PASS**
Only two key combinations are ever simulated: `Cmd+C` (keyCode `0x08` + `.maskCommand`) and `Cmd+V` (keyCode `0x09` + `.maskCommand`). Both are hardcoded constants, not derived from user input or model output. Both are gated behind the user-initiated hotkey press. Source ID is `.hidSystemState`. No attacker-controlled keystrokes beyond plain-text paste.

### 6.5 — AXObserver scope
✅ **PASS**
- `appObserver`: Watches only the frontmost app PID for focus changes. Torn down when the observed app changes (`teardownAppObserver()` in `handleAppActivated()`).
- `elementObserver`: Watches only the focused element for value/selection changes. Torn down when focus changes. The `trackedElement` reference is cleared on teardown.
- Text field content is never stored — only character count (integer) and frame (CGRect).
- Own-app exclusion: `pid == ProcessInfo.processInfo.processIdentifier` check prevents observing TextRefiner itself.

---

## Section 7: Network Security

### 7.1 — HTTPS enforcement
✅ **PASS**
All network connections use HTTPS:
- Sparkle appcast: `https://gist.githubusercontent.com/...` ✅
- Model downloads: HubApi from swift-transformers uses HTTPS against `huggingface.co` ✅
- No hardcoded HTTP URLs found ✅
- No `NSAppTransportSecurity` override in either `Info.plist` or `Info-Dev.plist` — ATS defaults apply (HTTPS required) ✅

### 7.2 — Certificate pinning
⚠️ **PARTIAL**
No certificate pinning is implemented. For the two network consumers:
- **Sparkle updates**: EdDSA signature verification provides equivalent protection — even if the HTTPS cert were compromised, a malicious update binary cannot be installed without the EdDSA private key ✅
- **Model downloads**: Relies on HTTPS transport + pinned git revision (`revision: "7f0dc925..."` in `LocalInferenceService.swift:20–22`). If the Hugging Face CDN were compromised, altered weight files served at the pinned revision could potentially be installed. The pinned revision provides git-level content integrity for files Hugging Face resolves by commit hash, but this is not independently verified by the app.

### 7.3 — Download integrity
⚠️ **PARTIAL**
`verifyConfigIntegrity()` verifies a SHA-256 hash of `config.json` only (`LocalInferenceService.swift:64–82`). The model weight files (`.safetensors`, ~1.8GB) are not individually hash-verified. The pinned revision provides some protection (git content addressing), but there is no cryptographic check that the downloaded weights match a known-good state beyond the transport layer.

This is LOW severity: (1) HTTPS makes MITM impractical, (2) model weights from a malicious download would produce incorrect output — detectable by the user — rather than code execution, (3) the pinned revision limits which files can be served.

Remediation option: embed SHA-256 hashes for the `.safetensors` files alongside `configIntegrityHash` and verify them in `verifyConfigIntegrity()`.

### 7.4 — Appcast feed security
✅ **PASS**
- HTTPS ✅
- EdDSA signing enforced via `SUPublicEDKey` ✅
- `LSMinimumSystemVersion: 13.0` in Info.plist ✅
- GitHub Gist is developer-controlled (requires GitHub account access + EdDSA private key to push a malicious update) ✅

---

## Section 8: Dependency & Package Security

### 8.1 — Swift Package Manager dependency audit
✅ **PASS**

| Package | Pinned Version | Source | Status |
|---|---|---|---|
| Sparkle | 2.9.1 | sparkle-project | Well-known, actively maintained ✅ |
| mlx-swift-lm | 2.31.3 | ml-explore (Apple) | Apple-maintained ✅ |
| mlx-swift | 0.31.3 | ml-explore (Apple) | Apple-maintained ✅ |
| swift-transformers | 1.2.1 | huggingface | Hugging Face official ✅ |
| eventsource | 1.4.1 | mattt | Indirect dep, focused scope ✅ |
| swift-asn1 | 1.6.0 | apple | Apple-maintained ✅ |
| swift-atomics | 1.3.0 | apple | Apple-maintained ✅ |
| swift-collections | 1.4.1 | apple | Apple-maintained ✅ |
| swift-crypto | 4.3.1 | apple | Apple-maintained ✅ |
| swift-huggingface | 0.9.0 | huggingface | Hugging Face official ✅ |
| swift-jinja | 2.3.5 | huggingface | Hugging Face official ✅ |
| swift-nio | 2.97.1 | apple | Apple-maintained ✅ |
| swift-numerics | 1.1.1 | apple | Apple-maintained ✅ |
| swift-system | 1.6.4 | apple | Apple-maintained ✅ |
| yyjson | 0.12.0 | ibireme | Widely used C JSON library ✅ |

All fetched over HTTPS from GitHub. No known CVEs identified for any dependency at current pinned versions.

### 8.2 — Package.resolved / lockfile committed
✅ **PASS**
`TextRefiner/Package.resolved` is committed to the repository and tracked by git. All 15 dependencies are pinned to exact commit revisions, preventing version drift across machines.

### 8.3 — Unnecessary dependencies
✅ **PASS**
All four direct dependencies are actively used:
- `Sparkle`: `UpdateManager.swift`
- `MLXLLM`/`MLXLMCommon`: `LocalInferenceService.swift`
- `Hub` (swift-transformers): `LocalInferenceService.swift`
- `MLX`/`MLXRandom`: `LocalInferenceService.swift`

No zombie imports or unused dependencies found.

### 8.4 — Framework embedding security
✅ **PASS**
`build.sh` signs Sparkle.framework and MLX metallib before signing the app bundle:
```bash
codesign --force --sign "$SIGN_ID" "$FRAMEWORKS_DIR/Sparkle.framework"
codesign --force --sign "$SIGN_ID" "$METALLIB_OUT"
codesign --force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
```
Signing order is correct. rpath is `@executable_path/../Frameworks` only — no user-writable or absolute paths that could be hijacked via dylib injection.

### 8.5 — Build script dependencies
⚠️ **PARTIAL**
System tools (`swift`, `xcrun`, `codesign`, `sips`, `iconutil`, `install_name_tool`, `PlistBuddy`, `ditto`, `tccutil`) are invoked by name (PATH lookup), not full paths. This is the macOS developer convention and acceptable in a developer environment where PATH is trusted. The Sparkle `sign_update` tool is invoked from `.build/artifacts/sparkle/...` — a local directory not in the repo. If the `.build/` directory were replaced with a malicious build (e.g., through a supply chain attack on `swift package resolve`), a malicious `sign_update` binary could output a false EdDSA signature. However, `.build/` is gitignored and only present on a developer machine — this is a development-environment concern, not a production concern.

---

## 1. Security Posture Rating

### 🟡 ACCEPTABLE

TextRefiner has a well-considered security posture for its threat model. No active data exposure vulnerabilities were found. The most sensitive user data — refinement history — is encrypted at rest with AES-GCM using a key stored in the Data Protection Keychain. Shell subprocess invocations use argument arrays (no injection surface), debug logging is fully suppressed in release builds, Sparkle updates are EdDSA-signed, and the CGEvent tap is correctly scoped. The open findings are LOW severity informational items: clipboard residue after paste (intentional design choice), absence of per-file hash verification for downloaded model weights (mitigated by HTTPS + pinned revision), and a single edge case around control characters in model output.

**Threat model context:** For a desktop app distributed ad-hoc outside the App Store, the primary threats are (1) other processes running as the same user reading clipboard/files, (2) supply chain compromise via dependencies or the update feed, (3) local physical access, and (4) the user's own input being misused. None of the open findings represent exploitable vulnerabilities under this threat model.

---

## 2. Critical and High Findings

None. No CRITICAL or HIGH severity findings identified in this audit.

---

## 3. Quick Wins

1. **Strip control characters from model output in `cleanResponse()`** — add a character filter that removes non-printable characters (except `\t`, `\n`, `\r`) before pasting. Eliminates the terminal control character edge case entirely. Effort: ~5 minutes.

2. **Add SHA-256 hashes for `.safetensors` files to `verifyConfigIntegrity()`** — extend the existing model integrity check to cover weight files, not just `config.json`. Effort: ~30 minutes (capture hashes at release time, add verification loop).

---

## 4. Prioritized Remediation Plan

| # | Finding | Severity | Effort |
|---|---|---|---|
| 1 | Control characters in model output not stripped (5.2) | LOW | ~5 min |
| 2 | Model weight files not hash-verified (7.3) | LOW | ~30 min |
| 3 | Clipboard not restored after paste (4.3) | LOW / Informational | Design decision |
| 4 | Model files lack explicit 0o600 permissions (4.2) | Informational | ~10 min |
| 5 | Build tools invoked by PATH lookup (8.5) | Informational | N/A (dev-time only) |
| 6 | Not notarized (2.4) | Informational | Design constraint |

---

## 5. What's Already Done Right

- **AES-GCM encryption for history** with a Data Protection Keychain key (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecUseDataProtectionKeychain: true`) — correct key storage, correct algorithm, correct accessibility attribute.
- **Prompt injection hardening** — delimiter strings stripped from clipboard input before template injection; model output post-processed to remove leaked delimiters.
- **Input length limit** — 10,000 character cap enforced before inference, preventing memory exhaustion and unbounded model input.
- **DEBUG-only logging** — every `print()` that touches operational state is `#if DEBUG` gated. Release builds are completely silent.
- **No shell injection surface** — all `Process` invocations use argument arrays; no user input ever flows into a subprocess argument.
- **Minimal subprocess environment** — `["PATH": "/usr/bin:/bin"]` explicitly set on all subprocesses; no environment inheritance.
- **Narrow CGEvent tap** — `keyDown` only, pass-through for all non-matching events, proper cleanup on `stop()`.
- **Escape interception scoped** — `onEscapePressed` is `nil` by default; only set during active processing, cleared on all exit paths.
- **tccutil scoped** — only resets the app's own bundle identifier; never broad permission categories.
- **AXObserver cleanup** — observers torn down on app switch, `stop()`, and focus change.
- **No sensitive UserDefaults** — only UI preferences stored in UserDefaults.
- **HTTPS everywhere** — no HTTP URLs, no ATS exceptions.
- **EdDSA Sparkle signing** — update delivery cryptographically protected end-to-end.
- **Package.resolved committed** — all 15 dependencies pinned to exact git revisions.
- **0o600 permissions** on `history.json` and `prompts.json`.
- **Atomic writes** — `options: .atomic` on all file persistence calls.
- **SHA-256 integrity for config.json** — model configuration verified against embedded hash before inference.
- **Quarantine removal scoped** to own bundle path only.
- **Inference timeout** — 60-second cap prevents indefinite hangs without user interaction.

---

## 6. Checklist Summary

```
1.1 ✅  1.2 ✅  1.3 ✅  1.4 ✅  1.5 ✅  1.6 ✅
2.1 ✅  2.2 ✅  2.3 ✅  2.4 ⚠️  2.5 ✅  2.6 ✅
3.1 ✅  3.2 ✅  3.3 ✅  3.4 ✅  3.5 ✅
4.1 ✅  4.2 ⚠️  4.3 ⚠️  4.4 ✅  4.5 ✅
5.1 ✅  5.2 ⚠️  5.3 ✅  5.4 ✅
6.1 ✅  6.2 ✅  6.3 ✅  6.4 ✅  6.5 ✅
7.1 ✅  7.2 ⚠️  7.3 ⚠️  7.4 ✅
8.1 ✅  8.2 ✅  8.3 ✅  8.4 ✅  8.5 ⚠️
9   ⬚  (no new attack surfaces from recent changes)
```

**Verdicts:** 33 ✅ PASS · 7 ⚠️ PARTIAL · 0 ❌ FAIL · 1 ⬚ N/A
