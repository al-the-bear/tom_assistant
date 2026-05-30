// Barrel for the `stacks/` module (Plan step A.23).
//
// Owns the first-class stack subsystem described in
// `memory_specification.md` § 5 — Tom Brain's persistent, transactional,
// observable mind-state. Per hard invariant § 1.6: **stacks are first
// class**; the scheduler's view of "what to do next" is exactly the
// contents of the stacks.
//
// Scope:
//
//   - `StackApi` — push, pop, peek, drain, move, snapshot.
//   - Priority policies (§ 5.2 — FIFO, LIFO, priority, deadline).
//   - Retention policies (§ 5.3 — drop, archive, demote).
//   - Bootstrap stacks (§ 5.4 — `interests`, `open_questions`,
//     `dream_seeds`, `pending_classifications`, `pending_migrations`,
//     `procedure_authoring`).
//   - Harvester hooks (§ 5.5) for agent-driven stack mutations.
//
// Wiring across later Phase A steps:
//
//   - A.60+ — Stack and StackEntry node shapes, StackApi surface.
//   - A.62+ — transactional push/pop against `memory.db`.
//   - A.64+ — bootstrap-stack registration on `open()`.
//
// At A.23 this folder is intentionally empty. No exports yet.
