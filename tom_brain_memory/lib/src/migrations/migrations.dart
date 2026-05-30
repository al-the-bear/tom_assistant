// Barrel for the `migrations/` module (Plan step A.23).
//
// Owns the long-running migration subsystem described in
// `memory_specification.md` § 11 — the mechanism for schema and
// node-type rollouts when there is too much data to migrate in a
// single transaction.
//
// Scope:
//
//   - Why long-running migrations exist (§ 11.1) — schema changes that
//     touch every node of a type cannot fit in a single transaction
//     window without locking out the brain.
//   - The mechanism (§ 11.2) — cursor-based, chunked, resumable; the
//     cursor lives in a `MigrationCursor` node persisted in
//     `memory.db`.
//   - Memory's contribution (§ 11.3) — the registry of pending
//     migrations and the cursor-advance API agents call from inside
//     sleep cycles.
//   - Non-completion is allowed (§ 11.4) — a migration that is still
//     running at shutdown resumes on the next boot from its cursor.
//
// Forward-only per hard invariant § 1.7 — "schema migrations and
// node-type rollouts run forward only."
//
// Wiring across later Phase A steps:
//
//   - A.80+ — MigrationCursor node + registry API.
//   - A.82+ — checkpoint file format under `<root>/checkpoints/`.
//   - A.84+ — sleep-cycle hooks for agent-driven cursor advancement.
//
// At A.23 this folder is intentionally empty. No exports yet.
