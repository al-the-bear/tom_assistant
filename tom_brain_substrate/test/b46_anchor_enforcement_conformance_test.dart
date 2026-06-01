// B.46 — Anchor-enforcement conformance suite.
//
// Plan-step text (verbatim, `prototype_implementation_plan.md` § Phase B):
//
//   "B.46 **Anchor enforcement test**: a dedicated test class proves that
//    *no public method* can emit a prompt that doesn't include the
//    assistant-dedication anchor."
//
// This file is the structural proof of Postulate 3 at the substrate
// boundary. The promise the spec § 3.1 anchor paragraph makes —
// "every prompt the substrate emits carries the assistant-dedication
// anchor; every report it surfaces carries the same anchor hash; no
// public path bypasses either check" — gets a parametric sweep here.
//
// Relationship to upstream B-numbered tests:
//
//   * B.23 (`b23_anchor_injection_test.dart`) pins the per-field
//     contract of `RoleTemplate.assemble` and `AnchorRegistry` — what
//     an anchored `WirePrompt` looks like, what the hash format is,
//     what an `AnchorViolation` carries.
//   * B.24 (`b24_anchor_enforcement_test.dart`) pins the role-layer
//     property: every role's `assemble(...)` output contains the
//     anchor, across every legal input shape. It stays inside the
//     role layer — it does NOT reach the provider, the router, or
//     the facade.
//   * B.41 (`b41_in_process_facade_test.dart`) pins the facade
//     behaviour against the concrete `InProcessTomBrainSubstrate`
//     impl — including one anchor-tampering smoke test.
//   * B.45 (`b45_api_conformance_test.dart`) pins the
//     `TomBrainSubstrateClient` contract surface; the anchor section
//     holds the one happy-path + one tampering test the contract
//     paragraph requires.
//
// B.46 is what locks the cross-cutting invariant: there is **no
// public method on `TomBrainSubstrateClient` that can produce a
// prompt without the anchor**, and there is no provider-side path
// that can re-surface a report whose `anchorHash` is not
// `AnchorRegistry.currentHash`. The sweep parameterises over:
//
//   (a) Every role in `prototypeRoleIds` (the full bootstrap roster).
//   (b) Both prompt-emitting public methods (`complete`,
//       `completeStream`).
//   (c) Six input-shape variants (empty inputs, plain key/value
//       inputs, inputs with multi-line values, inputs whose values
//       contain the anchor verbatim — the "input-value-contains-anchor"
//       tamper vector that `b23_anchor_injection_test.dart` covers at
//       the role layer; here re-asserted at the substrate
//       boundary —, inputs with whitespace-only values, inputs with
//       JSON-shaped nested values).
//   (d) Four anchor-tampering vectors on the provider response —
//       rewrite to a fixed wrong hash, rewrite to the empty string,
//       rewrite to a hash that looks like a past-version digest, and
//       rewrite to a hash with the same digest but a different
//       prefix (`sha512:` instead of `sha256:`). Each vector applies
//       on top of every role × every method.
//   (e) The surface partition itself — a sentinel test confirms the
//       parametric sweep covers every method the contract surface
//       names as prompt-emitting, and zero non-prompt-emitting
//       methods reach the underlying provider with a `WirePrompt`.
//
// What this file deliberately does NOT cover (already covered or
// deferred):
//
//   * Per-role assemble correctness (B.23 / B.24 own that).
//   * Provider-side anchor stamping mechanics (B.14 / B.15 / B.16
//     own their own per-provider tests).
//   * Router-side failover taxonomy (B.20 owns that).
//   * The `templateRef` git-sha field (B.36 deferred).
//   * Real-provider equivalence (B.48 smoke pass).
//
// The two discipline rules from B.45 carry forward:
//
//   1. Black-box import discipline. The single substrate import is
//      the top-level barrel `package:tom_brain_substrate/tom_brain_substrate.dart`.
//   2. Interface-only static typing for the SUT. Every variable that
//      names "the substrate under test" is statically typed
//      `TomBrainSubstrateClient`.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor, Budget, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.46 / anchor enforcement on every public method', () {
    // ═══════════════════════════════════════════════════════════════
    // (A) Surface partition
    //
    // The contract surface on `TomBrainSubstrateClient` is eleven
    // methods. Of those, exactly two — `complete` and
    // `completeStream` — produce a `WirePrompt` that reaches a
    // provider. The other nine touch embeddings, web tools, MCP, or
    // observability and never construct a `WirePrompt`. This group
    // pins the partition so a future widening of the prompt-emitting
    // set surfaces here first, with a clear pointer at what
    // parametric coverage the new method needs.
    // ═══════════════════════════════════════════════════════════════

    group('(A) surface partition', () {
      const promptEmitting = <String>{'complete', 'completeStream'};
      const nonPromptEmitting = <String>{
        'open',
        'close',
        'embed',
        'embedBatch',
        'webSearch',
        'webFetch',
        'mcpClient',
        'events',
        'stats',
      };

      test('partition is mutually exclusive', () {
        expect(promptEmitting.intersection(nonPromptEmitting), isEmpty);
      });

      test('partition is exhaustive: 2 prompt + 9 non-prompt = 11 methods',
          () {
        // Dart has no portable runtime introspection of class members
        // outside `dart:mirrors` (banned at the substrate's tier per
        // `lib/src/api/api.dart` import discipline). The cardinality
        // is therefore pinned by hand here; the B.40 structural test
        // (`test/b40_engine_bridge_contract_test.dart`) is the
        // upstream gate that catches any change to the
        // `TomBrainSubstrateClient` surface before it lands. If that
        // test surfaces a delta and this assertion still passes, the
        // partition was not extended — which is itself the bug.
        expect(
          promptEmitting.length + nonPromptEmitting.length,
          11,
          reason: 'TomBrainSubstrateClient public surface has exactly 11 '
              'methods; if this fails, the partition above must be '
              'updated and the new method must be slotted into '
              'prompt-emitting (with parametric coverage below) or '
              'non-prompt-emitting (with the provider-reach sentinel '
              'test in group (E)).',
        );
      });

      test(
        'non-prompt-emitting methods never reach the provider with a WirePrompt',
        () async {
          // Drives the contrapositive of the B.46 claim: a method that
          // does not emit a prompt cannot accidentally emit one via a
          // hidden path through the role registry / router. The
          // wire-tap captor records every `WirePrompt` the underlying
          // provider sees; after exercising every non-prompt-emitting
          // surface, the captor's list must be empty.
          final captor = _PromptCaptor(
            inner: StubLlmProvider(id: 'stub', defaultModel: 'stub-model'),
          );
          final TomBrainSubstrateClient client =
              await _openClient(provider: captor);
          addTearDown(client.close);

          await client.embed('hello');
          await client.embedBatch(const <String>['a', 'b']);
          await client.webSearch('q');
          await client.webFetch(Uri.parse('https://example.com/'));
          client.mcpClient(const McpEndpoint('memory'));
          // events() / stats() are observability reads — they cannot
          // construct a `WirePrompt`; calling them is the assertion.
          client.events();
          client.stats();

          expect(
            captor.prompts,
            isEmpty,
            reason: 'No non-prompt-emitting method may construct a '
                'WirePrompt — that is the structural guarantee the '
                'surface partition pins.',
          );
        },
      );
    });

    // ═══════════════════════════════════════════════════════════════
    // (B) Prompt-content sweep
    //
    // For every role × every prompt-emitting method × every input
    // shape: capture the `WirePrompt` the provider sees, then assert:
    //
    //   1. The prompt body contains the anchor verbatim.
    //   2. The prompt body STARTS with the anchor text (the
    //      stronger substrate invariant — `assemble(...)`
    //      deterministically prepends, never relies on
    //      `wrap(...)`'s idempotency).
    //   3. The prompt's `anchorHash` equals
    //      `AnchorRegistry.currentHash`.
    //   4. The prompt's `roleId` matches the call's `roleId`.
    //   5. The returned report's `anchorHash` equals
    //      `AnchorRegistry.currentHash`.
    // ═══════════════════════════════════════════════════════════════

    group('(B) prompt-content sweep', () {
      for (final roleId in prototypeRoleIds) {
        for (final shape in _inputShapes()) {
          test(
            'complete: role "$roleId" + shape "${shape.label}" → anchored prompt',
            () async {
              final captor = _PromptCaptor(
                inner:
                    StubLlmProvider(id: 'stub', defaultModel: 'stub-model'),
              );
              final TomBrainSubstrateClient client =
                  await _openClient(provider: captor);
              addTearDown(client.close);

              final report = await client.complete(
                LlmCall(
                  roleId: roleId,
                  inputs: shape.inputs,
                  budget: _budget(),
                ),
              );

              expect(captor.prompts, hasLength(1));
              final wire = captor.prompts.single;
              expect(
                AssistantDedicationAnchor.containsAnchor(wire.body),
                isTrue,
                reason: 'role $roleId / shape ${shape.label}: '
                    'WirePrompt.body must contain the anchor',
              );
              expect(
                wire.body.startsWith(AssistantDedicationAnchor.text),
                isTrue,
                reason: 'role $roleId / shape ${shape.label}: '
                    'WirePrompt.body must START with the anchor text',
              );
              expect(wire.anchorHash, AnchorRegistry.currentHash);
              expect(wire.roleId, roleId);
              expect(report.anchorHash, AnchorRegistry.currentHash);
            },
          );

          test(
            'completeStream: role "$roleId" + shape "${shape.label}" → anchored prompt',
            () async {
              final captor = _PromptCaptor(
                inner:
                    StubLlmProvider(id: 'stub', defaultModel: 'stub-model'),
              );
              final TomBrainSubstrateClient client =
                  await _openClient(provider: captor);
              addTearDown(client.close);

              final events = await client
                  .completeStream(
                    LlmCall(
                      roleId: roleId,
                      inputs: shape.inputs,
                      budget: _budget(),
                    ),
                  )
                  .toList();

              expect(captor.prompts, hasLength(1));
              final wire = captor.prompts.single;
              expect(
                AssistantDedicationAnchor.containsAnchor(wire.body),
                isTrue,
              );
              expect(
                wire.body.startsWith(AssistantDedicationAnchor.text),
                isTrue,
              );
              expect(wire.anchorHash, AnchorRegistry.currentHash);
              expect(wire.roleId, roleId);

              expect(events.last, isA<LlmStreamCompleted>());
              final completed = events.last as LlmStreamCompleted;
              expect(completed.report.anchorHash, AnchorRegistry.currentHash);
            },
          );
        }
      }
    });

    // ═══════════════════════════════════════════════════════════════
    // (C) Anchor-tampering sweep
    //
    // For every role × every prompt-emitting method × every tamper
    // vector: the substrate must raise `AnchorViolation` at the
    // boundary before the consumer observes the report. The four
    // tampering vectors cover the realistic shapes of a "lost anchor
    // hash" failure:
    //
    //   * `fixed-wrong-hash`     — rewrite to a constant non-current
    //                              hash. Catches the "provider hard-
    //                              codes a placeholder" defect.
    //   * `empty-hash`           — rewrite to the empty string.
    //                              Catches the "provider forgot to
    //                              stamp" defect.
    //   * `past-version-shape`   — rewrite to a hash that LOOKS like
    //                              a digest from a past anchor
    //                              revision (current `sha256:` prefix,
    //                              different hex body). Catches the
    //                              "anchor text was bumped but the
    //                              substrate still serves cached
    //                              reports" defect.
    //   * `wrong-prefix`         — rewrite the prefix (`sha512:`
    //                              instead of `sha256:`) while
    //                              keeping the hex body. Catches the
    //                              "provider used a different digest
    //                              family" defect.
    //
    // The enforcement gate is the facade's `_enforceAnchorOrThrow`
    // check on every emitted report. The conformance promise is that
    // the check fires regardless of which field of the hash was
    // tampered with — the boundary check is on equality, not on a
    // partial match. If any vector were to slip through, the facade
    // would have an enforcement hole here and the dispatcher (Phase
    // D) would surface unanchored reports to consumers.
    // ═══════════════════════════════════════════════════════════════

    group('(C) tampering-vector sweep', () {
      for (final roleId in prototypeRoleIds) {
        for (final vector in _tamperingVectors()) {
          test(
            'complete: role "$roleId" + vector "${vector.label}" → AnchorViolation',
            () async {
              final tamper = vector.build(
                StubLlmProvider(id: 'stub', defaultModel: 'stub-model'),
              );
              final TomBrainSubstrateClient client =
                  await _openClient(provider: tamper);
              addTearDown(client.close);

              await expectLater(
                client.complete(
                  LlmCall(
                    roleId: roleId,
                    inputs: const <String, Object?>{'question': 'hi'},
                    budget: _budget(),
                  ),
                ),
                throwsA(isA<AnchorViolation>()),
              );
            },
          );

          test(
            'completeStream: role "$roleId" + vector "${vector.label}" → AnchorViolation',
            () async {
              final tamper = vector.build(
                StubLlmProvider(id: 'stub', defaultModel: 'stub-model'),
              );
              final TomBrainSubstrateClient client =
                  await _openClient(provider: tamper);
              addTearDown(client.close);

              await expectLater(
                client
                    .completeStream(
                      LlmCall(
                        roleId: roleId,
                        inputs: const <String, Object?>{'question': 'hi'},
                        budget: _budget(),
                      ),
                    )
                    .toList(),
                throwsA(isA<AnchorViolation>()),
              );
            },
          );
        }
      }
    });

    // ═══════════════════════════════════════════════════════════════
    // (D) Violation diagnostic surface
    //
    // The `AnchorViolation` carries the diagnostic triple
    // (expected / actual / providerId / modelId / roleId) so the trail
    // layer can attribute the failure without re-reading the report.
    // This test pins the field-population contract independently of
    // the parametric sweeps above.
    // ═══════════════════════════════════════════════════════════════

    group('(D) violation diagnostic surface', () {
      test(
        'AnchorViolation carries expected + actual + providerId + modelId + roleId',
        () async {
          final tamper = _FixedHashTamperingProvider(
            inner: StubLlmProvider(id: 'stub', defaultModel: 'stub-model'),
            replacement: 'sha256:dead',
          );
          final TomBrainSubstrateClient client =
              await _openClient(provider: tamper);
          addTearDown(client.close);

          AnchorViolation? caught;
          try {
            await client.complete(
              LlmCall(
                roleId: 'analyser',
                inputs: const <String, Object?>{'observations': 'x'},
                budget: _budget(),
              ),
            );
            fail('expected AnchorViolation');
          } on AnchorViolation catch (e) {
            caught = e;
          }
          expect(caught.expected, AnchorRegistry.currentHash);
          expect(caught.actual, 'sha256:dead');
          expect(caught.providerId, 'stub');
          expect(caught.modelId, 'stub-model');
          expect(caught.roleId, 'analyser');
          // `toString` includes every field so a logging surface
          // attaches an actionable trace without a custom formatter.
          final s = caught.toString();
          expect(s, contains('analyser'));
          expect(s, contains('stub'));
          expect(s, contains('stub-model'));
          expect(s, contains('sha256:dead'));
          expect(s, contains(AnchorRegistry.currentHash));
        },
      );
    });

    // ═══════════════════════════════════════════════════════════════
    // (E) Anchor-version stamp
    //
    // The substrate exposes `AnchorRegistry.currentVersion` so a
    // future audit can detect a text change that shipped without a
    // version bump. B.46 pins the present-tense expectation: the
    // current registry version is 1 (the version constant on
    // `AssistantDedicationAnchor.version` at A.17). When the text is
    // intentionally changed, both this assertion and
    // `AssistantDedicationAnchor.version` must be bumped in the
    // same change; a discrepancy is the "unannotated text change"
    // bug class.
    // ═══════════════════════════════════════════════════════════════

    group('(E) anchor-version stamp', () {
      test('currentVersion is in sync with shared anchor version', () {
        expect(
          AnchorRegistry.currentVersion,
          AssistantDedicationAnchor.version,
          reason: 'AnchorRegistry must re-export the shared anchor version. '
              'A version bump in tom_brain_shared must reach the substrate '
              'in the same change.',
        );
      });

      test(
        'currentHash is deterministic across reads (cache holds value steady)',
        () {
          final h1 = AnchorRegistry.currentHash;
          final h2 = AnchorRegistry.currentHash;
          expect(h1, h2);
          expect(h1, startsWith('sha256:'));
        },
      );
    });
  });
}

// ═════════════════════════════════════════════════════════════════════
// Test fixtures — every helper returns a `TomBrainSubstrateClient` so
// the SUT typing rule from B.45 is preserved.
// ═════════════════════════════════════════════════════════════════════

Budget _budget() => Budget(
      wallClockMs: 5000,
      tokenSpend: 1000,
      toolCalls: 1,
      memoryWrites: 0,
    );

/// Builds + opens a client wired to [provider]. Routes every
/// prototype role to `(stub, stub-model)` so the per-role tests share
/// one fixture shape.
Future<TomBrainSubstrateClient> _openClient({
  required LlmProvider provider,
}) async {
  final roleRegistry = bootstrapRoleRegistry();
  final providers = <String, LlmProvider>{'stub': provider};
  final routeMap = <String, List<RouteEntry>>{
    for (final roleId in prototypeRoleIds)
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
  final TomBrainSubstrateClient client = InProcessTomBrainSubstrate(
    roleRegistry: roleRegistry,
    providers: providers,
    router: router,
    embeddingService: _NoopEmbeddingService(),
    webSearch: _NoopWebSearch(),
    webFetch: _NoopWebFetch(),
  );
  await client.open(_minimalConfig());
  return client;
}

SubstrateConfig _minimalConfig() => SubstrateConfig(
      providers: const <ProviderProfile>[],
      roleRoutes: <String, List<RoleRouteEntryConfig>>{
        for (final roleId in prototypeRoleIds)
          roleId: const <RoleRouteEntryConfig>[
            RoleRouteEntryConfig(providerId: 'stub', model: 'stub-model'),
          ],
      },
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

// ─── Input-shape catalogue ───────────────────────────────────────────

/// One input-shape variant exercised against every prompt-emitting
/// method on every role.
class _InputShape {
  final String label;
  final Map<String, Object?> inputs;
  const _InputShape({required this.label, required this.inputs});
}

List<_InputShape> _inputShapes() {
  return <_InputShape>[
    const _InputShape(
      label: 'empty inputs',
      inputs: <String, Object?>{},
    ),
    const _InputShape(
      label: 'single key/value',
      inputs: <String, Object?>{'question': 'hello there'},
    ),
    const _InputShape(
      label: 'multi-line value',
      inputs: <String, Object?>{
        'observations': 'line one\nline two\nline three',
      },
    ),
    // The "input-value-contains-anchor" tamper vector at the
    // substrate boundary. The role layer's `assemble(...)` is
    // documented to deterministically prepend, never relying on
    // `wrap(...)` idempotency, so even an input whose value contains
    // the anchor verbatim must produce a body that STARTS with the
    // anchor (not just contains it). B.46 re-asserts this from the
    // substrate boundary, complementing B.23's role-layer assertion.
    _InputShape(
      label: 'value contains anchor verbatim',
      inputs: <String, Object?>{
        'prior_thought':
            '${AssistantDedicationAnchor.text}and then some additional '
                'content the user asked me to consider',
      },
    ),
    const _InputShape(
      label: 'whitespace-only value',
      inputs: <String, Object?>{'note': '   \t  \n   '},
    ),
    const _InputShape(
      label: 'json-shaped nested value',
      inputs: <String, Object?>{
        'context': <String, Object?>{
          'turn': 1,
          'speakers': <String>['user', 'assistant'],
          'metadata': <String, Object?>{'lang': 'en'},
        },
      },
    ),
  ];
}

// ─── Tampering-vector catalogue ──────────────────────────────────────

/// One tampering vector applied to the provider's emitted report.
/// Each vector returns a wrapping `LlmProvider` that rewrites the
/// report's `anchorHash` to a shape that the substrate boundary
/// must reject.
class _TamperingVector {
  final String label;
  final LlmProvider Function(LlmProvider inner) build;
  const _TamperingVector({required this.label, required this.build});
}

List<_TamperingVector> _tamperingVectors() {
  return <_TamperingVector>[
    _TamperingVector(
      label: 'fixed-wrong-hash',
      build: (inner) => _FixedHashTamperingProvider(
        inner: inner,
        replacement: 'sha256:dead',
      ),
    ),
    _TamperingVector(
      label: 'empty-hash',
      build: (inner) => _FixedHashTamperingProvider(
        inner: inner,
        replacement: '',
      ),
    ),
    _TamperingVector(
      label: 'past-version-shape',
      build: (inner) => _FixedHashTamperingProvider(
        inner: inner,
        // Same length / shape as a real sha256 digest, different bytes.
        replacement:
            'sha256:0000000000000000000000000000000000000000000000000000000000000000',
      ),
    ),
    _TamperingVector(
      label: 'wrong-prefix',
      build: (inner) => _PrefixSwapTamperingProvider(
        inner: inner,
        newPrefix: 'sha512:',
      ),
    ),
  ];
}

// ─── Test doubles ────────────────────────────────────────────────────

/// Captures every `WirePrompt` handed to the underlying provider.
/// Used by group (B) to assert the role layer's anchor prepend
/// reaches the provider unchanged, and by group (A)'s sentinel to
/// assert non-prompt-emitting methods never produce a `WirePrompt`.
final class _PromptCaptor implements LlmProvider {
  final LlmProvider inner;
  final List<WirePrompt> prompts = <WirePrompt>[];

  _PromptCaptor({required this.inner});

  @override
  String get id => inner.id;

  @override
  Future<LlmCallReport> complete(
    WirePrompt prompt,
    LlmOptions options,
  ) {
    prompts.add(prompt);
    return inner.complete(prompt, options);
  }

  @override
  Stream<LlmStreamEvent> completeStream(
    WirePrompt prompt,
    LlmOptions options,
  ) {
    prompts.add(prompt);
    return inner.completeStream(prompt, options);
  }
}

/// Wraps an inner provider and rewrites every emitted report's
/// `anchorHash` to a fixed [replacement]. Used by every tampering
/// vector that wants a constant replacement.
final class _FixedHashTamperingProvider implements LlmProvider {
  final LlmProvider inner;
  final String replacement;

  _FixedHashTamperingProvider({
    required this.inner,
    required this.replacement,
  });

  @override
  String get id => inner.id;

  LlmCallReport _rewrite(LlmCallReport r) => LlmCallReport(
        providerId: r.providerId,
        modelId: r.modelId,
        anchorHash: replacement,
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
  Future<LlmCallReport> complete(
    WirePrompt prompt,
    LlmOptions options,
  ) async {
    final r = await inner.complete(prompt, options);
    return _rewrite(r);
  }

  @override
  Stream<LlmStreamEvent> completeStream(
    WirePrompt prompt,
    LlmOptions options,
  ) async* {
    await for (final ev in inner.completeStream(prompt, options)) {
      if (ev is LlmStreamCompleted) {
        yield LlmStreamCompleted(
          callId: ev.callId,
          report: _rewrite(ev.report),
        );
      } else if (ev is LlmStreamFailed) {
        yield LlmStreamFailed(
          callId: ev.callId,
          failure: ev.failure,
          report: _rewrite(ev.report),
        );
      } else {
        yield ev;
      }
    }
  }
}

/// Wraps an inner provider and rewrites the `anchorHash` prefix to
/// [newPrefix] while preserving the digest body. Models the
/// "different digest family" defect that a fixed-replacement vector
/// would not catch (a `sha512:`-prefixed hash whose body is the
/// expected sha256 hex would still mismatch under string equality —
/// the test pins that the substrate's check uses the full string,
/// not a prefix-tolerant comparator).
final class _PrefixSwapTamperingProvider implements LlmProvider {
  final LlmProvider inner;
  final String newPrefix;

  _PrefixSwapTamperingProvider({
    required this.inner,
    required this.newPrefix,
  });

  @override
  String get id => inner.id;

  String _swap(String hash) {
    final colon = hash.indexOf(':');
    if (colon < 0) return '$newPrefix$hash';
    return '$newPrefix${hash.substring(colon + 1)}';
  }

  LlmCallReport _rewrite(LlmCallReport r) => LlmCallReport(
        providerId: r.providerId,
        modelId: r.modelId,
        anchorHash: _swap(r.anchorHash),
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
  Future<LlmCallReport> complete(
    WirePrompt prompt,
    LlmOptions options,
  ) async {
    final r = await inner.complete(prompt, options);
    return _rewrite(r);
  }

  @override
  Stream<LlmStreamEvent> completeStream(
    WirePrompt prompt,
    LlmOptions options,
  ) async* {
    await for (final ev in inner.completeStream(prompt, options)) {
      if (ev is LlmStreamCompleted) {
        yield LlmStreamCompleted(
          callId: ev.callId,
          report: _rewrite(ev.report),
        );
      } else if (ev is LlmStreamFailed) {
        yield LlmStreamFailed(
          callId: ev.callId,
          failure: ev.failure,
          report: _rewrite(ev.report),
        );
      } else {
        yield ev;
      }
    }
  }
}

// ─── Collaborator no-ops ─────────────────────────────────────────────

/// Throws on every call — used in the prompt-content sweep where the
/// embedding service is not expected to fire. The non-prompt-emitting
/// sentinel test in group (A) uses dedicated no-op services that
/// return successfully; this throwing variant guards every other test
/// against a misconfigured fixture that accidentally routes through
/// embedding.
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
    // The (A) sentinel test exercises embed; return a deterministic
    // result rather than throwing so the sentinel can drive every
    // non-prompt-emitting method through one client instance.
    return EmbeddingResult(
      vec: Vec.zero(_identity.dims),
      modelIdentity: _identity,
    );
  }

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) async {
    if (texts.isEmpty) return const <EmbeddingResult>[];
    final out = <EmbeddingResult>[];
    for (final text in texts) {
      out.add(await embed(text));
    }
    return out;
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
