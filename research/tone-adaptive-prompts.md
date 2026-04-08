# Tone-Adaptive Prompt Engineering Research

*Date: 2026-04-07*

---

## 1. Tone Detection Approaches

### Can a 3B Model Reliably Detect Tone?

Yes, with caveats. Llama 3.2 3B Instruct scores 84.7 on NIH/Multi-needle instruction-following. Academic work (May 2025) tested it on text style transfer and found strong meaning preservation, competitive style transfer strength, and high grammatical acceptability (COLA ~0.95).

The model does pattern-matching on surface-level signals, not deep sociolinguistic analysis. For TextRefiner this is sufficient — it needs "is this casual or formal?" not an essay on register theory.

**Minimum text length for reliable detection**: ~20 words. Below this, tone detection is unreliable. Grammarly requires 150+ characters. For very short inputs, default to light-touch grammar fixes.

### Recommended Tone Categories (4, not 5)

1. **Casual** — Slack messages, texts, quick notes. Signals: contractions, slang, abbreviations ("u", "tmrw"), short sentences, emoji, lowercase starts.
2. **Professional** — Emails, LinkedIn, reports. Signals: complete sentences, formal vocabulary, hedging language, proper nouns.
3. **Technical** — Code comments, docs, bug reports. Signals: jargon, code-adjacent vocabulary, imperative mood, backticks, camelCase/snake_case.
4. **Creative** — Blog posts, essays, fiction. Signals: varied sentence length, figurative language, personal voice, intentional stylistic choices.

**Why not 5?** "Semi-formal" is a blurry spectrum a 3B model won't reliably distinguish. Better to have 4 clean categories.

**Mixed/ambiguous text**: Default to light-touch corrections, preserving author's voice. Safest failure mode.

### Single-Pass vs. Two-Pass?

**Strong recommendation: single-pass.** Two-pass classification doubles latency (~200-500ms overhead minimum). The 3B model handles structured instructions well enough for single-pass tone-adaptive refinement.

---

## 2. Prompt Architecture Options

### Option A — Single Unified Prompt
"Detect the tone and adapt accordingly."
- Pros: Simplest, one pass.
- Cons: Too vague for a 3B model. "Adapt accordingly" lacks concrete guidance.
- **Verdict: Too vague.**

### Option B — Classification + Branching (Two passes)
First classify tone, then use a tone-specific prompt.
- Pros: Each tone gets a tuned prompt. Easy to debug.
- Cons: **Doubles latency** — unacceptable for a hotkey tool. Classification errors cascade.
- **Verdict: Not recommended.**

### Option C — Few-Shot Examples
Single prompt with input/output pairs for each tone.
- Pros: Few-shot outperforms zero-shot for small models.
- Cons: Each example pair costs ~50-100 tokens. 4 tones = 200-400 extra tokens. Performance degradation starts at ~3,000 total tokens.
- **Verdict: Marginal.** Token cost concerning. Maybe 1-2 targeted examples as fallback.

### Option D — Conditional Instructions (RECOMMENDED)
Single prompt with explicit register-matching rules.
- Pros: One pass, explicit control, easy to tune per register.
- Cons: Longer prompt. Model might not follow IF/ELSE.
- **Key modification**: Use descriptive parallel rules, not literal IF/ELSE syntax. 3B models follow parallel rules more reliably than conditional logic.

### Recommended Approach

**Option D with inline register rules.** Instead of:
```
IF the text is casual THEN do X
```
Use:
```
- Casual text (slang, abbreviations, emoji): fix errors, keep the casual tone
- Professional text (formal vocabulary, complete sentences): elevate clarity
```

---

## 3. Prompt Efficiency for 3B 4-bit Models

### Optimal Prompt Length

- **Degradation begins at ~3,000 tokens** total context (prompt + input)
- **Focused prompts (~300 tokens) significantly outperform verbose ones**
- **"Lost in the middle" effect** — especially pronounced in small models. Put most important instructions at beginning and end.
- Current default prompt: ~80 tokens. Tone-adaptive version should target **150-200 tokens max**.

### Multi-Step Instructions

Llama 3.2 3B scores 63.4 on MMLU (5-shot) — moderate reasoning. Chain-of-thought is **not effective** at this size. Don't ask model to "first analyze, then rewrite" as separate steps. Provide clear parallel rules.

### Few-Shot Worth It?

**Probably not** for tone adaptation. Instruction-following approach is more token-efficient. Few-shot shines for unusual output formats or novel tasks — text refinement is well-represented in training data.

### Prompt Format

- **Markdown-style** (headers, bullets) recommended — token-efficient (15% savings vs XML), model heavily trained on markdown.
- XML tags overkill for non-nested structure.
- Chat template applied automatically by MLX tokenizer.

### Temperature

Consider **lowering from 0.7 to 0.5-0.6** — improves consistency of tone matching at slight cost to output variety.

---

## 4. Tone-Specific Refinement Rules

### Casual
- **Fix**: Obvious typos, missing apostrophes, run-on sentences that obscure meaning
- **Preserve**: Contractions, informal vocabulary, short sentences, emoji
- **Do NOT**: Add formal vocabulary, restructure to complex sentences, remove intentional slang
- **Edge case**: "u"/"tmrw" — fix only if rest of text uses standard spelling

### Professional
- **Fix**: Hedging ("I think maybe"), passive voice, wordiness, weak verbs
- **Elevate**: Sentence structure, transitions, vocabulary precision
- **Preserve**: Author's core argument and hierarchy
- **Do NOT**: Add jargon author didn't use, change the meaning

### Technical
- **Fix**: Clarity, conciseness, consistent terminology, ambiguous pronouns
- **Preserve**: Technical terms, code references, abbreviations (API, URL, TTL), imperative mood
- **Do NOT**: Expand standard abbreviations, add non-technical language

### Creative
- **Fix**: Only actual errors — typos, missing words, subject-verb agreement
- **Preserve**: Voice, rhythm, intentional rule-breaking, metaphors, fragments for effect
- **Do NOT**: Flatten varied sentence lengths, remove emphasis repetition
- **Hardest category** — safest approach is near-zero intervention

### How Competitors Handle This

- **Grammarly**: ML models trained on internal + public datasets, 40+ tone labels, analyzes word choice/phrasing/punctuation/capitalization
- **ProWritingAid**: Reference corpora per writing style (General, Academic, Business, Technical, Creative, Casual), suggestions relative to genre norms

Neither approach feasible for TextRefiner (no fine-tuned classifier, no corpus). Prompt-based approach is the right choice.

---

## 5. Evaluation Framework

### Test Corpus (15 examples)

**Casual:**
1. "hey can u check this tmrw? the deploy looks kinda broken lol"
2. "thanks for the update!! ill take a look when i get a chance :)"
3. "so basically the whole thing crashed and nobody knows why"

**Professional:**
4. "I would like to schedule a meeting to discuss the Q3 budget projections and align on the revised targets before the board presentation."
5. "Following up on our conversation yesterday, I wanted to confirm that the contract amendments have been reviewed by legal."
6. "Please find attached the updated project timeline. Let me know if you have any questions or concerns."

**Technical:**
7. "Returns the cached instance if TTL hasn't expired. Falls back to a fresh fetch otherwise. Thread-safe via NSLock."
8. "Bug: the onChange handler fires twice on mount because useEffect cleanup isn't running. Repro: toggle dark mode, check console."
9. "TODO: refactor this to use async/await instead of the completion handler chain. Current approach leaks closures on cancellation."

**Creative:**
10. "The morning light cut through the blinds like a verdict. She hadn't slept, and the coffee was already cold."
11. "There's something about empty parking lots at 2am that makes you feel like the last person on earth."

**Mixed/Edge Cases:**
12. "Hey team, just a heads up -- the API migration is done. Docs are at /wiki/api-v3. Lmk if anything breaks!" (casual + technical)
13. "Per our discussion, pls update the repo README w/ the new endpoints. thx" (formal intent + casual execution)
14. "Fixed the race condition in the auth flow. Basically the token refresh was competing with the logout handler and whoever won determined whether the user got a 401 or a clean redirect." (technical + casual)
15. "The implementation uses a priority queue to maintain O(log n) insertion time." (already correct)

### Evaluation Dimensions (1-5 each)

1. **Tone preservation** — Did the output match the register?
2. **Improvement quality** — Is the output objectively better?
3. **Meaning preservation** — Does it say the same thing?
4. **Naturalness** — Does it sound human-written?
5. **Minimal intervention** — Did the model avoid unnecessary changes?

### Automated vs. Human Evaluation

- **BLEU/ROUGE**: Not appropriate — no single correct output for refinement.
- **BERTScore**: Better (semantic similarity), can flag meaning-altering rewrites.
- **Human evaluation is essential.** Run all 15 cases through each prompt candidate, 5 reps each (225 total inferences, ~30-45 min on M1), compare side-by-side.

---

## 6. Edge Cases and Failure Modes

- **Code in text**: Preserve camelCase, snake_case, backticks, words with dots/slashes explicitly.
- **Non-English**: Llama 3.2 3B supports EN/DE/FR/IT/PT/HI/ES/TH. Others degrade. Current "rewrite in same language" instruction is correct.
- **Very short text (<20 words)**: Default to grammar-only. Tone detection unreliable.
- **Emoji, URLs, @mentions, hashtags**: Pass through unchanged. Prompt must explicitly list as preserve-as-is.
- **Already well-written text**: Model should return with minimal/no changes. Prompt reinforces this.

---

## 7. Candidate Prompts

### Candidate A — Minimal (~120 tokens) — START HERE

```
Rewrite the text between [TEXT_START] and [TEXT_END]. Output ONLY the rewritten result — nothing else.

Rules:
- Match the original tone. Casual text stays casual. Formal text stays formal.
- Casual text (slang, abbreviations, emoji): fix only errors, keep the casual voice.
- Professional text (full sentences, formal vocabulary): improve clarity, strengthen phrasing.
- Technical text (code terms, documentation style): fix clarity, preserve all technical terms and code.
- If already correct, return it unchanged.
- Preserve URLs, emoji, @mentions, hashtags, and code exactly as-is.
- Non-English: rewrite in the same language.

[TEXT_START]
{{USER_TEXT}}
[TEXT_END]

Refined text:
```

### Candidate B — Structured with register signals (~180 tokens)

```
You are a text refinement tool. Rewrite the text below. Output ONLY the refined text.

Detect the writing style and adapt:

Casual (contractions, slang, short sentences, emoji):
→ Fix grammar and typos. Keep the informal tone. Do not formalize.

Professional (complete sentences, formal words, no slang):
→ Improve clarity and structure. Remove hedging. Strengthen weak verbs.

Technical (code terms, APIs, documentation):
→ Fix clarity and conciseness. Preserve all code, variables, and technical terms exactly.

Creative (varied rhythm, figurative language, personal voice):
→ Fix only clear errors. Do not flatten the style.

Always preserve: URLs, emoji, @mentions, hashtags, code (camelCase, snake_case, backticks).
Already correct text: return with minimal changes.
Non-English: rewrite in the same language.

[TEXT_START]
{{USER_TEXT}}
[TEXT_END]

Refined text:
```

### Candidate C — Descriptive with negative examples (~220 tokens)

```
Rewrite the text between [TEXT_START] and [TEXT_END]. Output ONLY the refined text — no preamble, no quotes, no explanation.

Adapt your refinement to the text's register:

CASUAL (slang, abbreviations, emoji, lowercase):
Fix: typos, broken grammar, unclear meaning.
Keep: contractions, informal tone, short sentences, emoji.
Never: add formal vocabulary, restructure into long sentences, remove intentional abbreviations.

PROFESSIONAL (formal vocabulary, complete sentences):
Fix: hedging ("I think maybe"), passive voice, wordiness, weak verbs.
Keep: the author's argument and structure.
Never: add jargon the author didn't use, change the meaning.

TECHNICAL (code terms, APIs, docs, variable names):
Fix: clarity, conciseness, ambiguous pronouns.
Keep: all code references, technical terms, formatting.
Never: expand standard abbreviations (API, URL, TTL), add non-technical language.

CREATIVE (figurative language, varied rhythm, personal voice):
Fix: only actual errors (typos, missing words).
Keep: everything else — voice, rhythm, intentional fragments.

DEFAULT: When unsure, make only grammar and spelling fixes.

Preserve exactly: URLs, email addresses, emoji, @mentions, #hashtags, `code`, camelCase, snake_case.
Non-English text: rewrite in the same language.

[TEXT_START]
{{USER_TEXT}}
[TEXT_END]

Refined text:
```

### Recommendation

**Start with Candidate A.** Smallest delta from current working prompt, lowest risk. If tone matching is inconsistent, move to B. Only use C if explicit negative examples are needed to stop specific failure modes.

---

## Sources

- [Llama 3.2 Model Cards and Prompt Formats](https://www.llama.com/docs/model-cards-and-prompt-formats/llama3_2/)
- [Prompt Engineering for Small LLMs](https://maliknaik.medium.com/prompt-engineering-for-small-llms-llama-3b-qwen-4b-and-phi-3-mini-de711d38a002)
- [Llama Prompt Engineering Guides](https://www.llama.com/docs/how-to-guides/prompting/)
- [Steering LLMs with Register Analysis for Style Transfer](https://arxiv.org/html/2505.00679v1)
- [Lost in the Middle: How Language Models Use Long Contexts](https://arxiv.org/abs/2307.03172)
- [Effects of Prompt Length on LLM Performance](https://arxiv.org/html/2502.14255)
- [Context Rot: How Input Tokens Impact LLM Performance](https://research.trychroma.com/context-rot)
- [Conditional Prompts for LLMs](https://tilburg.ai/2024/07/become-a-prompt-engineer-conditional-prompt/)
- [Prompt Formatting Impact on LLM Performance](https://arxiv.org/html/2411.10541v1)
- [Grammarly Tone Detector](https://www.grammarly.com/blog/product/tone-detector/)
- [ProWritingAid Writing Styles](https://prowritingaid.com/art/1294/get-custom-writing-style-suggestions-with-prowritingaid.aspx)
- [A/B Testing for LLM Prompts](https://www.braintrust.dev/articles/ab-testing-llm-prompts)
- [RewriteLM: Instruction-Tuned LLM for Text Rewriting](https://arxiv.org/html/2305.15685v2)
- [Small Language Models in the Real World](https://arxiv.org/abs/2505.16078)
