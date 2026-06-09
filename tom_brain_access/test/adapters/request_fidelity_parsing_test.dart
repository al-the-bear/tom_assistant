// Step #20 — full request fidelity in the gateway parsers (proto spec § 5.2;
// hub § 22.1).
//
// The three gateway parsers (OpenAI `chat/completions`, Anthropic Messages,
// Ollama `/api/chat`) upgrade from collapse-to-last-user to full ingestion:
// the live prompt is still the last user message, but the parser now also
// populates `priorTurns` (the preceding turns), `toolResults` (client-executed
// tool results), and `remoteTools` (the top-level `tools[]`). `sessionId` is
// fed at `toInboundRequest` time (the edges read the `X-Tom-Session` header).
//
// This file asserts the step's *Test* clause for each dialect:
//
//   * a multi-message + `tools[]` + tool-result request yields all four fields
//     populated;
//   * a single-message request leaves them empty (the PE-9 regression guard);
//   * a trailing tool-result with no new user text is the client tool-loop
//     follow-up — the DTO `prompt` is empty and `toolResults` is populated;
//   * a malformed sub-entry is dropped and reported through `onMalformed`
//     (`access.wire.history.malformed`), while the live prompt still parses.

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

ChatCompletionRequest _openAi(
  Result<ChatCompletionRequest, ChatCompletionParseError> r,
) =>
    (r as Ok<ChatCompletionRequest, ChatCompletionParseError>).value;

ChatCompletionParseError _openAiErr(
  Result<ChatCompletionRequest, ChatCompletionParseError> r,
) =>
    (r as Err<ChatCompletionRequest, ChatCompletionParseError>).error;

AnthropicRequest _anthropic(
  Result<AnthropicRequest, AnthropicParseError> r,
) =>
    (r as Ok<AnthropicRequest, AnthropicParseError>).value;

OllamaRequest _ollama(Result<OllamaRequest, OllamaParseError> r) =>
    (r as Ok<OllamaRequest, OllamaParseError>).value;

void main() {
  group('OpenAI full request fidelity (§ 5.2)', () {
    test('multi-message + tools[] + tool_result → all four fields populated',
        () {
      final List<String> malformed = <String>[];
      final ChatCompletionRequest req = _openAi(
        ChatCompletionRequest.parse(
          <String, Object?>{
            'model': 'tom-assistant',
            'messages': <Object?>[
              <String, Object?>{'role': 'system', 'content': 'be nice'},
              <String, Object?>{'role': 'user', 'content': 'first question'},
              <String, Object?>{'role': 'assistant', 'content': 'an answer'},
              <String, Object?>{
                'role': 'tool',
                'tool_call_id': 'call_1',
                'content': 'tool said 42',
              },
              <String, Object?>{'role': 'user', 'content': 'the live prompt'},
            ],
            'tools': <Object?>[
              <String, Object?>{
                'type': 'function',
                'function': <String, Object?>{
                  'name': 'get_weather',
                  'description': 'Look up the weather',
                  'parameters': <String, Object?>{'type': 'object'},
                },
              },
            ],
          },
          onMalformed: malformed.add,
        ),
      );

      expect(req.prompt, 'the live prompt');
      expect(
        req.priorTurns.map((t) => '${t.role}:${t.text}').toList(),
        <String>['system:be nice', 'user:first question', 'assistant:an answer'],
      );
      expect(req.toolResults, hasLength(1));
      expect(req.toolResults.single.toolCallId, 'call_1');
      expect(req.toolResults.single.content, 'tool said 42');
      expect(req.remoteTools, hasLength(1));
      expect(req.remoteTools.single.name, 'get_weather');
      expect(req.remoteTools.single.description, 'Look up the weather');
      expect(req.remoteTools.single.inputSchema, <String, Object?>{'type': 'object'});
      expect(malformed, isEmpty);
    });

    test('single-message request leaves the four fields empty/null', () {
      final ChatCompletionRequest req = _openAi(
        ChatCompletionRequest.parse(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'just one'},
          ],
        }),
      );
      expect(req.prompt, 'just one');
      expect(req.priorTurns, isEmpty);
      expect(req.toolResults, isEmpty);
      expect(req.remoteTools, isEmpty);
    });

    test('trailing tool_result with no new user text → empty prompt, '
        'populated toolResults', () {
      final ChatCompletionRequest req = _openAi(
        ChatCompletionRequest.parse(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'weather?'},
            <String, Object?>{'role': 'assistant', 'content': null},
            <String, Object?>{
              'role': 'tool',
              'tool_call_id': 'c1',
              'content': 'sunny',
            },
          ],
        }),
      );
      expect(req.prompt, isEmpty);
      expect(req.toolResults.single.toolCallId, 'c1');
      expect(req.toolResults.single.content, 'sunny');
      // The original question survives as a prior turn; the empty-content
      // assistant turn is dropped (it carries no replayable text).
      expect(
        req.priorTurns.map((t) => '${t.role}:${t.text}').toList(),
        <String>['user:weather?'],
      );
    });

    test('a still-empty conversation (no user text, no tool result) is '
        'no_user_message', () {
      final ChatCompletionParseError e = _openAiErr(
        ChatCompletionRequest.parse(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'system', 'content': 'only system'},
            <String, Object?>{'role': 'assistant', 'content': 'only bot'},
          ],
        }),
      );
      expect(e.code, 'no_user_message');
    });

    test('a malformed sub-entry is dropped and reported via onMalformed', () {
      final List<String> malformed = <String>[];
      final ChatCompletionRequest req = _openAi(
        ChatCompletionRequest.parse(
          <String, Object?>{
            'messages': <Object?>[
              'not an object',
              <String, Object?>{'role': 'user', 'content': 'live'},
              <String, Object?>{'role': 'tool', 'content': 'no id here'},
            ],
            'tools': <Object?>[
              <String, Object?>{'type': 'function'},
            ],
          },
          onMalformed: malformed.add,
        ),
      );
      // The live prompt still parses despite the malformed neighbours.
      expect(req.prompt, 'live');
      expect(req.toolResults, isEmpty); // tool entry had no tool_call_id
      expect(req.remoteTools, isEmpty); // tool def had no function/name
      expect(malformed, isNotEmpty);
    });

    test('toInboundRequest carries the four fidelity fields + sessionId', () {
      final ChatCompletionRequest req = _openAi(
        ChatCompletionRequest.parse(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'first'},
            <String, Object?>{'role': 'assistant', 'content': 'ok'},
            <String, Object?>{'role': 'user', 'content': 'live'},
          ],
          'tools': <Object?>[
            <String, Object?>{
              'type': 'function',
              'function': <String, Object?>{'name': 't'},
            },
          ],
        }),
      );
      final InboundRequest inbound = req.toInboundRequest(sessionId: 'sess-9');
      expect(inbound.text, 'live');
      expect(inbound.priorTurns, hasLength(2));
      expect(inbound.remoteTools.single.name, 't');
      expect(inbound.sessionId, 'sess-9');
    });

    test('toInboundRequest sessionId defaults to null', () {
      final ChatCompletionRequest req = _openAi(
        ChatCompletionRequest.parse(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hi'},
          ],
        }),
      );
      expect(req.toInboundRequest().sessionId, isNull);
    });
  });

  group('Anthropic full request fidelity (§ 5.2)', () {
    test('multi-message + tools[] + tool_result block → all four populated',
        () {
      final AnthropicRequest req = _anthropic(
        AnthropicRequest.parse(<String, Object?>{
          'model': 'claude-3',
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'first question'},
            <String, Object?>{
              'role': 'assistant',
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': 'let me check'},
                <String, Object?>{
                  'type': 'tool_use',
                  'id': 'tu_1',
                  'name': 'get_weather',
                  'input': <String, Object?>{'city': 'x'},
                },
              ],
            },
            <String, Object?>{
              'role': 'user',
              'content': <Object?>[
                <String, Object?>{
                  'type': 'tool_result',
                  'tool_use_id': 'tu_1',
                  'content': 'sunny',
                },
              ],
            },
            <String, Object?>{'role': 'user', 'content': 'the live prompt'},
          ],
          'tools': <Object?>[
            <String, Object?>{
              'name': 'get_weather',
              'description': 'Look up the weather',
              'input_schema': <String, Object?>{'type': 'object'},
            },
          ],
        }),
      );

      expect(req.prompt, 'the live prompt');
      expect(
        req.priorTurns.map((t) => '${t.role}:${t.text}').toList(),
        <String>['user:first question', 'assistant:let me check'],
      );
      expect(req.toolResults.single.toolCallId, 'tu_1');
      expect(req.toolResults.single.content, 'sunny');
      expect(req.remoteTools.single.name, 'get_weather');
      expect(req.remoteTools.single.description, 'Look up the weather');
      expect(req.remoteTools.single.inputSchema, <String, Object?>{'type': 'object'});
    });

    test('single-message request leaves the four fields empty/null', () {
      final AnthropicRequest req = _anthropic(
        AnthropicRequest.parse(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'just one'},
          ],
        }),
      );
      expect(req.prompt, 'just one');
      expect(req.priorTurns, isEmpty);
      expect(req.toolResults, isEmpty);
      expect(req.remoteTools, isEmpty);
    });

    test('trailing tool_result with no new user text → empty prompt, '
        'populated toolResults', () {
      final AnthropicRequest req = _anthropic(
        AnthropicRequest.parse(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'weather?'},
            <String, Object?>{
              'role': 'assistant',
              'content': <Object?>[
                <String, Object?>{
                  'type': 'tool_use',
                  'id': 'tu_9',
                  'name': 'w',
                  'input': <String, Object?>{},
                },
              ],
            },
            <String, Object?>{
              'role': 'user',
              'content': <Object?>[
                <String, Object?>{
                  'type': 'tool_result',
                  'tool_use_id': 'tu_9',
                  'content': 'rainy',
                },
              ],
            },
          ],
        }),
      );
      expect(req.prompt, isEmpty);
      expect(req.toolResults.single.toolCallId, 'tu_9');
      expect(req.toolResults.single.content, 'rainy');
      expect(
        req.priorTurns.map((t) => '${t.role}:${t.text}').toList(),
        <String>['user:weather?'],
      );
    });

    test('toInboundRequest carries the four fidelity fields + sessionId', () {
      final AnthropicRequest req = _anthropic(
        AnthropicRequest.parse(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'first'},
            <String, Object?>{'role': 'user', 'content': 'live'},
          ],
        }),
      );
      final InboundRequest inbound = req.toInboundRequest(sessionId: 'sess-a');
      expect(inbound.text, 'live');
      expect(inbound.priorTurns.single.text, 'first');
      expect(inbound.sessionId, 'sess-a');
    });
  });

  group('Ollama full request fidelity (§ 5.2)', () {
    test('multi-message chat + tools[] → priorTurns + remoteTools populated',
        () {
      final OllamaRequest req = _ollama(
        OllamaRequest.parseChat(<String, Object?>{
          'model': 'llama3',
          'messages': <Object?>[
            <String, Object?>{'role': 'system', 'content': 'be brief'},
            <String, Object?>{'role': 'user', 'content': 'first'},
            <String, Object?>{'role': 'assistant', 'content': 'ok'},
            <String, Object?>{'role': 'user', 'content': 'the live prompt'},
          ],
          'tools': <Object?>[
            <String, Object?>{
              'type': 'function',
              'function': <String, Object?>{'name': 'lookup'},
            },
          ],
        }),
      );
      expect(req.prompt, 'the live prompt');
      expect(
        req.priorTurns.map((t) => '${t.role}:${t.text}').toList(),
        <String>['system:be brief', 'user:first', 'assistant:ok'],
      );
      expect(req.remoteTools.single.name, 'lookup');
    });

    test('single-message chat leaves the fidelity fields empty', () {
      final OllamaRequest req = _ollama(
        OllamaRequest.parseChat(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'just one'},
          ],
        }),
      );
      expect(req.prompt, 'just one');
      expect(req.priorTurns, isEmpty);
      expect(req.toolResults, isEmpty);
      expect(req.remoteTools, isEmpty);
    });

    test('generate request has no history and empty fidelity fields', () {
      final OllamaRequest req = _ollama(
        OllamaRequest.parseGenerate(<String, Object?>{
          'prompt': 'one shot',
        }),
      );
      expect(req.prompt, 'one shot');
      expect(req.priorTurns, isEmpty);
      expect(req.toolResults, isEmpty);
      expect(req.remoteTools, isEmpty);
    });

    test('toInboundRequest carries the fidelity fields + sessionId', () {
      final OllamaRequest req = _ollama(
        OllamaRequest.parseChat(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'first'},
            <String, Object?>{'role': 'user', 'content': 'live'},
          ],
        }),
      );
      final InboundRequest inbound = req.toInboundRequest(sessionId: 'sess-o');
      expect(inbound.text, 'live');
      expect(inbound.priorTurns.single.text, 'first');
      expect(inbound.sessionId, 'sess-o');
    });
  });
}
