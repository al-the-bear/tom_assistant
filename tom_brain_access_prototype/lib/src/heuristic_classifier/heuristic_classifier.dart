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
// At E.8 this folder is intentionally empty. No exports yet.
