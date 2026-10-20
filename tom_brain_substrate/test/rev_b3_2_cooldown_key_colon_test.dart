// Review fix B.3.2 — cooldown keys must not collide on the `:` that model
// ids legitimately contain.
//
// `prototype_review_result.md` § B.3.2 flagged that `LlmRouter` stored
// cooldowns under `:`-delimited string keys
// (`<providerId>:<modelId>:<classCode>`) and matched them with
// `startsWith('<providerId>:<modelId>:')`. Model ids in this workspace
// routinely contain colons — `gemma3:27b`, `qwen2.5:14b`,
// `text-embedding-3-small` does not but `llama3.1:8b` does. A cooldown
// parked on `gemma3:27b` has the full key `ollama:gemma3:27b:rate_limit`,
// and the prefix `ollama:gemma3:` is *also* a prefix of that key — so a
// query for the sibling model `gemma3` reports the sibling as cooled
// down too. One model's rate-limit silently parks an unrelated model on
// the same provider.
//
// These tests pin the structured-key behaviour: a cooldown on
// `(ollama, gemma3:27b)` is observable on exactly that route and on no
// sibling, while a provider-wide park (`auth`-class) is observable on
// every model of the provider.

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.3.2 / cooldown key does not collide on a colon in the model id', () {
    test('parking gemma3:27b does not park sibling gemma3', () async {
      final clock = _MutableClock(DateTime.utc(2026, 1, 1, 12));
      final ollama = _ScriptedFailureProvider(
        id: 'ollama',
        defaultModel: 'gemma3:27b',
        exceptions: <Object>[
          OllamaHttpException(
            statusCode: 429,
            body: 'rate',
            endpoint: Uri.parse('http://localhost:11434/api/chat'),
          ),
        ],
      );
      final paid = StubLlmProvider(id: 'paid', defaultModel: 'paid-model');
      final router = LlmRouter(
        providers: <String, LlmProvider>{'ollama': ollama, 'paid': paid},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'analyser': <RouteEntry>[
              const RouteEntry(providerId: 'ollama', model: 'gemma3:27b'),
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

      // The route that actually failed is parked …
      expect(
        router.isInCooldown(providerId: 'ollama', modelId: 'gemma3:27b'),
        isTrue,
        reason: 'the route that hit rate_limit must be in cooldown',
      );
      // … but the sibling model that shares the `gemma3` prefix is NOT.
      expect(
        router.isInCooldown(providerId: 'ollama', modelId: 'gemma3'),
        isFalse,
        reason: 'a sibling model must not be parked by a colon-prefix match',
      );
    });

    test('parking gemma3 does not park gemma3:27b', () async {
      final clock = _MutableClock(DateTime.utc(2026, 1, 1, 12));
      final ollama = _ScriptedFailureProvider(
        id: 'ollama',
        defaultModel: 'gemma3',
        exceptions: <Object>[
          OllamaHttpException(
            statusCode: 429,
            body: 'rate',
            endpoint: Uri.parse('http://localhost:11434/api/chat'),
          ),
        ],
      );
      final paid = StubLlmProvider(id: 'paid', defaultModel: 'paid-model');
      final router = LlmRouter(
        providers: <String, LlmProvider>{'ollama': ollama, 'paid': paid},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'analyser': <RouteEntry>[
              const RouteEntry(providerId: 'ollama', model: 'gemma3'),
              const RouteEntry(providerId: 'paid', model: 'paid-model'),
            ],
          },
        ),
        now: clock.read,
      );

      await router.dispatch(
        roleId: 'analyser',
        prompt: _prompt('h'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );

      expect(
        router.isInCooldown(providerId: 'ollama', modelId: 'gemma3'),
        isTrue,
      );
      // The longer, more specific model id is a different route entirely.
      expect(
        router.isInCooldown(providerId: 'ollama', modelId: 'gemma3:27b'),
        isFalse,
      );
    });
  });

  group('B.3.2 / provider-wide park still spans every model', () {
    test('auth_permanent parks all models of the provider', () async {
      final clock = _MutableClock(DateTime.utc(2026, 1, 1, 12));
      final ollama = _ScriptedFailureProvider(
        id: 'ollama',
        defaultModel: 'gemma3:27b',
        exceptions: <Object>[
          OpenAiHttpException(
            statusCode: 403,
            body: 'forbidden',
            endpoint: Uri.parse('http://localhost:11434/api/chat'),
          ),
        ],
      );
      final paid = StubLlmProvider(id: 'paid', defaultModel: 'paid-model');
      final router = LlmRouter(
        providers: <String, LlmProvider>{'ollama': ollama, 'paid': paid},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'analyser': <RouteEntry>[
              const RouteEntry(providerId: 'ollama', model: 'gemma3:27b'),
              const RouteEntry(providerId: 'paid', model: 'paid-model'),
            ],
          },
        ),
        now: clock.read,
      );

      await router.dispatch(
        roleId: 'analyser',
        prompt: _prompt('h'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );

      // auth_permanent → removeCredential → provider-wide park. Every
      // model of the provider — including ones never dispatched — reads
      // as in-cooldown.
      expect(
        router.isInCooldown(providerId: 'ollama', modelId: 'gemma3:27b'),
        isTrue,
      );
      expect(
        router.isInCooldown(providerId: 'ollama', modelId: 'some-other-model'),
        isTrue,
      );
      // A different provider is unaffected.
      expect(
        router.isInCooldown(providerId: 'paid', modelId: 'paid-model'),
        isFalse,
      );
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

class _MutableClock {
  DateTime _t;
  _MutableClock(this._t);
  DateTime read() => _t;
  void advance(Duration d) => _t = _t.add(d);
}

/// LlmProvider that throws a scripted exception on its first `complete`
/// call, then succeeds. Mirrors the fake from `b18_llm_router_test.dart`
/// kept local so this review-fix suite stands alone.
class _ScriptedFailureProvider extends LlmProvider {
  @override
  final String id;
  final String defaultModel;
  final List<Object> _exceptions;

  _ScriptedFailureProvider({
    required this.id,
    required this.defaultModel,
    required List<Object> exceptions,
  }) : _exceptions = List<Object>.of(exceptions);

  @override
  Future<LlmCallReport> complete(LlmRequest request) async {
    final prompt = request.prompt;
    final options = request.options;
    if (_exceptions.isNotEmpty) {
      throw _exceptions.removeAt(0);
    }
    return LlmCallReport(
      providerId: id,
      modelId: options.model ?? defaultModel,
      anchorHash: prompt.anchorHash,
      promptHash: 'sha256:body',
      tokensIn: prompt.combined.length,
      tokensOut: 1,
      retries: 0,
      wallClockMs: 0,
      templateSha: prompt.templateSha,
    );
  }

  @override
  Stream<LlmEvent> run(LlmRequest request) async* {
    final prompt = request.prompt;
    final options = request.options;
    final callId = 'sfp-$id';
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
