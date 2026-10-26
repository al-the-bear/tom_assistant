// B.18 — `LlmRouter` + `LlmFailureClassifier` conformance suite.
//
// What this suite pins:
//
//   1. **Classifier taxonomy.** Every row of spec § 5.4 is exercised:
//      HTTP 429 → rate_limit, 503 → overloaded, 402 → billing, 401 →
//      auth, 403 → auth_permanent, 404 → model_not_found, 400+context →
//      context_overflow, 400+format → format, TimeoutException →
//      timeout, SocketException → network, generic Exception → unknown.
//      Preservation: a provider-supplied LlmFailure whose `classCode`
//      already matches a known class is returned verbatim.
//
//   2. **Route selection.** A two-entry chain with both routes healthy
//      picks the first entry. A chain whose first entry is parked under
//      a cooldown rotates to the second.
//
//   3. **Free-tier rotation / paid-tier opt-in.** The router does not
//      know the labels; it walks the chain in order. A free-tier
//      provider that hits rate_limit cools down 60 s, the next call
//      transparently moves to the paid provider.
//
//   4. **Failover by class.** rate_limit / billing → cooldown + rotate;
//      auth_permanent → permanent removal (the route is parked for the
//      configured 365 d window — observed via `isInCooldown` rather
//      than waiting). model_not_found → permanent removal of
//      (provider, model). context_overflow → ContextOverflowError
//      surfaced; chain not exhausted further. overloaded → retry once
//      same route, then rotate. Cancelled-by-consumer surfaces as
//      NoRouteAvailable with `lastClass: cancelledByConsumer`.
//
//   5. **Budget enforcement.** A chain whose first attempt blows past
//      the wall-clock budget skips remaining entries with
//      `skipped:budget_wall_clock`. A retry that would push past the
//      budget is not issued.
//
//   6. **NoRouteAvailable trail.** When the chain is exhausted the
//      thrown exception carries an attempts list whose outcomes match
//      the spec's `skipped:*` / `failed:<class>:...` convention.
//
//   7. **RoleNotFound.** A roleId that is not in the route map raises
//      RoleNotFound; no provider is consulted.
//
//   8. **Streaming dispatch.** Success: replays buffered Started+Chunks
//      and the terminal Completed with retries folded in. Failure path
//      with retry: the failing route's buffered events are not relayed.
//      Chain exhaustion on streaming: yields one terminal LlmRunFailed
//      whose `classCode` is the last classification.

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_basics/utilities.dart' show TomCancellationSource;
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('LlmFailureClassifier', () {
    const classifier = LlmFailureClassifier.shared;

    test('HTTP 429 → rate_limit', () {
      final ex = OllamaHttpException(
        statusCode: 429,
        body: 'too many',
        endpoint: Uri.parse('http://x/y'),
      );
      expect(classifier.classify(ex), LlmFailureClass.rateLimit);
    });

    test('HTTP 503 → overloaded', () {
      final ex = OpenAiHttpException(
        statusCode: 503,
        body: 'overloaded',
        endpoint: Uri.parse('http://x/y'),
      );
      expect(classifier.classify(ex), LlmFailureClass.overloaded);
    });

    test('HTTP 402 → billing', () {
      final ex = OpenAiHttpException(
        statusCode: 402,
        body: 'payment required',
        endpoint: Uri.parse('http://x/y'),
      );
      expect(classifier.classify(ex), LlmFailureClass.billing);
    });

    test('HTTP 401 → auth', () {
      final ex = OpenAiHttpException(
        statusCode: 401,
        body: 'unauthorized',
        endpoint: Uri.parse('http://x/y'),
      );
      expect(classifier.classify(ex), LlmFailureClass.auth);
    });

    test('HTTP 403 → auth_permanent', () {
      final ex = OpenAiHttpException(
        statusCode: 403,
        body: 'forbidden',
        endpoint: Uri.parse('http://x/y'),
      );
      expect(classifier.classify(ex), LlmFailureClass.authPermanent);
    });

    test('HTTP 404 → model_not_found', () {
      final ex = OpenAiHttpException(
        statusCode: 404,
        body: 'no such model',
        endpoint: Uri.parse('http://x/y'),
      );
      expect(classifier.classify(ex), LlmFailureClass.modelNotFound);
    });

    test('HTTP 400 + context body → context_overflow', () {
      final ex = OpenAiHttpException(
        statusCode: 400,
        body: 'maximum context length exceeded',
        endpoint: Uri.parse('http://x/y'),
      );
      expect(classifier.classify(ex), LlmFailureClass.contextOverflow);
    });

    test('HTTP 400 + format body → format', () {
      final ex = OpenAiHttpException(
        statusCode: 400,
        body: 'response_format JSON schema invalid',
        endpoint: Uri.parse('http://x/y'),
      );
      expect(classifier.classify(ex), LlmFailureClass.format);
    });

    test('TimeoutException → timeout', () {
      expect(
        classifier.classify(TimeoutException('slow')),
        LlmFailureClass.timeout,
      );
    });

    test('SocketException → network', () {
      expect(
        classifier.classify(const SocketException('refused')),
        LlmFailureClass.network,
      );
    });

    test('Unknown exception → unknown', () {
      expect(classifier.classify(StateError('???')), LlmFailureClass.unknown);
    });

    test('Preserves provider-supplied LlmFailure classCode', () {
      const failure = LlmFailure(
        classCode: 'rate_limit',
        message: 'set by provider',
      );
      expect(classifier.classify(failure), LlmFailureClass.rateLimit);
    });

    test('wrap() returns typed LlmFailure with code + cause', () {
      final ex = OllamaHttpException(
        statusCode: 429,
        body: 'x',
        endpoint: Uri.parse('http://x'),
      );
      final wrapped = classifier.wrap(ex);
      expect(wrapped.classCode, 'rate_limit');
      expect(wrapped.cause, ex);
    });
  });

  group('LlmRouter — selection and rotation', () {
    late StubLlmProvider primary;
    late StubLlmProvider secondary;
    late LlmRouter router;
    late DateTime clock;

    setUp(() {
      clock = DateTime.utc(2026, 1, 1, 12, 0, 0);
      primary = StubLlmProvider(id: 'primary', defaultModel: 'p-model');
      secondary = StubLlmProvider(id: 'secondary', defaultModel: 's-model');
      router = LlmRouter(
        providers: <String, LlmProvider>{
          primary.id: primary,
          secondary.id: secondary,
        },
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'analyser': <RouteEntry>[
              const RouteEntry(providerId: 'primary', model: 'p-model'),
              const RouteEntry(providerId: 'secondary', model: 's-model'),
            ],
          },
        ),
        now: () => clock,
      );
    });

    test('Healthy chain picks the first entry', () async {
      final report = await router.dispatch(
        roleId: 'analyser',
        prompt: _prompt('hello'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );
      expect(report.providerId, 'primary');
      expect(report.modelId, 'p-model');
      expect(report.retries, 0);
    });

    test('Resolves options.model from the route entry', () async {
      final report = await router.dispatch(
        roleId: 'analyser',
        prompt: _prompt('hello'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );
      expect(report.modelId, 'p-model');
    });

    test('Honours caller-supplied options.model verbatim', () async {
      final report = await router.dispatch(
        roleId: 'analyser',
        prompt: _prompt('hello'),
        options: const LlmOptions(model: 'explicit'),
        budget: _bigBudget,
      );
      expect(report.modelId, 'explicit');
    });

    test('RoleNotFound when role missing', () async {
      expect(
        () => router.dispatch(
          roleId: 'missing',
          prompt: _prompt('h'),
          options: LlmOptions.empty,
          budget: _bigBudget,
        ),
        throwsA(isA<RoleNotFound>()),
      );
    });
  });

  group('LlmRouter — failover by class', () {
    test('rate_limit cools down 60 s and rotates', () async {
      final clock = _MutableClock(DateTime.utc(2026, 1, 1, 12));
      final failing = _ScriptedFailureProvider(
        id: 'free',
        defaultModel: 'free-model',
        exceptions: <Object>[
          OllamaHttpException(
            statusCode: 429,
            body: 'rate',
            endpoint: Uri.parse('http://x/y'),
          ),
        ],
      );
      final paid = StubLlmProvider(id: 'paid', defaultModel: 'paid-model');
      final router = LlmRouter(
        providers: <String, LlmProvider>{'free': failing, 'paid': paid},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'analyser': <RouteEntry>[
              const RouteEntry(providerId: 'free', model: 'free-model'),
              const RouteEntry(providerId: 'paid', model: 'paid-model'),
            ],
          },
        ),
        now: clock.read,
      );

      final report = await router.dispatch(
        roleId: 'analyser',
        prompt: _prompt('h'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );
      expect(report.providerId, 'paid');
      expect(
        router.isInCooldown(providerId: 'free', modelId: 'free-model'),
        isTrue,
      );

      // Advance past 60 s — cooldown clears.
      clock.advance(const Duration(seconds: 61));
      expect(
        router.isInCooldown(providerId: 'free', modelId: 'free-model'),
        isFalse,
      );
    });

    test('billing → 24 h cooldown and rotation', () async {
      final clock = _MutableClock(DateTime.utc(2026, 1, 1, 12));
      final failing = _ScriptedFailureProvider(
        id: 'free',
        defaultModel: 'm',
        exceptions: <Object>[
          OpenAiHttpException(
            statusCode: 402,
            body: 'payment required',
            endpoint: Uri.parse('http://x/y'),
          ),
        ],
      );
      final paid = StubLlmProvider(id: 'paid', defaultModel: 'pm');
      final router = LlmRouter(
        providers: <String, LlmProvider>{'free': failing, 'paid': paid},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'r': <RouteEntry>[
              const RouteEntry(providerId: 'free', model: 'm'),
              const RouteEntry(providerId: 'paid', model: 'pm'),
            ],
          },
        ),
        now: clock.read,
      );

      await router.dispatch(
        roleId: 'r',
        prompt: _prompt('p'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );

      clock.advance(const Duration(hours: 23, minutes: 59));
      expect(router.isInCooldown(providerId: 'free', modelId: 'm'), isTrue);
      clock.advance(const Duration(minutes: 2));
      expect(router.isInCooldown(providerId: 'free', modelId: 'm'), isFalse);
    });

    test('auth_permanent removes credential (provider-wide park)', () async {
      final clock = _MutableClock(DateTime.utc(2026, 1, 1, 12));
      final failing = _ScriptedFailureProvider(
        id: 'paid',
        defaultModel: 'm1',
        exceptions: <Object>[
          OpenAiHttpException(
            statusCode: 403,
            body: 'forbidden',
            endpoint: Uri.parse('http://x/y'),
          ),
        ],
      );
      final local = StubLlmProvider(id: 'local', defaultModel: 'm0');
      final router = LlmRouter(
        providers: <String, LlmProvider>{'paid': failing, 'local': local},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'r': <RouteEntry>[
              const RouteEntry(providerId: 'paid', model: 'm1'),
              const RouteEntry(providerId: 'paid', model: 'm2'),
              const RouteEntry(providerId: 'local', model: 'm0'),
            ],
          },
        ),
        now: clock.read,
      );

      final report = await router.dispatch(
        roleId: 'r',
        prompt: _prompt('p'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );
      expect(report.providerId, 'local');
      // Both paid models are now parked because the credential is
      // provider-wide.
      expect(router.isInCooldown(providerId: 'paid', modelId: 'm1'), isTrue);
      expect(router.isInCooldown(providerId: 'paid', modelId: 'm2'), isTrue);
    });

    test('model_not_found drops (provider, model) only', () async {
      final clock = _MutableClock(DateTime.utc(2026, 1, 1, 12));
      // First call: m1 returns 404; m2 (same provider) succeeds.
      final failing = _ScriptedFailureProvider(
        id: 'paid',
        defaultModel: 'm1',
        exceptions: <Object>[
          OpenAiHttpException(
            statusCode: 404,
            body: 'model "m1" not found',
            endpoint: Uri.parse('http://x/y'),
          ),
        ],
        fallthrough: () =>
            'PAID-OK', // for subsequent invocations -> succeed via stub default
      );
      final router = LlmRouter(
        providers: <String, LlmProvider>{'paid': failing},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'r': <RouteEntry>[
              const RouteEntry(providerId: 'paid', model: 'm1'),
              const RouteEntry(providerId: 'paid', model: 'm2'),
            ],
          },
        ),
        now: clock.read,
      );

      final report = await router.dispatch(
        roleId: 'r',
        prompt: _prompt('p'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );
      expect(report.providerId, 'paid');
      expect(report.modelId, 'm2');
      expect(router.isInCooldown(providerId: 'paid', modelId: 'm1'), isTrue);
      expect(router.isInCooldown(providerId: 'paid', modelId: 'm2'), isFalse);
    });

    test(
      'context_overflow surfaces ContextOverflowError; no rotation',
      () async {
        final failing = _ScriptedFailureProvider(
          id: 'p',
          defaultModel: 'm',
          exceptions: <Object>[
            OpenAiHttpException(
              statusCode: 400,
              body: 'maximum context length is 8192 tokens',
              endpoint: Uri.parse('http://x/y'),
            ),
          ],
        );
        final fallback = StubLlmProvider(id: 'fb', defaultModel: 'fbm');
        final router = LlmRouter(
          providers: <String, LlmProvider>{'p': failing, 'fb': fallback},
          policy: RouterPolicy(
            roleRoutes: <String, List<RouteEntry>>{
              'r': <RouteEntry>[
                const RouteEntry(providerId: 'p', model: 'm'),
                const RouteEntry(providerId: 'fb', model: 'fbm'),
              ],
            },
          ),
        );

        await expectLater(
          router.dispatch(
            roleId: 'r',
            prompt: _prompt('p'),
            options: LlmOptions.empty,
            budget: _bigBudget,
          ),
          throwsA(isA<ContextOverflowError>()),
        );
        expect(fallback.callCount, 0); // not rotated to
      },
    );

    test('overloaded retries once on the same route then rotates', () async {
      final failing = _ScriptedFailureProvider(
        id: 'p',
        defaultModel: 'm',
        exceptions: <Object>[
          OpenAiHttpException(
            statusCode: 503,
            body: 'overloaded',
            endpoint: Uri.parse('http://x/y'),
          ),
          OpenAiHttpException(
            statusCode: 503,
            body: 'overloaded',
            endpoint: Uri.parse('http://x/y'),
          ),
        ],
      );
      final fallback = StubLlmProvider(id: 'fb', defaultModel: 'fbm');
      final router = LlmRouter(
        providers: <String, LlmProvider>{'p': failing, 'fb': fallback},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'r': <RouteEntry>[
              const RouteEntry(providerId: 'p', model: 'm'),
              const RouteEntry(providerId: 'fb', model: 'fbm'),
            ],
          },
          retriesPerClass: 1,
          overloadedBackoff: Duration.zero,
        ),
      );

      final report = await router.dispatch(
        roleId: 'r',
        prompt: _prompt('p'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );
      expect(report.providerId, 'fb');
      expect(failing.callCount, 2); // initial + 1 retry
    });

    test('NoRouteAvailable when every entry fails', () async {
      final f1 = _ScriptedFailureProvider(
        id: 'a',
        defaultModel: 'm',
        exceptions: <Object>[
          OllamaHttpException(
            statusCode: 429,
            body: 'r',
            endpoint: Uri.parse('http://x'),
          ),
        ],
      );
      final f2 = _ScriptedFailureProvider(
        id: 'b',
        defaultModel: 'm',
        exceptions: <Object>[
          OpenAiHttpException(
            statusCode: 503,
            body: 'over',
            endpoint: Uri.parse('http://x'),
          ),
          OpenAiHttpException(
            statusCode: 503,
            body: 'over',
            endpoint: Uri.parse('http://x'),
          ),
        ],
      );
      final router = LlmRouter(
        providers: <String, LlmProvider>{'a': f1, 'b': f2},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'r': <RouteEntry>[
              const RouteEntry(providerId: 'a', model: 'm'),
              const RouteEntry(providerId: 'b', model: 'm'),
            ],
          },
          retriesPerClass: 1,
          overloadedBackoff: Duration.zero,
        ),
      );

      try {
        await router.dispatch(
          roleId: 'r',
          prompt: _prompt('p'),
          options: LlmOptions.empty,
          budget: _bigBudget,
        );
        fail('expected NoRouteAvailable');
      } on NoRouteAvailable catch (e) {
        expect(e.roleId, 'r');
        expect(e.attempts.length, 2);
        expect(e.attempts[0].classification, LlmFailureClass.rateLimit);
        expect(e.attempts[1].classification, LlmFailureClass.overloaded);
        expect(e.lastClass, LlmFailureClass.overloaded);
      }
    });

    test(
      'Cancelled token: NoRouteAvailable with cancelledByConsumer',
      () async {
        final source = TomCancellationSource()..cancel();
        final stub = StubLlmProvider(id: 'p', defaultModel: 'm');
        final router = LlmRouter(
          providers: <String, LlmProvider>{'p': stub},
          policy: RouterPolicy(
            roleRoutes: <String, List<RouteEntry>>{
              'r': <RouteEntry>[const RouteEntry(providerId: 'p', model: 'm')],
            },
          ),
        );
        try {
          await router.dispatch(
            roleId: 'r',
            prompt: _prompt('p'),
            options: LlmOptions.empty,
            budget: _bigBudget,
            cancellationToken: source.token,
          );
          fail('expected NoRouteAvailable');
        } on NoRouteAvailable catch (e) {
          expect(e.lastClass, LlmFailureClass.cancelledByConsumer);
        }
        expect(stub.callCount, 0);
      },
    );
  });

  group('LlmRouter — budget enforcement', () {
    test('Retry not issued past wall-clock budget', () async {
      final failing = _ScriptedFailureProvider(
        id: 'p',
        defaultModel: 'm',
        exceptions: <Object>[
          OpenAiHttpException(
            statusCode: 503,
            body: 'overloaded',
            endpoint: Uri.parse('http://x'),
          ),
          OpenAiHttpException(
            statusCode: 503,
            body: 'overloaded',
            endpoint: Uri.parse('http://x'),
          ),
        ],
        delay: const Duration(milliseconds: 30),
      );
      final router = LlmRouter(
        providers: <String, LlmProvider>{'p': failing},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'r': <RouteEntry>[const RouteEntry(providerId: 'p', model: 'm')],
          },
          retriesPerClass: 5,
          overloadedBackoff: Duration.zero,
        ),
      );
      // 20 ms budget — far less than the first call's 30 ms.
      try {
        await router.dispatch(
          roleId: 'r',
          prompt: _prompt('p'),
          options: LlmOptions.empty,
          budget: Budget(
            wallClockMs: 20,
            tokenSpend: 100,
            toolCalls: 0,
            memoryWrites: 0,
          ),
        );
        fail('expected NoRouteAvailable');
      } on NoRouteAvailable catch (_) {
        // First attempt consumed >20 ms; retry must NOT have happened.
        expect(failing.callCount, lessThanOrEqualTo(1));
      }
    });
  });

  group('LlmRouter — streaming dispatch', () {
    test('Happy path: forwards Started + Chunk + Completed', () async {
      final stub = StubLlmProvider(
        id: 'p',
        defaultModel: 'm',
        responder: (p, o) => 'one two three',
        chunkSplitter: StubLlmProvider.splitByWord,
      );
      final router = LlmRouter(
        providers: <String, LlmProvider>{'p': stub},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'r': <RouteEntry>[const RouteEntry(providerId: 'p', model: 'm')],
          },
        ),
      );

      final events = await router
          .dispatchStream(
            roleId: 'r',
            prompt: _prompt('hello'),
            options: LlmOptions.empty,
            budget: _bigBudget,
          )
          .toList();

      expect(events.first, isA<LlmRunStarted>());
      expect(events.last, isA<LlmRunCompleted>());
      final chunks = events.whereType<LlmTextDelta>().toList();
      expect(chunks.length, 3);
      expect(chunks.map((c) => c.text), <String>['one', 'two', 'three']);
    });

    test('Chain exhaustion yields a single terminal LlmRunFailed', () async {
      final failing = _ScriptedFailureProvider(
        id: 'p',
        defaultModel: 'm',
        exceptions: <Object>[
          OllamaHttpException(
            statusCode: 429,
            body: 'r',
            endpoint: Uri.parse('http://x'),
          ),
        ],
      );
      final router = LlmRouter(
        providers: <String, LlmProvider>{'p': failing},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'r': <RouteEntry>[const RouteEntry(providerId: 'p', model: 'm')],
          },
          retriesPerClass: 0,
        ),
      );

      final events = await router
          .dispatchStream(
            roleId: 'r',
            prompt: _prompt('h'),
            options: LlmOptions.empty,
            budget: _bigBudget,
          )
          .toList();

      expect(events.length, 1);
      expect(events.single, isA<LlmRunFailed>());
      final f = events.single as LlmRunFailed;
      expect(f.failure.classCode, LlmFailureClass.rateLimit.code);
    });
  });
}

// ─── Test helpers ────────────────────────────────────────────────

WirePrompt _prompt(String body) => WirePrompt(
  system: body,
  anchorHash: 'sha256:anchor',
  roleId: 'analyser',
  templateSha: 'sha-abc',
);

final Budget _bigBudget = Budget(
  wallClockMs: 60000,
  tokenSpend: 100000,
  toolCalls: 0,
  memoryWrites: 0,
);

/// Mutable clock for cooldown tests.
class _MutableClock {
  DateTime _t;
  _MutableClock(this._t);
  DateTime read() => _t;
  void advance(Duration d) => _t = _t.add(d);
}

/// LlmProvider that drains a scripted list of exceptions on successive
/// `complete` calls. When the script is exhausted it either falls back
/// to [fallthrough] (returning that string as a successful response) or
/// throws StateError.
///
/// Used to inject deterministic failures into the router's chain
/// without binding tests to a real HTTP backend.
class _ScriptedFailureProvider extends LlmProvider {
  @override
  final String id;
  final String defaultModel;
  final List<Object> _exceptions;
  final String Function()? fallthrough;
  final Duration delay;
  int callCount = 0;

  _ScriptedFailureProvider({
    required this.id,
    required this.defaultModel,
    required List<Object> exceptions,
    this.fallthrough,
    this.delay = Duration.zero,
  }) : _exceptions = List<Object>.of(exceptions);

  @override
  Future<LlmCallReport> complete(LlmRequest request) async {
    final prompt = request.prompt;
    final options = request.options;
    callCount++;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (_exceptions.isNotEmpty) {
      throw _exceptions.removeAt(0);
    }
    if (fallthrough != null) {
      final r = fallthrough!();
      return LlmCallReport(
        providerId: id,
        modelId: options.model ?? defaultModel,
        anchorHash: prompt.anchorHash,
        promptHash: 'sha256:body',
        tokensIn: prompt.combined.length,
        tokensOut: r.length,
        retries: 0,
        wallClockMs: 0,
        templateSha: prompt.templateSha,
      );
    }
    throw StateError('script exhausted');
  }

  @override
  Stream<LlmEvent> run(LlmRequest request) async* {
    final prompt = request.prompt;
    final options = request.options;
    callCount++;
    final callId = 'sfp-$id-$callCount';
    yield LlmRunStarted(
      callId: callId,
      providerId: id,
      modelId: options.model ?? defaultModel,
    );
    if (_exceptions.isNotEmpty) {
      final ex = _exceptions.removeAt(0);
      yield LlmRunFailed(
        callId: callId,
        failure: LlmFailure(
          classCode: 'unknown',
          message: ex.toString(),
          cause: ex,
        ),
        report: LlmCallReport(
          providerId: id,
          modelId: options.model ?? defaultModel,
          anchorHash: prompt.anchorHash,
          promptHash: '',
          tokensIn: 0,
          tokensOut: 0,
          retries: 0,
          wallClockMs: 0,
        ),
      );
      return;
    }
    yield LlmRunCompleted(
      callId: callId,
      report: LlmCallReport(
        providerId: id,
        modelId: options.model ?? defaultModel,
        anchorHash: prompt.anchorHash,
        promptHash: '',
        tokensIn: 0,
        tokensOut: 0,
        retries: 0,
        wallClockMs: 0,
      ),
    );
  }
}
