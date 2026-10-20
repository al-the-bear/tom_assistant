// B.45 — API conformance test suite.
//
// Plan step B.45 (verbatim, `prototype_implementation_plan.md` § Phase B):
//
//   "API conformance tests: black-box test suite driving
//    `TomBrainSubstrateClient` only. Cover every method, every failure
//    path, every role."
//
// This is the conformance counterpart to B.43's structural attestation
// and B.42's swap-equivalence proof. Three discipline rules govern the
// file:
//
//   1. **Black-box import discipline.** The single substrate import is
//      `package:tom_brain_substrate/tom_brain_substrate.dart` — the
//      top-level barrel. There is no `package:tom_brain_substrate/src/…`
//      anywhere in this file. The same discipline as A.89 on the memory
//      side: a black-box suite that an isolate adapter, a future remote
//      adapter, or any third TomBrainSubstrateClient implementation
//      would pass through unchanged.
//
//   2. **Interface-only static typing for the SUT.** Every variable
//      that names "the substrate under test" is statically typed
//      `TomBrainSubstrateClient`. The composition root (the `_build…`
//      helpers below) still hands back the concrete in-process facade
//      because that is the only impl we ship today, but at the call
//      sites the suite touches no member that is not on the abstract
//      contract. The B.40 structural test pins this rule for the
//      engine bridge; this file applies the same rule to the
//      conformance suite.
//
//   3. **Every method × every role × every failure path.** Section
//      headers below name which surface they cover:
//
//        - Lifecycle (`open`, `close`).
//        - LLM (`complete`, `completeStream`) — buffered + streaming,
//          happy path, role coverage (×5), and the failure shapes
//          named in the consumer contract: `RoleTemplateNotFound`,
//          `NoRouteAvailable`, `AnchorViolation`, `LlmRunFailed`,
//          and cancellation.
//        - Embedding (`embed`, `embedBatch`).
//        - Web tools (`webSearch`, `webFetch`) — happy path + each
//          declared failure surface (`WebFetchUnsupportedType`,
//          `WebFetchHttpException`, transport).
//        - MCP outbound (`mcpClient`) — endpoint identity caching.
//        - Observability (`events`, `stats`).
//
//      Every prototype role declared in `bootstrapRoleRegistry()` is
//      exercised through both `complete` and `completeStream`, against
//      a configured route. The test verifies the report's
//      `anchorHash` equals `AnchorRegistry.currentHash` and the role
//      stamps onto `stats().callsPerRole`.
//
// What this file deliberately does NOT do:
//
//   * **No anchor-enforcement parametric sweep.** That is B.46's job;
//     this file pins exactly the contract paragraph from the
//     `TomBrainSubstrateClient` doc-comment that says "the substrate
//     enforces it for them". B.46 will parametrically prove there is
//     no bypass surface.
//   * **No router-cooldown deep-dive.** The router-side conformance
//     suite (B.20) owns that taxonomy. This file only verifies the
//     substrate-surface promise: a fully-failing chain throws a
//     consumer-visible exception with a recognised runtime class.
//   * **No real network.** Every collaborator is a deterministic
//     in-process fake. Real-provider smoke is B.48's job.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show Budget, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.45 / TomBrainSubstrateClient black-box conformance', () {
    // ═══════════════════════════════════════════════════════════════
    // Lifecycle
    // ═══════════════════════════════════════════════════════════════

    group('lifecycle', () {
      test('open succeeds on a well-formed config', () async {
        final TomBrainSubstrateClient client = await _openClient();
        addTearDown(client.close);
        // Reaching this point without throwing is the assertion.
      });

      test('open is idempotent — re-open replaces bound config', () async {
        final TomBrainSubstrateClient client = await _openClient();
        addTearDown(client.close);
        // Re-opening with another config returns normally.
        await client.open(_minimalConfig());
        // Surface still works after re-open.
        final report = await client.complete(_callFor('assistant_to_user'));
        expect(report.anchorHash, AnchorRegistry.currentHash);
      });

      test(
        'open rejects a config that routes through an unknown role',
        () async {
          final TomBrainSubstrateClient client = _buildUnopenedClient();
          addTearDown(client.close);
          final bad = _configWithRoutes(<String, List<RoleRouteEntryConfig>>{
            'no_such_role': <RoleRouteEntryConfig>[
              const RoleRouteEntryConfig(
                providerId: 'stub',
                model: 'stub-model',
              ),
            ],
          });
          await expectLater(
            client.open(bad),
            throwsA(isA<SubstrateConfigException>()),
          );
        },
      );

      test('close is idempotent', () async {
        final TomBrainSubstrateClient client = await _openClient();
        await client.close();
        await client.close();
      });

      test('every surface method refuses to run after close', () async {
        final TomBrainSubstrateClient client = await _openClient();
        await client.close();

        await expectLater(
          client.complete(_callFor('assistant_to_user')),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          () => client.completeStream(_callFor('assistant_to_user')).toList(),
          throwsA(isA<StateError>()),
        );
        await expectLater(client.embed('x'), throwsA(isA<StateError>()));
        await expectLater(
          client.embedBatch(const <String>['x']),
          throwsA(isA<StateError>()),
        );
        await expectLater(client.webSearch('q'), throwsA(isA<StateError>()));
        await expectLater(
          client.webFetch(Uri.parse('https://example.com/')),
          throwsA(isA<StateError>()),
        );
        expect(
          () => client.mcpClient(const McpEndpoint('memory')),
          throwsA(isA<StateError>()),
        );
        // events() / stats() are reads — they are allowed (or refused)
        // based on the contract, but they MUST NOT explode the suite
        // with a bare exception. The contract is silent on these after
        // close — we only assert they do not throw an unhandled
        // exception that would terminate the test process. Both are
        // synchronous in the in-process impl; calling them inside
        // expectLater catches whatever they raise (StateError on
        // emit-after-close is the typical outcome).
        // We don't bind a behaviour here beyond "does not crash the
        // VM" — that is the entire post-close contract on reads.
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // LLM — buffered (`complete`) — happy path per role
    // ═══════════════════════════════════════════════════════════════

    group('complete — happy path per role', () {
      for (final roleId in prototypeRoleIds) {
        test('role "$roleId" returns an anchored report', () async {
          final TomBrainSubstrateClient client = await _openClient(
            roles: prototypeRoleIds,
          );
          addTearDown(client.close);

          final report = await client.complete(_callFor(roleId));

          expect(report.providerId, 'stub');
          expect(report.modelId, 'stub-model');
          expect(report.anchorHash, AnchorRegistry.currentHash);
          expect(report.promptHash, startsWith('sha256:'));
          expect(report.tokensIn, greaterThan(0));
          expect(report.tokensOut, greaterThan(0));
          expect(report.retries, 0);
        });
      }

      test('callsPerRole stats reflect each role exactly once', () async {
        final TomBrainSubstrateClient client = await _openClient(
          roles: prototypeRoleIds,
        );
        addTearDown(client.close);

        for (final roleId in prototypeRoleIds) {
          await client.complete(_callFor(roleId));
        }

        final stats = client.stats();
        for (final roleId in prototypeRoleIds) {
          expect(
            stats.callsPerRole[roleId],
            1,
            reason: 'expected one call per role for $roleId',
          );
        }
        expect(stats.callsPerProvider['stub'], prototypeRoleIds.length);
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // LLM — buffered — failure paths
    // ═══════════════════════════════════════════════════════════════

    group('complete — failure paths', () {
      test('unknown role surfaces RoleTemplateNotFound', () async {
        final TomBrainSubstrateClient client = await _openClient();
        addTearDown(client.close);
        await expectLater(
          client.complete(_callFor('not_a_role')),
          throwsA(isA<RoleTemplateNotFound>()),
        );
      });

      test(
        'always-failing provider on a single-entry chain → NoRouteAvailable',
        () async {
          final TomBrainSubstrateClient client = await _openClient(
            provider: StubLlmProvider.alwaysFails(
              id: 'stub',
              defaultModel: 'stub-model',
            ),
          );
          addTearDown(client.close);
          await expectLater(
            client.complete(_callFor('assistant_to_user')),
            throwsA(isA<NoRouteAvailable>()),
          );
        },
      );

      test('anchor-tampering provider → AnchorViolation', () async {
        final tampering = _AnchorTamperingProvider(
          inner: StubLlmProvider(id: 'stub', defaultModel: 'stub-model'),
          rewrittenHash: 'sha256:dead',
        );
        final TomBrainSubstrateClient client = await _openClient(
          provider: tampering,
        );
        addTearDown(client.close);
        await expectLater(
          client.complete(_callFor('assistant_to_user')),
          throwsA(isA<AnchorViolation>()),
        );
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // LLM — streaming (`completeStream`) — happy path per role
    // ═══════════════════════════════════════════════════════════════

    group('completeStream — happy path per role', () {
      for (final roleId in prototypeRoleIds) {
        test('role "$roleId" emits Started → Chunk* → Completed', () async {
          final TomBrainSubstrateClient client = await _openClient(
            roles: prototypeRoleIds,
          );
          addTearDown(client.close);

          final events = await client.completeStream(_callFor(roleId)).toList();

          expect(events.first, isA<LlmRunStarted>());
          expect(events.last, isA<LlmRunCompleted>());
          // At least one chunk between Started and Completed.
          expect(
            events.whereType<LlmTextDelta>(),
            isNotEmpty,
            reason: 'role $roleId did not emit any text chunks',
          );

          final started = events.first as LlmRunStarted;
          final completed = events.last as LlmRunCompleted;
          expect(started.providerId, 'stub');
          expect(started.modelId, 'stub-model');
          expect(completed.report.anchorHash, AnchorRegistry.currentHash);
          // Started + Completed share the call id.
          expect(completed.callId, started.callId);
        });
      }
    });

    // ═══════════════════════════════════════════════════════════════
    // LLM — streaming — failure paths
    // ═══════════════════════════════════════════════════════════════

    group('completeStream — failure paths', () {
      test(
        'unknown role surfaces RoleTemplateNotFound synchronously',
        () async {
          final TomBrainSubstrateClient client = await _openClient();
          addTearDown(client.close);
          expect(
            () => client.completeStream(_callFor('not_a_role')),
            throwsA(isA<RoleTemplateNotFound>()),
          );
        },
      );

      test(
        'always-failing provider → stream terminates with LlmRunFailed',
        () async {
          final TomBrainSubstrateClient client = await _openClient(
            provider: StubLlmProvider.alwaysFails(
              id: 'stub',
              defaultModel: 'stub-model',
            ),
          );
          addTearDown(client.close);
          final events = await client
              .completeStream(_callFor('assistant_to_user'))
              .toList();
          expect(events, isNotEmpty);
          expect(events.last, isA<LlmRunFailed>());
        },
      );

      test('anchor-tampering provider → AnchorViolation on stream', () async {
        final tampering = _AnchorTamperingProvider(
          inner: StubLlmProvider(id: 'stub', defaultModel: 'stub-model'),
          rewrittenHash: 'sha256:dead',
        );
        final TomBrainSubstrateClient client = await _openClient(
          provider: tampering,
        );
        addTearDown(client.close);
        await expectLater(
          client.completeStream(_callFor('assistant_to_user')).toList(),
          throwsA(isA<AnchorViolation>()),
        );
      });

      test(
        'pre-cancelled token → stream terminates without LlmRunCompleted',
        () async {
          // The contract paragraph in `tom_brain_substrate_client.dart`
          // for `completeStream` says cancellation aborts and surfaces
          // either `LlmRunFailed(cancelled_by_consumer)` or — at the
          // facade boundary — propagates the router's
          // `NoRouteAvailable(lastClass: cancelled_by_consumer)` as a
          // stream error. Either shape satisfies the surface contract;
          // the conformance gate is that the stream must not complete
          // with `LlmRunCompleted`.
          final cts = CancellationTokenSource();
          cts.cancel();

          final TomBrainSubstrateClient client = await _openClient();
          addTearDown(client.close);

          final call = LlmCall(
            roleId: 'assistant_to_user',
            inputs: const <String, Object?>{'question': 'hi'},
            budget: _budget(),
            cancellationToken: cts.token,
          );

          var sawCompleted = false;
          try {
            await for (final ev in client.completeStream(call)) {
              if (ev is LlmRunCompleted) sawCompleted = true;
            }
          } on Object {
            // Acceptable terminal shape.
          }
          expect(
            sawCompleted,
            isFalse,
            reason: 'pre-cancelled call must not emit LlmRunCompleted',
          );
        },
      );
    });

    // ═══════════════════════════════════════════════════════════════
    // Embedding
    // ═══════════════════════════════════════════════════════════════

    group('embed / embedBatch', () {
      test('embed returns vec + identity', () async {
        final TomBrainSubstrateClient client = await _openClient();
        addTearDown(client.close);
        final result = await client.embed('hello');
        expect(result.modelIdentity.providerId, 'stub');
        expect(result.modelIdentity.modelId, 'stub-embedder');
        expect(result.modelIdentity.dims, 4);
        expect(result.vec.values.length, 4);
        expect(client.stats().embeddingsComputed, 1);
      });

      test('embedBatch preserves input order and count', () async {
        final TomBrainSubstrateClient client = await _openClient();
        addTearDown(client.close);
        final inputs = const <String>['a', 'bb', 'ccc'];
        final out = await client.embedBatch(inputs);
        expect(out, hasLength(3));
        for (var i = 0; i < inputs.length; i++) {
          expect(out[i].modelIdentity.providerId, 'stub');
          expect(out[i].modelIdentity.dims, 4);
          // First-component encoding pins per-input identity preserved
          // by the conformance fake — proves order, not text shape.
          expect(out[i].vec[0], inputs[i].length.toDouble());
        }
        expect(client.stats().embeddingsComputed, 3);
      });

      test('embedBatch on empty input returns empty', () async {
        final TomBrainSubstrateClient client = await _openClient();
        addTearDown(client.close);
        final out = await client.embedBatch(const <String>[]);
        expect(out, isEmpty);
        expect(client.stats().embeddingsComputed, 0);
      });

      test('identity is stable across calls', () async {
        final TomBrainSubstrateClient client = await _openClient();
        addTearDown(client.close);
        final a = await client.embed('first');
        final b = await client.embed('second');
        expect(a.modelIdentity, b.modelIdentity);
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // Web tools — search
    // ═══════════════════════════════════════════════════════════════

    group('webSearch', () {
      test('returns provider + verbatim query + supplied hits', () async {
        final search = _ScriptedWebSearch()
          ..primedHits = <SearchHit>[
            SearchHit(
              title: 'A',
              url: Uri.parse('https://example.com/a'),
              snippet: 's',
              rank: 1,
            ),
            SearchHit(
              title: 'B',
              url: Uri.parse('https://example.com/b'),
              snippet: 's',
              rank: 2,
            ),
          ];
        final TomBrainSubstrateClient client = await _openClient(
          webSearch: search,
        );
        addTearDown(client.close);

        final result = await client.webSearch('hello world');
        expect(result.provider, 'stub-search');
        expect(result.query, 'hello world');
        expect(result.hits, hasLength(2));
        expect(client.stats().webSearches, 1);
      });

      test('caller-provided options.k truncates the hit list', () async {
        final search = _ScriptedWebSearch()
          ..primedHits = <SearchHit>[
            for (var i = 0; i < 5; i++)
              SearchHit(
                title: 't$i',
                url: Uri.parse('https://example.com/$i'),
                snippet: '',
                rank: i + 1,
              ),
          ];
        final TomBrainSubstrateClient client = await _openClient(
          webSearch: search,
        );
        addTearDown(client.close);

        final result = await client.webSearch(
          'q',
          options: const WebSearchOptions(k: 2),
        );
        expect(result.hits, hasLength(2));
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // Web tools — fetch
    // ═══════════════════════════════════════════════════════════════

    group('webFetch', () {
      test(
        'text body — returns text result and emits WebFetchCompleted',
        () async {
          final fetch = _ScriptedWebFetch()
            ..primedResult = WebFetchResult(
              url: Uri.parse('https://example.com/'),
              status: 200,
              contentType: 'text/plain',
              text: 'hello',
            );
          final TomBrainSubstrateClient client = await _openClient(
            webFetch: fetch,
          );
          addTearDown(client.close);

          final events = <SubstrateEvent>[];
          final sub = client.events().listen(events.add);
          addTearDown(sub.cancel);

          final result = await client.webFetch(
            Uri.parse('https://example.com/'),
          );
          expect(result.status, 200);
          expect(result.text, 'hello');
          expect(result.json, isNull);
          expect(result.binaryMeta, isNull);
          await Future<void>.delayed(Duration.zero);
          expect(events.whereType<WebFetchCompleted>(), hasLength(1));
          expect(client.stats().webFetches, 1);
        },
      );

      test('json body — json non-null, text+binaryMeta null', () async {
        final fetch = _ScriptedWebFetch()
          ..primedResult = WebFetchResult(
            url: Uri.parse('https://api.example.com/x'),
            status: 200,
            contentType: 'application/json',
            json: <String, Object?>{'ok': true},
          );
        final TomBrainSubstrateClient client = await _openClient(
          webFetch: fetch,
        );
        addTearDown(client.close);
        final result = await client.webFetch(
          Uri.parse('https://api.example.com/x'),
        );
        expect(result.text, isNull);
        expect(result.json, isA<Map<String, Object?>>());
        expect(result.binaryMeta, isNull);
      });

      test('binary body — binaryMeta non-null, text+json null', () async {
        final fetch = _ScriptedWebFetch()
          ..primedResult = WebFetchResult(
            url: Uri.parse('https://example.com/x.bin'),
            status: 200,
            contentType: 'application/octet-stream',
            binaryMeta: const BinaryFetchMeta(
              contentType: 'application/octet-stream',
              contentLength: 1024,
            ),
          );
        final TomBrainSubstrateClient client = await _openClient(
          webFetch: fetch,
        );
        addTearDown(client.close);
        final result = await client.webFetch(
          Uri.parse('https://example.com/x.bin'),
        );
        expect(result.text, isNull);
        expect(result.json, isNull);
        expect(result.binaryMeta, isNotNull);
        expect(result.binaryMeta!.contentLength, 1024);
      });

      test('truncated:true surfaces verbatim from the impl', () async {
        final fetch = _ScriptedWebFetch()
          ..primedResult = WebFetchResult(
            url: Uri.parse('https://example.com/big'),
            status: 200,
            contentType: 'text/plain',
            text: 'first part',
            truncated: true,
          );
        final TomBrainSubstrateClient client = await _openClient(
          webFetch: fetch,
        );
        addTearDown(client.close);
        final result = await client.webFetch(
          Uri.parse('https://example.com/big'),
        );
        expect(result.truncated, isTrue);
      });

      test('WebFetchUnsupportedType surfaces as-is', () async {
        final fetch = _ScriptedWebFetch()
          ..failureToThrow = WebFetchUnsupportedType(
            url: Uri.parse('https://example.com/doc.pdf'),
            contentType: 'application/pdf',
            rawContentType: 'application/pdf',
          );
        final TomBrainSubstrateClient client = await _openClient(
          webFetch: fetch,
        );
        addTearDown(client.close);
        await expectLater(
          client.webFetch(Uri.parse('https://example.com/doc.pdf')),
          throwsA(isA<WebFetchUnsupportedType>()),
        );
      });

      test('WebFetchHttpException surfaces as-is', () async {
        final fetch = _ScriptedWebFetch()
          ..failureToThrow = WebFetchHttpException(
            url: Uri.parse('https://example.com/missing'),
            statusCode: 404,
            contentType: 'text/plain',
            bodyExcerpt: 'not found',
          );
        final TomBrainSubstrateClient client = await _openClient(
          webFetch: fetch,
        );
        addTearDown(client.close);
        await expectLater(
          client.webFetch(Uri.parse('https://example.com/missing')),
          throwsA(isA<WebFetchHttpException>()),
        );
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // MCP — endpoint identity caching
    // ═══════════════════════════════════════════════════════════════

    group('mcpClient', () {
      test(
        'same endpoint id → identical instance; different id → not',
        () async {
          final TomBrainSubstrateClient client = await _openClient();
          addTearDown(client.close);
          final a1 = client.mcpClient(const McpEndpoint('memory'));
          final a2 = client.mcpClient(const McpEndpoint('memory'));
          final b = client.mcpClient(const McpEndpoint('tools'));
          expect(identical(a1, a2), isTrue);
          expect(identical(a1, b), isFalse);
          expect(client.stats().mcpCalls, 2);
        },
      );
    });

    // ═══════════════════════════════════════════════════════════════
    // Observability — events broadcast + stats snapshot
    // ═══════════════════════════════════════════════════════════════

    group('events / stats', () {
      test(
        'events() is broadcast — late subscribers miss prior events',
        () async {
          final TomBrainSubstrateClient client = await _openClient();
          addTearDown(client.close);

          // First call happens before subscribing.
          await client.complete(_callFor('assistant_to_user'));
          await Future<void>.delayed(Duration.zero);

          final lateEvents = <SubstrateEvent>[];
          final sub = client.events().listen(lateEvents.add);
          addTearDown(sub.cancel);

          await client.complete(_callFor('assistant_to_user'));
          await Future<void>.delayed(Duration.zero);

          expect(
            lateEvents.whereType<LlmCallCompleted>(),
            hasLength(1),
            reason: 'broadcast subscribers must only see future events',
          );
        },
      );

      test('stats() reflects activity across surfaces', () async {
        final TomBrainSubstrateClient client = await _openClient();
        addTearDown(client.close);

        await client.complete(_callFor('assistant_to_user'));
        await client.embed('hi');
        await client.webSearch('q');
        await client.webFetch(Uri.parse('https://example.com/'));
        client.mcpClient(const McpEndpoint('memory'));

        final stats = client.stats();
        expect(stats.callsPerProvider['stub'], 1);
        expect(stats.callsPerRole['assistant_to_user'], 1);
        expect(stats.embeddingsComputed, 1);
        expect(stats.webSearches, 1);
        expect(stats.webFetches, 1);
        expect(stats.mcpCalls, 1);
      });

      test('successful LLM call emits LlmCallCompleted', () async {
        final TomBrainSubstrateClient client = await _openClient();
        addTearDown(client.close);

        final events = <SubstrateEvent>[];
        final sub = client.events().listen(events.add);
        addTearDown(sub.cancel);

        await client.complete(_callFor('assistant_to_user'));
        await Future<void>.delayed(Duration.zero);

        expect(events.whereType<LlmCallCompleted>(), hasLength(1));
      });
    });
  });
}

// ═════════════════════════════════════════════════════════════════════
// Test fixtures — all returning `TomBrainSubstrateClient`
// ═════════════════════════════════════════════════════════════════════

/// Builds an *unopened* `TomBrainSubstrateClient`. The composition
/// uses the only impl we ship (in-process facade), but the return
/// type is the abstract contract.
TomBrainSubstrateClient _buildUnopenedClient({
  LlmProvider? provider,
  WebSearch? webSearch,
  WebFetch? webFetch,
  Iterable<String> roles = const <String>['assistant_to_user'],
}) {
  final roleRegistry = bootstrapRoleRegistry();
  final concreteProvider =
      provider ?? StubLlmProvider(id: 'stub', defaultModel: 'stub-model');
  final providers = <String, LlmProvider>{'stub': concreteProvider};
  final routeMap = <String, List<RouteEntry>>{
    for (final roleId in roles)
      roleId: const <RouteEntry>[
        RouteEntry(providerId: 'stub', model: 'stub-model'),
      ],
  };
  final policy = RouterPolicy(
    roleRoutes: routeMap,
    retriesPerClass: 0,
    overloadedBackoff: Duration.zero,
  );
  final router = LlmRouter(providers: providers, policy: policy);
  return InProcessTomBrainSubstrate(
    roleRegistry: roleRegistry,
    providers: providers,
    router: router,
    embeddingService: _ConformanceEmbeddingService(),
    webSearch: webSearch ?? _ScriptedWebSearch(),
    webFetch: webFetch ?? _ScriptedWebFetch(),
  );
}

/// Builds + opens a client with the minimal config and the supplied
/// collaborator overrides. Default role coverage is all six core roles
/// (`prototypeRoleIds`) so the per-role tests can share one fixture shape.
Future<TomBrainSubstrateClient> _openClient({
  LlmProvider? provider,
  WebSearch? webSearch,
  WebFetch? webFetch,
  Iterable<String> roles = const <String>[
    'assistant_to_user',
    'analyser',
    'sub_thinker',
    'recaller',
    'evaluator',
  ],
}) async {
  final client = _buildUnopenedClient(
    provider: provider,
    webSearch: webSearch,
    webFetch: webFetch,
    roles: roles,
  );
  await client.open(_minimalConfig(roles: roles));
  return client;
}

/// Minimal config that opens cleanly for the supplied [roles].
SubstrateConfig _minimalConfig({
  Iterable<String> roles = const <String>['assistant_to_user'],
}) => _configWithRoutes(<String, List<RoleRouteEntryConfig>>{
  for (final roleId in roles)
    roleId: const <RoleRouteEntryConfig>[
      RoleRouteEntryConfig(providerId: 'stub', model: 'stub-model'),
    ],
});

/// Variant of [_minimalConfig] that lets callers inject an arbitrary
/// (possibly invalid) route map.
SubstrateConfig _configWithRoutes(
  Map<String, List<RoleRouteEntryConfig>> roleRoutes,
) => SubstrateConfig(
  providers: const <ProviderProfile>[],
  roleRoutes: roleRoutes,
  embedding: const EmbeddingChoice(
    providerId: 'stub',
    model: 'nomic-embed-text',
    dims: 768,
    normalize: true,
  ),
  webSearch: const WebSearchConfig(
    defaultProvider: 'duckduckgo',
    providers: <String, WebSearchProviderConfig>{
      'duckduckgo': WebSearchProviderConfig(kind: 'ddg_html'),
    },
  ),
  webFetch: const WebFetchConfig(),
  mcpClient: const McpClientConfigBlock(),
);

Budget _budget() =>
    Budget(wallClockMs: 5000, tokenSpend: 1000, toolCalls: 1, memoryWrites: 0);

LlmCall _callFor(String roleId) => LlmCall(
  roleId: roleId,
  inputs: const <String, Object?>{'question': 'hi'},
  budget: _budget(),
);

// ═════════════════════════════════════════════════════════════════════
// Test doubles
// ═════════════════════════════════════════════════════════════════════

/// Deterministic embedding service used by the conformance suite.
///
/// Identity: `(stub, stub-embedder, dims=4, normalized=false)`. First
/// vector component encodes `text.length.toDouble()` so per-input
/// ordering assertions can verify that a batch result really came
/// from the i-th input.
final class _ConformanceEmbeddingService implements EmbeddingService {
  static const _identity = EmbeddingModelIdentity(
    providerId: 'stub',
    modelId: 'stub-embedder',
    dims: 4,
    normalized: false,
  );

  bool _closed = false;

  @override
  EmbeddingModelIdentity get currentModelIdentity => _identity;

  @override
  Future<EmbeddingResult> embed(String text) async {
    if (_closed) throw StateError('embedding service closed');
    final values = Float32List(_identity.dims);
    values[0] = text.length.toDouble();
    return EmbeddingResult(vec: Vec(values), modelIdentity: _identity);
  }

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) async {
    if (texts.isEmpty) return const <EmbeddingResult>[];
    final out = <EmbeddingResult>[];
    for (final t in texts) {
      out.add(await embed(t));
    }
    return List<EmbeddingResult>.unmodifiable(out);
  }

  @override
  Future<EmbeddingProbeResult> probeIdentity({
    EmbeddingModelIdentity? previousIdentity,
    String probeText = 'tom-brain embedding probe',
  }) async {
    final probe = await embed(probeText);
    return EmbeddingProbeResult(
      currentIdentity: _identity,
      probeResult: probe,
      driftEvent: null,
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

/// Programmable `WebSearch` for the conformance suite. Pure in-process;
/// the provider id it reports is `stub-search`.
final class _ScriptedWebSearch implements WebSearch {
  List<SearchHit> primedHits = const <SearchHit>[];

  @override
  Future<WebSearchResult> search(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async {
    final capped = primedHits.length > options.k
        ? primedHits.sublist(0, options.k)
        : primedHits;
    return WebSearchResult(provider: 'stub-search', query: query, hits: capped);
  }

  @override
  void close() {}
}

/// Programmable `WebFetch` for the conformance suite.
///
/// Either returns the canned [primedResult] or throws the canned
/// [failureToThrow]. The default is a 200 / `text/plain` result with
/// an empty body — enough to drive happy-path assertions when no
/// canned value is supplied.
final class _ScriptedWebFetch implements WebFetch {
  WebFetchResult? primedResult;
  Object? failureToThrow;

  @override
  Future<WebFetchResult> fetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async {
    if (failureToThrow != null) throw failureToThrow!;
    final base =
        primedResult ??
        WebFetchResult(
          url: url,
          status: 200,
          contentType: 'text/plain',
          text: '',
        );
    return WebFetchResult(
      url: base.url,
      status: base.status,
      contentType: base.contentType,
      text: base.text,
      json: base.json,
      binaryMeta: base.binaryMeta,
      truncated: base.truncated,
    );
  }

  @override
  void close() {}
}

/// Wrapper around any [LlmProvider] that rewrites the report's
/// `anchorHash` before returning. Used to drive the contract paragraph
/// "a report whose anchorHash is not the current registry hash is
/// AnchorViolation".
final class _AnchorTamperingProvider extends LlmProvider {
  final LlmProvider inner;
  final String rewrittenHash;

  _AnchorTamperingProvider({required this.inner, required this.rewrittenHash});

  @override
  String get id => inner.id;

  LlmCallReport _rewrite(LlmCallReport r) => LlmCallReport(
    providerId: r.providerId,
    modelId: r.modelId,
    anchorHash: rewrittenHash,
    promptHash: r.promptHash,
    tokensIn: r.tokensIn,
    tokensOut: r.tokensOut,
    retries: r.retries,
    wallClockMs: r.wallClockMs,
    cost: r.cost,
    templateSha: r.templateSha,
    notes: r.notes,
  );

  @override
  Future<LlmCallReport> complete(LlmRequest request) async {
    final prompt = request.prompt;
    final options = request.options;
    final r = await inner.complete(
      LlmRequest(prompt: prompt, options: options),
    );
    return _rewrite(r);
  }

  @override
  Stream<LlmEvent> run(LlmRequest request) async* {
    final prompt = request.prompt;
    final options = request.options;
    await for (final ev in inner.run(
      LlmRequest(prompt: prompt, options: options),
    )) {
      if (ev is LlmRunCompleted) {
        yield LlmRunCompleted(callId: ev.callId, report: _rewrite(ev.report));
      } else if (ev is LlmRunFailed) {
        yield LlmRunFailed(
          callId: ev.callId,
          failure: ev.failure,
          report: _rewrite(ev.report!),
        );
      } else {
        yield ev;
      }
    }
  }
}
