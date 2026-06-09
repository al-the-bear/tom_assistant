// ProcedureOrigin — where a procedure's source comes from (Plan step
// C.23; `tom_brain_procedure_specification.md` § 9).
//
// The store has two backends behind one interface; `ProcedureOrigin`
// is the discriminator that tells them apart and tells a consumer which
// provenance a reference carries:
//
//   - `system` — a shipped, well-known procedure on disk under
//     `scripts/system/`. The permanent safety net (`answer_with_memory_v1`
//     ships here; PE-6) and never demoted.
//   - `user`   — a user-authored procedure on disk under `scripts/user/`.
//   - `brain`  — a brain-authored procedure stored as a `Procedure`
//     node in memory (`procedure_specification.md` § 7.1), loaded via
//     the memory client at call time.

/// Provenance of a procedure reference, and the discriminator the store
/// routes reads on.
///
/// `system` and `user` are the two disk-backed origins; `brain` is the
/// memory-backed origin. A [ProcedureStore] backend declares which
/// origins it serves through `handles`.
enum ProcedureOrigin {
  /// Shipped, well-known procedure on disk (`scripts/system/`).
  system,

  /// User-authored procedure on disk (`scripts/user/`).
  user,

  /// Brain-authored procedure stored as a `Procedure` node in memory.
  brain;

  /// Whether this origin is served by the disk backend
  /// ([ProcedureOrigin.system] or [ProcedureOrigin.user]).
  bool get isDisk => this == ProcedureOrigin.system || this == ProcedureOrigin.user;

  /// Whether this origin is served by the memory backend
  /// ([ProcedureOrigin.brain]).
  bool get isMemory => this == ProcedureOrigin.brain;
}
