// PT-6 web data layer — [HttpMemoryApiClient] over the same-origin
// `/api/memory/*` surface (§ 8.4). A `MockClient` stands in for the network: the
// tests pin the URL/method/body each call marshals to, that `503` maps to a
// [MemoryUnavailable] (the deferred-connector signal), and that a node `404`
// decodes to `null` (absence is clean, not an error).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tom_brain_observatory_web/src/api/memory_api_client.dart';
import 'package:tom_brain_observatory_web/src/model/memory_nodes.dart';

void main() {
  final origin = Uri.parse('http://localhost:8787/');

  // Builds a client whose every request is captured into [seen] and answered
  // with [responder]'s (status, jsonBody).
  HttpMemoryApiClient clientThat(
    List<http.Request> seen,
    (int, Object) Function(http.Request) responder,
  ) =>
      HttpMemoryApiClient(
        origin: origin,
        httpClient: MockClient((req) async {
          seen.add(req);
          final (status, body) = responder(req);
          return http.Response(jsonEncode(body), status,
              headers: const <String, String>{
                'content-type': 'application/json'
              });
        }),
      );

  test('browseNodes marshals type/knownIds/traverseEdges into the query',
      () async {
    final seen = <http.Request>[];
    final client = clientThat(seen, (_) => (200, <String, Object?>{
          'typeName': 'Question',
          'exhaustive': false,
          'nodes': <Object?>[],
          'sources': <Object?>['recall'],
        }));

    final result = await client.browseNodes('Question',
        knownIds: <String>['n1', 'n2'], traverseEdges: true);

    expect(result.typeName, 'Question');
    expect(result.exhaustive, isFalse);
    final uri = seen.single.url;
    expect(uri.path, '/api/memory/nodes');
    expect(uri.queryParameters['type'], 'Question');
    expect(uri.queryParameters['knownIds'], 'n1,n2');
    expect(uri.queryParameters['traverseEdges'], 'true');
  });

  test('node decodes detail and computes embedding dimension + norm', () async {
    final seen = <http.Request>[];
    final client = clientThat(seen, (_) => (200, <String, Object?>{
          'id': 'n1',
          'typeName': 'Question',
          'status': 'active',
          'createdAt': '2026-01-01T00:00:00Z',
          'values': <String, Object?>{'text': 'hi'},
          'embedding': <Object?>[3.0, 4.0],
        }));

    final node = await client.node('n1');

    expect(node, isNotNull);
    expect(node!.embeddingDimension, 2);
    expect(node.embeddingNorm, closeTo(5.0, 1e-9));
    expect(seen.single.url.path, '/api/memory/nodes/n1');
  });

  test('node returns null on 404', () async {
    final client = clientThat(<http.Request>[],
        (_) => (404, <String, Object?>{'error': 'no node'}));
    expect(await client.node('missing'), isNull);
  });

  test('recall POSTs text/modes/k as a JSON body', () async {
    final seen = <http.Request>[];
    final client = clientThat(seen, (_) => (200, <String, Object?>{
          'nodes': <Object?>[],
          'report': <String, Object?>{'fusionStrategy': 'rrf'},
        }));

    await client.recall(
        text: 'backup', modes: <RecallMode>{RecallMode.bm25, RecallMode.vector}, k: 5);

    final req = seen.single;
    expect(req.method, 'POST');
    expect(req.url.path, '/api/memory/recall');
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    expect(body['text'], 'backup');
    expect(body['k'], 5);
    expect((body['modes'] as List), containsAll(<String>['bm25', 'vector']));
  });

  test('recallMulti POSTs the weighted seeds and decodes provenance', () async {
    final seen = <http.Request>[];
    final client = clientThat(seen, (_) => (200, <String, Object?>{
          'nodes': <Object?>[],
          'report': <String, Object?>{},
          'provenance': <Object?>[
            <String, Object?>{
              'nodeId': 'n1',
              'seedIndexes': <Object?>[0],
              'fusedScore': 0.5,
            },
          ],
        }));

    final result = await client.recallMulti(seeds: <RecallSeedSpec>[
      const RecallSeedSpec(mode: RecallMode.bm25, text: 'a', weight: 2.0),
    ]);

    expect(result.provenance, hasLength(1));
    expect(result.provenance!.single.nodeId, 'n1');
    final body = jsonDecode(seen.single.body) as Map<String, dynamic>;
    expect((body['seeds'] as List).single, <String, Object?>{
      'mode': 'bm25',
      'text': 'a',
      'weight': 2.0,
    });
  });

  test('classify POSTs the embedding and target', () async {
    final seen = <http.Request>[];
    final client = clientThat(seen, (_) => (200, <String, Object?>{
          'decision': 'confident',
          'bestMatch': 'Question',
          'bestSimilarity': 0.8,
          'secondSimilarity': 0.4,
        }));

    final result = await client.classify(<double>[0.1, 0.2],
        target: ClassifyTarget.concept);

    expect(result.decision, 'confident');
    final body = jsonDecode(seen.single.body) as Map<String, dynamic>;
    expect(body['embedding'], <double>[0.1, 0.2]);
    expect(body['target'], 'concept');
  });

  test('profiles combines the list and the current binding', () async {
    final client = clientThat(<http.Request>[], (_) => (200, <String, Object?>{
          'profiles': <Object?>['default', 'eval'],
          'current': 'default',
        }));
    final profiles = await client.profiles();
    expect(profiles.profiles, <String>['default', 'eval']);
    expect(profiles.current, 'default');
  });

  test('a 503 maps to MemoryUnavailable, never a generic error', () async {
    final client = clientThat(<http.Request>[],
        (_) => (503, <String, Object?>{'error': 'memory unavailable'}));
    expect(
      () => client.stacks(),
      throwsA(isA<MemoryUnavailable>()
          .having((e) => e.message, 'message', 'memory unavailable')),
    );
  });
}
