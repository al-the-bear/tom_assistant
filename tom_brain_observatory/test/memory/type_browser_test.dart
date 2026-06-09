// PT-5.2 — browse-by-type composition (`prompt_tracing.md` § 5.2, § 8.4).
//
// "List all nodes of type X" has no v1 MCP tool (the gap is recorded as a
// candidate read-tool addition in `memory_specification.md` § 3.2). Until it
// exists, the browser composes the answer from the nine reads — recall seeded
// by the type name, node ids surfaced in traces (`memory.get`), and edge
// traversal — then filters to the requested `typeName` and dedupes by id.
//
// The defining properties this test pins:
//   • the composition only ever calls READ tools (it routes through the
//     MemoryReadClient, so OBS-2 holds transitively — no DB, no write);
//   • the result is explicitly NON-exhaustive (`exhaustive == false`) — it is a
//     best-effort composition, never a claim of completeness;
//   • only nodes whose `typeName` matches are returned, deduped by id;
//   • each composition source (recall / get / edgesOf) is used only when it can
//     contribute, and is reported in `sources`.

import 'package:test/test.dart';
import 'package:tom_brain_observatory/src/memory/memory_read_client.dart';
import 'package:tom_brain_observatory/src/memory/type_browser.dart';

import 'support/fake_read_connection.dart';

void main() {
  // A recall stub over the given candidate nodes (the seed of every browse).
  Map<String, Object?> recallStub(List<Map<String, Object?>> nodes) =>
      <String, Object?>{'nodes': nodes, 'report': _minimalReport};

  test('browse seeds recall by type and filters to the requested type',
      () async {
    // Recall returns a mixed-type candidate set; only the Question survives.
    final conn = FakeReadConnection(<String, Map<String, Object?>>{
      'memory.recall': recallStub(<Map<String, Object?>>[_questionNode, _claimNode]),
    });
    final browser = TypeBrowser(MemoryReadClient(conn));

    final result = await browser.browse('Question');

    expect(result.typeName, equals('Question'));
    expect(result.nodes.map((n) => n.id), equals(<String>['n_question1']));
    expect(result.exhaustive, isFalse,
        reason: 'a composed browse is never a completeness claim');
    expect(result.sources, equals(<String>['recall']));

    // Recall was seeded by the type name; only the read tool was touched.
    expect(conn.calledTools, equals(<String>['memory.recall']));
    expect(conn.calledArgs.single['text'], equals('Question'));
  });

  test('known ids surfaced in traces are fetched via get and merged', () async {
    // Recall finds only the Question; the Claim arrives via its trace id.
    final conn = FakeReadConnection(<String, Map<String, Object?>>{
      'memory.recall': recallStub(<Map<String, Object?>>[_questionNode]),
      'memory.get': <String, Object?>{
        'nodes': <Object?>[_claimNode],
      },
    });
    final browser = TypeBrowser(MemoryReadClient(conn));

    final result =
        await browser.browse('Claim', knownIds: <String>['n_claim1']);

    expect(result.nodes.map((n) => n.id), equals(<String>['n_claim1']));
    expect(result.sources, equals(<String>['recall', 'get']));
    expect(conn.calledTools, equals(<String>['memory.recall', 'memory.get']));
    expect(conn.calledArgs.last['ids'], equals(<String>['n_claim1']));
  });

  test('edge traversal discovers a neighbour not in the recall seed', () async {
    // Recall finds only the Question; the Claim is reachable only by its edge,
    // so traversal must edge-walk then `get` the neighbour to surface it.
    final conn = FakeReadConnection(<String, Map<String, Object?>>{
      'memory.recall': recallStub(<Map<String, Object?>>[_questionNode]),
      'memory.edgesOf': <String, Object?>{
        'edges': <Object?>[_edge],
      },
      'memory.get': <String, Object?>{
        'nodes': <Object?>[_claimNode],
      },
    });
    final browser = TypeBrowser(MemoryReadClient(conn));

    final result = await browser.browse('Claim', traverseEdges: true);

    expect(result.nodes.map((n) => n.id), equals(<String>['n_claim1']));
    expect(result.sources, equals(<String>['recall', 'edgesOf', 'get']));
    expect(conn.calledTools, contains('memory.edgesOf'));
    expect(conn.calledTools, contains('memory.get'));
  });

  test('a neighbour already in the seed is not re-fetched', () async {
    // Recall already holds the Claim; edge traversal rediscovers it but must
    // not issue a redundant `get`.
    final conn = FakeReadConnection(<String, Map<String, Object?>>{
      'memory.recall': recallStub(<Map<String, Object?>>[_questionNode, _claimNode]),
      'memory.edgesOf': <String, Object?>{
        'edges': <Object?>[_edge],
      },
    });
    final browser = TypeBrowser(MemoryReadClient(conn));

    final result = await browser.browse('Claim', traverseEdges: true);

    expect(result.nodes.map((n) => n.id), equals(<String>['n_claim1']));
    expect(result.sources, equals(<String>['recall', 'edgesOf']));
    expect(conn.calledTools, isNot(contains('memory.get')));
  });

  test('every gathered node is deduped by id across sources', () async {
    // recall and get both yield the Claim; the result holds it once.
    final conn = FakeReadConnection(<String, Map<String, Object?>>{
      'memory.recall': recallStub(<Map<String, Object?>>[_questionNode, _claimNode]),
      'memory.get': <String, Object?>{
        'nodes': <Object?>[_claimNode],
      },
    });
    final browser = TypeBrowser(MemoryReadClient(conn));

    final result =
        await browser.browse('Claim', knownIds: <String>['n_claim1']);

    expect(result.nodes, hasLength(1));
  });

  test('the composition never calls a write tool (OBS-2 transitively)',
      () async {
    final conn = FakeReadConnection(<String, Map<String, Object?>>{
      'memory.recall': recallStub(<Map<String, Object?>>[_questionNode]),
      'memory.edgesOf': <String, Object?>{
        'edges': <Object?>[_edge],
      },
      'memory.get': <String, Object?>{
        'nodes': <Object?>[_claimNode],
      },
    });
    final browser = TypeBrowser(MemoryReadClient(conn));

    await browser.browse('Claim',
        knownIds: <String>['n_claim1'], traverseEdges: true);

    expect(conn.calledTools, isNot(contains(MemoryReadClient.writeToolName)));
    expect(conn.calledTools.toSet().difference(MemoryReadClient.readToolNames),
        isEmpty);
  });
}

const Map<String, Object?> _questionNode = <String, Object?>{
  'id': 'n_question1',
  'typeName': 'Question',
  'values': <String, Object?>{'text': 'what about backup?'},
  'embedding': <Object?>[0.1, 0.2, 0.3],
  'createdAt': '2026-01-01T12:00:00.000Z',
  'status': 'active',
};

const Map<String, Object?> _claimNode = <String, Object?>{
  'id': 'n_claim1',
  'typeName': 'Claim',
  'values': <String, Object?>{'statement': 'tiered backup is decided'},
  'embedding': null,
  'createdAt': '2026-01-01T12:01:00.000Z',
  'status': 'active',
};

const Map<String, Object?> _edge = <String, Object?>{
  'id': 'e_1',
  'from': 'n_question1',
  'type': 'satisfied_by',
  'to': 'n_claim1',
  'weight': 1.0,
  'attrs': <String, Object?>{},
};

const Map<String, Object?> _minimalReport = <String, Object?>{
  'candidatesPerMode': <String, Object?>{'bm25': 2},
  'fusionStrategy': 'rrf',
  'diversityStrategy': 'mmr',
  'elapsedMs': 1,
  'embeddingsCallouts': 0,
  'reRankInvoked': false,
  'degraded': false,
};
