// B.11 — `LlmProvider` interface + `WirePrompt` value class contract.
//
// Scope of this test file:
//
//   - Pin the `WirePrompt` value-class shape (4 fields:
//     `body`, `anchorHash`, `roleId`, optional `templateSha`) so a
//     future drop / rename triggers a compile failure here.
//   - Pin the `LlmProvider` abstract interface shape:
//       * `String get id;`
//       * `Future<LlmCallReport> complete(WirePrompt, LlmOptions);`
//       * `Stream<LlmStreamEvent> completeStream(WirePrompt, LlmOptions);`
//     Use a `_FakeProvider` that implements the interface and a
//     `_DummyProvider` that throws `UnimplementedError` from every
//     override; both must compile and instantiate.
//   - Prove the type-level statements about *what is NOT in the
//     interface at B.11*: there is no `embed(...)`, no
//     `embedBatch(...)`, no `health()` member yet. These are
//     deferred to later steps (B.18 / B.25 / B.26). A `noSuchMethod`
//     check on a `_DummyProvider` instance, gated through `dynamic`
//     dispatch, confirms the members do not exist on the interface.
//   - Prove the `_FakeProvider` honours the documented contract on
//     the cancellation / lifecycle / report shape that the interface
//     promises (anchor hash propagation, provider id propagation,
//     non-streaming buffering on `completeStream` → single chunk +
//     completed pattern).
//   - Prove the `llm/` surface is exported from the top-level
//     package barrel — i.e. tests can import only
//     `package:tom_brain_substrate/tom_brain_substrate.dart` and
//     still bind to `LlmProvider` and `WirePrompt`.
//
// Scope this file is NOT for:
//
//   - No actual HTTP. No real provider implementations exist yet —
//     `OllamaLlmProvider` (B.14), `OpenAiPassthroughProvider`
//     (B.15), `StubLlmProvider` (B.16) land later with their own
//     conformance test (B.17). This file is the *interface* test;
//     B.17 is the *implementations against the interface* test.
//   - No anchor enforcement test. That is B.46's job and covers the
//     whole `TomBrainSubstrateClient` surface. B.11's contract only
//     promises that a provider MUST propagate `anchorHash` if asked
//     to; it does not enforce that the prompt actually had one.
//   - No router / failure-classifier tests. The router (B.18+) owns
//     the failure taxonomy; this file's `_FakeProvider` raises
//     plain `StateError` on its failure path.

import 'dart:async';

import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

void main() {
  group('B.11 / WirePrompt', () {
    test('carries body + anchorHash + roleId + optional templateSha', () {
      const wp = WirePrompt(
        body: 'I am dedicated to this user.\n\n<role body here>',
        anchorHash: 'sha256:deadbeef',
        roleId: 'assistant_to_user',
        templateSha: 'a1b2c3d',
      );

      expect(wp.body, startsWith('I am dedicated to this user.'));
      expect(wp.anchorHash, 'sha256:deadbeef');
      expect(wp.roleId, 'assistant_to_user');
      expect(wp.templateSha, 'a1b2c3d');
    });

    test('templateSha is nullable (development / unstaged-template path)', () {
      const wp = WirePrompt(
        body: 'anchor + body',
        anchorHash: 'sha256:cafebabe',
        roleId: 'analyser',
      );

      expect(wp.templateSha, isNull);
    });

    test('is final — no subclasses permitted', () {
      // Subclassing `WirePrompt` would not compile (`final class`).
      // Implementing it via `implements WirePrompt` would also not
      // compile under the analyzer rule. The runtime equivalent
      // assertion: a constructed `WirePrompt` is exactly that runtime
      // type.
      const wp = WirePrompt(
        body: 'x',
        anchorHash: 'y',
        roleId: 'z',
      );

      expect(wp.runtimeType, WirePrompt);
      expect(wp, isA<WirePrompt>());
    });
  });

  group('B.11 / LlmProvider interface', () {
    test('exposes `String get id`', () {
      final provider = _FakeProvider(
        id: 'fake:test',
        completeBody: 'ignored',
      );

      expect(provider.id, 'fake:test');
      expect(provider, isA<LlmProvider>());
    });

    test(
      'complete returns a report carrying the prompt anchorHash + provider id',
      () async {
        final provider = _FakeProvider(
          id: 'fake:test',
          completeBody: 'fake completion',
        );

        final report = await provider.complete(
          const WirePrompt(
            body: 'anchor + body',
            anchorHash: 'sha256:expected-anchor',
            roleId: 'assistant_to_user',
            templateSha: 'tpl-1',
          ),
          const LlmOptions(),
        );

        expect(report.providerId, 'fake:test');
        expect(report.anchorHash, 'sha256:expected-anchor');
        expect(report.modelId, 'fake-model');
        expect(report.tokensIn, greaterThanOrEqualTo(0));
        expect(report.tokensOut, greaterThanOrEqualTo(0));
        expect(report.retries, 0);
        expect(report.wallClockMs, greaterThanOrEqualTo(0));
        expect(report.templateSha, 'tpl-1');
      },
    );

    test(
      'completeStream emits Started → Chunk+ → Completed for a non-streaming '
      'provider (buffer-then-emit shape per spec § 4.3)',
      () async {
        final provider = _FakeProvider(
          id: 'fake:test',
          completeBody: 'one big chunk',
        );

        final events = await provider
            .completeStream(
              const WirePrompt(
                body: 'anchor + body',
                anchorHash: 'sha256:expected-anchor',
                roleId: 'assistant_to_user',
              ),
              const LlmOptions(),
            )
            .toList();

        expect(events.first, isA<LlmStreamStarted>());
        expect(events.last, isA<LlmStreamCompleted>());

        // Per spec § 4.3 a non-streaming provider chunks the final
        // string into one `Chunk` followed by one `Completed`.
        final middle = events.sublist(1, events.length - 1);
        expect(middle, hasLength(1));
        expect(middle.single, isA<LlmStreamChunk>());

        final chunk = middle.single as LlmStreamChunk;
        expect(chunk.text, 'one big chunk');

        final started = events.first as LlmStreamStarted;
        final completed = events.last as LlmStreamCompleted;

        expect(started.providerId, 'fake:test');
        expect(started.callId, isNotEmpty);
        expect(completed.callId, started.callId);
        expect(chunk.callId, started.callId);

        // Report on the terminal event carries the same anchor hash
        // and provider id as `complete()` would.
        expect(completed.report.anchorHash, 'sha256:expected-anchor');
        expect(completed.report.providerId, 'fake:test');
      },
    );

    test(
      'a DummyProvider that throws UnimplementedError compiles and '
      'satisfies LlmProvider — the interface has no implemented members '
      'subclasses must invoke through `super`',
      () {
        // If `LlmProvider` ever grew a concrete member that required
        // a super-call in subclasses, this test would surface it
        // (the dummy would either fail to compile or pass through
        // a non-thrown method). Today every member is abstract.
        const dummy = _DummyProvider();

        expect(dummy, isA<LlmProvider>());
        expect(() => dummy.id, throwsA(isA<UnimplementedError>()));
        expect(
          () => dummy.complete(
            const WirePrompt(body: 'x', anchorHash: 'y', roleId: 'z'),
            const LlmOptions(),
          ),
          throwsA(isA<UnimplementedError>()),
        );
        expect(
          () => dummy.completeStream(
            const WirePrompt(body: 'x', anchorHash: 'y', roleId: 'z'),
            const LlmOptions(),
          ),
          throwsA(isA<UnimplementedError>()),
        );
      },
    );

    test(
      'B.11 surface does not yet expose embed / embedBatch / health '
      '(deferred per plan-step text + spec § 4.1)',
      () {
        // Dynamic dispatch lets us probe for members that should NOT
        // exist on the interface at this step. If a future change
        // adds `embed`/`embedBatch`/`health` to `LlmProvider`
        // without also updating B.11's documented surface, this
        // assertion fails — flagging the silent contract drift.
        final dynamic dyn = const _DummyProvider();
        expect(
          () => dyn.embed('x'),
          throwsA(isA<NoSuchMethodError>()),
          reason: 'embed is deferred to B.25.',
        );
        expect(
          () => dyn.embedBatch(<String>['x']),
          throwsA(isA<NoSuchMethodError>()),
          reason: 'embedBatch is deferred to B.26.',
        );
        expect(
          () => dyn.health(),
          throwsA(isA<NoSuchMethodError>()),
          reason: 'health is deferred to B.18 (router owns the type).',
        );
      },
    );
  });

  group('B.11 / llm/ surface is reachable via top-level package barrel', () {
    test('WirePrompt and LlmProvider import from the top-level barrel only',
        () {
      // The single test-file import line is
      //   import 'package:tom_brain_substrate/tom_brain_substrate.dart';
      // — i.e. no `package:tom_brain_substrate/src/...` deep import.
      // Reaching the two types under that constraint proves the
      // top-level barrel re-exports the llm/ surface.
      const _ = WirePrompt(body: 'x', anchorHash: 'y', roleId: 'z');
      expect(_FakeProvider(id: 'x', completeBody: 'y'), isA<LlmProvider>());
    });
  });
}

// ─── Test doubles ──────────────────────────────────────────────────

/// A deterministic in-test `LlmProvider` that honours the documented
/// contract — propagates the prompt's `anchorHash` onto the returned
/// `LlmCallReport`, propagates [id] as `providerId`, and emits the
/// non-streaming `completeStream` shape (one `Started`, one `Chunk`,
/// one `Completed`).
///
/// This is *not* the prototype `StubLlmProvider` (that arrives at
/// B.16 with the full provider conformance behaviour). It is the
/// minimum surface needed to prove the B.11 interface holds.
final class _FakeProvider implements LlmProvider {
  @override
  final String id;

  final String completeBody;

  _FakeProvider({required this.id, required this.completeBody});

  @override
  Future<LlmCallReport> complete(WirePrompt prompt, LlmOptions options) async {
    return LlmCallReport(
      providerId: id,
      modelId: 'fake-model',
      anchorHash: prompt.anchorHash,
      promptHash: 'sha256:fake-prompt-${prompt.body.hashCode}',
      tokensIn: prompt.body.length,
      tokensOut: completeBody.length,
      retries: 0,
      wallClockMs: 1,
      templateSha: prompt.templateSha,
      notes: const <String>[],
    );
  }

  @override
  Stream<LlmStreamEvent> completeStream(
    WirePrompt prompt,
    LlmOptions options,
  ) async* {
    final callId =
        'fake-call-${DateTime.now().microsecondsSinceEpoch}-${prompt.body.hashCode}';

    yield LlmStreamStarted(
      callId: callId,
      providerId: id,
      modelId: 'fake-model',
    );

    // Non-streaming providers (per spec § 4.3) emit one Chunk +
    // one Completed.
    yield LlmStreamChunk(callId: callId, text: completeBody);

    final report = await complete(prompt, options);
    yield LlmStreamCompleted(callId: callId, report: report);
  }
}

/// A pure `UnimplementedError` dummy that proves the interface has
/// no concrete members today.
final class _DummyProvider implements LlmProvider {
  const _DummyProvider();

  @override
  String get id => throw UnimplementedError();

  @override
  Future<LlmCallReport> complete(WirePrompt prompt, LlmOptions options) =>
      throw UnimplementedError();

  @override
  Stream<LlmStreamEvent> completeStream(
    WirePrompt prompt,
    LlmOptions options,
  ) =>
      throw UnimplementedError();
}
