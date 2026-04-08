# Stats Dashboard & Privacy-Respecting Data Collection Research

*Date: 2026-04-07*

---

## 1. What to Track

### Per-Refinement Metrics (captured at refinement time)

- **Timestamp** (ISO 8601)
- **Character count before / after**
- **Word count before / after**
- **Sentence count before / after**
- **Refinement duration in milliseconds** — from `onProcessingStarted` to `onRefinementComplete`
- **Was cancelled** (boolean) — tracks abandonment rate
- **Input source app** (bundle ID) — `TypingMonitor` already knows the frontmost app

### Diff-Derived Metrics (computed once, stored as numbers)

- **Words added** (in after but not before)
- **Words removed** (in before but not after)
- **Words unchanged**
- **Similarity score** (Jaccard index: intersection / union of word sets, 0.0-1.0)
- **Net character delta** (after - before)

### Aggregate Metrics (computed on-the-fly from stored entries)

- Total lifetime refinements
- Total words refined / produced
- Average refinement duration
- Refinements today / this week / this month
- Average text length
- Most active hour of day (24-bucket histogram)
- Most active day of week

### Streak Tracking

- **Current streak**: consecutive calendar days with at least one refinement
- **Longest streak ever**: high-water mark
- **Last active date**: for detecting breaks
- **Streak freeze**: one free missed day (Duolingo-style)

### Comparable Tools Reference

- **Grammarly**: total words checked, productivity score, accuracy score, vocabulary richness, top tones, streak badges
- **Hemingway Editor**: readability grade, character/word/sentence/paragraph counts, reading time, complexity scores
- **iA Writer**: character, word, sentence, paragraph counts, reading time
- **Bear**: words, characters, paragraphs, read time

**Recommendation for TextRefiner**: Focus on volume (how much refined), change profile (compression ratio, similarity), and consistency (streaks). Skip readability scoring for now.

---

## 2. Privacy-Respecting Data Architecture

### Core Principle: Store Derived Metrics, Never Raw Text

The stats layer must **never** store original or refined text. Compute word counts, character counts, diff metrics, and similarity scores **in memory** immediately after refinement, write only numbers to disk.

### Store vs. Compute On-the-Fly

**Store per-entry**: timestamp, charsBefore/After, wordsBefore/After, durationMs, wordsAdded/Removed/Unchanged, similarityScore, wasCancelled, sourceApp.

**Compute on-the-fly**: totals, averages, streaks, histograms, daily/weekly/monthly breakdowns — aggregation queries over stored entries.

### Data Retention

**Accumulate forever.** Even 50 refinements/day for 5 years = ~91,000 entries at ~200 bytes each = ~18 MB. Trivially small. Add a "Clear Stats" button in Settings for users who want a fresh start.

### Privacy Patterns from Research

- Zero network calls for analytics (already the case)
- All stats stored locally, never leave the device
- No opt-in/opt-out needed — nothing to opt out of
- Clear disclosure: "Your stats are stored locally on your Mac. Nothing is sent anywhere."
- User has full control: export (JSON), clear, or delete

### JSON vs. JSONL vs. SQLite

**JSON file** (current pattern for history.json, prompts.json):
- Pros: Consistent with codebase, human-readable
- Cons: Must read/write entire file every operation, no indexing

**JSONL (newline-delimited JSON)** — recommended:
- Pros: Append-only (`FileHandle.seekToEndOfFile()` + write), can stream-parse line by line, no full re-serialize
- Cons: No indexing, aggregation is O(n)

**SQLite via GRDB.swift**:
- Pros: Efficient queries (SUM, AVG, GROUP BY), indexing, ACID transactions
- Cons: Adds SPM dependency, overkill at this data volume

**Recommendation**: **JSONL** (`stats.jsonl`). Consistent with existing patterns, append-friendly, no dependency. Migrate to SQLite later if needed.

File location: `~/Library/Application Support/TextRefiner/stats.jsonl`

---

## 3. Diff Engine

### Algorithm

**Swift stdlib `CollectionDifference`** (available since Swift 5.1) — implements Myers diff algorithm (same as `git diff`). No third-party library needed.

### Why Word-Level

- **Character level**: Too granular — single word change produces many edits. Noisy.
- **Sentence level**: Too coarse — sentence boundaries ambiguous in informal text.
- **Word level**: Right granularity. "Fixed 3 words, added 2, removed 1" is meaningful.

### Implementation Approach

```swift
func computeDiffStats(before: String, after: String) -> DiffStats {
    let beforeWords = before.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let afterWords = after.split(whereSeparator: { $0.isWhitespace }).map(String.init)

    let diff = afterWords.difference(from: beforeWords)

    var removals = 0
    var insertions = 0
    for change in diff {
        switch change {
        case .remove: removals += 1
        case .insert: insertions += 1
        }
    }

    let unchanged = beforeWords.count - removals

    // Jaccard similarity
    let beforeSet = Set(beforeWords.map { $0.lowercased() })
    let afterSet = Set(afterWords.map { $0.lowercased() })
    let intersection = beforeSet.intersection(afterSet).count
    let union = beforeSet.union(afterSet).count
    let similarity = union > 0 ? Double(intersection) / Double(union) : 1.0

    return DiffStats(
        wordsAdded: insertions,
        wordsRemoved: removals,
        wordsUnchanged: unchanged,
        similarityScore: similarity
    )
}
```

### Performance

For 100-500 words with small D (minor corrections), Myers completes in microseconds. Even at 10,000-char cap (~2,000 words), well under 1ms. Runs once per refinement, after paste — no user-visible latency.

### Similarity Score

**Jaccard index** — simple, intuitive 0.0-1.0, no NLP libraries. Near 1.0 = barely changed, near 0.0 = almost completely rewritten.

---

## 4. Stats Dashboard UI

### Window Type

Separate `NSWindow`, accessible from "Stats..." menu item. Consistent with existing "History..." and "Prompt Settings..." patterns. Not part of Settings (that's for configuration, not data display).

### Layout

**Top section**: Big hero numbers in a horizontal row
- Total refinements (e.g., "247")
- Total words refined (e.g., "38.2K")
- Current streak (e.g., "12 days")

**Middle section**: Sparkline charts
- Refinements per day (last 30 days)
- Average text length over time

**Bottom section**: Two-column detail grid
- Average refinement time
- Average similarity score
- Most active hour
- Longest streak
- Words added/removed totals

### Charting Options (Recommended)

1. **DSFSparkline** (SPM package) — lightweight, macOS-native, supports line/bar/dot sparklines. One dependency.
2. **Custom NSView + Core Graphics** — for hero number displays and simple visualizations. Zero dependency.
3. SwiftUI Charts via `NSHostingView` — most powerful but introduces SwiftUI dependency into pure AppKit app.

**Recommendation**: DSFSparkline for sparklines + Core Graphics for hero numbers.

### Window Size

~480x520 points, consistent with History window (520x440).

---

## 5. Gamification

### Philosophy: Subtle Delight, Not a Game

TextRefiner is a productivity tool. Gamification should feel like gentle encouragement. Research from Trophy and Duolingo's design shows: **reward consistency, not volume**.

### Tier 1 — Streaks (implement first)

- Daily streak counter with subtle flame icon in stats window
- **Streak freeze**: 1 free missed day — reduces anxiety, prevents "already broke it" drop-off
- No notifications for streaks. Visible in Stats window and optionally menu bar tooltip.

### Tier 2 — Milestones (implement later)

- Markers at: 10, 50, 100, 250, 500, 1000 refinements
- Brief one-time HUD notification (3 seconds) using existing `StreamingPanelController` pattern
- Messages should be specific:
  - 10: "10 texts refined. You're getting the hang of it."
  - 100: "100 refinements. Your writing is consistently polished."
  - 1000: "1,000 refinements. TextRefiner power user."

### What to Avoid

- No XP/level system — overkill, feels forced in productivity tools
- No leaderboards (local-only, no server)
- No push notifications ("you haven't refined today!")
- No badge collections (UI bloat)
- No social sharing

---

## 6. Data Schema

### stats.jsonl — Per-refinement entry

```json
{
  "v": 1,
  "ts": "2026-04-07T14:32:05Z",
  "charsBefore": 342,
  "charsAfter": 298,
  "wordsBefore": 58,
  "wordsAfter": 51,
  "sentsBefore": 4,
  "sentsAfter": 4,
  "durationMs": 2340,
  "wordsAdded": 3,
  "wordsRemoved": 10,
  "wordsUnchanged": 48,
  "similarity": 0.84,
  "cancelled": false,
  "sourceApp": "com.google.Chrome"
}
```

| Field | Type | Description |
|---|---|---|
| `v` | int | Schema version (start at 1) — forward compatibility |
| `ts` | string | ISO 8601 timestamp |
| `charsBefore/After` | int | Character counts |
| `wordsBefore/After` | int | Word counts |
| `sentsBefore/After` | int | Sentence counts |
| `durationMs` | int | Hotkey-to-text-ready (not including paste) |
| `wordsAdded/Removed/Unchanged` | int | From diff |
| `similarity` | float | Jaccard score, 0.0-1.0 |
| `cancelled` | bool | User pressed Escape |
| `sourceApp` | string | Bundle ID of frontmost app |

**NOT stored**: original text, refined text, any user-identifiable information.

### stats-summary.json — Aggregate cache

```json
{
  "totalRefinements": 247,
  "totalWordsBefore": 38200,
  "totalWordsAfter": 34800,
  "currentStreak": 12,
  "longestStreak": 23,
  "lastActiveDate": "2026-04-07",
  "streakFreezeUsed": false,
  "milestonesShown": [10, 50, 100]
}
```

Updated after every refinement. Fully reconstructable from `stats.jsonl` if deleted/corrupted.

### Integration Point

In `RefinementCoordinator.startRefinement()`:
- Capture `Date()` before inference starts
- After `cleanResponse()` returns, compute diff stats and duration
- Append entry to `stats.jsonl`
- Update `stats-summary.json`
- Cancelled refinements: record with `cancelled: true`, no diff stats

### SQLite Alternative (if migrating later)

```sql
CREATE TABLE refinements (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    schema_version INTEGER NOT NULL DEFAULT 1,
    timestamp TEXT NOT NULL,
    chars_before INTEGER NOT NULL,
    chars_after INTEGER NOT NULL,
    words_before INTEGER NOT NULL,
    words_after INTEGER NOT NULL,
    sents_before INTEGER NOT NULL,
    sents_after INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    words_added INTEGER NOT NULL,
    words_removed INTEGER NOT NULL,
    words_unchanged INTEGER NOT NULL,
    similarity REAL NOT NULL,
    cancelled INTEGER NOT NULL DEFAULT 0,
    source_app TEXT
);
CREATE INDEX idx_timestamp ON refinements(timestamp);
```

Uses GRDB.swift (SPM). Makes aggregation trivial but adds a dependency.

---

## Sources

- [Grammarly Weekly Insights](https://support.grammarly.com/hc/en-us/articles/115000090892)
- [Grammarly Writing Progress Dashboard](https://support.grammarly.com/hc/en-us/articles/21940617172877)
- [Hemingway Readability](https://hemingwayapp.com/help/docs/readability)
- [iA Writer Stats](https://ia.net/writer/support/editor/stats)
- [Apple CollectionDifference docs](https://developer.apple.com/documentation/swift/collectiondifference)
- [How Collection Diffing Works in Swift](https://swiftrocks.com/how-collection-diffing-works-internally-in-swift)
- [Jaccard Similarity in NLP](https://studymachinelearning.com/jaccard-similarity-text-similarity-metric-in-nlp/)
- [DSFSparkline](https://github.com/dagronf/DSFSparkline)
- [GRDB.swift](https://github.com/groue/GRDB.swift)
- [Stats macOS monitor](https://github.com/exelban/stats)
- [Trophy — Gamification in Productivity Apps](https://trophy.so/blog/productivity-app-gamification-doesnt-backfire)
- [Duolingo Streak System Breakdown](https://medium.com/@salamprem49/duolingo-streak-system-detailed-breakdown-design-flow-886f591c953f)
- [AnythingLLM Privacy](https://docs.anythingllm.com/installation-desktop/privacy)
- [JSON Lines format](https://jsonlines.org/)
