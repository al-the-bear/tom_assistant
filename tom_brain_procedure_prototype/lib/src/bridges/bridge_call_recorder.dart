// BridgeCallRecorder — the seam that folds a bridged-primitive call into
// the run that issued it (Plan step C.32 wiring;
// `tom_brain_procedure_prototype_specification.md` § 8; review item E.3.2).
//
// A bridge ([MemoryBridge] / [SubstrateBridge]) dispatches a procedure's
// effect call to its client and then — when this hook is wired — reports
// the call so the run's `RunRecorder` can append it to the trail and fold
// its `EffortMetrics` delta into the run tally. The hook is `null` on the
// shared template bridges the engine is constructed with; the engine binds
// a per-run instance to the active recorder's `recordPrimitiveCall` for the
// duration of one run (`ProcedureEngine._runInternal`). Per-run binding is
// what makes the recording concurrency-safe: two runs that share the same
// underlying client each carry their own recorder, never a mutable observer
// shared across runs.
//
// The signature is exactly the prefix of `RunRecorder.recordPrimitiveCall`,
// so that method's tear-off is assignable here without an adapter.

/// Records one completed bridged-primitive call against the issuing run.
///
/// [primitive] is the bridge method name (`recall`, `llm`, `stackPush`, …)
/// — the same key the `EffortAccountant` classifies on. [input] is the
/// call's JSON-encodable argument map; [result] is its JSON-encodable
/// return map (`{'id': …}` for id-returning writes, `{'entries': […]}` for
/// list reads, the verbatim map for map-returning calls, `{}` for void
/// calls). [elapsedMs] is the measured wall-clock cost of the delegated
/// call when the bridge timed it.
typedef BridgeCallRecorder = Future<void> Function(
  String primitive,
  Map<String, Object?> input,
  Map<String, Object?> result, {
  int? elapsedMs,
});
