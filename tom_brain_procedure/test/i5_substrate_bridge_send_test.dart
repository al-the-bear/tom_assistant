// Increment 5 (prompt_configuration.md §7.4) — `sub.send`: one completion over
// an explicitly *named* LLM route.
//
// `send` is the low-level half of the routing seam. Where `llm` routes by the
// role's chain (`roleRoutes[role]`), `send` routes over the chain a named route
// resolves to — the prompt's `llm:` selection (§8). The role still assembles
// the wire prompt (persona + anchor), so the anchor invariant is preserved; the
// only thing that moves off the role is *route selection*.
//
// What this suite pins:
//
//   1. `send` resolves the route NAME through the injected RouteChainResolver
//      and rides the resolved chain onto `LlmCall.routeChain`.
//   2. The `role` is still carried as `LlmCall.roleId` — it assembles the wire
//      prompt; only the route moved off the role.
//   3. `temperature` / `maxOutputTokens` / `responseFormat` ride onto
//      `LlmOptions`.
//   4. `send` returns the same `{text, toolCalls, unresolvedToolCall, report}`
//      shape as `llm`.
//   5. With no resolver bound, `send` throws a StateError (a wiring bug — it
//      cannot route).
//   6. The resolver's own error (unknown route name) propagates.

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

void main() {
  late _FakeSubstrateClient client;

  setUp(() {
    client = _FakeSubstrateClient();
  });

  group('§7.4 SubstrateBridge.send — explicit-route completion', () {
    test('resolves the route name and rides the chain onto LlmCall.routeChain',
        () async {
      String? resolvedName;
      final bridge = SubstrateBridge(
        client,
        routeChainOf: (name) {
          resolvedName = name;
          return const <RouteEntry>[
            RouteEntry(providerId: 'fast-provider', model: 'fast-model'),
            RouteEntry(providerId: 'backup-provider', model: 'backup-model'),
          ];
        },
      );
      client.streamEvents = _completedStream('answer');

      await bridge.send('a transcript', llmRoute: 'fast');

      // The resolver was consulted with the route NAME.
      expect(resolvedName, 'fast');
      // The resolved chain rides onto the call, NOT a role-keyed lookup.
      final call = client.lastCall!;
      expect(call.routeChain, isNotNull);
      expect(call.routeChain!.map((e) => e.providerId),
          <String>['fast-provider', 'backup-provider']);
      // The prompt body is the transcript, under the role template's `prompt`.
      expect(call.inputs, <String, Object?>{'prompt': 'a transcript'});
    });

    test('still carries the role as LlmCall.roleId (role assembles the prompt)',
        () async {
      final bridge = SubstrateBridge(
        client,
        routeChainOf: (_) =>
            const <RouteEntry>[RouteEntry(providerId: 'p', model: 'm')],
      );
      client.streamEvents = _completedStream('ok');

      await bridge.send('q', llmRoute: 'deep', role: 'sub_thinker');

      expect(client.lastCall!.roleId, 'sub_thinker');
    });

    test('defaults the role to assistant_to_user when none is named', () async {
      final bridge = SubstrateBridge(
        client,
        routeChainOf: (_) =>
            const <RouteEntry>[RouteEntry(providerId: 'p', model: 'm')],
      );
      client.streamEvents = _completedStream('ok');

      await bridge.send('q', llmRoute: 'fast');

      expect(client.lastCall!.roleId, SubstrateBridge.defaultRole);
    });

    test('carries temperature / maxOutputTokens / responseFormat onto options',
        () async {
      final bridge = SubstrateBridge(
        client,
        routeChainOf: (_) =>
            const <RouteEntry>[RouteEntry(providerId: 'p', model: 'm')],
      );
      client.streamEvents = _completedStream('ok');

      await bridge.send(
        'q',
        llmRoute: 'fast',
        temperature: 0.2,
        maxOutputTokens: 256,
        responseFormat: const <String, Object?>{'type': 'json_object'},
      );

      final options = client.lastCall!.options;
      expect(options.temperature, 0.2);
      expect(options.maxOutputTokens, 256);
      expect(options.responseFormat, <String, Object?>{'type': 'json_object'});
    });

    test('returns the same shape as llm (text, toolCalls, report)', () async {
      final bridge = SubstrateBridge(
        client,
        routeChainOf: (_) =>
            const <RouteEntry>[RouteEntry(providerId: 'p', model: 'm')],
      );
      client.streamEvents = <LlmStreamEvent>[
        const LlmStreamChunk(callId: 'c', text: 'one '),
        const LlmStreamChunk(callId: 'c', text: 'two'),
        const LlmStreamCompleted(
          callId: 'c',
          report: LlmCallReport(
            providerId: 'p',
            modelId: 'm',
            anchorHash: 'a',
            promptHash: 'pr',
            tokensIn: 5,
            tokensOut: 3,
            retries: 0,
            wallClockMs: 9,
          ),
        ),
      ];

      final out = await bridge.send('q', llmRoute: 'fast');

      expect(out['text'], 'one two');
      expect(out['toolCalls'], <Object?>[]);
      expect(out['unresolvedToolCall'], false);
      final report = out['report']! as Map<String, Object?>;
      expect(report['providerId'], 'p');
      expect(report['tokensIn'], 5);
      expect(report['tokensOut'], 3);
    });

    test('throws StateError when no RouteChainResolver is bound', () {
      final bridge = SubstrateBridge(client); // no routeChainOf
      expect(
        () => bridge.send('q', llmRoute: 'fast'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('sub.send requires a RouteChainResolver'),
        )),
      );
    });

    test('propagates the resolver error for an unknown route name', () {
      final bridge = SubstrateBridge(
        client,
        routeChainOf: (name) =>
            throw ArgumentError.value(name, 'route', 'unknown LLM route'),
      );
      expect(
        () => bridge.send('q', llmRoute: 'nope'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

/// Builds a minimal Started→Chunk→Completed stream emitting [text].
List<LlmStreamEvent> _completedStream(String text) => <LlmStreamEvent>[
      LlmStreamChunk(callId: 'c', text: text),
      const LlmStreamCompleted(
        callId: 'c',
        report: LlmCallReport(
          providerId: 'p',
          modelId: 'm',
          anchorHash: 'a',
          promptHash: 'pr',
          tokensIn: 1,
          tokensOut: 1,
          retries: 0,
          wallClockMs: 1,
        ),
      ),
    ];

/// Fake `TomBrainSubstrateClient` capturing the `LlmCall` `send` issues.
class _FakeSubstrateClient implements TomBrainSubstrateClient {
  LlmCall? lastCall;
  List<LlmStreamEvent> streamEvents = const <LlmStreamEvent>[];

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    lastCall = call;
    return Stream<LlmStreamEvent>.fromIterable(streamEvents);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
