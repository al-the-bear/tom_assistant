// Cheap kind-hint classifier (access-side).
//
// Owns the heuristic that, for each inbound prompt, embeds the text via
// substrate, calls memory's `classify(embedding,
// ClassificationTarget.procedure)`, and — on a `confident` decision —
// attaches the procedure id as `Access.envelope.kindHint` (else `null`,
// leaving the dispatcher to run `classify_inbound_v1`). Also owns the
// in-process recent-embedding cache (keyed by exact text, TTL 5 min) that
// saves an embed call on repeat prompts. See
// `tom_brain_access_prototype_specification.md` § Kind-hint classifier
// and Plan steps E.33 – E.35.
//
// E.33 ✅ — the three-step heuristic (`HeuristicKindHintClassifier` +
// the `KindHintEmbedder` / `KindHintClassifier` injected seams and the
// access-local `KindHintClassification` / `KindHintDecision` result mirror).
// Embed the inbound text → `classify(embedding,
// ClassificationTarget.procedure)` → attach the returned procedure id as
// `InboundRequest.kindHint` *only* on a `confident` decision (else null,
// leaving the dispatcher's `classify_inbound_v1` to take over, D.15). The
// classifier never routes (AC-9) and is allowed to be silent.
//
// E.34 ✅ — the in-process embedding cache (`EmbeddingCache`, § 9.2): keyed by
// *exact* inbound text, TTL 5 min. `EmbeddingCache.embed` is itself a
// `KindHintEmbedder`, so the cache composes *in front of* the substrate seam
// without touching `HeuristicKindHintClassifier`; a cache hit returns the
// stored embedding and saves the embed call (the E.50 smoke and E.55
// conformance assert the short-circuit).
//
// E.35 ✅ — the `## E.7` test sweep (`test/heuristic_classifier/
// e7_kind_hint_sweep_test.dart`): the formal acceptance sweep over the
// *integrated* surface (the classifier with its embed seam bound to the
// cache, as boot wires it). Locks the three plan-named outcomes — confident
// classification produces a kindHint; uncertain / unknown leaves it null; a
// cache hit avoids the embed call. Closes `## E.7`.

export 'embedding_cache.dart';
export 'heuristic_kind_hint_classifier.dart';
