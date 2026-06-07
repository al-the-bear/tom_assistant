// Extension F step 10 — low-level `llm` tool-protocol widening.
//
// `SubstrateBridge.llm` gains an optional `tools` catalogue and widens its
// return from `{text, report}` to `{text, toolCalls, report}` (`toolCalls`
// empty when none). The substrate hides the wire protocol behind the
// resolved provider's `toolProtocol`
// (`tom_brain_procedure_prototype_specification.md` § 21.1, § 21.6, Q-F.4):
//
//   - `openai`    — the provider surfaces native `tool_calls` as
//                   `LlmStreamToolCallProposed` events; the bridge collects
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

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

void main() {
  late _FakeSubstrateClient client;

  setUp(() {
    client = _FakeSubstrateClient();
  });

  group('F.10 SubstrateBridge.llm — tools inbound conversion', () {
    test('passes the tool catalogue onto LlmOptions (name/desc/schema)',
        () async {
      client.streamEvents = _completed('answer', providerId: 'omlx');
      final bridge = SubstrateBridge(client);

      await bridge.llm('q', tools: <Object?>[
        <String, Object?>{
          'name': 'memory.read',
          'description': 'reads a memory node',
          'input_schema': <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{'id': <String, Object?>{'type': 'string'}},
          },
        },
      ]);

      final catalogue = client.lastCall!.options.toolCatalogue;
      expect(catalogue.tools, hasLength(1));
      final descriptor = catalogue.tools.single;
      expect(descriptor.name, 'memory.read');
      expect(descriptor.description, 'reads a memory node');
      expect(descriptor.parametersSchema['type'], 'object');
    });

    test('no tools ⇒ empty catalogue, and the return still carries toolCalls',
        () async {
      client.streamEvents = _completed('plain answer', providerId: 'omlx');
      final bridge = SubstrateBridge(client);

      final out = await bridge.llm('q');

      expect(client.lastCall!.options.toolCatalogue.isEmpty, isTrue);
      expect(out['text'], 'plain answer');
      expect(out['toolCalls'], isEmpty);
      expect(out.containsKey('report'), isTrue);
    });

    test('rejects a tool entry missing its name with a FormatException',
        () async {
      client.streamEvents = _completed('a', providerId: 'omlx');
      final bridge = SubstrateBridge(client);

      await expectLater(
        bridge.llm('q', tools: <Object?>[
          <String, Object?>{'description': 'no name here'},
        ]),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('F.10 SubstrateBridge.llm — openai protocol (native tool_calls)', () {
    test('collects LlmStreamToolCallProposed events into uniform toolCalls',
        () async {
      client.streamEvents = <LlmStreamEvent>[
        const LlmStreamStarted(
          callId: 'c1',
          providerId: 'omlx',
          modelId: 'gemma',
        ),
        const LlmStreamToolCallProposed(
          callId: 'c1',
          toolCallId: 'call_1',
          toolName: 'memory.read',
          arguments: <String, Object?>{'q': 'x'},
        ),
        _ok('c1'),
      ];
      // Default (no resolver) ⇒ openai protocol.
      final bridge = SubstrateBridge(client);

      final out = await bridge.llm('q', tools: _oneTool());

      final calls = out['toolCalls']! as List<Object?>;
      expect(calls, hasLength(1));
      final call = calls.single! as Map<String, Object?>;
      expect(call['id'], 'call_1');
      expect(call['name'], 'memory.read');
      expect(call['arguments'], <String, Object?>{'q': 'x'});
    });

    test('a plain completion under openai ⇒ empty toolCalls, no note',
        () async {
      final notes = <_CapturedNote>[];
      client.streamEvents = _completed('just prose', providerId: 'omlx');
      final bridge = SubstrateBridge(client, onNote: _capture(notes));

      final out = await bridge.llm('q', tools: _oneTool());

      expect(out['text'], 'just prose');
      expect(out['toolCalls'], isEmpty);
      expect(notes, isEmpty);
    });
  });

  group('F.10 SubstrateBridge.llm — json_text protocol (JSON in text)', () {
    test('parses a JSON tool-call object from the completion identically',
        () async {
      client.streamEvents = _completed(
        '{"tool": "memory.read", "arguments": {"q": "x"}}',
        providerId: 'ollama',
      );
      final bridge = SubstrateBridge(
        client,
        toolProtocolOf: (_) => ToolProtocol.jsonText,
      );

      final out = await bridge.llm('q', tools: _oneTool());

      final calls = out['toolCalls']! as List<Object?>;
      expect(calls, hasLength(1));
      final call = calls.single! as Map<String, Object?>;
      // Same uniform shape as the openai path: id/name/arguments keys.
      expect(call.keys.toSet(), <String>{'id', 'name', 'arguments'});
      expect(call['name'], 'memory.read');
      expect(call['arguments'], <String, Object?>{'q': 'x'});
    });

    test('tolerates a markdown-fenced JSON tool-call block', () async {
      client.streamEvents = _completed(
        '```json\n{"tool": "memory.read", "arguments": {}}\n```',
        providerId: 'ollama',
      );
      final bridge = SubstrateBridge(
        client,
        toolProtocolOf: (_) => ToolProtocol.jsonText,
      );

      final out = await bridge.llm('q', tools: _oneTool());

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
        onNote: _capture(notes),
        toolProtocolOf: (_) => ToolProtocol.jsonText,
      );

      final out = await bridge.llm('q', tools: _oneTool());

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
        onNote: _capture(notes),
        toolProtocolOf: (_) => ToolProtocol.jsonText,
      );

      final out = await bridge.llm('q', tools: _oneTool());

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
        onNote: _capture(notes),
        toolProtocolOf: (_) => ToolProtocol.jsonText,
      );

      final out = await bridge.llm('q', tools: _oneTool());

      expect(out['toolCalls'], isEmpty);
      expect(notes, hasLength(1));
      expect(notes.single.category, 'llm.toolcall.parse.failed');
    });
  });

  group('F.10 SubstrateBridge.llm — protocol uniformity (Q-F.4)', () {
    test('openai native and json_text text yield the same toolCalls shape',
        () async {
      // openai path.
      client.streamEvents = <LlmStreamEvent>[
        const LlmStreamToolCallProposed(
          callId: 'c1',
          toolCallId: 'call_1',
          toolName: 'memory.read',
          arguments: <String, Object?>{'q': 'x'},
        ),
        _ok('c1'),
      ];
      final openaiBridge = SubstrateBridge(client);
      final openaiOut = await openaiBridge.llm('q', tools: _oneTool());

      // json_text path.
      final client2 = _FakeSubstrateClient()
        ..streamEvents = _completed(
          '{"tool": "memory.read", "arguments": {"q": "x"}}',
          providerId: 'ollama',
        );
      final jsonBridge = SubstrateBridge(
        client2,
        toolProtocolOf: (_) => ToolProtocol.jsonText,
      );
      final jsonOut = await jsonBridge.llm('q', tools: _oneTool());

      final a = (openaiOut['toolCalls']! as List<Object?>).single!
          as Map<String, Object?>;
      final b = (jsonOut['toolCalls']! as List<Object?>).single!
          as Map<String, Object?>;
      expect(a.keys.toSet(), b.keys.toSet());
      expect(a['name'], b['name']);
      expect(a['arguments'], b['arguments']);
    });
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
List<LlmStreamEvent> _completed(String text, {required String providerId}) =>
    <LlmStreamEvent>[
      LlmStreamStarted(callId: 'c', providerId: providerId, modelId: 'm'),
      LlmStreamChunk(callId: 'c', text: text),
      _ok('c', providerId: providerId),
    ];

/// A terminal completed event with a minimal report.
LlmStreamCompleted _ok(String callId, {String providerId = 'omlx'}) =>
    LlmStreamCompleted(
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
