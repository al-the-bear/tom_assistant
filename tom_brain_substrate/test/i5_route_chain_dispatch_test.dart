// Increment 5 (prompt_configuration.md §7.4) — explicit-route-chain dispatch.
//
// The cognition-config `llm:` routing seam: a prompt selects its LLM route by
// *name*, the bridge resolves the name to a `List<RouteEntry>`, and routing
// dispatches over that chain instead of the role-keyed `roleRoutes[roleId]`
// chain. The role still assembles the wire prompt (persona + anchor) upstream;
// here we pin only the routing half.
//
// What this suite pins:
//
//   1. `dispatchStreamOverChain` walks the SUPPLIED chain, not `roleRoutes` —
//      proven by using a `roleId` that is absent from `roleRoutes` (which would
//      otherwise raise `RoleNotFound`).
//   2. `dispatchOverChain` (buffered) does the same.
//   3. Failover within the explicit chain: first entry fails → rotate to the
//      second, identical to role-keyed failover.
//   4. An empty explicit chain raises `EmptyRouteChain`.

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('LlmRouter — explicit route-chain dispatch (§7.4)', () {
    late StubLlmProvider primary;
    late StubLlmProvider secondary;
    late LlmRouter router;

    setUp(() {
      primary = StubLlmProvider(id: 'primary', defaultModel: 'p-model');
      secondary = StubLlmProvider(id: 'secondary', defaultModel: 's-model');
      router = LlmRouter(
        providers: <String, LlmProvider>{
          primary.id: primary,
          secondary.id: secondary,
        },
        // Deliberately empty: the explicit-chain path must NOT consult this.
        policy: RouterPolicy(roleRoutes: const <String, List<RouteEntry>>{}),
      );
    });

    test('dispatchOverChain routes over the supplied chain, not roleRoutes',
        () async {
      final report = await router.dispatchOverChain(
        // `unmapped` is not in roleRoutes; role-keyed routing would throw.
        roleId: 'unmapped',
        chain: const <RouteEntry>[
          RouteEntry(providerId: 'primary', model: 'p-model'),
          RouteEntry(providerId: 'secondary', model: 's-model'),
        ],
        prompt: _prompt('hello'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );
      expect(report.providerId, 'primary');
      expect(report.modelId, 'p-model');
      expect(report.retries, 0);
    });

    test('dispatchStreamOverChain routes over the supplied chain', () async {
      final stub = StubLlmProvider(
        id: 'p',
        defaultModel: 'm',
        responder: (p, o) => 'one two three',
        chunkSplitter: StubLlmProvider.splitByWord,
      );
      final streamRouter = LlmRouter(
        providers: <String, LlmProvider>{'p': stub},
        policy: RouterPolicy(roleRoutes: const <String, List<RouteEntry>>{}),
      );

      final events = await streamRouter
          .dispatchStreamOverChain(
            roleId: 'unmapped',
            chain: const <RouteEntry>[RouteEntry(providerId: 'p', model: 'm')],
            prompt: _prompt('hello'),
            options: LlmOptions.empty,
            budget: _bigBudget,
          )
          .toList();

      expect(events.first, isA<LlmStreamStarted>());
      expect(events.last, isA<LlmStreamCompleted>());
      final chunks = events.whereType<LlmStreamChunk>().toList();
      expect(chunks.map((c) => c.text), <String>['one', 'two', 'three']);
    });

    test('failover within the explicit chain rotates to the second entry',
        () async {
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
      final foRouter = LlmRouter(
        providers: <String, LlmProvider>{'free': failing, 'paid': paid},
        policy: RouterPolicy(
          roleRoutes: const <String, List<RouteEntry>>{},
          retriesPerClass: 0,
        ),
      );

      final report = await foRouter.dispatchOverChain(
        roleId: 'unmapped',
        chain: const <RouteEntry>[
          RouteEntry(providerId: 'free', model: 'free-model'),
          RouteEntry(providerId: 'paid', model: 'paid-model'),
        ],
        prompt: _prompt('hi'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );
      expect(report.providerId, 'paid');
    });

    test('empty explicit chain raises EmptyRouteChain (buffered)', () {
      expect(
        () => router.dispatchOverChain(
          roleId: 'unmapped',
          chain: const <RouteEntry>[],
          prompt: _prompt('h'),
          options: LlmOptions.empty,
          budget: _bigBudget,
        ),
        throwsA(isA<EmptyRouteChain>()),
      );
    });

    test('empty explicit chain raises EmptyRouteChain (streaming)', () {
      expect(
        () => router
            .dispatchStreamOverChain(
              roleId: 'unmapped',
              chain: const <RouteEntry>[],
              prompt: _prompt('h'),
              options: LlmOptions.empty,
              budget: _bigBudget,
            )
            .toList(),
        throwsA(isA<EmptyRouteChain>()),
      );
    });
  });
}

// ─── Test helpers ────────────────────────────────────────────────

WirePrompt _prompt(String body) => WirePrompt(
      body: body,
      anchorHash: 'sha256:anchor',
      roleId: 'assistant_to_user',
      templateSha: 'sha-abc',
    );

final Budget _bigBudget = Budget(
  wallClockMs: 60000,
  tokenSpend: 100000,
  toolCalls: 0,
  memoryWrites: 0,
);

/// LlmProvider that throws a scripted exception on its first `complete` call,
/// forcing the router to rotate to the next chain entry. Mirrors the helper in
/// `b18_llm_router_test.dart` (kept local to avoid cross-test coupling).
class _ScriptedFailureProvider implements LlmProvider {
  @override
  final String id;
  final String defaultModel;
  final List<Object> _exceptions;
  int callCount = 0;

  _ScriptedFailureProvider({
    required this.id,
    required this.defaultModel,
    required List<Object> exceptions,
  }) : _exceptions = List<Object>.of(exceptions);

  @override
  Future<LlmCallReport> complete(WirePrompt prompt, LlmOptions options) async {
    callCount++;
    if (_exceptions.isNotEmpty) throw _exceptions.removeAt(0);
    return LlmCallReport(
      providerId: id,
      modelId: options.model ?? defaultModel,
      anchorHash: prompt.anchorHash,
      promptHash: 'sha256:body',
      tokensIn: prompt.body.length,
      tokensOut: 1,
      retries: 0,
      wallClockMs: 0,
      templateSha: prompt.templateSha,
    );
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
