// Extension F step 10 — substrate-completion tool-protocol widening.
//
// `SubstrateBridge.send` (the surviving low-level completion entry after the
// `llm` method was retired in Phase 5, step 12) carries an optional `tools`
// catalogue and returns `{text, toolCalls, unresolvedToolCall, report}`
// (`toolCalls` empty when none). The substrate hides the wire protocol behind
// the resolved provider's `toolProtocol`
// (`tom_brain_procedure_specification.md` § 21.1, § 21.6, Q-F.4):
//
//   - `openai`    — the provider surfaces native `tool_calls` as
//                   `LlmToolCall` events; the bridge collects
//                   them into the uniform `toolCalls` list.
//   - `json_text` — a non-tool-calling model emits a simple JSON tool-call
//                   object in the completion text; the bridge parses it into
//                   the *same* uniform shape. A malformed object is treated as
//                   a no-tool answer plus an `llm.toolcall.parse.failed` note.
//
// `call_llm_v1` (step 11) thereby sees one `toolCalls` shape regardless of
// provider. No loop is added here — that lives entirely in `call_llm_v1`.
//
// Native Dart tests against the `TomBrainSubstrateClient` interface boundary
// (PE-10); no d4rt generator, no network.

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

/// A trivial [RouteChainResolver] every `send` in this file routes over — the
/// low-level `llm` method was retired (Phase 5, step 12), so the bridge's
/// completion entry is now `send`, which selects a route by name and needs a
/// resolver bound. The fake client ignores the chain; only its presence
/// matters.
List<RouteEntry> _fastRoute(String _) => const <RouteEntry>[
  RouteEntry(providerId: 'p', model: 'm'),
];

void main() {
  late _FakeSubstrateClient client;

  setUp(() {
    client = _FakeSubstrateClient();
  });

  group('F.10 SubstrateBridge.send — tools inbound conversion', () {
    test(
      'passes the tool catalogue onto LlmOptions (name/desc/schema)',
      () async {
        client.streamEvents = _completed('answer', providerId: 'omlx');
        final bridge = SubstrateBridge(client, routeChainOf: _fastRoute);

        await bridge.send(
          'q',
          llmRoute: 'fast',
          tools: <Object?>[
            <String, Object?>{
              'name': 'memory.read',
              'description': 'reads a memory node',
              'input_schema': <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'id': <String, Object?>{'type': 'string'},
                },
              },
            },
          ],
        );

        final catalogue = client.lastCall!.options.toolCatalogue;
        expect(catalogue.tools, hasLength(1));
        final descriptor = catalogue.tools.single;
        expect(descriptor.name, 'memory.read');
        expect(descriptor.description, 'reads a memory node');
        expect(descriptor.parametersSchema['type'], 'object');
      },
    );

    test(
      'no tools ⇒ empty catalogue, and the return still carries toolCalls',
      () async {
        client.streamEvents = _completed('plain answer', providerId: 'omlx');
        final bridge = SubstrateBridge(client, routeChainOf: _fastRoute);

        final out = await bridge.send('q', llmRoute: 'fast');

        expect(client.lastCall!.options.toolCatalogue.isEmpty, isTrue);
        expect(out['text'], 'plain answer');
        expect(out['toolCalls'], isEmpty);
        expect(out.containsKey('report'), isTrue);
      },
    );

    test(
      'rejects a tool entry missing its name with a FormatException',
      () async {
        client.streamEvents = _completed('a', providerId: 'omlx');
        final bridge = SubstrateBridge(client, routeChainOf: _fastRoute);

        await expectLater(
          bridge.send(
            'q',
            llmRoute: 'fast',
            tools: <Object?>[
              <String, Object?>{'description': 'no name here'},
            ],
          ),
          throwsA(isA<FormatException>()),
        );
      },
    );
  });

  group('F.10 SubstrateBridge.send — openai protocol (native tool_calls)', () {
    test('collects LlmToolCall events into uniform toolCalls', () async {
      client.streamEvents = <LlmEvent>[
        const LlmRunStarted(callId: 'c1', providerId: 'omlx', modelId: 'gemma'),
        const LlmToolCall(
          callId: 'call_1',
          name: 'memory.read',
          arguments: <String, Object?>{'q': 'x'},
        ),
        _ok('c1'),
      ];
      // Default (no resolver) ⇒ openai protocol.
      final bridge = SubstrateBridge(client, routeChainOf: _fastRoute);

      final out = await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

      final calls = out['toolCalls']! as List<Object?>;
      expect(calls, hasLength(1));
      final call = calls.single! as Map<String, Object?>;
      expect(call['id'], 'call_1');
      expect(call['name'], 'memory.read');
      expect(call['arguments'], <String, Object?>{'q': 'x'});
    });

    test(
      'a plain completion under openai ⇒ empty toolCalls, no note',
      () async {
        final notes = <_CapturedNote>[];
        client.streamEvents = _completed('just prose', providerId: 'omlx');
        final bridge = SubstrateBridge(
          client,
          routeChainOf: _fastRoute,
          onNote: _capture(notes),
        );

        final out = await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

        expect(out['text'], 'just prose');
        expect(out['toolCalls'], isEmpty);
        expect(notes, isEmpty);
      },
    );
  });

  group('F.10 SubstrateBridge.send — json_text protocol (JSON in text)', () {
    test(
      'parses a JSON tool-call object from the completion identically',
      () async {
        client.streamEvents = _completed(
          '{"tool": "memory.read", "arguments": {"q": "x"}}',
          providerId: 'ollama',
        );
        final bridge = SubstrateBridge(
          client,
          routeChainOf: _fastRoute,
          toolProtocolOf: (_) => ToolProtocol.jsonText,
        );

        final out = await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

        final calls = out['toolCalls']! as List<Object?>;
        expect(calls, hasLength(1));
        final call = calls.single! as Map<String, Object?>;
        // Same uniform shape as the openai path: id/name/arguments keys.
        expect(call.keys.toSet(), <String>{'id', 'name', 'arguments'});
        expect(call['name'], 'memory.read');
        expect(call['arguments'], <String, Object?>{'q': 'x'});
      },
    );

    test('tolerates a markdown-fenced JSON tool-call block', () async {
      client.streamEvents = _completed(
        '```json\n{"tool": "memory.read", "arguments": {}}\n```',
        providerId: 'ollama',
      );
      final bridge = SubstrateBridge(
        client,
        routeChainOf: _fastRoute,
        toolProtocolOf: (_) => ToolProtocol.jsonText,
      );

      final out = await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

      final calls = out['toolCalls']! as List<Object?>;
      expect(calls, hasLength(1));
      expect((calls.single! as Map<String, Object?>)['name'], 'memory.read');
    });

    test('malformed JSON ⇒ empty toolCalls + the typed note', () async {
      final notes = <_CapturedNote>[];
      client.streamEvents = _completed(
        '{"tool": "memory.read", "arguments": {bad', // broken JSON
        providerId: 'ollama',
      );
      final bridge = SubstrateBridge(
        client,
        routeChainOf: _fastRoute,
        onNote: _capture(notes),
        toolProtocolOf: (_) => ToolProtocol.jsonText,
      );

      final out = await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

      expect(out['toolCalls'], isEmpty);
      // The text falls through as the no-tool answer.
      expect(out['text'], contains('"tool"'));
      expect(notes, hasLength(1));
      expect(notes.single.category, 'llm.toolcall.parse.failed');
    });

    test('plain prose under json_text ⇒ empty toolCalls, no note', () async {
      final notes = <_CapturedNote>[];
      client.streamEvents = _completed(
        'The answer is 42.',
        providerId: 'ollama',
      );
      final bridge = SubstrateBridge(
        client,
        routeChainOf: _fastRoute,
        onNote: _capture(notes),
        toolProtocolOf: (_) => ToolProtocol.jsonText,
      );

      final out = await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

      expect(out['text'], 'The answer is 42.');
      expect(out['toolCalls'], isEmpty);
      expect(notes, isEmpty);
    });

    test('a JSON object that is not a tool call ⇒ malformed note', () async {
      final notes = <_CapturedNote>[];
      client.streamEvents = _completed(
        '{"answer": 42}', // valid JSON, but no `tool` key
        providerId: 'ollama',
      );
      final bridge = SubstrateBridge(
        client,
        routeChainOf: _fastRoute,
        onNote: _capture(notes),
        toolProtocolOf: (_) => ToolProtocol.jsonText,
      );

      final out = await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

      expect(out['toolCalls'], isEmpty);
      expect(notes, hasLength(1));
      expect(notes.single.category, 'llm.toolcall.parse.failed');
    });
  });

  group('F.10 SubstrateBridge.send — multi-format text recovery', () {
    // The live failure that motivated this: Gemma-on-oMLX runs under the
    // `openai` protocol but writes the tool call into the completion text in
    // its own chat-template dialect instead of emitting a native `tool_calls`
    // array. The bridge must recover the call from text under *any* protocol,
    // across the usual dialects, keeping only calls to a tool on offer.

    test(
      'recovers a Gemma <|tool_call>call:NAME{…} dialect under openai',
      () async {
        client.streamEvents = _completed(
          '<|tool_call>call:memory.read{id: "n1"}<tool_call|>',
          providerId: 'omlx',
        );
        // Default bridge ⇒ openai protocol (no native tool_calls emitted).
        final bridge = SubstrateBridge(client, routeChainOf: _fastRoute);

        final out = await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

        final calls = out['toolCalls']! as List<Object?>;
        expect(calls, hasLength(1));
        final call = calls.single! as Map<String, Object?>;
        expect(call.keys.toSet(), <String>{'id', 'name', 'arguments'});
        expect(call['name'], 'memory.read');
        expect(call['arguments'], <String, Object?>{'id': 'n1'});
      },
    );

    test(
      'recovers a Hermes <tool_call>{…}</tool_call> block under json_text',
      () async {
        client.streamEvents = _completed(
          'Sure.\n<tool_call>{"name": "memory.read", "arguments": {"id": "n1"}}'
          '</tool_call>',
          providerId: 'ollama',
        );
        final bridge = SubstrateBridge(
          client,
          routeChainOf: _fastRoute,
          toolProtocolOf: (_) => ToolProtocol.jsonText,
        );

        final out = await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

        final calls = out['toolCalls']! as List<Object?>;
        expect(calls, hasLength(1));
        expect((calls.single! as Map<String, Object?>)['name'], 'memory.read');
      },
    );

    test('recovers a bare functional call:NAME{…} under json_text', () async {
      client.streamEvents = _completed(
        'call:memory.read{id: "n1"}',
        providerId: 'ollama',
      );
      final bridge = SubstrateBridge(
        client,
        routeChainOf: _fastRoute,
        toolProtocolOf: (_) => ToolProtocol.jsonText,
      );

      final out = await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

      final calls = out['toolCalls']! as List<Object?>;
      expect(calls, hasLength(1));
      expect((calls.single! as Map<String, Object?>)['name'], 'memory.read');
    });

    test(
      'a text call to an unknown tool ⇒ empty toolCalls + the typed note',
      () async {
        final notes = <_CapturedNote>[];
        client.streamEvents = _completed(
          '<|tool_call>call:rm_rf{path: "/"}<tool_call|>',
          providerId: 'omlx',
        );
        // Catalogue offers only memory.read; rm_rf is not on offer.
        final bridge = SubstrateBridge(
          client,
          routeChainOf: _fastRoute,
          onNote: _capture(notes),
        );

        final out = await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

        expect(out['toolCalls'], isEmpty);
        expect(notes, hasLength(1));
        expect(notes.single.category, 'llm.toolcall.parse.failed');
      },
    );
  });

  group(
    'F.10 SubstrateBridge.send — unresolved tool-call guard (§ 9.1 Todo 8)',
    () {
      // A completion that *looks* like a tool-call attempt but resolves to zero
      // executable calls (a name not on offer, or args that fail every parse)
      // must be flagged so the answer loop feeds an error turn back instead of
      // leaking the raw `call:NAME{…}` text as the answer. The flag rides on the
      // result map (`unresolvedToolCall`), alongside the existing typed note.

      test('an unknown-tool text call flags unresolvedToolCall', () async {
        final notes = <_CapturedNote>[];
        client.streamEvents = _completed(
          'call:totally.bogus{text: "x"}',
          providerId: 'omlx',
        );
        // Catalogue offers only memory.read; totally.bogus is not on offer.
        final bridge = SubstrateBridge(
          client,
          routeChainOf: _fastRoute,
          onNote: _capture(notes),
        );

        final out = await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

        expect(out['toolCalls'], isEmpty);
        // The new guard signal — the loop reads this to feed an error turn back.
        expect(out['unresolvedToolCall'], isTrue);
        // The existing typed note still fires (defense-in-depth, both signals).
        expect(notes.single.category, 'llm.toolcall.parse.failed');
      });

      test('plain prose does not flag unresolvedToolCall', () async {
        client.streamEvents = _completed(
          'The answer is 42.',
          providerId: 'omlx',
        );
        final bridge = SubstrateBridge(client, routeChainOf: _fastRoute);

        final out = await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

        expect(out['text'], 'The answer is 42.');
        expect(out['toolCalls'], isEmpty);
        expect(out['unresolvedToolCall'], isFalse);
      });

      test('a resolved tool call does not flag unresolvedToolCall', () async {
        client.streamEvents = _completed(
          'call:memory.read{id: "n1"}',
          providerId: 'omlx',
        );
        final bridge = SubstrateBridge(client, routeChainOf: _fastRoute);

        final out = await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

        expect((out['toolCalls']! as List<Object?>), hasLength(1));
        expect(out['unresolvedToolCall'], isFalse);
      });

      test('an unresolved attempt routes its text to the thinking channel, '
          'never the answer', () async {
        final notices = <String>[];
        final answerTokens = <String>[];
        final bridge = SubstrateBridge(
          client,
          routeChainOf: _fastRoute,
          onToken: (delta) async => answerTokens.add(delta),
          onThinking: (text) => notices.add(text),
        );
        client.streamEvents = _completed(
          'call:totally.bogus{text: "x"}',
          providerId: 'omlx',
        );

        await bridge.send('q', llmRoute: 'fast', tools: _oneTool());

        // The bogus call text surfaces on the thinking channel…
        expect(notices.single, contains('call:totally.bogus'));
        // …and is never replayed to the answer the user reads.
        expect(answerTokens.join(), isNot(contains('call:totally.bogus')));
      });
    },
  );

  group('F.10 SubstrateBridge.send — protocol uniformity (Q-F.4)', () {
    test(
      'openai native and json_text text yield the same toolCalls shape',
      () async {
        // openai path.
        client.streamEvents = <LlmEvent>[
          const LlmToolCall(
            callId: 'call_1',
            name: 'memory.read',
            arguments: <String, Object?>{'q': 'x'},
          ),
          _ok('c1'),
        ];
        final openaiBridge = SubstrateBridge(client, routeChainOf: _fastRoute);
        final openaiOut = await openaiBridge.send(
          'q',
          llmRoute: 'fast',
          tools: _oneTool(),
        );

        // json_text path.
        final client2 = _FakeSubstrateClient()
          ..streamEvents = _completed(
            '{"tool": "memory.read", "arguments": {"q": "x"}}',
            providerId: 'ollama',
          );
        final jsonBridge = SubstrateBridge(
          client2,
          routeChainOf: _fastRoute,
          toolProtocolOf: (_) => ToolProtocol.jsonText,
        );
        final jsonOut = await jsonBridge.send(
          'q',
          llmRoute: 'fast',
          tools: _oneTool(),
        );

        final a =
            (openaiOut['toolCalls']! as List<Object?>).single!
                as Map<String, Object?>;
        final b =
            (jsonOut['toolCalls']! as List<Object?>).single!
                as Map<String, Object?>;
        expect(a.keys.toSet(), b.keys.toSet());
        expect(a['name'], b['name']);
        expect(a['arguments'], b['arguments']);
      },
    );
  });
}

/// A single-tool catalogue in the `tool.list` wire shape (`name`,
/// `description`, `input_schema`).
List<Object?> _oneTool() => <Object?>[
  <String, Object?>{
    'name': 'memory.read',
    'description': 'reads a memory node',
    'input_schema': <String, Object?>{'type': 'object'},
  },
];

/// A Started→Chunk→Completed stream emitting [text] from [providerId].
List<LlmEvent> _completed(String text, {required String providerId}) =>
    <LlmEvent>[
      LlmRunStarted(callId: 'c', providerId: providerId, modelId: 'm'),
      LlmTextDelta(text),
      _ok('c', providerId: providerId),
    ];

/// A terminal completed event with a minimal report.
LlmRunCompleted _ok(String callId, {String providerId = 'omlx'}) =>
    LlmRunCompleted(
      callId: callId,
      report: LlmCallReport(
        providerId: providerId,
        modelId: 'm',
        anchorHash: 'a',
        promptHash: 'pr',
        tokensIn: 1,
        tokensOut: 1,
        retries: 0,
        wallClockMs: 1,
      ),
    );

typedef _CapturedNote = ({String category, Map<String, Object?> payload});

SubstrateNoteSink _capture(List<_CapturedNote> sink) =>
    (category, payload) async =>
        sink.add((category: category, payload: payload));

/// Fake `TomBrainSubstrateClient` capturing the call and replaying a
/// scripted event stream. Unused members fall through to `noSuchMethod`.
class _FakeSubstrateClient implements TomBrainSubstrateClient {
  LlmCall? lastCall;
  List<LlmEvent> streamEvents = const <LlmEvent>[];

  @override
  Stream<LlmEvent> completeStream(LlmCall call) {
    lastCall = call;
    return Stream<LlmEvent>.fromIterable(streamEvents);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
