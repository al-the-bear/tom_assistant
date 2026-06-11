// ProcedureInvocation — the single, immutable request a caller hands to
// `ProcedureEngine.invoke` (Plan step C.38;
// `tom_brain_procedure_specification.md` § 10.1, § 5.3).
//
// The dispatcher (Phase D) is the production caller: it classifies an
// inbound request, selects a procedure id, and builds a
// `ProcedureInvocation` naming that procedure, its bound arguments, and
// (optionally) a pinned version. The engine resolves the id, runs the
// procedure on the sandboxed host, records the run, and hands back a
// `ProcedureRun` handle.
//
// ── Why arguments are a plain map, not a `ProcedureInputs` ───────────
//
// Two consumers need the bound values in two shapes: the procedure's
// `run` entry point wants the typed `ProcedureInputs` bag (§ 4.3), and
// the run recorder wants a plain `Map<String, Object?>` for the trail's
// `invocation` entry (§ 8). Carrying the raw map as the source of truth
// and deriving the typed bag ([inputs]) keeps the two in lock-step from
// one declaration — there is no way for the recorded arguments and the
// arguments the procedure actually receives to drift apart.

import 'package:tom_brain_shared/tom_brain_shared.dart' show TurnId;

import 'procedure_inputs.dart';

/// A request to run one procedure, addressed by id (and optional version).
///
/// Immutable: [arguments] is copied on construction, so a caller cannot
/// mutate the bound values after the invocation is built and the engine
/// cannot mutate the caller's map.
final class ProcedureInvocation {
  /// Builds an invocation for [procedureId] with [arguments].
  ///
  /// [version] pins a specific version; when `null` the resolver picks the
  /// latest. [parentRunId] links this run to the run that dispatched it
  /// (a nested `runProcedure`); `null` for a top-level invocation. [runId]
  /// pins the engine-assigned run id; when `null` the engine generates one.
  /// [turnId] is the access-edge-minted turn correlation id (logging-spec §3);
  /// the engine builds one [TurnContext] per turn from it and threads the
  /// `turnId` + per-turn `callSeq` onto every substrate call of the turn,
  /// including nested runs. `null` for an internal / free-time / dream
  /// invocation that runs outside a user turn. [memoryProfile] is the memory
  /// profile the request runs under (logging-spec §5.6); the engine threads it
  /// onto every memory access this turn issues so the per-profile memory log
  /// buckets correctly. `null` for a turn-less / process-default invocation.
  /// [sessionId] is the conversation session this invocation serves (access
  /// spec § 21.10); the engine binds the run's working todo list to the
  /// session's persistent store so the list survives from one prompt to the
  /// next within the conversation. `null` for a turn-less / internal / dream
  /// invocation that belongs to no user session — those get a fresh, run-scoped
  /// todo list as before.
  ProcedureInvocation({
    required this.procedureId,
    Map<String, Object?> arguments = const <String, Object?>{},
    this.version,
    this.parentRunId,
    this.runId,
    this.turnId,
    this.memoryProfile,
    this.sessionId,
  }) : arguments = Map<String, Object?>.unmodifiable(
          Map<String, Object?>.of(arguments),
        ) {
    if (procedureId.isEmpty) {
      throw ArgumentError.value(
        procedureId,
        'procedureId',
        'an invocation must name a procedure',
      );
    }
  }

  /// The target procedure id (e.g. `answer_with_memory_v1`).
  final String procedureId;

  /// The bound argument values, exactly as the trail records them.
  final Map<String, Object?> arguments;

  /// The pinned version, or `null` to resolve the latest.
  final int? version;

  /// The dispatching run's id when nested; `null` for a top-level run.
  final String? parentRunId;

  /// The pinned run id, or `null` to let the engine generate one.
  final String? runId;

  /// The turn this invocation serves (logging-spec §3), or `null` for an
  /// internal / free-time / dream invocation that runs outside a user turn.
  /// Minted at the access edge and threaded onto every substrate call of the
  /// turn via the engine's per-turn [TurnContext].
  final TurnId? turnId;

  /// The memory profile the request runs under (logging-spec §5.6), or `null`
  /// for a turn-less / process-default invocation. Threaded onto every memory
  /// access of the turn so the per-profile memory log buckets correctly.
  final String? memoryProfile;

  /// The conversation session this invocation serves (access spec § 21.10), or
  /// `null` for a turn-less / internal / dream invocation that belongs to no
  /// user session. The engine binds the run's `ToolContext.todos` to the
  /// session's persistent store, so the working todo list survives across the
  /// runs of one conversation; a `null` session id gets a fresh per-run store.
  final String? sessionId;

  /// The typed input bag the procedure's `run` entry point receives.
  ///
  /// Derived from [arguments] so the recorded invocation and the values the
  /// procedure sees are always the same set.
  ProcedureInputs get inputs => ProcedureInputs(arguments);

  @override
  String toString() {
    final target =
        version == null ? procedureId : '$procedureId (v$version)';
    return 'ProcedureInvocation($target, args: ${arguments.keys.join(', ')})';
  }
}
