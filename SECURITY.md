# TextRefiner Security Audit
*Automated audit — run: 2026-04-18 01:03 UTC*

---

## 1. Security Posture Rating

**🟡 ACCEPTABLE** — Minor issues, no immediate data exposure risk to a standard threat model.

TextRefiner has no hardcoded credentials, no shell injection paths, properly uses the macOS Keychain for sensitive data (history encryption key), has robust prompt injection hardening, uses process argument arrays throughout (no shell -c interpolation), and carries minimal entitlements. All seven PARTIAL findings are either inherent to the paste-simulation design, limited to dev-only features, or mitigated by compensating controls. No FAIL findings were identified across 33 checklist items.

The primary threat model for this app — local privilege escalation, data exposure to co-user processes, and supply chain attacks — is addressed: clipboard data exposure is inherent to the Cmd+V design and time-bounded; supply chain is mitigated by EdDSA update signing and SHA-256 model config verification; no paths exist for privilege escalation. The one meaningful gap is that model weight files (.safetensors) are not individually checksummed — only config.json is verified.

---

## 2. Critical And High Findings

**None.** No CRITICAL or HIGH severity findings were identified in this audit.

---

## 3. Quick Wins

1. **3.3 / ~5 min** — Set `process.environment` explicitly in `SettingsWindowController.rebuildAndRelaunch()` to match the pattern used in AppDelegate. Copy the `["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/libexec", "HOME": ...]` block already present in AppDelegate's `rebuildAndRelaunch()`.

2. **1.5 / ~2 min** — Add `**/*.dSYM` to `.gitignore` as an explicit exclusion alongside `TextRefiner/.build/`. While .dSYMs are generated inside `.build/` (already covered), an explicit entry makes the intent clear.

3. **8.5 / ~10 min** — Prefix commonly-hijackable tool invocations in build.sh with full paths (`/usr/bin/sips`, `/usr/bin/iconutil`, `/usr/bin/ditto`) to eliminate PATH dependency for tools not yet using full paths.

---

## 4. Prioritized Remediation Plan

| # | Finding | Severity | Effort | Section |
|---|---------|----------|--------|---------|
| 1 | Model weight files (.safetensors) not individually verified — only config.json SHA-256 checked | MEDIUM | ~60 min | 7.3 |
| 2 | SettingsWindowController.rebuildAndRelaunch() inherits parent process environment | LOW | ~5 min | 3.3 |
| 3 | build.sh uses PATH-relative tool names for sips, iconutil, ditto | LOW | ~10 min | 8.5 |
| 4 | Appcast hosted on third-party GitHub Gist (not developer-controlled infrastructure) | LOW | ~30 min | 2.3 |
| 5 | prompts.json stored unencrypted (user-created prompt templates) | LOW | ~90 min | 4.2 |
| 6 | Refined text remains on clipboard after paste (readable by co-user processes) | LOW/Info | Architectural | 4.3 |
| 7 | .gitignore lacks explicit *.dSYM entry | Info | ~2 min | 1.5 |

---

## 5. What's Already Done Right

- **No hardcoded secrets** — all credentials and keys absent from source; only the Sparkle EdDSA public key (correctly public) appears in plists.
- **Keychain for encryption key** — history.json encryption key stored with `kSecUseDataProtectionKeychain` and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- **AES-GCM encrypted history** — refinement history (user text) encrypted at rest; plaintext-to-keychain migration path correctly implemented.
- **Prompt injection hardening** — `[TEXT_START]`/`[TEXT_END]` delimiters + explicit stripping of delimiter strings from clipboard before injection.
- **Shell injection prevention** — every `Process` invocation uses `.arguments = [...]` arrays; no `/bin/bash -c "\(userInput)"` pattern found anywhere.
- **Process environment isolation** — tccutil and xattr processes set explicit `["PATH": "/usr/bin:/bin"]` environments (AppDelegate path).
- **tccutil scoped to own bundle ID** — `Bundle.main.bundleIdentifier` used as the reset target, never a hardcoded or user-supplied value.
- **Minimal entitlements** — only `com.apple.security.app-sandbox: false` required for Accessibility + CGEvent tap; no unnecessary capabilities.
- **EdDSA update signing** — `SUPublicEDKey` configured; build pipeline uses Sparkle's `sign_update` tool; HTTPS appcast URL.
- **Model integrity check** — SHA-256 of config.json verified before inference; mismatch deletes model directory and forces re-download.
- **Narrow CGEvent tap** — only `keyDown` events captured; non-matching events passed through unchanged; tap properly invalidated on `stop()`.
- **No text content in logs** — all `print()` statements wrapped in `#if DEBUG`; character counts (not text content) used for typing indicator logic.
- **Pasteboard size limit** — 10,000 character ceiling enforced before LLM call; non-string pasteboard types gracefully handled as no-op.
- **AX reads limited to metadata** — only character count and frame geometry read via Accessibility API; full text content only accessed via clipboard at refinement time.
- **Package.resolved committed** — dependency versions pinned; deterministic builds across machines.
- **Quarantine removal scoped** — `xattr -dr com.apple.quarantine` targets only `Bundle.main.bundlePath`, not arbitrary paths.

---

## 6. Checklist Summary

```
1.1 ✅  1.2 ✅  1.3 ✅  1.4 ✅  1.5 ⚠️  1.6 ✅
2.1 ✅  2.2 ✅  2.3 ⚠️  2.4 ⬚  2.5 ✅  2.6 ✅
3.1 ✅  3.2 ✅  3.3 ⚠️  3.4 ✅  3.5 ✅
4.1 ✅  4.2 ⚠️  4.3 ⚠️  4.4 ✅  4.5 ✅
5.1 ✅  5.2 ✅  5.3 ✅  5.4 ✅
6.1 ✅  6.2 ✅  6.3 ✅  6.4 ✅  6.5 ✅
7.1 ✅  7.2 ✅  7.3 ⚠️  7.4 ✅
8.1 ✅  8.2 ✅  8.3 ✅  8.4 ✅  8.5 ⚠️
9   — No additions this run
```

---

## Section-by-Section Results

### Section 1: Secrets & Credential Management

**1.1 — Hardcoded secrets** ✅ PASS
No API keys, tokens, passwords, private keys, JWT tokens, AWS keys, or HuggingFace tokens found anywhere in source, plists, scripts, or configuration. The `SUPublicEDKey` value in Info.plist (`P9AXPluTwv6uB5JYvou3vFpB6d16Ov8zTbt5SHB9sEo=`) is an Ed25519 **public** key — correct placement for Sparkle signature verification. The SHA-256 hash in `LocalInferenceService` (`configIntegrityHash`) is a file digest used for integrity verification, not a credential.

**1.2 — Keychain vs plaintext storage** ✅ PASS
Sensitive data (history encryption key) is stored in the macOS Keychain via `SecItemAdd` with `kSecUseDataProtectionKeychain: true` and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. UserDefaults stores only non-sensitive preferences (hotkey codes, UI toggles, update counters). `prompts.json` stores user-created prompt templates (not credentials) with 0600 file permissions — noted under 4.2 but not a credential management failure.

**1.3 — Git history for secrets** ✅ PASS
17 commits audited. The commit "Configure Sparkle appcast URL and EdDSA public key" adds only the public key and HTTPS URL — no private material. No `.env` files, Keychain exports, dSYM files, or deleted credential files found in history. No patterns matching `sk_`, `AKIA`, `ghp_`, `eyJ`, or `hf_` found.

**1.4 — Logging and print statement leaks** ✅ PASS
All `print()` statements throughout the codebase are wrapped in `#if DEBUG` blocks and compile out of release builds. Logged content is limited to: tap creation status, app names, AX element roles, character counts (never text content), build status strings. No clipboard content, user text, model output, or credentials appear in any log statement.

**1.5 — Build artifact exposure** ⚠️ PARTIAL
`.gitignore` covers `TextRefiner/.build/` (which contains dSYM directories), `TextRefiner/TextRefiner.app/`, and `TextRefiner/*.zip`. dSYM files are not explicitly listed. In practice they live inside `.build/` so are covered, but an explicit `**/*.dSYM` entry would make intent unambiguous. No source maps, Keychain exports, or debug builds were found committed. Fix: ~2 minutes.

**1.6 — Info.plist secrets** ✅ PASS
`Info.plist` contains `SUPublicEDKey` (Ed25519 public key — correct) and `SUFeedURL` (HTTPS URL — expected). `Info-Dev.plist` contains neither (dev builds don't use Sparkle). No private keys, API secrets, or credentials in either plist.

---

### Section 2: Code Signing & Distribution Security

**2.1 — Entitlements review** ✅ PASS
`TextRefiner.entitlements` contains a single entry: `com.apple.security.app-sandbox: false`. No sandbox is required for Accessibility API and CGEvent tap creation, and is the documented permanent distribution model. No unnecessary entitlements (no unrestricted network access, no file system exceptions, no temporary exceptions).

**2.2 — Code signing method** ✅ PASS
Ad-hoc signing (`--sign -`) is the documented and accepted distribution method. The implications — Gatekeeper warning on first run, TCC entries tied to binary hash, no notarization, TCC reset required after updates — are all handled correctly by the re-onboarding flow and quarantine removal. This is not a misconfiguration; it is an intentional architectural choice.

**2.3 — Sparkle / update framework configuration** ⚠️ PARTIAL
Feed URL uses HTTPS ✅. EdDSA key (`SUPublicEDKey`) is configured ✅. `SUEnableAutomaticChecks: true` and `SUScheduledCheckInterval: 3600` are present ✅. `build.sh` uses Sparkle's `sign_update` tool to sign release ZIPs ✅. Gap: the appcast is hosted on **GitHub Gist** — third-party infrastructure. If the GitHub account were compromised, an attacker could modify the appcast XML. EdDSA signature verification prevents a malicious binary from being installed (the attacker would also need the private signing key), but appcast metadata (version strings, download URLs) could be manipulated. Mitigation: host appcast on developer-controlled infrastructure.

**2.4 — Notarization status** ⬚ N/A
Notarization is not possible for ad-hoc signed apps — this is an accepted tradeoff of the distribution model documented in CLAUDE.md. Users must manually approve the app via right-click → Open, or via the quarantine removal the app performs internally.

**2.5 — Quarantine handling** ✅ PASS
`removeQuarantineFlag()` strips `com.apple.quarantine` from `Bundle.main.bundlePath` only — the app's own bundle. Uses `process.arguments = ["-dr", "com.apple.quarantine", bundlePath]` (argument array, not shell -c string). Runs asynchronously on a background thread. Scoped and necessary for Sparkle-updated binaries.

**2.6 — Framework embedding** ✅ PASS
`build.sh` signs `Sparkle.framework` before signing the app bundle: `codesign --force --sign "$SIGN_ID" "$FRAMEWORKS_DIR/Sparkle.framework"`. `@rpath` is set to `@executable_path/../Frameworks` via `install_name_tool`. No world-writable path components in the rpath chain.

---

### Section 3: Process & Shell Execution Security

**3.1 — Process/NSTask inventory** ✅ PASS
Five Process invocations found. All use argument arrays, not shell string construction:
1. `AppDelegate.resetAccessibilityPermission()` — `/usr/bin/tccutil reset Accessibility <bundleID>`
2. `AppDelegate.removeQuarantineFlag()` — `/usr/bin/xattr -dr com.apple.quarantine <bundlePath>`
3. `AppDelegate.rebuildAndRelaunch()` — `/bin/bash [buildScript]` (dev-only)
4. `AppDelegate.rebuildAndRelaunch()` relaunch — `/usr/bin/open -n [appBundleURL.path]` (dev-only)
5. `SettingsWindowController.rebuildAndRelaunch()` — `/bin/bash [buildScript]` + `/usr/bin/open [appBundleURL.path]` (dev-only)

No argument derives from user input or external data in any invocation.

**3.2 — Shell command injection** ✅ PASS
No `process.arguments = ["-c", "command \(userInput)"]` pattern exists anywhere. Dev rebuild processes execute `buildScript` directly via bash — the script path is derived from `Bundle.main.bundlePath`, not user input. All argument arrays are constructed from internal constants.

**3.3 — Subprocess environment** ⚠️ PARTIAL
`resetAccessibilityPermission()` and `removeQuarantineFlag()` set `process.environment = ["PATH": "/usr/bin:/bin"]`. `AppDelegate.rebuildAndRelaunch()` sets explicit PATH + HOME. `SettingsWindowController.rebuildAndRelaunch()` does **not** set `process.environment`, inheriting the parent process environment. Dev-only feature, low practical risk, but inconsistent with the pattern used elsewhere. Fix: copy the environment dict from AppDelegate's `rebuildAndRelaunch()`. ~5 minutes.

**3.4 — Dynamic library loading** ✅ PASS
No `dlopen()` calls in Swift sources. `@rpath` set to `@executable_path/../Frameworks` only. `mlx.metallib` compiled to `Contents/MacOS/` (not user-writable). No user-writable paths in the rpath chain.

**3.5 — tccutil and privilege-sensitive commands** ✅ PASS
`tccutil reset Accessibility` invoked only with `Bundle.main.bundleIdentifier` as the target — never a hardcoded or user-supplied value. Same pattern in `build.sh`. Never invoked for any bundle ID other than the app's own.

---

### Section 4: Local Data Storage Security

**4.1 — UserDefaults for sensitive data** ✅ PASS
UserDefaults stores: onboarding completion flag, last onboarded build string, hotkey key code (integer), hotkey modifier flags (integer), typing indicator toggle, dock icon toggle, sound toggle, update dismiss count, update dismissed version string, update snooze count. None are credentials, tokens, or personal data.

**4.2 — Application Support files** ⚠️ PARTIAL
- `history.json`: Contains original and refined user text. Encrypted with AES-GCM (256-bit key stored in Keychain). File permissions: 0o600. ✅
- `prompts.json`: Contains active prompt template and prompt history. Permissions: 0o600. Content is **unencrypted JSON**. Prompts are user-created style instructions, not credentials, but storing them unencrypted while history is encrypted is inconsistent.
- `models/`: Model weights from HuggingFace, config integrity verified via SHA-256. Not sensitive data.

**4.3 — Pasteboard handling** ⚠️ PARTIAL
The app uses the system pasteboard as the paste vector. After refinement, the refined text **remains on the pasteboard** — the original clipboard content is not restored. Any process running as the same user can read the refined text during and after the operation. This is inherent to the Cmd+V paste approach: text must be on the clipboard to be pasted. The exposure window is short (typically <2 seconds) and triggered only by an explicit user action.

**4.4 — Temporary files and caches** ✅ PASS
No `NSTemporaryDirectory()` or `/tmp` usage in Swift sources. `build.sh` uses `$BUILD_DIR/mlx_air` for temporary Metal .air compilation artifacts, cleaned up immediately after metallib is built. No sensitive data passes through temp files.

**4.5 — JSON/plist deserialization safety** ✅ PASS
All JSON decoding uses `try?` with fallback to safe defaults — malformed `prompts.json` falls back to the built-in default prompt; malformed `history.json` falls back to an empty array. No `fatalError` or force-unwrap on decoded external data. A crafted `prompts.json` could inject a malicious prompt template, but impact is limited to text refinement behavior — no code execution or file operations result from model output.

---

### Section 5: Input Validation & Injection

**5.1 — LLM prompt injection** ✅ PASS
Clipboard text is sanitized before injection: `[TEXT_START]`, `[TEXT_END]`, and `{{USER_TEXT}}` are stripped from user text in `LocalInferenceService.streamRewrite()`. The cleaned text is wrapped in `[TEXT_START]/[TEXT_END]` delimiters in the prompt template. Model output is not used to drive any system actions — only pasted as text. Prompt templates validated for `{{USER_TEXT}}` on save.

**5.2 — Model output sanitization** ✅ PASS
`cleanResponse()` strips leaked delimiters (`[TEXT_START]`, `[TEXT_END]`), preamble phrases, closing anchor echo, and wrapping quotes. Output written to pasteboard as `.string` type — no binary injection possible. Model output cannot drive keystrokes beyond a single Cmd+V paste.

**5.3 — Pasteboard content validation** ✅ PASS
`RefinementCoordinator.maxInputCharacters = 10_000` enforces a size ceiling before the LLM call. `simulateCopyAndRead()` requests `.string` type — non-string pasteboard content returns nil, triggering `noTextSelected`. Memory risk from oversized input is bounded.

**5.4 — Untrusted data deserialization** ✅ PASS
All deserialization uses `try?` with safe fallbacks. No force-unwrap on external data. A co-user process modifying `prompts.json` (0o600 permissions prevent cross-user modification) could alter prompt behavior — impact limited to text refinement style, not code execution.

---

### Section 6: Accessibility & System Integration Security

**6.1 — CGEvent tap scope** ✅ PASS
Event mask: `1 << CGEventType.keyDown.rawValue` — only keyDown events. Tap type: `.defaultTap` (required to consume hotkey). Non-matching events: `return Unmanaged.passRetained(event)` passes all non-hotkey, non-escape events through. Escape only consumed when `onEscapePressed != nil` (set only during active processing). Cleanup: `CFMachPortInvalidate(tap)` + `CFRunLoopRemoveSource` in `stop()`.

**6.2 — Accessibility API usage patterns** ✅ PASS
AX reads limited to: character count, element frame, role, placeholder presence, value string length for fallback counting. Full text content is **never read via AX** — only accessed via clipboard at refinement time. No AX data logged in release builds. Observers torn down in `teardownElementObserver()` and `teardownAppObserver()`.

**6.3 — TCC permission handling** ✅ PASS
`NSAccessibilityUsageDescription` present in both plists. Permission denial before refinement caught in `startRefinement()` and routed to alert. Mid-session revocation caught by copy simulation failure. Background polling self-heals when permission is re-granted.

**6.4 — Key simulation scope** ✅ PASS
Only Cmd+C (`keyCode 0x08`) and Cmd+V (`keyCode 0x09`) are simulated. Both gated behind user-initiated hotkey press. `CGEventSource` uses `.hidSystemState`. No path exists where attacker-controlled text becomes simulated keystrokes — model output goes to pasteboard, single Cmd+V follows.

**6.5 — AXObserver scope** ✅ PASS
Per-app observer targets frontmost app PID — not system-wide. Per-element observer targets the focused text field. Both torn down on app switch. Browser and terminal apps excluded entirely. No text content read or stored by observers.

---

### Section 7: Network Security

**7.1 — HTTPS enforcement** ✅ PASS
Sparkle appcast URL uses HTTPS. HuggingFace model downloads via Hub library use HTTPS. No `NSAllowsArbitraryLoads` in either plist. No HTTP URLs found in source or config.

**7.2 — Certificate pinning** ✅ PASS
Sparkle uses HTTPS + EdDSA signature verification (`SUPublicEDKey` configured). EdDSA signing is more robust than certificate pinning for update distribution: even if transport is compromised, a malicious binary cannot be installed without the private signing key. Model download integrity verified post-download via embedded SHA-256.

**7.3 — Download integrity** ⚠️ PARTIAL
Sparkle update integrity: EdDSA signatures ✅. Model config integrity: SHA-256 of `config.json` verified against embedded `configIntegrityHash` constant ✅. Gap: **model weight files** (`.safetensors`) are **not individually verified**. `verifyConfigIntegrity()` only checks `config.json`. A compromised HuggingFace account or MITM attacker could replace `.safetensors` files while leaving `config.json` unchanged, passing the integrity check and substituting a different model. Remediation: extend verification to hash each `.safetensors` file against a pinned manifest embedded in the app. ~60 minutes.

**7.4 — Appcast feed security** ✅ PASS
Appcast served over HTTPS. EdDSA signatures prevent malicious update injection even if the appcast host is compromised (attacker would also need the private signing key). GitHub Gist hosting noted under 2.3 — EdDSA mitigates binary injection risk in that scenario.

---

### Section 8: Dependency & Package Security

**8.1 — Swift Package Manager dependency audit** ✅ PASS
All direct and transitive dependencies fetched over HTTPS from trusted sources. All pinned to specific revisions in `Package.resolved`. No branch-based dependencies. No known CVEs identified for any pinned versions.

| Package | Version | Source |
|---------|---------|--------|
| Sparkle | 2.9.1 | sparkle-project |
| mlx-swift-lm | 2.31.3 | ml-explore |
| mlx-swift | 0.31.3 | ml-explore |
| swift-transformers | 1.2.1 | huggingface |
| eventsource | 1.4.1 | mattt |
| swift-asn1/atomics/collections/crypto/nio/numerics/system | various | apple |
| swift-huggingface / swift-jinja | 0.9.0 / 2.3.5 | huggingface |
| yyjson | 0.12.0 | ibireme |

**8.2 — Package.resolved committed** ✅ PASS
`TextRefiner/Package.resolved` committed at the root of the TextRefiner package. All 15 dependencies pinned to specific revisions.

**8.3 — Unnecessary dependencies** ✅ PASS
All declared dependencies are used: Sparkle (auto-updates), MLXLLM + MLX + MLXRandom + MLXLMCommon (inference), Hub (model download). No unused packages detected.

**8.4 — Framework embedding security** ✅ PASS
`build.sh` signs `Sparkle.framework` before signing the app bundle (correct signing order). `@rpath` set to `@executable_path/../Frameworks`. Sparkle's embedded XPC helpers signed as part of framework signing. No user-writable paths in the rpath chain.

**8.5 — Build script dependencies** ⚠️ PARTIAL
`build.sh` uses full paths for security-sensitive tools: `/usr/libexec/PlistBuddy`, `/usr/bin/tccutil`. Several tools invoked by name only via PATH: `sips`, `iconutil`, `ditto`. Build script is not distributed to end users — developer-only. An attacker with write access to a PATH-prior directory could theoretically hijack these tools, but this requires compromising the developer machine itself. Fix: use `/usr/bin/sips`, `/usr/bin/iconutil`, `/usr/bin/ditto`. ~10 minutes.

---

## Section 9: Recent-Change Additions (this run only)

Changes since the previous audit (from daily log 2026-04-16):
1. HUD positioning thread-safety fix — NSScreen.main cache on main thread, stale frame clearing, cursor fallback
2. Electron pill change-detection baseline fix — immediate gate open at attach time when content already above threshold
3. Terminal app exclusion — `terminalBundleIDs` set, early return in `attachToFrontmostApp()`

**No additions this run.** None of these changes introduce new attack surfaces beyond the standard checklist. The terminal exclusion is a read-only bundle ID lookup. The HUD and pill fixes are pure UI state management with no new data entry points, network calls, file I/O, or subprocess invocations.
