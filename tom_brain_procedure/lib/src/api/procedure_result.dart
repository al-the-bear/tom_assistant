// ProcedureResult — the typed, immutable result a procedure's `run`
// entry point returns (`tom_brain_procedure_specification.md`
// § 4.3, § 5.3).
//
// The spec: the runtime "invokes `run` with the parsed inputs and expects
// a `ProcedureResult`; anything else is `procedure.contract.violation`",
// and the shape is `ProcedureResult { Map<String,Object?> outputs;
// ProcedureStatus status; }`. Introduced at C.19 alongside
// `ProcedureInputs` because `runProcedure(...)` resolves to a
// `ProcedureResult`; the richer engine surface (`ProcedureEngine`, the run
// handle, the sugar aliases) lands at C.38–C.41.

import 'dart:collection';

/// The terminal status of a procedure run.
///
/// The prototype distinguishes only the two outcomes the depth-capped
/// `runProcedure` machinery needs to thread: a run that produced its
/// declared outputs ([succeeded]) and a run that did not ([failed]). The
/// finer typed failure classes the dispatcher's fallback chain keys on
/// (`procedure.contract.violation`, `procedure.critique.rejected`, …) are
/// modelled separately when the fallback executor lands (Phase D, D.29).
enum ProcedureStatus {
  /// The procedure produced its declared outputs and met its success
  /// criterion.
  succeeded,

  /// The procedure did not produce a usable result.
  failed,
}

/// The typed result of a procedure run.
///
/// Immutable: [outputs] is copied and wrapped on construction.
final class ProcedureResult {
  /// Builds a result with an explicit [status] and [outputs].
  ProcedureResult({
    required this.status,
    Map<String, Object?> outputs = const <String, Object?>{},
  }) : outputs = UnmodifiableMapView<String, Object?>(
          Map<String, Object?>.of(outputs),
        );

  /// A [ProcedureStatus.succeeded] result carrying [outputs].
  factory ProcedureResult.succeeded({
    Map<String, Object?> outputs = const <String, Object?>{},
  }) =>
      ProcedureResult(status: ProcedureStatus.succeeded, outputs: outputs);

  /// A [ProcedureStatus.failed] result carrying [outputs].
  factory ProcedureResult.failed({
    Map<String, Object?> outputs = const <String, Object?>{},
  }) =>
      ProcedureResult(status: ProcedureStatus.failed, outputs: outputs);

  /// The terminal status of the run.
  final ProcedureStatus status;

  /// The named outputs the procedure produced.
  final Map<String, Object?> outputs;

  /// Whether the run succeeded.
  bool get isSuccess => status == ProcedureStatus.succeeded;

  /// Returns output [name] as a [T], or `null` when absent / null / of the
  /// wrong type. Output reads are lenient by design: a caller inspecting a
  /// result it did not produce should get `null`, not an exception.
  T? output<T>(String name) {
    final value = outputs[name];
    return value is T ? value : null;
  }

  @override
  String toString() =>
      'ProcedureResult($status, outputs: ${outputs.keys.join(', ')})';
}
