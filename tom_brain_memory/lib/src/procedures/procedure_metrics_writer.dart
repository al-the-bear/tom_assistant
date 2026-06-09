// ProcedureMetricsWriter — the single in-place write for a Procedure node's
// derived metric/status cache (`procedure_specification.md` § 6.4, § 7.1,
// G-PR5).
//
// A Procedure node carries four fields that are *not* fixed at authoring time:
// the rolling `successRate`, the `runCount`, the `lastRunAt`, and the
// `active ⇄ preferred` stage. The metrics pass (`dream_procedure_metrics_v1`,
// run in the Synthesizer sleep cadence) recomputes them from the immutable
// `ProcedureRun` history and writes the result back here.
//
// Why this is sound under hard principle 6 (no event ever lost): the authoritative
// record is the ProcedureRun history, which this never touches and from which the
// cache is always recomputable. The Procedure node's metric fields are a derived
// cache, and procedural memory is the explicitly-mutable layer — episodic memory
// (the immutable one) is untouched. The write refuses any node that is not a
// `Procedure`, so it cannot be turned against an immutable Claim/Event node.
//
// Why no `Scope`: like `NodeLifecycleManager.demote`, this mutates a cached
// lifecycle field rather than writing a graph node/edge, so it carries no agent
// scope (mirroring the existing lifecycle-write convention). `demoted` is reached
// through `demote`; this write only moves `active ⇄ preferred` and the counters.

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeId, ProcedureStatus;

/// Writes the derived metric/status cache of a `Procedure` node in place.
final class ProcedureMetricsWriter {
  final Database _db;
  final DateTime Function() _now;

  /// Constructs the writer around an already-opened, already-migrated
  /// `memory.db` handle. [now] is injectable for deterministic tests.
  ProcedureMetricsWriter({
    required Database memoryDb,
    DateTime Function()? now,
  })  : _db = memoryDb,
        _now = now ?? DateTime.now;

  /// The node type this writer is allowed to mutate. Hoisted to a constant so
  /// the guard and the eventual registry-driven validator share one source.
  static const String _procedureTypeName = 'Procedure';

  /// Merges the supplied cached metric/status fields into the `Procedure` node
  /// [id], leaving every other field untouched.
  ///
  /// Only the non-null arguments are written — a caller that recomputes the
  /// counters but does not change the stage passes `status: null` and the
  /// stored stage survives. [successRate] is stored as a JSON double in [0,1];
  /// [lastRunAt] as an ISO-8601 UTC string (matching `ProcedureRun`).
  ///
  /// Contract:
  ///   * A write against a missing id is a no-op (a concurrent forget is not a
  ///     failure), mirroring [demote].
  ///   * A write against a node that is not a `Procedure` throws
  ///     [ArgumentError] — the type guard is the immutability protection.
  ///   * When every argument is null there is nothing to write; the call still
  ///     validates the id/type but performs no UPDATE.
  Future<void> updateProcedureMetrics(
    NodeId id, {
    ProcedureStatus? status,
    double? successRate,
    int? runCount,
    DateTime? lastRunAt,
  }) async {
    final idStr = id.toString();
    final rows = _db.select(
      'SELECT type_name, attrs_json FROM nodes WHERE id = ? LIMIT 1',
      <Object?>[idStr],
    );
    if (rows.isEmpty) return; // No-op on a missing/forgotten id.

    final typeName = rows.first['type_name'] as String;
    if (typeName != _procedureTypeName) {
      throw ArgumentError.value(
        typeName,
        'node.typeName',
        'updateProcedureMetrics refuses a non-"$_procedureTypeName" node '
            '($idStr) — the metric cache write is Procedure-only so it cannot '
            'mutate immutable nodes',
      );
    }

    // Nothing to merge — the type/id were still validated above.
    if (status == null &&
        successRate == null &&
        runCount == null &&
        lastRunAt == null) {
      return;
    }

    final decoded = jsonDecode(rows.first['attrs_json'] as String);
    final values = <String, Object?>{
      ...(decoded as Map).cast<String, Object?>(),
    };
    if (status != null) values['status'] = status.token;
    if (successRate != null) values['successRate'] = successRate;
    if (runCount != null) values['runCount'] = runCount;
    if (lastRunAt != null) {
      values['lastRunAt'] = lastRunAt.toUtc().toIso8601String();
    }

    final now = _now().toUtc();
    _db.execute(
      'UPDATE nodes SET attrs_json = ?, updated_at_ms = ?, updated_at_iso = ? '
      'WHERE id = ?',
      <Object?>[
        jsonEncode(values),
        now.millisecondsSinceEpoch,
        now.toIso8601String(),
        idStr,
      ],
    );
  }
}
