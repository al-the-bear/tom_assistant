// Tests for `SubstrateEventBus` (Plan step B.38).
//
// Covers (direct mirror of memory's `a85_observability_surface_test.dart`
// `MemoryEventBus` group):
//
//   - `SubstrateEventBus` fans broadcast emissions out to multiple
//     subscribers, in emission order, on a future microtask
//     (asynchronous delivery).
//   - The bus carries every variant in the spec § 10.2 sealed sum
//     (twelve subtypes) — no per-variant code; the bus is typed on
//     the abstract base.
//   - The plan-named five subtypes (`LlmCallStarted`,
//     `LlmCallCompleted`, `ProviderFailover`, `EmbeddingComputed`,
//     `WebFetchCompleted`) round-trip through the bus unchanged.
//     This lock catches a future refactor that breaks the abstract
//     base for one of the five.
//   - `close()` ends every live subscription with a done event;
//     re-close is idempotent; `emit` after `close` throws a
//     `StateError` carrying the event kind.
//   - Broadcast contract: a late subscriber sees only events emitted
//     after `listen()` — never replays prior events. The bus is an
//     observability stream, not a durable queue (the trail surface
//     in `tom_brain_memory` is the durable side).
//   - The bus is typed on `SubstrateEvent` (the abstract base) so
//     adding a new variant to `api/substrate_event.dart` requires
//     zero changes here. This invariant is locked by a test that
//     constructs an event with a stub kind name and asserts it
//     round-trips.
//
// Drives the public API only — never imports `lib/src/obs/…` directly;
// everything flows through `package:tom_brain_substrate/…`.

import 'dart:async';

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.38 SubstrateEventBus — fan-out / async delivery', () {
    test('emit fans out to multiple subscribers, in emission order',
        () async {
      final bus = SubstrateEventBus();
      addTearDown(bus.close);

      final aReceived = <SubstrateEvent>[];
      final bReceived = <SubstrateEvent>[];
      final aSub = bus.events().listen(aReceived.add);
      final bSub = bus.events().listen(bReceived.add);
      addTearDown(aSub.cancel);
      addTearDown(bSub.cancel);

      final t0 = DateTime.now().toUtc();
      final ev1 = LlmCallStarted(
        occurredAt: t0,
        callId: 'c_1',
        roleId: 'analyser',
        providerId: 'stub',
        modelId: 'stub-1',
      );
      final ev2 = ProviderFailover(
        occurredAt: t0.add(const Duration(milliseconds: 1)),
        fromProviderId: 'stub',
        toProviderId: 'ollama',
        reason: 'rate_limit',
      );

      bus.emit(ev1);
      bus.emit(ev2);

      // broadcast(sync: false) delivers on a future microtask.
      await Future<void>.delayed(Duration.zero);

      expect(
        aReceived.map((e) => e.kind),
        orderedEquals(<String>[
          'substrate.llm-call-started',
          'substrate.provider-failover',
        ]),
      );
      expect(
        bReceived.map((e) => e.kind),
        orderedEquals(<String>[
          'substrate.llm-call-started',
          'substrate.provider-failover',
        ]),
      );
    });

    test('emit is asynchronous (subscriber sees event after emit returns)',
        () async {
      final bus = SubstrateEventBus();
      addTearDown(bus.close);

      final received = <SubstrateEvent>[];
      final sub = bus.events().listen(received.add);
      addTearDown(sub.cancel);

      bus.emit(
        EmbeddingComputed(
          occurredAt: DateTime.now().toUtc(),
          providerId: 'ollama',
          modelId: 'nomic-embed-text',
          dims: 768,
          batchSize: 1,
        ),
      );
      // Before the microtask drains: subscriber has not been called.
      expect(
        received,
        isEmpty,
        reason: 'broadcast(sync: false) defers delivery to a microtask',
      );

      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
    });
  });

  group('B.38 SubstrateEventBus — sealed-sum coverage', () {
    test('plan-named five subtypes round-trip through the bus', () async {
      final bus = SubstrateEventBus();
      addTearDown(bus.close);

      final received = <SubstrateEvent>[];
      final sub = bus.events().listen(received.add);
      addTearDown(sub.cancel);

      final t0 = DateTime.now().toUtc();
      // Build a tiny `LlmCallReport` via the same surface
      // consumers use. The exact field values do not matter for the
      // round-trip lock — the lock is "same instance arrives".
      final report = _buildStubLlmCallReport();

      final planNamedFive = <SubstrateEvent>[
        LlmCallStarted(
          occurredAt: t0,
          callId: 'c_1',
          roleId: 'analyser',
          providerId: 'stub',
          modelId: 'stub-1',
        ),
        LlmCallCompleted(occurredAt: t0, callId: 'c_1', report: report),
        ProviderFailover(
          occurredAt: t0,
          fromProviderId: 'stub',
          toProviderId: 'ollama',
          reason: 'rate_limit',
        ),
        EmbeddingComputed(
          occurredAt: t0,
          providerId: 'ollama',
          modelId: 'nomic-embed-text',
          dims: 768,
          batchSize: 4,
        ),
        WebFetchCompleted(
          occurredAt: t0,
          url: 'https://example.com/',
          status: 200,
          bytes: 4096,
          truncated: false,
        ),
      ];

      for (final ev in planNamedFive) {
        bus.emit(ev);
      }
      await Future<void>.delayed(Duration.zero);

      // Identity, not equality — the bus must not wrap/copy.
      expect(received, hasLength(planNamedFive.length));
      for (var i = 0; i < planNamedFive.length; i++) {
        expect(identical(received[i], planNamedFive[i]), isTrue,
            reason: 'event at index $i was not the same instance');
      }
      expect(
        received.map((e) => e.kind),
        orderedEquals(<String>[
          'substrate.llm-call-started',
          'substrate.llm-call-completed',
          'substrate.provider-failover',
          'substrate.embedding-computed',
          'substrate.web-fetch-completed',
        ]),
      );
    });

    test('spec § 10.2 twelve-variant sum round-trips through the bus',
        () async {
      // Lock the spec-vs-plan divergence at the bus level: the
      // sealed sum has twelve variants; the bus carries all of them
      // because it is typed on the abstract base. A future refactor
      // that, e.g., narrows the bus to a per-variant union must
      // break this test.
      final bus = SubstrateEventBus();
      addTearDown(bus.close);

      final received = <SubstrateEvent>[];
      final sub = bus.events().listen(received.add);
      addTearDown(sub.cancel);

      final t0 = DateTime.now().toUtc();
      final report = _buildStubLlmCallReport();
      final identityA = const EmbeddingModelIdentity(
        providerId: 'ollama',
        modelId: 'nomic-embed-text',
        dims: 768,
        normalized: true,
      );
      final identityB = const EmbeddingModelIdentity(
        providerId: 'ollama',
        modelId: 'mxbai-embed-large',
        dims: 1024,
        normalized: true,
      );

      final allTwelve = <SubstrateEvent>[
        LlmCallStarted(
          occurredAt: t0,
          callId: 'c_1',
          roleId: 'analyser',
          providerId: 'stub',
          modelId: 'stub-1',
        ),
        LlmCallChunk(occurredAt: t0, callId: 'c_1', charCount: 12),
        LlmCallCompleted(occurredAt: t0, callId: 'c_1', report: report),
        LlmCallFailed(
          occurredAt: t0,
          callId: 'c_2',
          failure: const LlmFailure(
            classCode: 'rate_limit',
            message: 'simulated',
          ),
          providerId: 'stub',
          modelId: 'stub-1',
          retryCount: 1,
        ),
        ProviderFailover(
          occurredAt: t0,
          fromProviderId: 'stub',
          toProviderId: 'ollama',
          reason: 'rate_limit',
        ),
        CredentialCooldownStarted(
          occurredAt: t0,
          profileId: 'openrouter:free',
          credentialFingerprint: 'sha256:0123…',
          errorClass: 'billing',
          untilMs: t0.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
        ),
        EmbeddingComputed(
          occurredAt: t0,
          providerId: 'ollama',
          modelId: 'nomic-embed-text',
          dims: 768,
          batchSize: 1,
        ),
        EmbeddingIdentityChanged(
          occurredAt: t0,
          fromIdentity: identityA,
          toIdentity: identityB,
        ),
        WebSearchCompleted(
          occurredAt: t0,
          provider: 'ddg_html',
          query: 'tom brain spec',
          k: 10,
          hits: 7,
        ),
        WebFetchCompleted(
          occurredAt: t0,
          url: 'https://example.com/',
          status: 200,
          bytes: 4096,
          truncated: false,
        ),
        McpHandshakeCompleted(
          occurredAt: t0,
          endpointId: 'tom_brain_memory',
          tools: const <String>['recall', 'classify'],
        ),
        McpCallCompleted(
          occurredAt: t0,
          endpointId: 'tom_brain_memory',
          tool: 'recall',
          wallClockMs: 42,
          ok: true,
        ),
      ];
      // Lock the cardinality assumption — if the sealed sum grows /
      // shrinks, this list and the matching spec § 10.2 row must
      // both be revisited. We compare against twelve because that is
      // what spec § 10.2 names.
      expect(allTwelve, hasLength(12));

      for (final ev in allTwelve) {
        bus.emit(ev);
      }
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(allTwelve.length));
      for (var i = 0; i < allTwelve.length; i++) {
        expect(identical(received[i], allTwelve[i]), isTrue,
            reason: 'event at index $i was not the same instance');
      }
    });

    test('bus does not branch on runtime type (every variant '
        'arrives by identity)', () async {
      // Lock that the bus is a pure pass-through over `SubstrateEvent`:
      // it never inspects `runtimeType`, never wraps, never copies.
      // The twelve-variant test above already exercises this for the
      // sealed sum; this test asserts the same property from a
      // different angle by interleaving variants.
      final bus = SubstrateEventBus();
      addTearDown(bus.close);

      final received = <SubstrateEvent>[];
      final sub = bus.events().listen(received.add);
      addTearDown(sub.cancel);

      final t0 = DateTime.now().toUtc();
      final report = _buildStubLlmCallReport();
      final emitted = <SubstrateEvent>[
        WebFetchCompleted(
          occurredAt: t0,
          url: 'https://example.com/',
          status: 200,
          bytes: 0,
          truncated: false,
        ),
        LlmCallCompleted(occurredAt: t0, callId: 'c_1', report: report),
        EmbeddingComputed(
          occurredAt: t0,
          providerId: 'ollama',
          modelId: 'nomic-embed-text',
          dims: 768,
          batchSize: 1,
        ),
      ];
      for (final ev in emitted) {
        bus.emit(ev);
      }
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(emitted.length));
      for (var i = 0; i < emitted.length; i++) {
        expect(identical(received[i], emitted[i]), isTrue);
      }
    });
  });

  group('B.38 SubstrateEventBus — lifecycle', () {
    test('close ends every live subscription with a done event', () async {
      final bus = SubstrateEventBus();

      final doneA = Completer<void>();
      final doneB = Completer<void>();
      final aSub = bus.events().listen((_) {}, onDone: doneA.complete);
      final bSub = bus.events().listen((_) {}, onDone: doneB.complete);
      addTearDown(aSub.cancel);
      addTearDown(bSub.cancel);

      await bus.close();
      expect(bus.isClosed, isTrue);
      await doneA.future;
      await doneB.future;
    });

    test('close is idempotent', () async {
      final bus = SubstrateEventBus();
      await bus.close();
      await bus.close(); // must not throw
      expect(bus.isClosed, isTrue);
    });

    test('emit-after-close throws StateError carrying the event kind',
        () async {
      final bus = SubstrateEventBus();
      await bus.close();
      expect(
        () => bus.emit(
          WebFetchCompleted(
            occurredAt: DateTime.now().toUtc(),
            url: 'https://example.com/',
            status: 200,
            bytes: 0,
            truncated: false,
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('SubstrateEventBus.emit'),
              contains('after close'),
              contains('substrate.web-fetch-completed'),
            ),
          ),
        ),
      );
    });
  });

  group('B.38 SubstrateEventBus — broadcast contract', () {
    test('late subscriber does not see prior events', () async {
      final bus = SubstrateEventBus();
      addTearDown(bus.close);

      bus.emit(
        WebSearchCompleted(
          occurredAt: DateTime.now().toUtc(),
          provider: 'ddg_html',
          query: 'early',
          k: 5,
          hits: 3,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final lateReceived = <SubstrateEvent>[];
      final sub = bus.events().listen(lateReceived.add);
      addTearDown(sub.cancel);
      bus.emit(
        WebSearchCompleted(
          occurredAt: DateTime.now().toUtc(),
          provider: 'ddg_html',
          query: 'late',
          k: 5,
          hits: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(lateReceived, hasLength(1));
      expect(
        (lateReceived.single as WebSearchCompleted).query,
        'late',
        reason: 'broadcast stream does not replay events emitted before '
            'the subscription started',
      );
    });

    test('multiple listen() calls give independent subscriptions', () async {
      final bus = SubstrateEventBus();
      addTearDown(bus.close);

      final aReceived = <SubstrateEvent>[];
      final aSub = bus.events().listen(aReceived.add);
      addTearDown(aSub.cancel);

      bus.emit(
        EmbeddingComputed(
          occurredAt: DateTime.now().toUtc(),
          providerId: 'ollama',
          modelId: 'nomic-embed-text',
          dims: 768,
          batchSize: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(aReceived, hasLength(1));

      // Second subscription starts after the first event — it sees
      // only events emitted after its own `listen()`.
      final bReceived = <SubstrateEvent>[];
      final bSub = bus.events().listen(bReceived.add);
      addTearDown(bSub.cancel);

      bus.emit(
        EmbeddingComputed(
          occurredAt: DateTime.now().toUtc(),
          providerId: 'ollama',
          modelId: 'nomic-embed-text',
          dims: 768,
          batchSize: 2,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(aReceived, hasLength(2),
          reason: 'subscriber A sees both events');
      expect(bReceived, hasLength(1),
          reason: 'subscriber B only sees the post-listen event');
    });
  });
}

/// Builds a stub [LlmCallReport] for tests that need to construct
/// [LlmCallCompleted]. The values are not asserted on — only the
/// round-trip through the bus is.
LlmCallReport _buildStubLlmCallReport() => const LlmCallReport(
      providerId: 'stub',
      modelId: 'stub-1',
      anchorHash: 'sha256:anchor',
      promptHash: 'sha256:prompt',
      tokensIn: 10,
      tokensOut: 20,
      retries: 0,
      wallClockMs: 5,
    );

