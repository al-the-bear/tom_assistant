// PT-5.1 — the Memory MCP read client (`prompt_tracing.md` § 5.1, § 8.4).
//
// The defining test of Phase 5 is OBS-2 (§ 6.2): the client registers ONLY the
// nine read tools — `memory.persistNote` is never wired, so the observatory
// cannot write memory. The first two tests are that invariant stated two ways
// (the static registry, and the dynamic surface — exercising every method calls
// exactly the nine and never the write tool). The rest assert each read tool's
// payload decodes into the right view model (the wire shapes in
// `tom_brain_memory/lib/src/mcp_server/mcp_tools.dart`).
//
// OBS-3 is structural here: the client's only collaborator is the injected
// [McpReadConnection]; it holds no `File`/`Directory`/DB handle, so every memory
// access flows through the MCP seam (the file-watch-only / no-DB conformance
// harness is Phase 8). The fake records every call so that discipline is visible.

import 'package:test/test.dart';
import 'package:tom_brain_observatory/src/memory/memory_nodes.dart';
import 'package:tom_brain_observatory/src/memory/memory_read_client.dart';

import 'support/fake_read_connection.dart';

void main() {
  group('OBS-2 — only the nine read tools', () {
    test('the static registry is exactly the nine reads, never the write', () {
      expect(MemoryReadClient.readToolNames, hasLength(9));
      expect(
        MemoryReadClient.readToolNames,
        isNot(contains(MemoryReadClient.writeToolName)),
      );
      expect(MemoryReadClient.writeToolName, equals('memory.persistNote'));
      expect(
        MemoryReadClient.readToolNames,
        containsAll(<String>[
          'memory.recall',
          'memory.recall.multi',
          'memory.get',
          'memory.edgesOf',
          'memory.stack.list',
          'memory.stack.peek',
          'memory.classify',
          'memory.profiles.list',
          'memory.profile.current',
        ]),
      );
    });

    test('exercising the whole client surface calls exactly the nine reads',
        () async {
      final conn = FakeReadConnection(allReadToolStubs());
      final client = MemoryReadClient(conn);

      await client.recall(text: 'backup');
      await client.recallMulti(
        seeds: <RecallSeedSpec>[RecallSeedSpec(mode: RecallMode.bm25, text: 'x')],
      );
      await client.get(<String>['n_question1']);
      await client.edgesOf('n_question1');
      await client.stackList();
      await client.stackPeek('working');
      await client.classify(<double>[0.1, 0.2]);
      await client.profilesList();
      await client.profileCurrent();

      // The full surface maps onto exactly the nine read tools — if anyone
      // wired a write tool into a client method, this set would no longer
      // equal the read registry.
      expect(conn.calledTools.toSet(), equals(MemoryReadClient.readToolNames));
      expect(conn.calledTools, isNot(contains('memory.persistNote')));
    });
  });

  group('read-tool decoding', () {
    late FakeReadConnection conn;
    late MemoryReadClient client;

    setUp(() {
      conn = FakeReadConnection(allReadToolStubs());
      client = MemoryReadClient(conn);
    });

    test('recall decodes nodes + the per-mode cost report', () async {
      final result = await client.recall(
        text: 'backup',
        modes: <RecallMode>{RecallMode.bm25, RecallMode.vector},
        k: 5,
        wallClockMs: 100,
      );
      expect(result.nodes.map((n) => n.id),
          containsAllInOrder(<String>['n_question1', 'n_claim1']));
      expect(result.report.candidatesPerMode['bm25'], equals(5));
      expect(result.report.fusionStrategy, equals('rrf'));
      expect(result.report.diversityLambda, equals(0.7));
      expect(result.report.degraded, isFalse);

      // The args were marshalled to the tool schema shape.
      final args = conn.calledArgs.single;
      expect(args['text'], equals('backup'));
      expect(args['modes'], equals(<String>['bm25', 'vector']));
      expect(args['k'], equals(5));
      expect(args['wallClockMs'], equals(100));
    });

    test('recallMulti decodes per-node seed provenance', () async {
      final result = await client.recallMulti(seeds: <RecallSeedSpec>[
        RecallSeedSpec(mode: RecallMode.bm25, text: 'backup', weight: 2),
        RecallSeedSpec(mode: RecallMode.vector, embedding: <double>[0.1, 0.2]),
      ]);
      expect(result.provenance, isNotNull);
      expect(result.provenance!.single.nodeId, equals('n_question1'));
      expect(result.provenance!.single.seedIndexes, equals(<int>[0, 1]));
      expect(result.provenance!.single.fusedScore, closeTo(0.66, 1e-9));

      final seeds = conn.calledArgs.single['seeds'] as List<Object?>;
      expect((seeds.first as Map)['mode'], equals('bm25'));
      expect((seeds.first as Map)['weight'], equals(2.0));
      expect((seeds.last as Map)['embedding'], equals(<double>[0.1, 0.2]));
    });

    test('get decodes nodes with embedding dimension + norm', () async {
      final nodes = await client.get(<String>['n_question1']);
      final node = nodes.single;
      expect(node.id, equals('n_question1'));
      expect(node.typeName, equals('Question'));
      expect(node.values['text'], equals('what about backup?'));
      expect(node.status, equals('active'));
      expect(node.embeddingDimension, equals(3));
      expect(node.embeddingNorm, closeTo(0.37416, 1e-4));
      expect(conn.calledArgs.single['ids'], equals(<String>['n_question1']));
    });

    test('get decodes a node with a null embedding', () async {
      final conn2 = FakeReadConnection(<String, Map<String, Object?>>{
        'memory.get': <String, Object?>{
          'nodes': <Object?>[
            <String, Object?>{
              'id': 'n_claim1',
              'typeName': 'Claim',
              'values': <String, Object?>{'statement': 's'},
              'embedding': null,
              'createdAt': '2026-01-01T12:01:00.000Z',
              'status': 'active',
            },
          ],
        },
      });
      final node = (await MemoryReadClient(conn2).get(<String>['n_claim1'])).single;
      expect(node.embedding, isNull);
      expect(node.embeddingDimension, isNull);
      expect(node.embeddingNorm, isNull);
    });

    test('edgesOf decodes edges and marshals direction + types', () async {
      final edges = await client.edgesOf(
        'n_question1',
        direction: EdgeDirection.outgoing,
        types: <String>{'satisfied_by'},
      );
      final edge = edges.single;
      expect(edge.from, equals('n_question1'));
      expect(edge.type, equals('satisfied_by'));
      expect(edge.to, equals('n_claim1'));
      expect(edge.weight, equals(1.0));

      final args = conn.calledArgs.single;
      expect(args['id'], equals('n_question1'));
      expect(args['direction'], equals('outgoing'));
      expect(args['types'], equals(<String>['satisfied_by']));
    });

    test('stackList decodes the inventory', () async {
      final stacks = await client.stackList();
      expect(stacks.single.name, equals('working'));
      expect(stacks.single.size, equals(3));
      expect(stacks.single.bootstrap, isFalse);
    });

    test('stackPeek decodes entries and marshals k', () async {
      final entries = await client.stackPeek('working', k: 8);
      expect(entries.single.nodeId, equals('n_question1'));
      expect(entries.single.priority, equals(0.9));
      final args = conn.calledArgs.single;
      expect(args['name'], equals('working'));
      expect(args['k'], equals(8));
    });

    test('classify decodes the decision band', () async {
      final result = await client.classify(
        <double>[0.1, 0.2],
        target: ClassifyTarget.nodeType,
      );
      expect(result.decision, equals('confident'));
      expect(result.bestMatch, equals('Question'));
      expect(result.bestSimilarity, closeTo(0.82, 1e-9));
      final args = conn.calledArgs.single;
      expect(args['embedding'], equals(<double>[0.1, 0.2]));
      expect(args['target'], equals('nodeType'));
    });

    test('profilesList + profileCurrent decode', () async {
      expect(await client.profilesList(), equals(<String>['default', 'eval']));
      expect(await client.profileCurrent(), equals('default'));
    });

    test('profileCurrent on the unprofiled root decodes null', () async {
      final conn2 = FakeReadConnection(<String, Map<String, Object?>>{
        'memory.profile.current': <String, Object?>{'profile': null},
      });
      expect(await MemoryReadClient(conn2).profileCurrent(), isNull);
    });
  });

  test('a tool error surfaces as McpReadException', () async {
    final conn = FakeReadConnection(const <String, Map<String, Object?>>{});
    expect(
      () => MemoryReadClient(conn).profileCurrent(),
      throwsA(isA<McpReadException>()),
    );
  });
}
