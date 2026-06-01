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
// Cancellation and an external timeout on the handle are C.39 — wired below
// through [cancel] and the engine-owned [RunCancellation]. The sugar aliases
// (`think`, `plan`, …) that resolve to `runProcedure('<name>_v1', …)` are
// C.40.

import 'package:tom_brain_memory/tom_brain_memory.dart' show TrailEntry;

import 'procedure_outcome.dart';
import 'run_cancellation.dart';

/// A running (or finished) procedure invocation.
///
/// Constructed by the engine; consumers read [trail] / [outcome] and may
/// [cancel] the run. The engine drives [trail] (one event per recorded trail
/// entry) and completes [outcome] when the run closes. The handle does not
/// own the run's resources — the engine does — it is the consumer-facing
/// view plus the cancel lever.
final class ProcedureRun {
  /// Builds a handle over a live [trail] stream, an [outcome] future, and the
  /// engine-owned [cancellation] control.
  ///
  /// The engine supplies all three; this type is a thin, immutable bundle.
  const ProcedureRun({
    required this.runId,
    required this.procedureId,
    required Stream<TrailEntry> trail,
    required Future<ProcedureOutcome> outcome,
    required RunCancellation cancellation,
  })  : _trail = trail,
        _outcome = outcome,
        _cancellation = cancellation;

  /// The engine-assigned run id.
  final String runId;

  /// The procedure this run is executing.
  final String procedureId;

  final Stream<TrailEntry> _trail;
  final Future<ProcedureOutcome> _outcome;
  final RunCancellation _cancellation;

  /// The live stream of trail entries this run writes, in order.
  ///
  /// A broadcast stream: subscribe before the run advances to observe every
  /// entry. The terminal trail is always also available on
  /// [ProcedureOutcome.entries] for consumers that only need the final view.
  Stream<TrailEntry> get trail => _trail;

  /// Resolves to the run's terminal outcome once it finishes.
  Future<ProcedureOutcome> get outcome => _outcome;

  /// Whether this run was cancelled or timed out before finishing on its own.
  bool get isCancelled => _cancellation.isSignalled;

  /// Cancels the run on the caller's behalf (cooperative abandonment).
  ///
  /// The engine stops waiting on the run's current step and closes it
  /// `aborted` with a `run_cancelled` trail note; the abandoned work may
  /// still finish in the background, its result dropped. Idempotent and a
  /// no-op once the run has already produced its [outcome].
  void cancel() => _cancellation.cancel();

  @override
  String toString() => 'ProcedureRun($procedureId/$runId)';
}
