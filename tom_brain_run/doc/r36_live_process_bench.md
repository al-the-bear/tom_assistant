# Plan-2 #36 — Process-level latency bench (LIVE stack)

**Metric:** inbound-prompt → first-answer-chunk latency (streaming `POST /v1/chat/completions`; the buffered SSE first frame is the whole answer, so a sample is the full prompt→procedure→memory→oMLX→answer round-trip).

**Substrate:** real `OpenAiPassthroughProvider` → oMLX (`gemma-4-26b-a4b-it-4bit`) for chat, `OllamaEmbeddingService` for embeddings; **memory:** real on-disk isolate-hosted `SqliteTomBrainMemory`.

**Generated:** 2026-06-12T11:28:26.527923Z

| Metric | Value |
| --- | --- |
| samples | 8 |
| warm-up (discarded) | 1 |
| min | 2240.38 ms |
| p50 | 2700.88 ms |
| p95 | 5085.86 ms |
| max | 5085.86 ms |

## Comparison to the E.58 stub bench

E.58 (`tom_brain_smoke_prototype`) measures the *same* metric with the framework wired to an in-process stub substrate + a recording in-memory store, isolating the framework's own overhead at a p95 target of **250.00 ms**.

This live bench measures the identical edge over the real stack. The live latency is

> framework overhead (bounded by E.58, p95 ≤ 250.00 ms) + real oMLX token-generation latency.

The live p95 (5085.86 ms) is therefore expected to sit well above the E.58 stub target — the difference is the real-LLM generation cost, not a framework regression. The framework overhead component is unchanged from E.58 (same code path; only the substrate + store are real here).

