// Barrel for the `trails/` module (Plan step A.23).
//
// Owns the JSONL run-trail subsystem described in
// `memory_specification.md` § 8. Trails are the canonical audit log of
// every run — thinking, planning, creation, procedure — and are the
// streaming input for `dream_extract_v1` (§ 9).
//
// Scope:
//
//   - Trail lifecycle (§ 8.1) — open, append, close, archive.
//   - Entry shape (§ 8.2) — structured JSONL records with strict ID,
//     ordering, and clock invariants.
//   - Trail consumption (§ 8.3) — cursor-based readers for cognitive
//     agents.
//   - Trail retention (§ 8.4) — demote, never delete (§ 1 / quest
//     overview hard principle 6 — "no event is ever truly lost").
//   - fsync discipline: JSONL line is durable before the `Trail` index
//     row in `memory.db` is written (§ 2.4).
//
// Wiring across later Phase A steps:
//
//   - A.70+ — Trail and TrailEntry record shapes, append API.
//   - A.72+ — date-sharded directory writer + fsync ordering.
//   - A.74+ — cursor-based reader for the cognitive-agent surface.
//
// At A.23 this folder is intentionally empty. No exports yet.
