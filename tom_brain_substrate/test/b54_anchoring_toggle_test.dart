// B.54 — the per-run **anchoring toggle** (`session_configuration.md` § 3.4,
// plan step 9 / SCP-36…SCP-38).
//
// Postulate 3's dedication anchor is structural and present on *every* prompt by
// default. A small number of profiles (the passthrough relay being the first)
// deliberately run **un-anchored** — a thin OpenAI-format proxy that must not
// inject the assistant persona. This suite pins the toggle that makes that
// possible *without* opening a hole in the default safety lever:
//
//   1. `RoleTemplate.assemble({anchored})` defaults to `anchored: true` and
//      reproduces today's byte-for-byte anchored wire prompt (no regression).
//   2. `assemble(anchored: false)` omits the anchor from the `system` channel
//      entirely — and the toggle is the *only* difference: the anchored system
//      is exactly `anchor.text + unanchoredSystem`, and the two `user` channels
//      are identical.
//   3. An un-anchored prompt carries `AnchorRegistry.unanchoredHash` (a distinct
//      sentinel, never a real `sha256:` digest) so the trail can *flag* the run
//      as un-anchored (logging-spec § 7.1, step 11) instead of silently
//      recording the current anchor hash.
//   4. The facade lets an un-anchored `LlmCall` through enforcement (the report
//      echoes the sentinel, which is accepted *iff* the call asked to be
//      un-anchored), while the default anchored call still proves the anchor.
//
// The anchored-enforcement guarantee for the *default* path stays owned by
// `b23` / `b24` / `b41` / `b46`; this file only adds the un-anchored escape and
// its containment.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  RoleTemplate makeRole({
    String id = 'r',
    String personaText = 'I am the role.',
    String objective = 'Do the role thing.',
    Set<AllowedAction> allowedActions = const {AllowedAction.llmCall},
    Map<String, Object?>? outputSchema,
  }) =>
      RoleTemplate(
        id: id,
        personaText: personaText,
        objective: objective,
        allowedActions: allowedActions,
        outputSchema: outputSchema,
      );

  group('RoleTemplate.assemble anchoring toggle', () {
    test('default (anchored: true) carries the anchor + current hash', () {
      final p = makeRole().assemble();
      expect(p.system.startsWith(AssistantDedicationAnchor.text), isTrue);
      expect(p.anchorHash, equals(AnchorRegistry.currentHash));
    });

    test('anchored: true is byte-identical to the no-arg default', () {
      final inputs = <String, Object?>{'prompt': 'why is the sky blue'};
      final a = makeRole().assemble(inputs: inputs);
      final b = makeRole().assemble(inputs: inputs, anchored: true);
      expect(a.system, equals(b.system));
      expect(a.user, equals(b.user));
      expect(a.anchorHash, equals(b.anchorHash));
    });

    test('anchored: false omits the anchor from the system channel', () {
      final p = makeRole(personaText: 'RELAY-PERSONA')
          .assemble(anchored: false);
      expect(p.system.startsWith(AssistantDedicationAnchor.text), isFalse,
          reason: 'an un-anchored prompt must not lead with the anchor');
      expect(p.system.contains(AssistantDedicationAnchor.text), isFalse,
          reason: 'the anchor must not appear anywhere in an un-anchored system');
      // The persona/objective scaffold is still produced — only the anchor is
      // gone. (The relay still has a role; it just is not dedication-anchored.)
      expect(p.system, startsWith('PERSONA:'));
      expect(p.system, contains('RELAY-PERSONA'));
    });

    test('the toggle is the ONLY difference (anchored == anchor + unanchored)',
        () {
      final inputs = <String, Object?>{'prompt': 'hello', 'k': 'v'};
      final anchored = makeRole().assemble(inputs: inputs);
      final unanchored = makeRole().assemble(inputs: inputs, anchored: false);
      // System differs by exactly the leading anchor block, nothing else.
      expect(
        anchored.system,
        equals('${AssistantDedicationAnchor.text}${unanchored.system}'),
        reason: 'stripping the anchor lead from the anchored system must yield '
            'the un-anchored system verbatim',
      );
      // User channel is anchor-independent: identical for both.
      expect(unanchored.user, equals(anchored.user));
      expect(unanchored.roleId, equals(anchored.roleId));
    });

    test('un-anchored anchorHash is the distinct unanchored sentinel', () {
      final p = makeRole().assemble(anchored: false);
      expect(p.anchorHash, equals(AnchorRegistry.unanchoredHash));
      expect(p.anchorHash, isNot(equals(AnchorRegistry.currentHash)));
      // Never a real sha256 digest — so a trail reader can tell an un-anchored
      // run apart from any anchored one at a glance (§7.1 auditability).
      expect(p.anchorHash.startsWith('sha256:'), isFalse);
      expect(AnchorRegistry.isCurrent(p.anchorHash), isFalse);
    });
  });

  group('InProcessTomBrainSubstrate anchoring toggle', () {
    test('default anchored call still proves the anchor on the report',
        () async {
      final fx = _buildFacade();
      addTearDown(fx.facade.close);
      final report = await fx.facade.complete(_assistantCall());
      expect(report.anchorHash, equals(AnchorRegistry.currentHash));
    });

    test('un-anchored call passes enforcement and carries the sentinel',
        () async {
      final fx = _buildFacade();
      addTearDown(fx.facade.close);
      final report =
          await fx.facade.complete(_assistantCall(anchored: false));
      // No AnchorViolation thrown; the report echoes the un-anchored sentinel.
      expect(report.anchorHash, equals(AnchorRegistry.unanchoredHash));
    });

    test('un-anchored stream call passes enforcement and completes', () async {
      final fx = _buildFacade();
      addTearDown(fx.facade.close);
      LlmCallReport? completed;
      await for (final event
          in fx.facade.completeStream(_assistantCall(anchored: false))) {
        if (event is LlmStreamCompleted) completed = event.report;
      }
      expect(completed, isNotNull);
      expect(completed!.anchorHash, equals(AnchorRegistry.unanchoredHash));
    });
  });
}

// ─── Test fixtures ────────────────────────────────────────────────

class _FacadeFixture {
  final InProcessTomBrainSubstrate facade;
  _FacadeFixture(this.facade);
}

_FacadeFixture _buildFacade() {
  final roles = bootstrapRoleRegistry();
  final realProvider =
      StubLlmProvider(id: 'stub', defaultModel: 'stub-model');
  final providers = <String, LlmProvider>{'stub': realProvider};
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
    embeddingService: _StubEmbeddingService(),
    webSearch: _StubWebSearch(),
    webFetch: _StubWebFetch(),
  );
  return _FacadeFixture(facade);
}

LlmCall _assistantCall({bool anchored = true}) => LlmCall(
      roleId: 'assistant_to_user',
      inputs: const <String, Object?>{'question': 'hi'},
      anchored: anchored,
      budget: Budget(
        wallClockMs: 5000,
        tokenSpend: 1000,
        toolCalls: 1,
        memoryWrites: 0,
      ),
    );

// ─── Minimal test doubles (mirrors b41's) ─────────────────────────

final class _StubEmbeddingService implements EmbeddingService {
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
    final values = Float32List(_identity.dims);
    return EmbeddingResult(vec: Vec(values), modelIdentity: _identity);
  }

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) async =>
      <EmbeddingResult>[for (final t in texts) await embed(t)];

  @override
  Future<EmbeddingProbeResult> probeIdentity({
    EmbeddingModelIdentity? previousIdentity,
    String probeText = 'tom-brain embedding probe',
  }) async =>
      EmbeddingProbeResult(
        currentIdentity: _identity,
        probeResult: await embed(probeText),
        driftEvent: null,
      );

  @override
  Future<void> close() async {}
}

final class _StubWebSearch implements WebSearch {
  @override
  Future<WebSearchResult> search(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async =>
      WebSearchResult(
        provider: 'stub-search',
        query: query,
        hits: const <SearchHit>[],
      );

  @override
  void close() {}
}

final class _StubWebFetch implements WebFetch {
  @override
  Future<WebFetchResult> fetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async =>
      WebFetchResult(
        url: url,
        status: 200,
        contentType: 'text/plain',
        text: '',
      );

  @override
  void close() {}
}
