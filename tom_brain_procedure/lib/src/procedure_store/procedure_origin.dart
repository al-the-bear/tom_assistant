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
//   - `bundle` — a shipped `scripts/system/` procedure compiled into the
//     executable's procedure *bundle* (CLI plan step 3). The standalone
//     `tom_brain` CLI carries its safety-net procedures with no on-disk
//     `scripts/` tree; a writable disk `scripts/` overlays the bundle by
//     procedure id. The bundle backend is read-only by construction.

/// Provenance of a procedure reference, and the discriminator the store
/// routes reads on.
///
/// `system` and `user` are the two disk-backed origins; `brain` is the
/// memory-backed origin; `bundle` is the compiled-in bundle origin. A
/// [ProcedureStore] backend declares which origins it serves through
/// `handles`.
enum ProcedureOrigin {
  /// Shipped, well-known procedure on disk (`scripts/system/`).
  system,

  /// User-authored procedure on disk (`scripts/user/`).
  user,

  /// Brain-authored procedure stored as a `Procedure` node in memory.
  brain,

  /// Shipped procedure compiled into the executable's procedure bundle
  /// (CLI plan step 3). Read-only — authored procedures cannot land here.
  bundle;

  /// Whether this origin is served by the disk backend
  /// ([ProcedureOrigin.system] or [ProcedureOrigin.user]).
  bool get isDisk => this == ProcedureOrigin.system || this == ProcedureOrigin.user;

  /// Whether this origin is served by the memory backend
  /// ([ProcedureOrigin.brain]).
  bool get isMemory => this == ProcedureOrigin.brain;

  /// Whether this origin is served by the compiled-in bundle backend
  /// ([ProcedureOrigin.bundle]).
  bool get isBundle => this == ProcedureOrigin.bundle;
}
