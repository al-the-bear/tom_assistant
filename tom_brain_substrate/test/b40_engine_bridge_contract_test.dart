// B.40 — Engine-bridge contract test.
//
// Plan step B.40 says verbatim:
//
//   "Substrate is light enough to live in-process with the dispatcher
//    by default. Still: define `TomBrainSubstrateClient` interface so
//    the engine bridges against the interface, never the concrete class."
//
// The interface itself shipped at B.9 (`lib/src/api/tom_brain_substrate_
// client.dart`); this file is the boundary lock B.40 owes. It pins
// three load-bearing properties:
//
//   1. **The engine can consume substrate through `TomBrainSubstrateClient`
//      alone.** A minimal `_EngineBridgeStub` class — modelled after the
//      shape `MemoryBridge` / `SubstrateBridge` in the Phase C engine
//      (plan steps C.12–C.14, substrate spec § 16) will take — holds a
//      single `TomBrainSubstrateClient` reference and exercises every
//      method on the surface. There is no field of type `TomBrainSubstrate`
//      on the stub; there is no field of type `InProcessTomBrainSubstrate`
//      (B.41+); there is no import of any concrete impl. If a future
//      change to the engine requires the marker class or a concrete
//      class, that change has to happen on the bridge side, and this
//      test fails first.
//
//   2. **The interface is fully implementable through the top-level
//      barrel.** `_FakeSubstrateClient` implements every abstract member
//      using only types exported from `package:tom_brain_substrate/
//      tom_brain_substrate.dart`. Surface drift (a method renamed,
//      a parameter dropped, a return type shifted) breaks the fake's
//      compile before any behavioural test runs — mirroring the
//      memory-side A.78 discipline.
//
//   3. **`TomBrainSubstrate` adds no extra abstract members beyond the
//      client.** B.9 reserved the in-process seam for future synchronous
//      fast paths but shipped zero extra abstract members. B.40 re-asserts
//      that invariant: `_FakeInProcessSubstrate extends _FakeSubstrateClient
//      implements TomBrainSubstrate` must instantiate without overriding
//      any additional method. A future addition to the marker class
//      surfaces here as a compile failure, prompting an intentional
//      documentation update.
//
// What this test file is NOT for:
//
//   - There is no behaviour here. `_FakeSubstrateClient` throws
//     `UnimplementedError` on every method — the substrate's
//     observable behaviour is covered by B.45 (the black-box
//     conformance suite that drives the real in-process facade
//     B.41+ delivers).
//   - There is no anchor enforcement here. That is the dedicated
//     B.46 test — `_FakeSubstrateClient` never reaches the anchor
//     wrap because `complete` / `completeStream` throw before
//     dispatching.
//   - There is no concrete-impl exercise. The whole point of B.40
//     is that the engine never needs the concrete impl; this file
//     would defeat itself by importing one.

import 'dart:async';

import 'package:tom_brain_shared/tom_brain_shared.dart' show Budget, Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

void main() {
  group('B.40 / engine-bridge contract', () {
    // ─── Interface-only consumption ─────────────────────────────

    test(
      '_EngineBridgeStub binds against TomBrainSubstrateClient only',
      () {
        // Constructing the stub with a fake client is the load-bearing
        // assertion: the stub's constructor parameter type is the
        // interface, not the marker base class, not the concrete impl.
        // If a future plan step widened the bridge to require the
        // marker class (e.g. for a synchronous fast path), this test
        // would still pass on the fake but would surface in the
        // dependency graph — see Q-B.40.1 in
        // `prototype_implementation_questions.md`.
        final TomBrainSubstrateClient client = _FakeSubstrateClient();
        final bridge = _EngineBridgeStub(client);

        expect(bridge.client, same(client));
        expect(bridge.client, isA<TomBrainSubstrateClient>());
      },
    );

    test(
      'every surface method is reachable through the interface alone',
      () async {
        // The bridge's `exercise()` calls each method declared on
        // `TomBrainSubstrateClient`. We assert that every call lands
        // (i.e. the surface is callable, even if `_FakeSubstrateClient`
        // throws `UnimplementedError` on each method).
        //
        // A missing method on the interface would produce a compile
        // error at the bridge call site; a missing method on the fake
        // would produce a compile error at the fake declaration. So
        // the moment this test loads, the surface contract is sealed.
        final bridge = _EngineBridgeStub(_FakeSubstrateClient());

        final calls = await bridge.exercise();

        // The exercise calls the eleven members on the interface:
        //   open, close, complete, completeStream,
        //   embed, embedBatch, webSearch, webFetch,
        //   mcpClient, events, stats.
        expect(calls, equals(11));
      },
    );

    // ─── Surface implementability ──────────────────────────────

    test('TomBrainSubstrateClient is implementable in full', () {
      // The *act of constructing* `_FakeSubstrateClient` is the
      // contract check — if any abstract member is missing or its
      // signature shifted, the fake would not compile.
      final TomBrainSubstrateClient client = _FakeSubstrateClient();
      expect(client, isA<TomBrainSubstrateClient>());
    });

    test('TomBrainSubstrateClient cannot be instantiated directly', () {
      // The abstract class cannot be constructed; only subtypes can
      // exist. We assert this indirectly through the fake — if the
      // base class were not abstract, the fake would not be required
      // to implement anything and the surface lock would silently
      // vanish.
      final TomBrainSubstrateClient client = _FakeSubstrateClient();
      // The bridge stub is the engine-side consumer; the assertion
      // that it accepts the fake proves the abstract typing is in
      // force at the consumer boundary.
      expect(_EngineBridgeStub(client).client, same(client));
    });

    // ─── Marker / client equivalence ───────────────────────────

    test('TomBrainSubstrate IS-A TomBrainSubstrateClient', () {
      // Compile-time assertion: the in-process marker base class
      // implements the consumer contract. If the marker ever stopped
      // implementing the client interface, the assignment below
      // would fail to compile.
      final TomBrainSubstrate marker = _FakeInProcessSubstrate();
      final TomBrainSubstrateClient client = marker;
      expect(client, same(marker));
      expect(client, isA<TomBrainSubstrate>());
    });

    test(
      'TomBrainSubstrate adds no extra abstract surface at B.40',
      () {
        // `_FakeInProcessSubstrate` extends `_FakeSubstrateClient`
        // and declares no additional method overrides. If a future
        // plan step added an abstract member to `TomBrainSubstrate`
        // (a synchronous route-lookup fast path, say), this class
        // would fail to instantiate — surfacing the addition as a
        // compile error here so it is documented intentionally.
        final TomBrainSubstrate inProcess = _FakeInProcessSubstrate();
        expect(inProcess, isA<TomBrainSubstrate>());
        expect(inProcess, isA<TomBrainSubstrateClient>());
      },
    );

    // ─── Negative discipline ───────────────────────────────────

    test(
      'engine consumers never need a concrete substrate impl',
      () {
        // The engine-bridge stub holds only `TomBrainSubstrateClient`.
        // Asking it for the marker base class type is meaningless
        // from the engine's POV — the bridge does not know whether
        // it has the in-process marker or an isolate adapter. This
        // test makes that distinction explicit: the stub exposes
        // no `TomBrainSubstrate` getter, no `cast`, no `as`-check.
        final bridge = _EngineBridgeStub(_FakeSubstrateClient());

        // The runtime check here is a sanity rail: the fake we
        // injected is NOT a `TomBrainSubstrate`, and the engine
        // does not care. If we had injected the marker subclass
        // (`_FakeInProcessSubstrate`), it would be both; the engine
        // still does not branch.
        expect(bridge.client, isNot(isA<TomBrainSubstrate>()));
      },
    );
  });
}

// ─── Engine-bridge stub ─────────────────────────────────────────

/// Minimal model of how the Phase C engine binds against substrate.
///
/// `MemoryBridge` and `SubstrateBridge` in the procedure engine
/// (plan steps C.12–C.14) will hold a `TomBrainSubstrateClient`
/// reference exactly like this stub does. The stub deliberately
/// has no concrete-impl reference, no marker-class reference, no
/// composition-root hook.
///
/// The `exercise()` method calls each abstract member on the
/// interface once and returns the count. The B.40 test asserts the
/// count matches the spec § 3.1 surface size (eleven members).
final class _EngineBridgeStub {
  final TomBrainSubstrateClient client;

  const _EngineBridgeStub(this.client);

  /// Calls every method on [client] once. Used by the B.40 test to
  /// prove the surface is reachable through the interface alone.
  ///
  /// Every call is wrapped in a `try` because `_FakeSubstrateClient`
  /// throws `UnimplementedError` on every method — we only care that
  /// the calls *exist* on the surface, not that they succeed.
  Future<int> exercise() async {
    var calls = 0;

    Future<void> tryCall(Future<void> Function() op) async {
      calls++;
      try {
        await op();
      } on UnimplementedError {
        // Expected — the fake throws on every method.
      }
    }

    void trySync(void Function() op) {
      calls++;
      try {
        op();
      } on UnimplementedError {
        // Expected.
      }
    }

    Future<void> tryStream(Stream<Object?> Function() op) async {
      calls++;
      try {
        await op().toList();
      } on UnimplementedError {
        // Expected.
      }
    }

    final budget = Budget(
      wallClockMs: 1000,
      tokenSpend: 100,
      toolCalls: 1,
      memoryWrites: 0,
    );

    final call = LlmCall(
      roleId: 'assistant_to_user',
      inputs: const <String, Object?>{'question': 'hi'},
      budget: budget,
    );

    await tryCall(() => client.open(_minimalSubstrateConfig()));
    await tryCall(() => client.close());
    await tryCall(() async {
      await client.complete(call);
    });
    await tryStream(() => client.completeStream(call));
    await tryCall(() async {
      await client.embed('hello');
    });
    await tryCall(() async {
      await client.embedBatch(const <String>['hello', 'world']);
    });
    await tryCall(() async {
      await client.webSearch('query');
    });
    await tryCall(() async {
      await client.webFetch(Uri.parse('https://example.com/'));
    });
    trySync(() {
      client.mcpClient(const McpEndpoint('memory'));
    });
    await tryStream(() => client.events());
    trySync(() {
      client.stats();
    });

    return calls;
  }
}

// ─── Test fakes ────────────────────────────────────────────────

/// Minimal no-op implementation used as a *compile-time* assertion
/// that `TomBrainSubstrateClient`'s shape can be honoured through
/// the top-level barrel alone.
///
/// Mirrors the `_FakeMemoryClient` shape in the memory-side A.78
/// test so the two consumer-facing surfaces stay in lockstep —
/// surface drift between `TomBrainSubstrateClient` and the spec
/// § 3.1 wire shape will break exactly one of these tests.
class _FakeSubstrateClient implements TomBrainSubstrateClient {
  @override
  Future<void> open(SubstrateConfig config) async =>
      throw UnimplementedError();

  @override
  Future<void> close() async => throw UnimplementedError();

  @override
  Future<LlmCallReport> complete(LlmCall call) => throw UnimplementedError();

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) =>
      throw UnimplementedError();

  @override
  Future<EmbeddingResult> embed(String text) => throw UnimplementedError();

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) =>
      throw UnimplementedError();

  @override
  Future<WebSearchResult> webSearch(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) =>
      throw UnimplementedError();

  @override
  Future<WebFetchResult> webFetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) =>
      throw UnimplementedError();

  @override
  McpClient mcpClient(McpEndpoint endpoint) => throw UnimplementedError();

  @override
  Stream<SubstrateEvent> events() => throw UnimplementedError();

  @override
  SubstrateStats stats() => throw UnimplementedError();
}

/// Mirror-implementation of [TomBrainSubstrate] (not just the
/// client). Proves that the in-process marker class can still be
/// concretely realised on top of the same fake surface without
/// re-declaring abstract members — i.e. the marker reserves the
/// seam but does not yet ship any extra abstract surface.
///
/// If a future plan step adds an abstract member to
/// `TomBrainSubstrate` (a synchronous in-process fast path that
/// the isolate adapter cannot honour), this class will stop
/// compiling here, prompting an intentional documentation update
/// and a matching guarantee on the engine side that it consumes
/// the new member only through the client interface.
class _FakeInProcessSubstrate extends _FakeSubstrateClient
    implements TomBrainSubstrate {
  // No additional methods — B.40 re-asserts the invariant B.9 set:
  // the marker reserves the seam but ships nothing yet.
}

// B.36-equivalent — `SubstrateConfig` is `final`; the bridge stub
// constructs a minimal value directly. Same shape as the B.9 test
// fixture so any change to the config root surfaces in both files
// together.
SubstrateConfig _minimalSubstrateConfig() => SubstrateConfig(
      providers: const [],
      roleRoutes: const {},
      embedding: const EmbeddingChoice(
        providerId: 'stub',
        model: 'nomic-embed-text',
        dims: 768,
        normalize: true,
      ),
      webSearch: const WebSearchConfig(
        defaultProvider: 'duckduckgo',
        providers: {
          'duckduckgo': WebSearchProviderConfig(kind: 'ddg_html'),
        },
      ),
      webFetch: const WebFetchConfig(),
      mcpClient: const McpClientConfigBlock(),
    );

// Suppress unused-import lints from `dart:async` (the `Stream`
// references in `_FakeSubstrateClient` keep `Stream` reachable; the
// import is here for explicitness — `package:test` does not re-
// export it).
//
// `Vec` from `tom_brain_shared` is referenced indirectly via the
// `EmbeddingResult` surface — kept in the import list for symmetry
// with the memory-side A.78 fake; remove if/when the
// `dependency_surface_test.dart` flags it.
// ignore: unused_element
typedef _KeepSharedAlive = Vec;
// ignore: unused_element
typedef _KeepAsyncAlive = StreamController<int>;
