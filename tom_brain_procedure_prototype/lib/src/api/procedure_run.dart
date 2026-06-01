// ProcedureRun — the handle `ProcedureEngine.invoke` returns (Plan step
// C.38; `tom_brain_procedure_prototype_specification.md` § 10.1).
//
// The plan's C.38 phrasing is exact: invoke "returns a `ProcedureRun`
// handle that streams trail entries and resolves to a `ProcedureOutcome`".
// This is that handle and nothing more — the two surfaces a caller drives
// a run through:
//
//   - [trail] — a live stream of every trail entry the run writes, in
//     order, as it writes them. The dispatcher subscribes to forward a
//     run's progress; a test subscribes to assert the unfolding order.
//   - [outcome] — a future that resolves to the run's [ProcedureOutcome]
//     once it finishes (success, truncation, or crash all resolve it;
//     the run never leaves a dangling future).
//
// Cancellation and an external timeout on the handle are the next step
// (C.39); the sugar aliases (`think`, `plan`, …) that resolve to
// `runProcedure('<name>_v1', …)` are C.40. C.38 ships only the handle.

import 'package:tom_brain_memory/tom_brain_memory.dart' show TrailEntry;

import 'procedure_outcome.dart';

/// A running (or finished) procedure invocation.
///
/// Constructed by the engine; consumers only read it. The engine drives
/// [trail] (one event per recorded trail entry) and completes [outcome]
/// when the run closes. The handle does not own the run's resources — the
/// engine does — it is purely the consumer-facing view.
final class ProcedureRun {
  /// Builds a handle over a live [trail] stream and an [outcome] future.
  ///
  /// The engine supplies both; this type is a thin, immutable bundle.
  const ProcedureRun({
    required this.runId,
    required this.procedureId,
    required Stream<TrailEntry> trail,
    required Future<ProcedureOutcome> outcome,
  })  : _trail = trail,
        _outcome = outcome;

  /// The engine-assigned run id.
  final String runId;

  /// The procedure this run is executing.
  final String procedureId;

  final Stream<TrailEntry> _trail;
  final Future<ProcedureOutcome> _outcome;

  /// The live stream of trail entries this run writes, in order.
  ///
  /// A broadcast stream: subscribe before the run advances to observe every
  /// entry. The terminal trail is always also available on
  /// [ProcedureOutcome.entries] for consumers that only need the final view.
  Stream<TrailEntry> get trail => _trail;

  /// Resolves to the run's terminal outcome once it finishes.
  Future<ProcedureOutcome> get outcome => _outcome;

  @override
  String toString() => 'ProcedureRun($procedureId/$runId)';
}
