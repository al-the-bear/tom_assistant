// CreationTrailWriter — the creation-trail writer (UB5;
// `creation_specification.md` § 9.2 / § 12).
//
// A `create_v1` [ProcedureTreeRecord] projects into the typed [CreationEvent]
// family and writes as one `creation/<turnId>__<runId>.jsonl` file (one
// `event.toJson()` per line). A record for any other procedure is a no-op.
//
// Pins: procedure-id guard; the accepted and the rolled-back terminal shapes;
// the Question-persist → CreationRequested projection (intent + criterion parse,
// correlation id); the test_first note → TestDrafted + TestRun; the recall →
// EnvironmentObserved; the scope-violation error → ScopeViolation; the turn-less
// key.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_memory/tom_brain_memory.dart' show TrailOutcomeStatus;
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('creation_trail_writer_test_');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  ProcedurePrimitiveNode recallNode({int returned = 3}) =>
      ProcedurePrimitiveNode(
        primitive: 'recall',
        input: <String, Object?>{
          'modes': <String>['bm25', 'vector'],
          'k': 8,
        },
        result: <String, Object?>{
          'nodes': List<Object?>.filled(returned, <String, Object?>{}),
        },
      );

  ProcedurePrimitiveNode persistNode(
    String typeName, {
    required String id,
    Map<String, Object?> values = const <String, Object?>{},
  }) =>
      ProcedurePrimitiveNode(
        primitive: 'persist',
        input: <String, Object?>{'typeName': typeName, 'values': values},
        result: <String, Object?>{'id': id},
      );

  ProcedureNoteNode finalNote({
    required bool accepted,
    required int iterations,
    String target = 'lib/exporter.dart',
  }) =>
      ProcedureNoteNode(
        category: 'progress',
        payload: <String, Object?>{
          'procedure': 'create_v1',
          'iterations': iterations,
          'accepted': accepted,
          'target': target,
        },
      );

  ProcedureTreeRecord recordOf(
    List<ProcedureTreeNode> nodes, {
    String procedureId = 'create_v1',
    String runId = 'disp-fg-run-7',
    String? turnId = 'turn_01JZ',
    TrailOutcomeStatus status = TrailOutcomeStatus.accepted,
  }) =>
      ProcedureTreeRecord(
        procedureId: procedureId,
        version: 1,
        runId: runId,
        parentRunId: null,
        turnId: turnId,
        depth: 1,
        status: status,
        elapsedMs: 1400,
        entryCount: nodes.length + 1,
        nodes: nodes,
      );

  List<Map<String, Object?>> readEvents(String key) {
    final file = File('${tempRoot.path}/creation/$key.jsonl');
    if (!file.existsSync()) return const <Map<String, Object?>>[];
    return file
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .toList();
  }

  test('ignores a non-create_v1 run — no file written', () {
    final writer = CreationTrailWriter(root: tempRoot);
    writer.write(recordOf(
      <ProcedureTreeNode>[recallNode()],
      procedureId: 'answer_with_memory_v1',
    ));
    expect(Directory('${tempRoot.path}/creation').existsSync(), isFalse);
  });

  test('projects an accepted creation into the realised event subset', () {
    final writer = CreationTrailWriter(root: tempRoot);
    writer.write(recordOf(<ProcedureTreeNode>[
      recallNode(returned: 4),
      persistNode('Question',
          id: 'QN-1',
          values: <String, Object?>{
            'text': 'Create (code): a CSV exporter\n'
                'Success criterion: golden test passes',
          }),
      ProcedureNoteNode(
        category: 'progress',
        payload: const <String, Object?>{
          'procedure': 'create_v1',
          'stage': 'test_first',
          'testTarget': 'test/exporter_test.dart',
          'failedOrSkipped': true,
        },
      ),
      finalNote(accepted: true, iterations: 2),
      persistNode('Artifact', id: 'ART-9'),
    ]));

    final events = readEvents('turn_01JZ__disp-fg-run-7');
    expect(events.map((e) => e['kind']).toList(), <String>[
      'creation.requested',
      'creation.environment-observed',
      'creation.test-drafted',
      'creation.test-run',
      'creation.accepted',
    ]);

    final requested = events.first;
    expect((requested['payload'] as Map)['intent'], 'a CSV exporter');
    expect(
        (requested['payload'] as Map)['successCriterion'], 'golden test passes');
    expect((requested['payload'] as Map)['creationId'], 'QN-1');
    expect(requested['runId'], 'disp-fg-run-7');

    final observed = events[1];
    expect((observed['payload'] as Map)['targetCount'], 4);

    final testRun = events[3];
    expect((testRun['payload'] as Map)['failedOrSkipped'], isTrue);

    final accepted = events[4];
    expect((accepted['payload'] as Map)['target'], 'lib/exporter.dart');
    expect((accepted['payload'] as Map)['iterations'], 2);
    // The Artifact id wins as the correlation handle once it exists.
    expect((accepted['payload'] as Map)['creationId'], 'ART-9');
  });

  test('projects an exhausted creation into a rolled-back terminal', () {
    final writer = CreationTrailWriter(root: tempRoot);
    writer.write(recordOf(<ProcedureTreeNode>[
      recallNode(),
      persistNode('Question',
          id: 'QN-2',
          values: <String, Object?>{
            'text': 'Create (code): a thing\nSuccess criterion: it compiles',
          }),
      finalNote(accepted: false, iterations: 3),
    ]));

    final events = readEvents('turn_01JZ__disp-fg-run-7');
    expect(events.map((e) => e['kind']).toList(), <String>[
      'creation.requested',
      'creation.environment-observed',
      'creation.rolled-back',
    ]);
    final rolledBack = events.last;
    expect((rolledBack['payload'] as Map)['iteration'], 3);
    expect((rolledBack['payload'] as Map)['incomplete'], isTrue);
  });

  test('emits a ScopeViolation from a file-scope error node', () {
    final writer = CreationTrailWriter(root: tempRoot);
    writer.write(recordOf(
      <ProcedureTreeNode>[
        persistNode('Question',
            id: 'QN-3',
            values: const <String, Object?>{
              'text': 'Create (code): x\nSuccess criterion: y',
            }),
        const ProcedureErrorNode(
          errorKind: 'procedure.tool.FileScopeViolation',
          message: 'path escapes the run file scope',
        ),
      ],
      status: TrailOutcomeStatus.errored,
    ));

    final events = readEvents('turn_01JZ__disp-fg-run-7');
    expect(events.map((e) => e['kind']),
        containsAll(<String>['creation.requested', 'creation.scope-violation']));
  });

  test('keys a turn-less run by the bare run id', () {
    final writer = CreationTrailWriter(root: tempRoot);
    writer.write(recordOf(
      <ProcedureTreeNode>[
        persistNode('Question',
            id: 'QN-4',
            values: const <String, Object?>{
              'text': 'Create (code): x\nSuccess criterion: y',
            }),
        finalNote(accepted: true, iterations: 1),
        persistNode('Artifact', id: 'ART-1'),
      ],
      turnId: null,
      runId: 'dream-run-2',
    ));

    expect(readEvents('dream-run-2'), isNotEmpty);
  });
}
