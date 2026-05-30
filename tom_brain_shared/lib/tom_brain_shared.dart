/// Shared types and primitives used across all Tom Brain components.
///
/// This is the cross-component vocabulary for the Tom Brain quest. It carries
/// **no behaviour with side effects** — no I/O, no LLM calls, no storage. It
/// is allowed exactly one runtime dependency: `tom_basics`.
///
/// Modules are introduced in subsequent Phase-A steps (A.10 – A.17). At the
/// step A.7 scaffold this barrel is intentionally empty; consumers can still
/// import the package and rely on the dependency being resolvable.
///
/// See `_ai/quests/tom_brain/prototype_implementation_plan.md` § Phase A for
/// the surface that will be exported from this library.
library;

// Exports land here, one per module, as A.10 – A.17 ship.

// A.10 — ids/ module: ULID + NodeId/EdgeId/TrailId/StackEntryId/ProcedureId.
export 'src/ids/ids.dart';

// A.11 — embedding/ module: Vec (Float32List wrapper) + cosine / dot / l2.
export 'src/embedding/embedding.dart';
