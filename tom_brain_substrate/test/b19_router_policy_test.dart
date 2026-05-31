// B.19 — `RouterPolicy` value-class conformance suite.
//
// What this suite pins:
//
//   1. **Defaults.** A `RouterPolicy.empty` carries no roles, the
//      spec-§ 5.3 default cooldowns (rate_limit 60 s, billing 24 h,
//      auth / auth_permanent / model_not_found 365 d), `retriesPerClass = 1`,
//      and `overloadedBackoff = 50 ms`. A policy constructed with
//      only `roleRoutes` inherits those defaults.
//
//   2. **Immutability.** `roleRoutes` and every chain inside it are
//      unmodifiable views; mutating attempts raise
//      `UnsupportedError`. Same for `cooldownByClass`. Mutating the
//      *source* map after construction does not leak into the policy
//      (the policy froze the snapshot).
//
//   3. **Lookups.** `routesFor(roleId)` returns the chain or `null`;
//      `cooldownFor(class)` returns the configured window or
//      `Duration.zero` for absent classes.
//
//   4. **Validation.** Negative `retriesPerClass`, negative
//      `overloadedBackoff`, and any negative entry in
//      `cooldownByClass` each raise `ArgumentError`. Empty
//      `roleRoutes` is allowed (the router will produce
//      `RoleNotFound` on first dispatch). An empty chain for a role
//      is allowed too (produces `NoRouteAvailable` with no
//      attempts).
//
//   5. **`copyWith` / `withRole`.** `copyWith` replaces named fields;
//      passing nothing returns a structurally equivalent policy. The
//      `withRole` shortcut adds or replaces one role's chain.
//
//   6. **Wiring into `LlmRouter`.** A router constructed with a
//      RouterPolicy honours its `retriesPerClass`,
//      `cooldownByClass`, and `overloadedBackoff`: a custom
//      cooldown window is respected by `isInCooldown` after the
//      relevant failure; a custom `retriesPerClass = 3` lets the
//      router burn three retries before rotating; the policy's
//      `roleRoutes` is the one the router walks.

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('RouterPolicy — construction + defaults', () {
    test('empty policy has no roles and inherits default cooldowns', () {
      final policy = RouterPolicy.empty;

      expect(policy.roleRoutes, isEmpty);
      expect(policy.retriesPerClass, RouterPolicy.defaultRetriesPerClass);
      expect(
        policy.overloadedBackoff,
        RouterPolicy.defaultOverloadedBackoff,
      );
      // Spec § 5.3 defaults — verify the named entries.
      expect(
        policy.cooldownFor(LlmFailureClass.rateLimit),
        const Duration(seconds: 60),
      );
      expect(
        policy.cooldownFor(LlmFailureClass.billing),
        const Duration(hours: 24),
      );
      expect(
        policy.cooldownFor(LlmFailureClass.auth),
        const Duration(days: 365),
      );
      expect(
        policy.cooldownFor(LlmFailureClass.authPermanent),
        const Duration(days: 365),
      );
      expect(
        policy.cooldownFor(LlmFailureClass.modelNotFound),
        const Duration(days: 365),
      );
    });

    test('absent class in cooldownByClass ⇒ Duration.zero', () {
      final policy = RouterPolicy(
        roleRoutes: const <String, List<RouteEntry>>{},
      );
      // `overloaded` and `timeout` are intentionally not in the default
      // cooldown map — they are handled by retry, not cooldown.
      expect(
        policy.cooldownFor(LlmFailureClass.overloaded),
        Duration.zero,
      );
      expect(
        policy.cooldownFor(LlmFailureClass.timeout),
        Duration.zero,
      );
      expect(
        policy.cooldownFor(LlmFailureClass.network),
        Duration.zero,
      );
    });

    test('policy with roleRoutes inherits default cooldowns', () {
      final policy = RouterPolicy(
        roleRoutes: <String, List<RouteEntry>>{
          'analyser': <RouteEntry>[
            const RouteEntry(providerId: 'a', model: 'm'),
          ],
        },
      );
      expect(policy.roleRoutes.keys, equals(<String>['analyser']));
      expect(
        policy.cooldownFor(LlmFailureClass.rateLimit),
        const Duration(seconds: 60),
      );
    });

    test('explicit cooldownByClass replaces defaults wholesale', () {
      final policy = RouterPolicy(
        roleRoutes: const <String, List<RouteEntry>>{},
        cooldownByClass: const <LlmFailureClass, Duration>{
          LlmFailureClass.rateLimit: Duration(seconds: 5),
        },
      );
      expect(
        policy.cooldownFor(LlmFailureClass.rateLimit),
        const Duration(seconds: 5),
      );
      // `billing` was in the defaults; an explicit map replaces wholesale,
      // so the previously-default 24 h is no longer present.
      expect(
        policy.cooldownFor(LlmFailureClass.billing),
        Duration.zero,
      );
    });

    test('explicit retriesPerClass + overloadedBackoff are honoured', () {
      final policy = RouterPolicy(
        roleRoutes: const <String, List<RouteEntry>>{},
        retriesPerClass: 4,
        overloadedBackoff: const Duration(milliseconds: 200),
      );
      expect(policy.retriesPerClass, 4);
      expect(policy.overloadedBackoff, const Duration(milliseconds: 200));
    });
  });

  group('RouterPolicy — immutability', () {
    test('roleRoutes map is unmodifiable', () {
      final policy = RouterPolicy(
        roleRoutes: <String, List<RouteEntry>>{
          'analyser': <RouteEntry>[
            const RouteEntry(providerId: 'a', model: 'm'),
          ],
        },
      );
      expect(
        () => policy.roleRoutes['x'] = <RouteEntry>[],
        throwsUnsupportedError,
      );
      expect(
        () => policy.roleRoutes.remove('analyser'),
        throwsUnsupportedError,
      );
    });

    test('each chain inside roleRoutes is unmodifiable', () {
      final policy = RouterPolicy(
        roleRoutes: <String, List<RouteEntry>>{
          'analyser': <RouteEntry>[
            const RouteEntry(providerId: 'a', model: 'm'),
          ],
        },
      );
      expect(
        () => policy.routesFor('analyser')!.add(
              const RouteEntry(providerId: 'b', model: 'm2'),
            ),
        throwsUnsupportedError,
      );
    });

    test('cooldownByClass map is unmodifiable', () {
      final policy = RouterPolicy(
        roleRoutes: const <String, List<RouteEntry>>{},
      );
      expect(
        () => policy.cooldownByClass[LlmFailureClass.rateLimit] =
            const Duration(seconds: 1),
        throwsUnsupportedError,
      );
    });

    test('mutating the source map after construction does not leak', () {
      final source = <String, List<RouteEntry>>{
        'analyser': <RouteEntry>[
          const RouteEntry(providerId: 'a', model: 'm'),
        ],
      };
      final policy = RouterPolicy(roleRoutes: source);
      // Mutate the source after the policy is built.
      source['analyser'] = <RouteEntry>[
        const RouteEntry(providerId: 'tampered', model: 'x'),
      ];
      source['extra'] = <RouteEntry>[];
      // Policy snapshot was frozen at construction.
      expect(policy.routesFor('analyser')!.single.providerId, 'a');
      expect(policy.routesFor('extra'), isNull);
    });
  });

  group('RouterPolicy — lookups', () {
    test('routesFor returns the chain when present, null otherwise', () {
      final policy = RouterPolicy(
        roleRoutes: <String, List<RouteEntry>>{
          'analyser': <RouteEntry>[
            const RouteEntry(providerId: 'a', model: 'm1'),
            const RouteEntry(providerId: 'b', model: 'm2'),
          ],
        },
      );
      expect(policy.routesFor('analyser'), hasLength(2));
      expect(policy.routesFor('missing'), isNull);
    });

    test('routesFor on an empty chain returns an empty list, not null', () {
      final policy = RouterPolicy(
        roleRoutes: <String, List<RouteEntry>>{
          'declared_but_unconfigured': const <RouteEntry>[],
        },
      );
      final chain = policy.routesFor('declared_but_unconfigured');
      expect(chain, isNotNull);
      expect(chain, isEmpty);
    });
  });

  group('RouterPolicy — validation', () {
    test('negative retriesPerClass raises ArgumentError', () {
      expect(
        () => RouterPolicy(
          roleRoutes: const <String, List<RouteEntry>>{},
          retriesPerClass: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('negative overloadedBackoff raises ArgumentError', () {
      expect(
        () => RouterPolicy(
          roleRoutes: const <String, List<RouteEntry>>{},
          overloadedBackoff: const Duration(milliseconds: -1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('negative duration in cooldownByClass raises ArgumentError', () {
      expect(
        () => RouterPolicy(
          roleRoutes: const <String, List<RouteEntry>>{},
          cooldownByClass: const <LlmFailureClass, Duration>{
            LlmFailureClass.rateLimit: Duration(seconds: -5),
          },
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('zero retriesPerClass is allowed', () {
      final policy = RouterPolicy(
        roleRoutes: const <String, List<RouteEntry>>{},
        retriesPerClass: 0,
      );
      expect(policy.retriesPerClass, 0);
    });

    test('zero overloadedBackoff is allowed', () {
      final policy = RouterPolicy(
        roleRoutes: const <String, List<RouteEntry>>{},
        overloadedBackoff: Duration.zero,
      );
      expect(policy.overloadedBackoff, Duration.zero);
    });

    test('empty roleRoutes is allowed', () {
      final policy = RouterPolicy(
        roleRoutes: const <String, List<RouteEntry>>{},
      );
      expect(policy.roleRoutes, isEmpty);
    });
  });

  group('RouterPolicy — copyWith / withRole', () {
    test('copyWith with no args returns a structurally equivalent policy', () {
      final original = RouterPolicy(
        roleRoutes: <String, List<RouteEntry>>{
          'r': <RouteEntry>[const RouteEntry(providerId: 'a', model: 'm')],
        },
        retriesPerClass: 3,
        overloadedBackoff: const Duration(milliseconds: 25),
      );
      final copy = original.copyWith();
      expect(copy.roleRoutes.keys.toList(), original.roleRoutes.keys.toList());
      expect(copy.retriesPerClass, original.retriesPerClass);
      expect(copy.overloadedBackoff, original.overloadedBackoff);
      expect(copy.cooldownByClass.length, original.cooldownByClass.length);
    });

    test('copyWith replaces only the named fields', () {
      final original = RouterPolicy(
        roleRoutes: const <String, List<RouteEntry>>{},
        retriesPerClass: 1,
      );
      final modified = original.copyWith(retriesPerClass: 7);
      expect(modified.retriesPerClass, 7);
      // Other fields unchanged.
      expect(
        modified.overloadedBackoff,
        RouterPolicy.defaultOverloadedBackoff,
      );
      expect(
        modified.cooldownFor(LlmFailureClass.rateLimit),
        const Duration(seconds: 60),
      );
    });

    test('withRole adds a role to an empty policy', () {
      final added = RouterPolicy.empty.withRole(
        'analyser',
        <RouteEntry>[const RouteEntry(providerId: 'a', model: 'm')],
      );
      expect(added.routesFor('analyser'), hasLength(1));
    });

    test('withRole replaces an existing role wholesale', () {
      final original = RouterPolicy(
        roleRoutes: <String, List<RouteEntry>>{
          'analyser': <RouteEntry>[
            const RouteEntry(providerId: 'a', model: 'm'),
          ],
        },
      );
      final replaced = original.withRole(
        'analyser',
        <RouteEntry>[const RouteEntry(providerId: 'b', model: 'n')],
      );
      expect(replaced.routesFor('analyser')!.single.providerId, 'b');
      // Original untouched.
      expect(original.routesFor('analyser')!.single.providerId, 'a');
    });

    test('toString surfaces the headline fields without leaking entries', () {
      final policy = RouterPolicy(
        roleRoutes: <String, List<RouteEntry>>{
          'analyser': <RouteEntry>[
            const RouteEntry(providerId: 'a', model: 'm'),
          ],
        },
        retriesPerClass: 2,
      );
      final s = policy.toString();
      expect(s, contains('analyser'));
      expect(s, contains('retries=2'));
    });
  });

  group('RouterPolicy — wiring into LlmRouter', () {
    test('Router honours policy.retriesPerClass', () async {
      // 3 consecutive 503 failures + a stub fallback. With
      // retriesPerClass = 3, the router burns three retries on the
      // first route before rotating; the fallback should still answer.
      final failing = _ScriptedFailingProvider(
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
          retriesPerClass: 3,
          overloadedBackoff: Duration.zero,
        ),
      );

      final report = await router.dispatch(
        roleId: 'r',
        prompt: _prompt('h'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );
      expect(report.providerId, 'fb');
      // Initial attempt + 3 retries on the failing route.
      expect(failing.callCount, 4);
    });

    test('Router honours policy.cooldownByClass (custom 1 s window)', () async {
      final clock = _MutableClock(DateTime.utc(2026, 1, 1, 12));
      final failing = _ScriptedFailingProvider(
        id: 'free',
        defaultModel: 'm',
        exceptions: <Object>[
          OllamaHttpException(
            statusCode: 429,
            body: 'rate',
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
          cooldownByClass: const <LlmFailureClass, Duration>{
            LlmFailureClass.rateLimit: Duration(seconds: 1),
          },
        ),
        now: clock.read,
      );

      await router.dispatch(
        roleId: 'r',
        prompt: _prompt('h'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );
      // Cooldown active immediately, gone after 1 s.
      expect(
        router.isInCooldown(providerId: 'free', modelId: 'm'),
        isTrue,
      );
      clock.advance(const Duration(milliseconds: 1100));
      expect(
        router.isInCooldown(providerId: 'free', modelId: 'm'),
        isFalse,
      );
    });

    test('Router walks policy.roleRoutes (RoleNotFound on unknown role)', () {
      final router = LlmRouter(
        providers: <String, LlmProvider>{
          'p': StubLlmProvider(id: 'p', defaultModel: 'm'),
        },
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'analyser': <RouteEntry>[
              const RouteEntry(providerId: 'p', model: 'm'),
            ],
          },
        ),
      );
      expect(
        () => router.dispatch(
          roleId: 'evaluator',
          prompt: _prompt('h'),
          options: LlmOptions.empty,
          budget: _bigBudget,
        ),
        throwsA(isA<RoleNotFound>()),
      );
    });

    test('Router.policy getters mirror the underlying policy', () {
      final policy = RouterPolicy(
        roleRoutes: <String, List<RouteEntry>>{
          'r': <RouteEntry>[const RouteEntry(providerId: 'a', model: 'm')],
        },
        retriesPerClass: 5,
        overloadedBackoff: const Duration(milliseconds: 12),
      );
      final router = LlmRouter(
        providers: <String, LlmProvider>{
          'a': StubLlmProvider(id: 'a', defaultModel: 'm'),
        },
        policy: policy,
      );
      expect(identical(router.policy, policy), isTrue);
      expect(router.retriesPerClass, 5);
      expect(router.overloadedBackoff, const Duration(milliseconds: 12));
      expect(router.roleRoutes.keys.toList(), <String>['r']);
    });
  });
}

// ─── Test helpers ────────────────────────────────────────────────

WirePrompt _prompt(String body) => WirePrompt(
      body: body,
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

class _MutableClock {
  DateTime _t;
  _MutableClock(this._t);
  DateTime read() => _t;
  void advance(Duration d) => _t = _t.add(d);
}

/// Hand-rolled scripted provider — same posture as B.14 / B.15 / B.16
/// (no `mocktail`, no `mockito`). Drains a queue of exceptions on each
/// `complete()` call; after the queue is empty it falls back to throwing
/// `StateError('script exhausted')`.
class _ScriptedFailingProvider implements LlmProvider {
  @override
  final String id;
  final String defaultModel;
  final List<Object> _exceptions;
  int callCount = 0;

  _ScriptedFailingProvider({
    required this.id,
    required this.defaultModel,
    required List<Object> exceptions,
  }) : _exceptions = List<Object>.of(exceptions);

  @override
  Future<LlmCallReport> complete(
    WirePrompt prompt,
    LlmOptions options,
  ) async {
    callCount++;
    if (_exceptions.isNotEmpty) {
      throw _exceptions.removeAt(0);
    }
    throw StateError('script exhausted');
  }

  @override
  Stream<LlmStreamEvent> completeStream(
    WirePrompt prompt,
    LlmOptions options,
  ) async* {
    callCount++;
    final callId = 'sfp-$id-$callCount';
    yield LlmStreamStarted(
      callId: callId,
      providerId: id,
      modelId: options.model ?? defaultModel,
    );
    if (_exceptions.isNotEmpty) {
      final ex = _exceptions.removeAt(0);
      yield LlmStreamFailed(
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
    yield LlmStreamCompleted(
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
