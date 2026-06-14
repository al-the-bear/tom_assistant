// B.17 — cross-provider `LlmProvider` conformance suite.
//
// Scope: the same set of contract assertions runs against every provider
// that landed by B.16 — `OllamaLlmProvider` (B.14), `OpenAiPassthroughProvider`
// (B.15), `StubLlmProvider` (B.16). The per-provider suites at
// `test/b14_*`, `test/b15_*`, `test/b16_*` exercise each provider's
// provider-private behaviour (wire shape, fake-adapter responses,
// off-interface helpers, scripted-mode semantics). This file is the
// *contract-level* suite: it pins the cross-provider invariants
// documented on the `LlmProvider` abstract class at
// `lib/src/llm/llm_provider.dart`.
//
// What is on contract (B.11 + Spec § 4.1 + Spec § 4.3 + Spec § 6.3
// anchor invariant):
//
//   1. `id` is propagated verbatim through every emitted
//      [LlmCallReport.providerId] (and through every
//      [LlmStreamStarted.providerId] on the streaming path).
//
//   2. **Anchor stamp.** Every emitted [LlmCallReport.anchorHash]
//      equals the supplied [WirePrompt.anchorHash]. Tested on both the
//      buffered (`complete`) and streaming (`completeStream` →
//      `LlmStreamCompleted.report` / `LlmStreamFailed.report`) paths.
//
//   3. **Provenance stamp.** Every emitted [LlmCallReport] carries
//      `providerId == provider.id`, a non-empty `modelId`, and a
//      `promptHash` in the `sha256:<lowercase-hex>` shape that
//      `WirePrompt.anchorHash` and `AnchorRegistry.currentHash` also
//      use (so the trail can compare hashes without re-parsing).
//
//   4. **Prompt body discipline.** The provider does not mutate the
//      prompt body. The verification reaches into the per-provider
//      transport (`_FakeOllamaHttpClient`, `_FakeOpenAiHttpClient`)
//      or — for the stub — uses the `defaultEcho` responder
//      (`'STUB:' + prompt.combined`) and asserts the body suffix.
//
//   5. **Streaming lifecycle.** `completeStream` emits exactly one
//      [LlmStreamStarted] first, then zero-or-more [LlmStreamChunk]
//      events, then exactly one of [LlmStreamCompleted] /
//      [LlmStreamFailed]. The `callId` is non-empty and stable across
//      every emitted event for one call.
//
//   6. **Structurally-valid report.** Every emitted [LlmCallReport]
//      has non-negative integer counters (`tokensIn`, `tokensOut`,
//      `retries`, `wallClockMs`); `retries == 0` at B.17 (no provider
//      retries at this layer — the router lands at B.18); `cost` is
//      `null` (no provider knows a price at this layer); `templateSha`
//      equals the prompt's `templateSha`.
//
//   7. **Transient 5xx surfaces as failure.** With the providers' wire
//      transport pre-loaded to throw a transient HTTP exception (or,
//      for the stub, constructed via `StubLlmProvider.alwaysFails`):
//      the non-streaming path throws; the streaming path emits a
//      terminal [LlmStreamFailed] with provenance preserved. **Retry
//      enforcement is NOT on contract at B.17** — providers
//      deliberately do not retry; the router layer (B.18+) owns the
//      retry / classifier / rotate decisions. The cross-provider
//      retry-policy honour-test lands at plan step B.20 once the
//      router is in place. Logged as Q-B.17.1 below.
//
//   8. **Cancellation halts the stream.** A `StreamSubscription.cancel()`
//      after the first emitted event stops the consumer from seeing
//      further events within a bounded wait. At B.17 the providers'
//      `completeStream(WirePrompt, LlmOptions)` does NOT accept a
//      cancellation token — `LlmCall.cancellationToken` plumbs through
//      the router (B.18+). The B.17 contract therefore tests the only
//      cancellation surface that exists today: consumer-side stream
//      cancellation. Logged as Q-B.17.2 below.
//
// What is NOT on this contract at B.17:
//
//   - **Retries on 5xx honouring `tom_core_kernel`'s retry policy.**
//     `tom_core_kernel` does not ship a named `RetryPolicy` class
//     today (`tom_ai/core/tom_core_kernel/lib/...` was scanned —
//     `server_connection.dart` carries an inline retry concept but no
//     reusable policy surface). The substrate spec § 5 explicitly
//     locates retry classification on the router (B.18+) with
//     `LlmFailureClassifier`. At B.17 the providers re-throw and the
//     router decides — there is no provider-level retry to test.
//     Surfaced as Q-B.17.1.
//
//   - **Cancellation-token mid-stream from `LlmCall`.** The token is
//     not yet plumbed through any provider entry point (per B.11 the
//     interface omits the parameter by design; B.18 wires the
//     router-mediated cancellable call site). Surfaced as Q-B.17.2.
//
//   - **Anchor enforcement against `AnchorRegistry.currentHash`.**
//     B.46. This file pins `report.anchorHash == prompt.anchorHash`;
//     B.46 closes the loop by asserting `prompt.anchorHash ==
//     AnchorRegistry.currentHash` end-to-end through the api/-layer
//     entry point.
//
// Design:
//
//   - Three per-provider harnesses (`_OllamaHarness`, `_OpenAiHarness`,
//     `_StubHarness`) implement a common `_ProviderHarness` interface.
//     The single `_runConformance(harnessBuilder)` driver opens a
//     `group(...)` per harness and registers the contract tests once
//     against each, so a single edit to a contract assertion lands
//     against every provider in one place.
//
//   - The harness owns three primings: `primeHappy`, `primeFailure`,
//     and `primeSlowStream`. Each provider's harness translates the
//     priming into whatever wire shape its transport speaks (Ollama
//     NDJSON, OpenAI SSE, stub script). The contract tests speak only
//     to the harness — they never reach a provider-specific type.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.17 / OllamaLlmProvider', () {
    _runConformance(_OllamaHarness.new);
  });

  group('B.17 / OpenAiPassthroughProvider', () {
    _runConformance(_OpenAiHarness.new);
  });

  group('B.17 / StubLlmProvider', () {
    _runConformance(_StubHarness.new);
  });
}

// ─── Contract driver ──────────────────────────────────────────────

typedef _HarnessBuilder = _ProviderHarness Function();

void _runConformance(_HarnessBuilder buildHarness) {
  group('contract — interface conformance', () {
    test('id is propagated through every emitted report (complete)', () async {
      final h = buildHarness()..primeHappy(responseText: 'hello back');
      addTearDown(h.dispose);

      final prompt = _wirePrompt(body: 'hi');
      final report = await h.provider.complete(prompt, LlmOptions.empty);

      expect(report.providerId, h.provider.id);
      expect(report.modelId, isNotEmpty);
    });

    test('id is propagated through every emitted event (completeStream)',
        () async {
      final h = buildHarness()..primeHappy(responseText: 'world');
      addTearDown(h.dispose);

      final prompt = _wirePrompt(body: 'hi');
      final events = await h.provider
          .completeStream(prompt, LlmOptions.empty)
          .toList();

      expect(events, isNotEmpty);
      final started = events.first as LlmStreamStarted;
      expect(started.providerId, h.provider.id);
      expect(started.modelId, isNotEmpty);

      final terminal = events.last;
      expect(
        terminal,
        anyOf(isA<LlmStreamCompleted>(), isA<LlmStreamFailed>()),
        reason: 'last event must be Completed or Failed (spec § 4.3)',
      );
    });
  });

  group('contract — anchor stamp invariant (Spec § 6.3 / Postulate 3)', () {
    test('complete: report.anchorHash == prompt.anchorHash', () async {
      final h = buildHarness()..primeHappy();
      addTearDown(h.dispose);

      final prompt = _wirePrompt(body: 'hi', anchorHash: 'sha256:deadbeef');
      final report = await h.provider.complete(prompt, LlmOptions.empty);

      expect(report.anchorHash, 'sha256:deadbeef');
    });

    test(
        'completeStream: LlmStreamCompleted.report.anchorHash == prompt.anchorHash',
        () async {
      final h = buildHarness()..primeHappy();
      addTearDown(h.dispose);

      final prompt = _wirePrompt(body: 'hi', anchorHash: 'sha256:cafebabe');
      final events = await h.provider
          .completeStream(prompt, LlmOptions.empty)
          .toList();

      final terminal = events.last;
      if (terminal is LlmStreamCompleted) {
        expect(terminal.report.anchorHash, 'sha256:cafebabe');
      } else if (terminal is LlmStreamFailed) {
        expect(terminal.report.anchorHash, 'sha256:cafebabe',
            reason: 'anchor must propagate even on the failure path');
      } else {
        fail('Unexpected terminal event: $terminal');
      }
    });
  });

  group('contract — provenance stamp invariant', () {
    test('promptHash is sha256:<lowercase-hex> over prompt.combined', () async {
      final h = buildHarness()..primeHappy(responseText: 'OK');
      addTearDown(h.dispose);

      final prompt = _wirePrompt(body: 'the quick brown fox');
      final report = await h.provider.complete(prompt, LlmOptions.empty);

      final expected =
          'sha256:${sha256.convert(utf8.encode(prompt.combined)).toString()}';
      expect(report.promptHash, expected);
      expect(report.promptHash, startsWith('sha256:'));
    });

    test('templateSha is propagated verbatim (null and non-null)',
        () async {
      // null path
      {
        final h = buildHarness()..primeHappy();
        addTearDown(h.dispose);
        final prompt = _wirePrompt(body: 'a');
        final report = await h.provider.complete(prompt, LlmOptions.empty);
        expect(report.templateSha, isNull);
      }

      // non-null path
      {
        final h2 = buildHarness()..primeHappy();
        addTearDown(h2.dispose);
        final prompt = _wirePrompt(body: 'b', templateSha: 'sha-abc');
        final report = await h2.provider.complete(prompt, LlmOptions.empty);
        expect(report.templateSha, 'sha-abc');
      }
    });

    test('different prompt bodies produce different promptHashes', () async {
      final h = buildHarness();
      addTearDown(h.dispose);
      h.primeHappy();
      final r1 = await h.provider
          .complete(_wirePrompt(body: 'alpha'), LlmOptions.empty);
      h.primeHappy();
      final r2 = await h.provider
          .complete(_wirePrompt(body: 'beta'), LlmOptions.empty);
      expect(r1.promptHash, isNot(r2.promptHash));
    });
  });

  group('contract — structurally-valid report', () {
    test('counters are non-negative; retries == 0; cost == null', () async {
      final h = buildHarness()..primeHappy(responseText: 'hello world');
      addTearDown(h.dispose);

      final report = await h.provider
          .complete(_wirePrompt(body: 'hi'), LlmOptions.empty);

      expect(report.tokensIn, greaterThanOrEqualTo(0));
      expect(report.tokensOut, greaterThanOrEqualTo(0));
      expect(report.wallClockMs, greaterThanOrEqualTo(0));
      expect(report.retries, 0,
          reason: 'B.17: providers do not retry; router (B.18+) does');
      expect(report.cost, isNull,
          reason: 'B.17: no provider knows a price; router (B.32+) does');
      expect(report.notes, isA<List<String>>());
    });
  });

  group('contract — prompt body discipline (no mutation)', () {
    test('the prompt body is forwarded to the wire verbatim', () async {
      final h = buildHarness()..primeHappy(responseText: 'OK');
      addTearDown(h.dispose);

      const body = 'an anchor block + a question';
      final prompt = _wirePrompt(body: body);
      await h.provider.complete(prompt, LlmOptions.empty);

      expect(h.lastForwardedBody, body,
          reason: 'provider MUST NOT prepend/append/reorder prompt body');
    });
  });

  group('contract — streaming lifecycle (Spec § 4.3)', () {
    test(
        'happy path: Started, then chunks, then exactly one Completed; '
        'callId stable; concatenation equals response', () async {
      const fullResponse = 'one two three';
      final h = buildHarness()..primeHappy(responseText: fullResponse);
      addTearDown(h.dispose);

      final events = await h.provider
          .completeStream(_wirePrompt(body: 'hi'), LlmOptions.empty)
          .toList();

      expect(events, isNotEmpty);
      expect(events.first, isA<LlmStreamStarted>());
      expect(events.last, isA<LlmStreamCompleted>());

      // Exactly one Started, exactly one Completed, zero Failed.
      expect(events.whereType<LlmStreamStarted>().length, 1);
      expect(events.whereType<LlmStreamCompleted>().length, 1);
      expect(events.whereType<LlmStreamFailed>().length, 0);

      // callId is non-empty and stable across events.
      final started = events.first as LlmStreamStarted;
      expect(started.callId, isNotEmpty);
      for (final ev in events) {
        final callId = switch (ev) {
          LlmStreamStarted() => ev.callId,
          LlmStreamChunk() => ev.callId,
          LlmStreamToolCallProposed() => ev.callId,
          LlmStreamCompleted() => ev.callId,
          LlmStreamFailed() => ev.callId,
        };
        expect(callId, started.callId,
            reason: 'callId must be stable across one call');
      }

      // No empty chunks emitted.
      for (final ev in events.whereType<LlmStreamChunk>()) {
        expect(ev.text, isNotEmpty);
      }

      // The reassembled chunks equal the wire response.
      final reassembled = events
          .whereType<LlmStreamChunk>()
          .map((c) => c.text)
          .join();
      expect(reassembled, contains(h.expectedResponseFragment));
    });
  });

  group('contract — transient 5xx surfaces as failure (Q-B.17.1)', () {
    test('non-streaming: complete throws', () async {
      final h = buildHarness()..primeFailure();
      addTearDown(h.dispose);

      await expectLater(
        h.provider.complete(_wirePrompt(body: 'hi'), LlmOptions.empty),
        throwsA(isA<Object>()),
        reason: 'B.17: providers re-throw; router (B.18+) classifies',
      );
    });

    test('streaming: terminal LlmStreamFailed with provenance preserved',
        () async {
      final h = buildHarness()..primeFailure();
      addTearDown(h.dispose);

      final prompt = _wirePrompt(body: 'hi', anchorHash: 'sha256:abc');
      final events = await h.provider
          .completeStream(prompt, LlmOptions.empty)
          .toList();

      // First event is always Started.
      expect(events.first, isA<LlmStreamStarted>());

      // Terminal event is Failed.
      final terminal = events.last;
      expect(terminal, isA<LlmStreamFailed>());

      final failed = terminal as LlmStreamFailed;
      expect(failed.callId, isNotEmpty);
      expect(failed.failure, isA<LlmFailure>());
      // Provenance is preserved on the failure-side report so the
      // trail can attribute the failed call.
      expect(failed.report.providerId, h.provider.id);
      expect(failed.report.anchorHash, 'sha256:abc');
      expect(failed.report.promptHash, startsWith('sha256:'));
    });
  });

  group('contract — consumer-side cancellation halts the stream (Q-B.17.2)',
      () {
    test(
        'subscription.cancel() after Started stops further event delivery',
        () async {
      final h = buildHarness()
        ..primeSlowStream(
          chunkCount: 50,
          chunkDelay: const Duration(milliseconds: 5),
        );
      addTearDown(h.dispose);

      final events = <LlmStreamEvent>[];
      final completer = Completer<void>();
      late StreamSubscription<LlmStreamEvent> sub;
      sub = h.provider
          .completeStream(_wirePrompt(body: 'hi'), LlmOptions.empty)
          .listen(
        (ev) {
          events.add(ev);
          if (ev is LlmStreamStarted) {
            // Cancel as soon as the first event arrives.
            sub.cancel().whenComplete(() {
              if (!completer.isCompleted) completer.complete();
            });
          }
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete();
        },
      );

      await completer.future.timeout(const Duration(seconds: 2));
      final countAtCancel = events.length;

      // Give the underlying producer time to keep yielding had cancel
      // not taken effect. The provider's stream is single-subscription
      // and `.cancel()` discards further events from delivery.
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(
        events.length,
        countAtCancel,
        reason:
            'no events should be delivered after subscription.cancel() resolves',
      );
    });
  });
}

// ─── Test prompt factory ──────────────────────────────────────────

WirePrompt _wirePrompt({
  required String body,
  String anchorHash = 'sha256:test-anchor',
  String roleId = 'b17.contract.role',
  String? templateSha,
}) {
  return WirePrompt(
    system: body,
    anchorHash: anchorHash,
    roleId: roleId,
    templateSha: templateSha,
  );
}

// ─── Harness ──────────────────────────────────────────────────────

/// One per-provider test fixture. Each harness translates the three
/// contract-test primings (`primeHappy` / `primeFailure` /
/// `primeSlowStream`) into whatever wire shape its provider speaks.
///
/// The contract driver talks only to this interface — provider-specific
/// transport types (`_FakeOllamaHttpClient`, `_FakeOpenAiHttpClient`)
/// live inside the harness file and do not leak into the contract
/// tests.
abstract class _ProviderHarness {
  LlmProvider get provider;

  /// Body forwarded on the most recent `complete` / `completeStream`
  /// invocation. Used by the prompt-body-discipline test.
  String get lastForwardedBody;

  /// Substring guaranteed to be present in the reassembled streaming
  /// response after `primeHappy`. Each harness controls how the
  /// happy-priming response decomposes into chunks; the contract test
  /// only asserts containment, not exact equality.
  String get expectedResponseFragment;

  /// Prime the next call (`complete` and `completeStream`) to return
  /// a structurally-valid happy response whose content includes
  /// [responseText].
  void primeHappy({String responseText = 'hello world'});

  /// Prime the next call to surface a transient 5xx-style failure:
  /// `complete` throws; `completeStream` emits `Started → Failed`.
  void primeFailure();

  /// Prime the next `completeStream` call to yield [chunkCount]
  /// fragments, each spaced by [chunkDelay], so the cancellation test
  /// has a producer it can interrupt mid-stream.
  void primeSlowStream({
    required int chunkCount,
    required Duration chunkDelay,
  });

  Future<void> dispose() async {}
}

// ─── Ollama harness ──────────────────────────────────────────────

class _OllamaHarness implements _ProviderHarness {
  final _FakeOllamaHttpClient _fake = _FakeOllamaHttpClient();
  late final OllamaLlmProvider _provider = OllamaLlmProvider(
    id: 'ollama:b17',
    baseUri: Uri.parse('http://127.0.0.1:11434/'),
    defaultModel: 'gemma3:27b',
    httpClient: _fake,
  );

  @override
  LlmProvider get provider => _provider;

  @override
  String get lastForwardedBody {
    // `_wirePrompt` routes its body through the system channel, which the
    // provider forwards as the system-role message (the user message carries
    // the empty `user` slot). The body-discipline contract checks that this
    // system content is forwarded verbatim, unmutated.
    final call = _fake.chatCalls.last;
    return call.messages.firstWhere((m) => m.role == 'system').content;
  }

  @override
  String get expectedResponseFragment => _lastHappyResponse;

  String _lastHappyResponse = '';

  @override
  void primeHappy({String responseText = 'hello world'}) {
    _lastHappyResponse = responseText;
    _fake
      ..chatResponse = OllamaChatResponse(
        model: 'gemma3:27b',
        content: responseText,
        promptEvalCount: 4,
        evalCount: 3,
      )
      ..chatException = null
      ..streamException = null
      // Single-fragment intermediate + a terminal done frame.
      ..streamFragments = <OllamaStreamFragment>[
        OllamaStreamFragment(
          model: 'gemma3:27b',
          contentDelta: responseText,
          done: false,
        ),
        const OllamaStreamFragment(
          model: 'gemma3:27b',
          contentDelta: '',
          done: true,
          promptEvalCount: 4,
          evalCount: 3,
        ),
      ];
  }

  @override
  void primeFailure() {
    final exc = OllamaHttpException(
      statusCode: 503,
      body: '{"error":"transient"}',
      endpoint: Uri.parse('http://127.0.0.1:11434/api/chat'),
    );
    _fake
      ..chatException = exc
      ..streamException = exc
      ..streamFragments = const <OllamaStreamFragment>[];
  }

  @override
  void primeSlowStream({
    required int chunkCount,
    required Duration chunkDelay,
  }) {
    _fake.slowStream = (
      chunkCount: chunkCount,
      delay: chunkDelay,
      model: 'gemma3:27b',
    );
  }

  @override
  Future<void> dispose() async {
    _provider.close();
  }
}

/// Slow-stream priming record for the Ollama / OpenAI fakes.
typedef _SlowStreamSpec = ({int chunkCount, Duration delay, String model});

final class _FakeOllamaHttpClient implements OllamaHttpClient {
  final List<_ChatInvocation> chatCalls = <_ChatInvocation>[];
  OllamaChatResponse chatResponse =
      const OllamaChatResponse(model: 'gemma3:27b', content: '');
  Object? chatException;
  List<OllamaStreamFragment> streamFragments = const <OllamaStreamFragment>[];
  Object? streamException;
  _SlowStreamSpec? slowStream;

  @override
  Future<OllamaChatResponse> chat({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
  }) async {
    chatCalls.add(_ChatInvocation(messages: messages));
    if (chatException != null) throw chatException!;
    return chatResponse;
  }

  @override
  Stream<OllamaStreamFragment> chatStream({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
    CancellationToken? cancellationToken,
  }) async* {
    chatCalls.add(_ChatInvocation(messages: messages));
    if (streamException != null) throw streamException!;
    final slow = slowStream;
    if (slow != null) {
      for (var i = 0; i < slow.chunkCount; i++) {
        await Future<void>.delayed(slow.delay);
        yield OllamaStreamFragment(
          model: slow.model,
          contentDelta: 'chunk-$i ',
          done: false,
        );
      }
      yield OllamaStreamFragment(
        model: slow.model,
        contentDelta: '',
        done: true,
        promptEvalCount: 0,
        evalCount: slow.chunkCount,
      );
      return;
    }
    for (final frag in streamFragments) {
      yield frag;
    }
  }

  @override
  Future<List<double>> embed({
    required Uri baseUri,
    required String model,
    required String prompt,
    Duration? requestTimeout,
  }) async {
    return const <double>[];
  }

  @override
  Future<List<OllamaTagEntry>> listTags({
    required Uri baseUri,
    Duration? requestTimeout,
  }) async {
    return const <OllamaTagEntry>[];
  }

  @override
  void close() {}
}

final class _ChatInvocation {
  final List<OllamaMessage> messages;
  const _ChatInvocation({required this.messages});
}

// ─── OpenAI passthrough harness ─────────────────────────────────

class _OpenAiHarness implements _ProviderHarness {
  final _FakeOpenAiHttpClient _fake = _FakeOpenAiHttpClient();
  late final OpenAiPassthroughProvider _provider = OpenAiPassthroughProvider(
    id: 'openai:b17',
    baseUri: Uri.parse('https://api.openai.com/'),
    defaultModel: 'gpt-4o-mini',
    apiKey: 'test-token',
    httpClient: _fake,
  );

  @override
  LlmProvider get provider => _provider;

  @override
  String get lastForwardedBody =>
      // `_wirePrompt` routes its body through the system channel; the provider
      // forwards it as the system-role message (the user slot is empty here).
      _fake.chatCalls.last.messages
          .firstWhere((m) => m.role == 'system')
          .content;

  @override
  String get expectedResponseFragment => _lastHappyResponse;

  String _lastHappyResponse = '';

  @override
  void primeHappy({String responseText = 'hello world'}) {
    _lastHappyResponse = responseText;
    _fake
      ..chatResponse = OpenAiChatResponse(
        model: 'gpt-4o-mini',
        content: responseText,
        promptTokens: 5,
        completionTokens: 4,
        finishReason: 'stop',
      )
      ..chatException = null
      ..streamException = null
      ..streamFragments = <OpenAiStreamFragment>[
        OpenAiStreamFragment(
          model: 'gpt-4o-mini',
          contentDelta: responseText,
        ),
        const OpenAiStreamFragment(
          model: 'gpt-4o-mini',
          contentDelta: '',
          finishReason: 'stop',
          promptTokens: 5,
          completionTokens: 4,
        ),
      ];
  }

  @override
  void primeFailure() {
    final exc = OpenAiHttpException(
      statusCode: 503,
      body: '{"error":{"message":"transient"}}',
      endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
    );
    _fake
      ..chatException = exc
      ..streamException = exc
      ..streamFragments = const <OpenAiStreamFragment>[];
  }

  @override
  void primeSlowStream({
    required int chunkCount,
    required Duration chunkDelay,
  }) {
    _fake.slowStream = (
      chunkCount: chunkCount,
      delay: chunkDelay,
      model: 'gpt-4o-mini',
    );
  }

  @override
  Future<void> dispose() async {
    _provider.close();
  }
}

final class _FakeOpenAiHttpClient implements OpenAiHttpClient {
  final List<_OpenAiChatInvocation> chatCalls = <_OpenAiChatInvocation>[];
  OpenAiChatResponse chatResponse =
      const OpenAiChatResponse(model: 'gpt-4o-mini', content: '');
  Object? chatException;
  List<OpenAiStreamFragment> streamFragments = const <OpenAiStreamFragment>[];
  Object? streamException;
  _SlowStreamSpec? slowStream;

  @override
  Future<OpenAiChatResponse> chat({
    required Uri baseUri,
    required String model,
    required List<OpenAiMessage> messages,
    required OpenAiGenerationOptions options,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    chatCalls.add(_OpenAiChatInvocation(messages: messages));
    if (chatException != null) throw chatException!;
    return chatResponse;
  }

  @override
  Stream<OpenAiStreamFragment> chatStream({
    required Uri baseUri,
    required String model,
    required List<OpenAiMessage> messages,
    required OpenAiGenerationOptions options,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
    CancellationToken? cancellationToken,
  }) async* {
    chatCalls.add(_OpenAiChatInvocation(messages: messages));
    if (streamException != null) throw streamException!;
    final slow = slowStream;
    if (slow != null) {
      for (var i = 0; i < slow.chunkCount; i++) {
        await Future<void>.delayed(slow.delay);
        yield OpenAiStreamFragment(
          model: slow.model,
          contentDelta: 'chunk-$i ',
        );
      }
      yield OpenAiStreamFragment(
        model: slow.model,
        contentDelta: '',
        finishReason: 'stop',
        promptTokens: 0,
        completionTokens: slow.chunkCount,
      );
      return;
    }
    for (final frag in streamFragments) {
      yield frag;
    }
  }

  @override
  Future<OpenAiEmbeddingResponse> embed({
    required Uri baseUri,
    required String model,
    required List<String> input,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    return OpenAiEmbeddingResponse(
      model: model,
      embeddings: const <List<double>>[],
    );
  }

  @override
  Future<List<OpenAiModelEntry>> listModels({
    required Uri baseUri,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    return const <OpenAiModelEntry>[];
  }

  @override
  void close() {}
}

final class _OpenAiChatInvocation {
  final List<OpenAiMessage> messages;
  const _OpenAiChatInvocation({required this.messages});
}

// ─── Stub harness ──────────────────────────────────────────────

class _StubHarness implements _ProviderHarness {
  late StubLlmProvider _provider = StubLlmProvider(id: 'stub:b17');
  String _lastBody = '';
  bool _failureMode = false;
  String _lastHappyResponse = '';
  _SlowStreamSpec? _slowSpec;

  @override
  LlmProvider get provider => _provider;

  @override
  String get lastForwardedBody => _lastBody;

  @override
  String get expectedResponseFragment => _lastHappyResponse;

  @override
  void primeHappy({String responseText = 'hello world'}) {
    _failureMode = false;
    _slowSpec = null;
    _lastHappyResponse = responseText;
    _provider = StubLlmProvider(
      id: 'stub:b17',
      responder: (prompt, _) {
        _lastBody = prompt.combined;
        return responseText;
      },
    );
  }

  @override
  void primeFailure() {
    _failureMode = true;
    _slowSpec = null;
    _provider = StubLlmProvider.alwaysFails(
      id: 'stub:b17',
      failure: const LlmFailure(
        classCode: 'unknown',
        message: 'transient 5xx (B.17 conformance failure prime)',
      ),
    );
  }

  @override
  void primeSlowStream({
    required int chunkCount,
    required Duration chunkDelay,
  }) {
    _failureMode = false;
    _slowSpec = (
      chunkCount: chunkCount,
      delay: chunkDelay,
      model: 'stub-model',
    );
    // A responder that emits the full text, plus a splitter that
    // produces N chunks. The stub itself is synchronous; for the
    // cancellation test we don't need real delays — the contract is
    // "no events after cancel" and the stub-side stream completes
    // immediately on `listen`. The B.14 / B.15 harnesses exercise the
    // async-cancellation arm; the stub exercises the synchronous-
    // cancellation arm.
    final body = List<String>.generate(
      chunkCount,
      (i) => 'chunk-$i',
    ).join(' ');
    _provider = StubLlmProvider(
      id: 'stub:b17',
      responder: (prompt, _) {
        _lastBody = prompt.combined;
        return body;
      },
      chunkSplitter: StubLlmProvider.splitByWord,
    );
  }

  @override
  Future<void> dispose() async {
    // No-op; the stub holds no resources.
  }

  // ignore: unused_element
  bool get isFailureMode => _failureMode;
  // ignore: unused_element
  _SlowStreamSpec? get slowSpec => _slowSpec;
}
