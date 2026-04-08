# Performance Optimization Research — MLX Inference Speed

*Date: 2026-04-07*

---

## 1. Model Selection

### Current Model

`mlx-community/Llama-3.2-3B-Instruct-4bit` — ~20-30 tok/s on M1/8GB, ~1.5-2 GB RAM.

### Model Candidates (Ranked)

**Tier 1 — Strong Contenders for Replacement**

| Model | Params | Est. tok/s on M1 | RAM (4-bit) | Notes |
|---|---|---|---|---|
| **SmolLM3-3B** | 3B | ~25-40 | ~1.5 GB | HuggingFace's latest 3B with reasoning capability. Outperforms Llama-3.2-3B and Qwen2.5-3B across 12 benchmarks. Day-zero MLX support. |
| **Qwen3-4B-Instruct-4bit** | 4B | ~20-35 | ~2.5 GB | Newest generation. Strong instruction following. 100+ languages. |
| **Qwen3.5-4B-MLX-4bit** | 4B | ~20-30 | ~2.5 GB | Released March 2026. OptiQ mixed-precision variant also exists. |
| **Llama-3.2-3B-Instruct-4bit** (current) | 3B | ~25 | ~1.5 GB | Solid baseline. Well-tested. |

**Tier 2 — Speed-Optimized**

| Model | Params | Est. tok/s on M1 | RAM (4-bit) | Notes |
|---|---|---|---|---|
| **Qwen3-0.6B-4bit** | 0.6B | ~80-120 | ~0.5 GB | Extremely fast. Good for simple grammar fixes only. |
| **Llama-3.2-1B-Instruct-4bit** | 1B | ~50-70 | ~0.5 GB | Noticeably weaker than 3B on reasoning. |
| **Gemma 4 E2B** | 2.3B | ~40-60 | ~1-1.5 GB | MMLU Pro 60% — below 3B-class competitors. |

### Grammar-Correction-Specific Models

General-purpose instruction-tuned models (Qwen, Llama, Gemma) perform well on grammar tasks without specialized fine-tuning. Dedicated GEC models (Karen-strict/creative) are 7B+ and too large. At 1-3B scale, a well-prompted general instruction model is the best approach.

### Recommendation

**SmolLM3-3B** — same parameter count as current model (drop-in RAM replacement), outperforms it across benchmarks. Consider offering **Qwen3-4B** as a higher-quality option in Settings (~1 GB more RAM).

---

## 2. MLX Runtime Optimization

### 2.1 Model Pre-Loading

Current code keeps `modelContainer` as a persistent property — correct. But the model is only loaded on first inference (lazy). **Optimization: load at app launch or when the typing indicator first appears.**

### 2.2 Memory Cache Limit

Current: `Memory.cacheLimit = 20 * 1024 * 1024` (20 MB) — very conservative. **Raise to 128-256 MB** to allow MLX to keep more intermediate tensors cached. On 8GB systems, balance carefully.

### 2.3 System Prompt KV-Cache Pre-Computation (HIGHEST IMPACT)

MLX supports prompt caching via `mlx_lm.cache_prompt` — stores KV cache of a computed prompt prefix as `.safetensors`. In testing, this reduced response time from **~10s to 0.11s** for reusing a ~3000 token context.

For TextRefiner: the system prompt is identical across all refinements. Pre-computing its KV cache means only user text needs processing at inference time.

**Caveat:** Prefix caching only works for pure full-attention models. Models with sliding window attention (some Llama 3.2 layers) may silently fall back to full recomputation. Verify with chosen model before relying on this.

In Swift, create and retain a KV cache object across calls. WWDC 2025 Session 298 covers this pattern.

### 2.4 Quantization

- **4-bit is the sweet spot** — going below causes NaN errors on small models.
- **OptiQ / mixed-precision** (different bit widths per layer) is a promising middle ground.
- **8-bit** preserves quality but halves throughput — not worth it for 3B models.
- Stay at 4-bit. If quality concerns arise, try OptiQ before falling back to 8-bit.

### 2.5 Lazy Evaluation

MLX handles this automatically during generation. Do not call `eval()` prematurely on intermediate results — prevents operation fusion.

### 2.6 Memory Mapping

MLX uses lazy loading from file paths. First inference triggers actual weight loading. Keeping `modelContainer` alive avoids repeated load costs.

---

## 3. Architecture-Level Speed Improvements

### 3.1 Warm-Up on Typing Indicator (HIGH IMPACT — Recommended)

When `TypingMonitor` detects 7+ words, the user is likely to use the hotkey soon.

**What to do:**
1. Call `inferenceService.loadModel()` if not already loaded — ensures weights are memory-resident.
2. Run a **dummy inference** pass (single token) to force MLX to initialize GPU buffers and compile Metal shaders. First real inference on MLX is significantly slower due to lazy weight paging and kernel compilation.
3. Pre-compute the **system prompt KV cache** — tokenize and prefill the system prompt, store the KV pairs.

**Expected impact:** Eliminates 2-5 seconds of cold-start latency on first refinement after launch.

**Memory note:** Model consumes ~1.5-2 GB when loaded. Acceptable for a menu bar utility, but should unload under memory pressure (see 3.6).

### 3.2 Warm-Up on Text Selection (MEDIUM IMPACT)

When user selects text (detectable via `kAXSelectedTextChangedNotification`), they're likely about to press the hotkey.

**What to do:**
1. Same as 3.1 if not already done.
2. **Speculative prefill**: Read selected text via `kAXSelectedTextAttribute` (not Cmd+C — that's disruptive), tokenize, begin prefilling. If selection hasn't changed when hotkey fires, skip to generation.

**Challenges:**
- User might change selection, wasting prefill work.
- `kAXSelectedTextAttribute` isn't supported by all apps.
- Modest gain (~200-500ms for short texts).

**Recommendation:** Implement 3.1 first. Only add speculative prefill if benchmarks show prefill is a significant bottleneck.

### 3.3 Streaming Paste (NOT RECOMMENDED)

Researched three approaches:
1. Clipboard + Cmd+V per chunk — extremely disruptive (multiple undo entries, flickering)
2. AXUIElement value setting — not all apps support it, replaces entire field
3. CGEvent key simulation — slow, visibly types at model speed

**Verdict:** UX tradeoffs are severe. The wait-then-paste approach is cleaner. Reduce actual inference time instead.

### 3.4 System Prompt KV-Cache Persistence (HIGH IMPACT — Recommended)

Save the system prompt's KV cache to a `.safetensors` file on disk. On every refinement, load from file instead of recomputing.

In MLX Python:
```
mlx_lm.cache_prompt --model <model> --prompt "<system prompt>" --prompt-cache-file system_prompt_kv.safetensors
```

In Swift: Create KV cache object, run system prompt tokens through model, retain between calls. See WWDC 2025 Session 298.

**Performance gain:** Saves ~100-500ms per refinement for the system prompt prefill.

### 3.5 Speculative Decoding (FUTURE — v1.3+)

Use a 0.6B draft model to generate candidates, verify with the 3B model in parallel. Apple's MLX implementation achieves **up to 2.3x speedup**.

Adds complexity (two models in memory, coordination logic). The 0.6B model adds ~0.5 GB RAM. On 8GB M1, feasible (~2.5 GB total) but not a priority.

### 3.6 Memory Pressure Handling (IMPORTANT for M1/8GB)

1. **Monitor pressure:** `DispatchSource.makeMemoryPressureSource()` — on `.warning` consider unloading, on `.critical` definitely unload.
2. **GPU memory cap:** Set `MLX.GPU.set(memoryLimit:)` to 3-4 GB on 8GB systems.
3. **Lazy re-load:** If unloaded, re-load transparently on next hotkey (warm-up-on-indicator helps hide this).
4. **Bounded KV cache:** Current `maxTokens: 2048` already bounds this.
5. **Kernel panic prevention:** Known MLX issue (#883) — explicit memory limits prevent this.

---

## 4. Benchmarking

### Metrics to Measure

| Metric | Target for M1/8GB |
|---|---|
| Time to First Token (TTFT) | < 1 second (warm model + KV cache) |
| Generation throughput | > 20 tok/s |
| Total refinement latency (50 words) | < 3 seconds |
| Total refinement latency (200 words) | < 8 seconds |
| Peak memory footprint | < 3.5 GB |
| Cold-start latency | < 5 seconds |

### How to Measure

Instrument `RefinementCoordinator.startRefinement()` with timestamps:
- T0: hotkey fired
- T1: text copied from clipboard
- T2: first token received
- T3: last token received
- T4: paste complete

Use `CFAbsoluteTimeGetCurrent()` for sub-ms timing. Log in `#if DEBUG` builds.

### Realistic Latency Estimates (50-word refinement, M1/8GB)

| Phase | Cold | Warm (model + KV cached) |
|---|---|---|
| Copy text | ~500ms | ~500ms |
| Model load | ~3-5s | 0ms |
| System prompt prefill | ~200-500ms | 0ms (KV cached) |
| User text prefill | ~100-200ms | ~100-200ms |
| Generation (250 tokens @ 25 tok/s) | ~10s | ~10s |
| Post-processing + paste | ~200ms | ~200ms |
| **Total** | **~14-16s** | **~11s** |

With model upgrade (SmolLM3-3B) + warm-up: **~8-10s**. With speculative decoding: **~5-6s**.

---

## 5. Prioritized Optimization Roadmap

### Phase 1 — Quick Wins (v1.2)
1. Warm-up on typing indicator (load model + dummy inference + system prompt KV cache)
2. Raise `Memory.cacheLimit` to 128-256 MB
3. Add `DispatchSource.makeMemoryPressureSource()` for graceful unloading
4. Add timing instrumentation in debug builds

### Phase 2 — Model + KV Cache (v1.2 or v1.3)
5. Evaluate SmolLM3-3B and Qwen3-4B via `mlx_lm.benchmark`
6. Implement system prompt KV-cache persistence
7. Set explicit GPU memory limit (3-4 GB on 8GB systems)

### Phase 3 — Advanced (v1.3+)
8. Speculative decoding with a 0.6B draft model
9. Model selection in Settings (speed vs quality)
10. OptiQ mixed-precision quantization

---

## Sources

- [SiliconBench — Apple Silicon LLM Benchmarks](https://siliconbench.radicchio.page/)
- [Best Small Language Models (March 2026)](https://localaimaster.com/blog/small-language-models-guide-2026)
- [SmolLM3 overview](https://news.smol.ai/issues/25-07-08-smollm3/)
- [Best Open-Source Small Language Models 2026](https://www.bentoml.com/blog/the-best-open-source-small-language-models)
- [Local LLMs Apple Silicon Mac 2026](https://www.sitepoint.com/local-llms-apple-silicon-mac-2026/)
- [WWDC 2025 Session 298: Explore LLMs with MLX](https://developer.apple.com/videos/play/wwdc2025/298/)
- [WWDC 2025 Session 315: Get started with MLX](https://developer.apple.com/videos/play/wwdc2025/315/)
- [MLX Lazy Evaluation docs](https://ml-explore.github.io/mlx/build/html/usage/lazy_evaluation.html)
- [MLX Unified Memory docs](https://ml-explore.github.io/mlx/build/html/usage/unified_memory.html)
- [Prefix cache reuse issue (mlx-lm #980)](https://github.com/ml-explore/mlx-lm/issues/980)
- [MLX-LM kernel panic issue (#883)](https://github.com/ml-explore/mlx-lm/issues/883)
- [Apple MLX Recurrent Drafter research](https://machinelearning.apple.com/research/recurrent-drafter)
- [LM Studio 0.3.10: Speculative Decoding](https://lmstudio.ai/blog/lmstudio-v0.3.10)
- [MLX vs llama.cpp comparison](https://groundy.com/articles/mlx-vs-llamacpp-on-apple-silicon-which-runtime-to-use-for-local-llm-inference/)
