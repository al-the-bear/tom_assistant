// Tests for the Todo-7 typed read-projections `ProcedureView` /
// `ProcedureRunView` (`procedure_specification.md` § 7.1, § 9.2).
//
// These decode the untyped `Node.values` map at the node boundary. The tests
// pin: the happy-path projection of every field, the lenient handling of the
// nullable lifecycle fields (a node persisted before the metrics pass), the
// loud failures (wrong node type, unknown status token, malformed timestamp),
// and the `producedNodeIds` round-trip on a run record.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

Node _procedureNode({
  required String name,
  String? summary,
  String? status,
  int? revision,
  List<String>? requires,
  num? successRate,
  int? runCount,
  String? lastRunAt,
  String? authoredAt,
  Vec? embedding,
}) {
  return Node(
    id: NodeId.generate(),
    typeName: procedureNodeTypeName,
    createdAt: DateTime.utc(2026, 1, 1),
    embedding: embedding,
    values: <String, Object?>{
      'name': name,
      'summary': ?summary,
      'code': 'void main() {}',
      'status': ?status,
      'revision': ?revision,
      'requires': ?requires,
      'successRate': ?successRate,
      'runCount': ?runCount,
      'lastRunAt': ?lastRunAt,
      'authoredAt': ?authoredAt,
    },
  );
}

void main() {
  group('ProcedureView.fromNode', () {
    test('projects every field of a fully-stamped procedure', () {
      final embedding = Vec.fromList(<double>[0.1, 0.2, 0.3]);
      final node = _procedureNode(
        name: 'answer_with_memory_v1',
        summary: 'Answer a prompt grounded in recall.',
        status: 'active',
        revision: 3,
        requires: <String>['recall', 'llm'],
        successRate: 0.82,
        runCount: 11,
        lastRunAt: '2026-05-01T10:00:00.000Z',
        authoredAt: '2026-04-01T09:00:00.000Z',
        embedding: embedding,
      );

      final view = ProcedureView.fromNode(node);

      expect(view.id, node.id);
      expect(view.name, 'answer_with_memory_v1');
      expect(view.summary, 'Answer a prompt grounded in recall.');
      expect(view.status, ProcedureStatus.active);
      expect(view.revision, 3);
      expect(view.requires, CapabilitySet.fromIterable(['recall', 'llm']));
      expect(view.successRate, closeTo(0.82, 1e-9));
      expect(view.runCount, 11);
      expect(view.lastRunAt, DateTime.utc(2026, 5, 1, 10));
      expect(view.authoredAt, DateTime.utc(2026, 4, 1, 9));
      expect(view.embedding, embedding);
      expect(view.isRetrievable, isTrue);
    });

    test('tolerates a node persisted before the metrics pass (null caches)',
        () {
      final node = _procedureNode(
        name: 'draft_proc_v1',
        status: 'draft',
        revision: 1,
        requires: <String>['recall'],
      );

      final view = ProcedureView.fromNode(node);

      expect(view.status, ProcedureStatus.draft);
      expect(view.successRate, isNull);
      expect(view.runCount, isNull);
      expect(view.lastRunAt, isNull);
      expect(view.requires, CapabilitySet.fromIterable(['recall']));
      // draft is not retrievable.
      expect(view.isRetrievable, isFalse);
    });

    test('a node with no status is not retrievable and projects null status',
        () {
      final view = ProcedureView.fromNode(_procedureNode(name: 'bare_v1'));
      expect(view.status, isNull);
      expect(view.requires.isEmpty, isTrue);
      expect(view.isRetrievable, isFalse);
    });

    test('preferred is retrievable', () {
      final view = ProcedureView.fromNode(
        _procedureNode(name: 'p', status: 'preferred'),
      );
      expect(view.isRetrievable, isTrue);
    });

    test('rejects a non-Procedure node loudly', () {
      final wrong = Node(
        id: NodeId.generate(),
        typeName: 'Event',
        createdAt: DateTime.utc(2026),
        values: const <String, Object?>{},
      );
      expect(() => ProcedureView.fromNode(wrong), throwsArgumentError);
    });

    test('rejects an unknown status token loudly', () {
      final node = _procedureNode(name: 'p', status: 'retired');
      expect(() => ProcedureView.fromNode(node), throwsArgumentError);
    });

    test('rejects a malformed timestamp loudly', () {
      final node = _procedureNode(name: 'p', lastRunAt: 'not-a-date');
      expect(() => ProcedureView.fromNode(node), throwsFormatException);
    });
  });

  group('ProcedureRunView.fromNode', () {
    Node runNode({
      String? summary,
      String? finishedAt,
      List<String>? producedNodeIds,
      Map<String, Object?>? effort,
      String? parentRunId,
    }) {
      return Node(
        id: NodeId.generate(),
        typeName: procedureRunNodeTypeName,
        createdAt: DateTime.utc(2026, 1, 1),
        values: <String, Object?>{
          'procedureId': 'answer_with_memory_v1',
          'version': 3,
          'runId': 'run-42',
          'parentRunId': ?parentRunId,
          'status': finishedAt == null ? 'running' : 'succeeded',
          'summary': ?summary,
          'startedAt': '2026-05-01T10:00:00.000Z',
          'finishedAt': ?finishedAt,
          'effort': ?effort,
          'producedNodeIds': ?producedNodeIds,
          'trailId': 'trail-7',
        },
      );
    }

    test('projects a completed run record', () {
      final out1 = NodeId.generate();
      final out2 = NodeId.generate();
      final node = runNode(
        summary: 'Produced two claims.',
        finishedAt: '2026-05-01T10:00:05.000Z',
        producedNodeIds: <String>[out1.value, out2.value],
        effort: <String, Object?>{'llmCalls': 2},
        parentRunId: 'run-1',
      );

      final view = ProcedureRunView.fromNode(node);

      expect(view.id, node.id);
      expect(view.procedureId, 'answer_with_memory_v1');
      expect(view.version, 3);
      expect(view.runId, 'run-42');
      expect(view.parentRunId, 'run-1');
      expect(view.status, 'succeeded');
      expect(view.summary, 'Produced two claims.');
      expect(view.startedAt, DateTime.utc(2026, 5, 1, 10));
      expect(view.finishedAt, DateTime.utc(2026, 5, 1, 10, 0, 5));
      expect(view.effort, <String, Object?>{'llmCalls': 2});
      expect(view.producedNodeIds, <NodeId>[out1, out2]);
      expect(view.trailId, 'trail-7');
    });

    test('projects a start marker (nulls + empty produced list)', () {
      final view = ProcedureRunView.fromNode(runNode());
      expect(view.status, 'running');
      expect(view.summary, isNull);
      expect(view.finishedAt, isNull);
      expect(view.effort, isNull);
      expect(view.producedNodeIds, isEmpty);
    });

    test('rejects a non-ProcedureRun node loudly', () {
      final wrong = Node(
        id: NodeId.generate(),
        typeName: 'Procedure',
        createdAt: DateTime.utc(2026),
        values: const <String, Object?>{'name': 'x'},
      );
      expect(() => ProcedureRunView.fromNode(wrong), throwsArgumentError);
    });
  });
}
