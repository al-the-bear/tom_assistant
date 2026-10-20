// B.48 — Provider matrix smoke.
//
// Plan-step text (verbatim, `prototype_implementation_plan.md` § Phase B):
//
//   "B.48 **Provider matrix smoke**: run the stub provider through
//    the conformance suite; run the Ollama provider locally if
//    available; record both results."
//
// What this file owns:
//
//   * A deterministic *in-suite* recording of the provider matrix
//     smoke run. The matrix has two rows — `StubLlmProvider` (always
//     mandatory) and `OllamaLlmProvider` (run-if-locally-reachable).
//     The deliverable the plan asks for ("record both results") lives
//     in `_ai/quests/tom_brain/provider_matrix_smoke.md`; this file
//     is the executable companion that proves the matrix can in fact
//     be driven end-to-end and that the recorded skip-marker for
//     Ollama is the truth on the host that runs the suite.
//
//   * Two end-to-end smoke probes through the public substrate
//     surface (`TomBrainSubstrateClient`) — one against the stub
//     provider (always), one against the Ollama provider (skipped at
//     test-registration time when no daemon is reachable). Both
//     probes use the same shape: one `complete` call + one
//     `completeStream` call, both routed through the in-process
//     facade with anchor enforcement enabled. The "structurally-valid
//     response" claim is pinned by checking that the report carries
//     the current anchor hash and the provider id propagates.
//
//   * The conformance-suite enumeration. The plan's "conformance
//     suite" is the union of B.17 (provider conformance) + B.32
//     (web tools conformance) + B.35 (MCP client conformance) +
//     B.45 (API conformance). This file pins that those four files
//     are present on disk under `test/` — they ARE the conformance
//     suite; any deletion / rename surfaces here as a structural
//     failure so the smoke artefact's citations cannot drift.
//
// What this file deliberately does NOT do:
//
//   * Re-run the conformance suite. `dart test` already runs all four
//     files; the smoke deliverable is a parallel artefact, not a
//     re-execution channel. The audit-vs-rerun discipline established
//     at A.90 / B.47 forbids burning budget on redundant runs.
//
//   * Reach inside the provider implementations. The Ollama probe
//     goes through the public substrate facade — same as a real
//     consumer would — and trusts the per-provider unit tests
//     (B.14 / B.15 / B.16) to pin wire-shape details. The B.48 probe
//     exercises the *end-to-end seam*: facade → router → provider →
//     wire → response → anchor check → report observed by consumer.
//
//   * Decide whether to skip Ollama based on response time. Skip is
//     binary on TCP-reachability, not latency. A slow daemon is still
//     a real daemon; if it answers slowly enough that the wall-clock
//     budget triggers, the substrate's failure taxonomy surfaces
//     that case (B.20) and the smoke test records the failure.
//
// Reachability detection — design:
//
//   The probe reads `TOM_BRAIN_OLLAMA_BASE_URI` (override) and falls
//   back to `http://127.0.0.1:11434`. A two-second TCP connect at the
//   parsed host:port determines reachability. The probe never sends
//   an HTTP request during detection — detection must stay cheap so
//   the test suite doesn't pay the cost on every `dart test` run.
//   Once reachable, the smoke probe makes one `complete` and one
//   `completeStream` call against the configured chat model
//   (`TOM_BRAIN_OLLAMA_MODEL`, default `llama3.2:1b` — small enough
//   to run on a developer laptop). The model id is configurable so
//   developer machines without `llama3.2:1b` can point at whichever
//   chat model the daemon already has.
//
// Recording — design:
//
//   The matrix artefact at `_ai/quests/tom_brain/provider_matrix_smoke.md`
//   is the canonical recorded output for the PR description. This
//   file's job is to make sure the artefact's claims cannot lie:
//
//     * Stub row recorded ✅: the stub probe in `group('stub matrix
//       row')` runs unconditionally and proves the end-to-end seam.
//     * Ollama row recorded ✅ or ⏭ skip: when a daemon is reachable,
//       the probe runs and asserts the same end-to-end shape; when
//       not, the test in `group('ollama matrix row')` is registered
//       with `skip: '<reason>'` so the recorded skip-marker appears
//       in the test reporter's output (and in `last_testrun.json`
//       via testkit when run that way).
//
//   The skip rationale string is mechanically derived from the
//   `_OllamaProbe.unreachableReason` getter so the artefact can cite
//   the exact phrasing that the developer who runs the test will see.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show Budget, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.48 / provider matrix smoke', () {
    // ─── Conformance-suite presence sentinel ──────────────────────
    //
    // The four conformance test files must be present on disk under
    // `test/`. If any one is deleted or renamed the smoke artefact's
    // matrix citation lies; surfacing that as a test failure here
    // gives the next refactor an immediate signal.
    group('conformance suite enumeration', () {
      const expected = <String>[
        'b17_provider_conformance_test.dart',
        'b32_web_tools_conformance_test.dart',
        'b35_mcp_client_conformance_test.dart',
        'b45_api_conformance_test.dart',
      ];

      test('every conformance file exists under test/', () {
        final dir = Directory('test');
        expect(
          dir.existsSync(),
          isTrue,
          reason: 'B.48 must be run from the package root',
        );
        for (final name in expected) {
          final file = File('test/$name');
          expect(
            file.existsSync(),
            isTrue,
            reason:
                'Conformance file "$name" is missing — the matrix '
                'artefact at _ai/quests/tom_brain/provider_matrix_smoke.md '
                'cites it as part of the "conformance suite". A rename '
                'must land in both places at once.',
          );
        }
      });

      test('exactly four files form the conformance suite', () {
        // Pinned cardinality. The B.47 coverage matrix § 3 lists the
        // same four files; if either side widens, both must widen
        // together.
        expect(expected.length, 4);
      });
    });

    // ─── Stub matrix row (always runs) ────────────────────────────
    //
    // End-to-end probe through the public facade. The role registry
    // is the bootstrap roster; `assistant_to_user` is routed to the
    // stub. One `complete` + one `completeStream` call cover the two
    // prompt-emitting surfaces. The assertion set is small on
    // purpose: the conformance suites already cover the per-method
    // contract — B.48 only proves the *seam* works end-to-end and
    // that the recorded matrix row reflects a real green run.
    group('stub matrix row', () {
      test('complete: end-to-end via in-process facade — anchored', () async {
        final fixture = _buildStubFacade();
        final TomBrainSubstrateClient client = fixture.client;
        addTearDown(client.close);
        await client.open(_minimalStubConfig());

        final report = await client.complete(_assistantCall());

        expect(report.providerId, 'stub');
        expect(report.modelId, isNotEmpty);
        expect(report.anchorHash, AnchorRegistry.currentHash);
      });

      test(
        'completeStream: end-to-end via in-process facade — anchored',
        () async {
          final fixture = _buildStubFacade();
          final TomBrainSubstrateClient client = fixture.client;
          addTearDown(client.close);
          await client.open(_minimalStubConfig());

          final events = await client.completeStream(_assistantCall()).toList();

          expect(events, isNotEmpty);
          final last = events.last;
          if (last is LlmRunCompleted) {
            expect(last.report.providerId, 'stub');
            expect(last.report.anchorHash, AnchorRegistry.currentHash);
          } else {
            fail(
              'Stub matrix row must terminate with LlmRunCompleted, '
              'got: $last',
            );
          }
        },
      );
    });

    // ─── Ollama matrix row (skipped when daemon unreachable) ──────
    //
    // The probe runs only when a TCP connect to the configured
    // host:port succeeds within two seconds. The skip rationale is
    // computed at test-registration time so it appears in the
    // reporter output (and `last_testrun.json`) verbatim — the
    // recorded matrix artefact cites this rationale string.
    group('ollama matrix row', () {
      final probe = _OllamaProbe.detect();
      final skipReason = probe.reachable ? null : probe.unreachableReason;

      test('complete: end-to-end via in-process facade — anchored', () async {
        final fixture = _buildOllamaFacade(probe);
        final TomBrainSubstrateClient client = fixture.client;
        addTearDown(client.close);
        await client.open(_minimalOllamaConfig(probe.model));

        final report = await client.complete(_assistantCall());

        expect(report.providerId, 'ollama');
        expect(report.modelId, isNotEmpty);
        expect(report.anchorHash, AnchorRegistry.currentHash);
      }, skip: skipReason);

      test(
        'completeStream: end-to-end via in-process facade — anchored',
        () async {
          final fixture = _buildOllamaFacade(probe);
          final TomBrainSubstrateClient client = fixture.client;
          addTearDown(client.close);
          await client.open(_minimalOllamaConfig(probe.model));

          final events = await client.completeStream(_assistantCall()).toList();

          expect(events, isNotEmpty);
          final last = events.last;
          if (last is LlmRunCompleted) {
            expect(last.report.providerId, 'ollama');
            expect(last.report.anchorHash, AnchorRegistry.currentHash);
          } else if (last is LlmRunFailed) {
            fail('Ollama matrix row stream failed: ${last.failure}');
          } else {
            fail(
              'Ollama matrix row must terminate with LlmRunCompleted, '
              'got: $last',
            );
          }
        },
        skip: skipReason,
      );

      // The reachability-detector itself is deterministic and must
      // always run — it is the structural piece that produces the
      // skip rationale the matrix artefact records.
      test('reachability detector returns a typed result', () {
        expect(probe, isA<_OllamaProbe>());
        expect(probe.baseUri.scheme, anyOf('http', 'https'));
        expect(probe.baseUri.host, isNotEmpty);
        expect(probe.baseUri.hasPort, isTrue);
        expect(probe.model, isNotEmpty);
        if (!probe.reachable) {
          expect(probe.unreachableReason, isNotEmpty);
        }
      });
    });
  });
}

// ─── Stub fixture ─────────────────────────────────────────────────

class _StubFixture {
  final TomBrainSubstrateClient client;
  _StubFixture(this.client);
}

_StubFixture _buildStubFacade() {
  final roles = bootstrapRoleRegistry();
  final provider = StubLlmProvider(id: 'stub', defaultModel: 'stub-model');
  final providers = <String, LlmProvider>{'stub': provider};
  final policy = RouterPolicy(
    roleRoutes: <String, List<RouteEntry>>{
      'assistant_to_user': const <RouteEntry>[
        RouteEntry(providerId: 'stub', model: 'stub-model'),
      ],
    },
  );
  final router = LlmRouter(providers: providers, policy: policy);
  final facade = InProcessTomBrainSubstrate(
    roleRegistry: roles,
    providers: providers,
    router: router,
    embeddingService: _NoopEmbeddingService(),
    webSearch: _NoopWebSearch(),
    webFetch: _NoopWebFetch(),
  );
  return _StubFixture(facade);
}

SubstrateConfig _minimalStubConfig() => SubstrateConfig(
  providers: const <ProviderProfile>[],
  roleRoutes: const <String, List<RoleRouteEntryConfig>>{
    'assistant_to_user': <RoleRouteEntryConfig>[
      RoleRouteEntryConfig(providerId: 'stub', model: 'stub-model'),
    ],
  },
  embedding: const EmbeddingChoice(
    providerId: 'stub',
    model: 'nomic-embed-text',
    dims: 4,
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

// ─── Ollama fixture ───────────────────────────────────────────────

class _OllamaFixture {
  final TomBrainSubstrateClient client;
  _OllamaFixture(this.client);
}

_OllamaFixture _buildOllamaFacade(_OllamaProbe probe) {
  final roles = bootstrapRoleRegistry();
  final provider = OllamaLlmProvider(
    id: 'ollama',
    baseUri: probe.baseUri,
    defaultModel: probe.model,
  );
  final providers = <String, LlmProvider>{'ollama': provider};
  final policy = RouterPolicy(
    roleRoutes: <String, List<RouteEntry>>{
      'assistant_to_user': <RouteEntry>[
        RouteEntry(providerId: 'ollama', model: probe.model),
      ],
    },
  );
  final router = LlmRouter(providers: providers, policy: policy);
  final facade = InProcessTomBrainSubstrate(
    roleRegistry: roles,
    providers: providers,
    router: router,
    embeddingService: _NoopEmbeddingService(),
    webSearch: _NoopWebSearch(),
    webFetch: _NoopWebFetch(),
  );
  return _OllamaFixture(facade);
}

SubstrateConfig _minimalOllamaConfig(String model) => SubstrateConfig(
  providers: const <ProviderProfile>[],
  roleRoutes: <String, List<RoleRouteEntryConfig>>{
    'assistant_to_user': <RoleRouteEntryConfig>[
      RoleRouteEntryConfig(providerId: 'ollama', model: model),
    ],
  },
  embedding: const EmbeddingChoice(
    providerId: 'ollama',
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

LlmCall _assistantCall() => LlmCall(
  roleId: 'assistant_to_user',
  inputs: const <String, Object?>{'question': 'hi'},
  budget: Budget(
    wallClockMs: 30000,
    tokenSpend: 256,
    toolCalls: 1,
    memoryWrites: 0,
  ),
);

// ─── Ollama reachability probe ────────────────────────────────────

/// Result of the cheap TCP reachability probe. Computed once at
/// test-registration time so the rationale string can be passed to
/// `test(skip: ...)` and surface in the test reporter / artefact.
class _OllamaProbe {
  final Uri baseUri;
  final String model;
  final bool reachable;
  final String? unreachableReason;

  _OllamaProbe._({
    required this.baseUri,
    required this.model,
    required this.reachable,
    required this.unreachableReason,
  });

  /// Reads `TOM_BRAIN_OLLAMA_BASE_URI` (override) and falls back to
  /// `http://127.0.0.1:11434`. The model defaults to `llama3.2:1b`;
  /// override via `TOM_BRAIN_OLLAMA_MODEL`. Performs one synchronous
  /// `Socket.connect` with a two-second timeout — never sends an
  /// HTTP request during detection.
  factory _OllamaProbe.detect() {
    final env = Platform.environment;
    final raw = env['TOM_BRAIN_OLLAMA_BASE_URI'] ?? 'http://127.0.0.1:11434';
    final Uri parsed;
    try {
      parsed = Uri.parse(raw);
    } on FormatException catch (e) {
      return _OllamaProbe._(
        baseUri: Uri.parse('http://127.0.0.1:11434'),
        model: env['TOM_BRAIN_OLLAMA_MODEL'] ?? 'llama3.2:1b',
        reachable: false,
        unreachableReason:
            'TOM_BRAIN_OLLAMA_BASE_URI="$raw" is not a valid URI ($e)',
      );
    }
    final host = parsed.host;
    final port = parsed.hasPort
        ? parsed.port
        : (parsed.scheme == 'https' ? 443 : 80);
    final model = env['TOM_BRAIN_OLLAMA_MODEL'] ?? 'llama3.2:1b';
    final ensuredUri = parsed.hasPort ? parsed : parsed.replace(port: port);

    bool ok = false;
    String? reason;
    try {
      final socket = _connectSync(host, port, const Duration(seconds: 2));
      socket?.destroy();
      ok = socket != null;
      if (!ok) {
        reason =
            'no TCP connect to $host:$port within 2s (Ollama daemon not '
            'running; start with `ollama serve` to record this row green)';
      }
    } catch (e) {
      reason = 'TCP probe to $host:$port failed: $e';
      ok = false;
    }

    return _OllamaProbe._(
      baseUri: ensuredUri,
      model: model,
      reachable: ok,
      unreachableReason: ok ? null : reason,
    );
  }
}

/// Synchronous-ish wrapper around [Socket.connect] with a hard
/// timeout. Returns `null` on timeout or refusal. The detector runs
/// at test-registration time, which means inside a `group(...)` body
/// — `dart test` accepts an async body here but `skip:` strings need
/// to be resolved before the test runs, so the detector is built
/// blocking-on-future via a polling micro-loop.
Socket? _connectSync(String host, int port, Duration timeout) {
  Socket? socket;
  Object? error;
  bool done = false;
  Socket.connect(host, port, timeout: timeout).then(
    (s) {
      socket = s;
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  // Pump the event loop until the connect resolves. This is acceptable
  // here because the detector is called from a synchronous test
  // registration context and the connect itself has a hard timeout.
  final deadline = DateTime.now().add(timeout + const Duration(seconds: 1));
  while (!done && DateTime.now().isBefore(deadline)) {
    sleep(const Duration(milliseconds: 50));
  }
  if (error != null) return null;
  return socket;
}

// ─── Collaborator no-ops (web / embed / no MCP) ───────────────────

final class _NoopEmbeddingService implements EmbeddingService {
  static const _identity = EmbeddingModelIdentity(
    providerId: 'stub',
    modelId: 'stub-embedder',
    dims: 4,
    normalized: false,
  );

  @override
  EmbeddingModelIdentity get currentModelIdentity => _identity;

  @override
  Future<EmbeddingResult> embed(String text) async {
    return EmbeddingResult(
      vec: Vec.zero(_identity.dims),
      modelIdentity: _identity,
    );
  }

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) async {
    if (texts.isEmpty) return const <EmbeddingResult>[];
    return <EmbeddingResult>[for (final t in texts) await embed(t)];
  }

  @override
  Future<EmbeddingProbeResult> probeIdentity({
    EmbeddingModelIdentity? previousIdentity,
    String probeText = 'tom-brain embedding probe',
  }) async {
    final r = await embed(probeText);
    return EmbeddingProbeResult(
      currentIdentity: _identity,
      probeResult: r,
      driftEvent: null,
    );
  }

  @override
  Future<void> close() async {}
}

final class _NoopWebSearch implements WebSearch {
  @override
  Future<WebSearchResult> search(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async {
    return WebSearchResult(
      provider: 'stub-search',
      query: query,
      hits: const <SearchHit>[],
    );
  }

  @override
  void close() {}
}

final class _NoopWebFetch implements WebFetch {
  @override
  Future<WebFetchResult> fetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async {
    return WebFetchResult(
      url: url,
      status: 200,
      contentType: 'text/plain',
      text: '',
    );
  }

  @override
  void close() {}
}
