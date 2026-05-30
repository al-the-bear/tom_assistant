// Barrel for the `classification/` module (Plan step A.23).
//
// Owns the LLM-independent classification path described in
// `memory_specification.md` § 7:
//
//   - Centroids (§ 7.1) — per-class mean embedding, maintained by
//     `dream_recentroid_v1`.
//   - The classification call (§ 7.2) — cosine to nearest centroid,
//     with explicit certainty bands (high / borderline / low).
//   - Centroid maintenance (§ 7.3) — incremental update + periodic
//     recompute.
//   - Batch LLM classification (§ 7.4) — opt-in, scheduled, budgeted,
//     and always procedure-initiated (hard invariant § 1.2 — "memory
//     does not call LLMs on the hot path").
//
// Wiring across later Phase A steps:
//
//   - A.65+ — Centroid node + ClassificationResult shape.
//   - A.67+ — classify() implementation against the centroid table.
//   - A.69+ — uncertainty-band query (`findUncertain`) for the batch
//             LLM path.
//
// At A.23 this folder is intentionally empty. No exports yet.
