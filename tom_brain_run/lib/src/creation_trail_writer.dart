// CreationTrailWriter — the creation-trail writer (UB5; `creation_specification.md`
// § 9.2 / § 9.3, § 12 "Creation-trail writer → tom_brain_run").
//
// The engine hands one [ProcedureTreeRecord] per top-level run to the
// `procedureTreeSink`; this writer is fanned out on that sink alongside the
// `ProcedureTreeWriter`. It projects a **`create_v1`** run's combined tree into
// the typed [CreationEvent] family (`tom_brain_shared`) and writes it as one
// `creation/<turnId>__<runId>.jsonl` file (bare `<runId>.jsonl` for a turn-less
// run) — one `event.toJson()` per line. Every other procedure id is ignored.
//
// This writer is the **first real consumer** that `creation_specification.md`
// § 12.1 decision 4 deferred the typed `CreationEvent` family to. Its very
// existence is UB5's done-when and the OT1 reopen trigger.
//
// Projection is driven by the **deliberate structured signals** the shipped
// `create_v1` procedure emits into the tree — never brittle role-name or path
// matching:
//
//   * `persist` primitives carry a structured `input.typeName` + `input.values`
//     + `result.id`. The `Question` persist yields [CreationRequested] (its
//     `text` values field carries the intent + success criterion, in
//     `create_v1`'s own `Create (<kind>): <intent>` / `Success criterion: …`
//     shape); the `Artifact` persist supplies the accepted [CreationAccepted]'s
//     `creationId`.
//   * The single pre-loop `recall` primitive is the § 4.2 environment observe →
//     [EnvironmentObserved].
//   * The `note('progress', …)` payloads are structured: the `stage:'test_first'`
//     note yields [TestDrafted] + [TestRun]; the final note (`iterations` /
//     `accepted` / `target`) yields [CreationAccepted] or [CreationRolledBack].
//   * A file-scope [ProcedureErrorNode] yields [ScopeViolation].
//
// The per-iteration events the spec also names (`DraftProduced`, `DraftWritten`,
// `PostObservationCaptured`, `SuccessChecked`, `CritiqueProduced`) require
// per-iteration structured notes the shipped `create_v1` body does not yet emit
// (a `ProcedureToolNode` carries only a capped `argSummary` string, so a write's
// path / a check's verdict cannot be recovered reliably). Enriching `create_v1`
// with that per-stage `note(…)` vocabulary is the UC follow-up; the typed family
// already carries the leaves, so that enrichment is purely additive.
//
// Best-effort and non-blocking (`tom_brain_logging.md` §9): the whole write is
// guarded — a trail-write failure must never fail a run.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        ProcedureErrorNode,
        ProcedureNoteNode,
        ProcedurePrimitiveNode,
        ProcedureTreeNode,
        ProcedureTreeRecord;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        CreationAccepted,
        CreationEvent,
        CreationRequested,
        CreationRolledBack,
        EnvironmentObserved,
        ScopeViolation,
        TestDrafted,
        TestRun;

/// The `create_v1` procedure id — the only run this writer projects.
const String _createProcedureId = 'create_v1';

/// Writes the creation trail for one `create_v1` run, one file per top-level
/// (or turn-less) run (`creation_specification.md` § 9.2).
final class CreationTrailWriter {
  /// The trail tree root (`trail.root`). Creation trails land under
  /// `<root>/creation/`.
  final Directory root;

  /// Builds a writer rooted at [root].
  CreationTrailWriter({required this.root});

  /// Projects [record] into the typed [CreationEvent] family and writes it to
  /// `creation/<turnId>__<runId>.jsonl` (bare `<runId>.jsonl` for a turn-less
  /// run). A record for any procedure other than `create_v1` is ignored.
  /// Best-effort: any failure is swallowed so a trail write never breaks the
  /// run (§9).
  void write(ProcedureTreeRecord record) {
    if (record.procedureId != _createProcedureId) {
      return;
    }
    try {
      final events = _project(record);
      if (events.isEmpty) {
        return;
      }
      final key = record.turnId != null
          ? '${record.turnId}__${record.runId}'
          : record.runId;
      final file = File('${root.path}/creation/$key.jsonl');
      final buffer = StringBuffer();
      for (final event in events) {
        buffer.writeln(jsonEncode(event.toJson()));
      }
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      file.writeAsStringSync(buffer.toString(), flush: true);
    } catch (_) {
      // Best-effort: a read-only root, a path collision, or a parent that
      // cannot be created must never propagate into the logging call site.
    }
  }

  /// Projects a `create_v1` [record] into the realised [CreationEvent] subset,
  /// in trail order. All events share the projection wall-clock timestamp and
  /// the run id; the JSONL line order carries the sequence.
  List<CreationEvent> _project(ProcedureTreeRecord record) {
    final now = DateTime.now().toUtc();
    final runId = record.runId;
    final events = <CreationEvent>[];

    // The `Question` persist supplies the request + the correlation id used on
    // every downstream event.
    final questionPersist = _firstPersistOfType(record.nodes, 'Question');
    final questionId = _idOf(questionPersist);
    final artifactPersist = _firstPersistOfType(record.nodes, 'Artifact');
    final creationId = _idOf(artifactPersist) ?? questionId;

    // CreationRequested is the canonical first event of a run (§ 4.1), emitted
    // ahead of the walk — the request logically precedes the § 4.2 observe even
    // though the Question persist trails the pre-loop `recall` in the raw trail.
    if (questionPersist != null) {
      final (:intent, :criterion) = _parseQuestion(_textValueOf(questionPersist));
      events.add(CreationRequested(
        occurredAt: now,
        intent: intent,
        successCriterion: criterion,
        creationId: questionId,
        runId: runId,
      ));
    }

    for (final node in record.nodes) {
      switch (node) {
        case ProcedurePrimitiveNode(:final primitive):
          if (primitive == 'recall') {
            events.add(EnvironmentObserved(
              occurredAt: now,
              targetCount: _resultNodeCount(node),
              creationId: questionId,
              runId: runId,
            ));
          }
        case ProcedureNoteNode(:final category, :final payload):
          if (category == 'progress' && payload['stage'] == 'test_first') {
            final testTarget = payload['testTarget'];
            events.add(TestDrafted(
              occurredAt: now,
              testTarget: testTarget is String ? testTarget : null,
              creationId: creationId,
              runId: runId,
            ));
            events.add(TestRun(
              occurredAt: now,
              failedOrSkipped: payload['failedOrSkipped'] == true,
              creationId: creationId,
              runId: runId,
            ));
          } else if (category == 'progress' &&
              payload.containsKey('accepted')) {
            events.add(_terminalEvent(now, runId, creationId, payload));
          }
        case ProcedureErrorNode(:final errorKind, :final message):
          if (_isScopeViolation(errorKind, message)) {
            events.add(ScopeViolation(
              occurredAt: now,
              creationId: creationId,
              runId: runId,
            ));
          }
        default:
        // Tool / subtree nodes carry no robustly-projectable creation signal
        // in the shipped `create_v1` body (see the file header); they are the
        // UC note-vocabulary follow-up's source.
      }
    }
    return events;
  }

  /// The final `note('progress', …)` maps to acceptance or rollback per its
  /// `accepted` flag (`create_v1` §§ 4.1 / 4.7). `iterations` is the loop's
  /// 1-based count; rollback reports it as the rolled-back iteration and flags
  /// the terminal best-effort incompletion.
  CreationEvent _terminalEvent(
    DateTime now,
    String runId,
    String? creationId,
    Map<String, Object?> payload,
  ) {
    final iterations = payload['iterations'];
    final iterationCount = iterations is int ? iterations : 0;
    final target = payload['target'];
    final targetText = target is String ? target : '';
    if (payload['accepted'] == true) {
      return CreationAccepted(
        occurredAt: now,
        target: targetText,
        iterations: iterationCount,
        creationId: creationId,
        runId: runId,
      );
    }
    return CreationRolledBack(
      occurredAt: now,
      iteration: iterationCount,
      incomplete: true,
      creationId: creationId,
      runId: runId,
    );
  }

  /// The first `persist` primitive whose `input.typeName` equals [typeName], or
  /// `null` when the run persisted no such node.
  ProcedurePrimitiveNode? _firstPersistOfType(
    List<ProcedureTreeNode> nodes,
    String typeName,
  ) {
    for (final node in nodes) {
      if (node is ProcedurePrimitiveNode &&
          node.primitive == 'persist' &&
          _typeNameOf(node) == typeName) {
        return node;
      }
    }
    return null;
  }

  /// The `input.typeName` of a `persist` primitive node, or `null`.
  String? _typeNameOf(ProcedurePrimitiveNode node) {
    final typeName = node.input['typeName'];
    return typeName is String ? typeName : null;
  }

  /// The persisted node id (`result.id`), non-empty; `null` for a skipped
  /// persist (empty-id sentinel) or a missing node.
  String? _idOf(ProcedurePrimitiveNode? node) {
    if (node == null) return null;
    final id = node.result['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  /// The `text` value a `Question` persist carried (`input.values.text`), or an
  /// empty string.
  String _textValueOf(ProcedurePrimitiveNode node) {
    final values = node.input['values'];
    if (values is Map) {
      final text = values['text'];
      if (text is String) return text;
    }
    return '';
  }

  /// The number of nodes a `recall` primitive returned (`result.nodes`), the
  /// § 4.2 observed-target count.
  int _resultNodeCount(ProcedurePrimitiveNode node) {
    final nodes = node.result['nodes'];
    return nodes is List ? nodes.length : 0;
  }

  /// Parses `create_v1`'s Question text — `Create (<kind>): <intent>` on the
  /// first line, `Success criterion: <criterion>` on the second — into its
  /// intent + criterion. Falls back to the whole text as the intent when the
  /// shape does not match (the writer and `create_v1` evolve together, so this
  /// is a defensive fallback, not a supported format drift).
  ({String intent, String criterion}) _parseQuestion(String text) {
    if (text.isEmpty) return (intent: '', criterion: '');
    final lines = text.split('\n');
    var intent = text.trim();
    var criterion = '';
    final firstColon = lines.first.indexOf('): ');
    if (firstColon >= 0) {
      intent = lines.first.substring(firstColon + 3).trim();
    }
    for (final line in lines.skip(1)) {
      const marker = 'Success criterion:';
      if (line.startsWith(marker)) {
        criterion = line.substring(marker.length).trim();
        break;
      }
    }
    return (intent: intent, criterion: criterion);
  }

  /// Whether an error node records a file-scope violation (§ 7 / § 10
  /// `error.scope_violation`) — matched on the typed error class or its message.
  bool _isScopeViolation(String errorKind, String message) {
    final haystack = '$errorKind $message'.toLowerCase();
    return haystack.contains('scope');
  }
}
