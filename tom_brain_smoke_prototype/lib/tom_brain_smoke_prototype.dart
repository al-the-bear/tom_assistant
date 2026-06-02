/// End-to-end smoke harness for the Tom Brain prototype.
///
/// The higher assembly that boots a whole cognition (a stub substrate + an
/// in-isolate memory) and stands the access process up on a local port — the
/// one package that may legally wire `tom_brain_substrate`, `tom_brain_memory`,
/// `tom_brain_procedure_prototype`, and `tom_brain_access_prototype` together.
/// It fulfils the access package's `BrainProvisioner` seam, whose default
/// refuses because the access package cannot boot a brain on its own. See
/// Phase E.10 (steps E.46–E.50) of `prototype_implementation_plan.md`.
///
/// - E.46 ✅ — Stand-up smoke: [standUpSmokeProcess] boots the cognition with
///   [SmokeSubstrate] + in-isolate [SmokeMemory] and binds the OpenAI +
///   `/healthz` socket on a local port, returning a [SmokeProcess] handle.
library;

export 'src/smoke_brain.dart' show SmokeProcess, standUpSmokeProcess;
export 'src/smoke_memory.dart' show SmokeMemory, spawnSmokeMemory;
export 'src/smoke_substrate.dart' show SmokeSubstrate;
