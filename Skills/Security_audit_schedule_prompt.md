# Scheduled Task Prompt — Daily Security Audit

Use this as the prompt when creating the scheduled remote agent trigger.
Copy everything inside the code block below into the task prompt field.

---

**Recommended schedule:** Daily, 8am Berlin time = `0 6 * * *` (UTC)

---

```
You are running the daily automated security audit for TextRefiner, a macOS menu bar app built with AppKit and Apple MLX.

## Your task

1. Read the full audit instructions from `Skills/Security_audit.md` in this repo.
2. Follow those instructions exactly:
   - Pass 1: read the entire codebase to build a mental model of the architecture
   - Pass 2: work through every checklist item (Sections 1–8), one by one, with an explicit verdict for each
3. Write the complete audit report to `SECURITY.md` at the repo root, overwriting any previous report.

## Report format

Start `SECURITY.md` with this header (fill in today's UTC date and time):

# TextRefiner Security Audit
*Automated audit — run: YYYY-MM-DD HH:MM UTC*

---

Then output the full report as specified in `Skills/Security_audit.md`.

## Where to look

The daily logs are in `memory-compiler/daily/`. Read the most recent
one first (Pass 0) before touching the source code.

The codebase lives in `TextRefiner/Sources/`. Key files:
- All `.swift` files under `TextRefiner/Sources/App/`, `TextRefiner/Sources/Core/`, `TextRefiner/Sources/UI/`
- `TextRefiner/build.sh` (shell script — check for injection, unsafe patterns)
- `TextRefiner/Resources/TextRefiner.entitlements`
- `TextRefiner/Resources/Info.plist` and `TextRefiner/Resources/Info-Dev.plist`
- `TextRefiner/Package.swift`
- `TextRefiner/Package.resolved`
- `.gitignore`

## After writing the report

Commit `SECURITY.md` with the message:
`chore: daily security audit YYYY-MM-DD`

If committing is not possible, write the file only — the report is still useful without a commit.
```
