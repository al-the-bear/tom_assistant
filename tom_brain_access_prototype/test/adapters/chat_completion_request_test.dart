// E.12 OpenAI `chat/completions` request parsing — contract test.
//
// Two layers, matching the substep's two deliverables (proto spec § 5.2):
//
//   1. `ChatCompletionRequest.parse` as a pure unit — the field extraction
//      and validation rules (last-user-message prompt, model id, stream
//      flag) and every typed parse-failure branch.
//   2. The same parsing reached black-box through `OpenAiHttpSseAdapter`'s
//      shelf handler (Q-E.5.2: a synthesised `shelf.Request`, no socket):
//      a malformed body becomes the OpenAI `400 invalid_request_error`
//      envelope with the offending `param`; a well-formed body gets past
//      parsing to the not-yet-wired `501` response path (E.13 – E.15).
//
// E.12 is parsing only: persona resolution (E.15), response generation
// (E.13 / E.14), and the dispatcher (boot, E.41+) are not asserted here.

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// Drives [adapter] with a synthesised request and returns the response.
Future<Response> _call(
  OpenAiHttpSseAdapter adapter,
  String method,
  String path, {
  String? body,
}) async {
  final Request request = Request(
    method,
    Uri.parse('http://localhost$path'),
    body: body,
  );
  return await adapter.handler(request);
}

/// Reads the response body and returns the inner `error` object.
Future<Map<String, Object?>> _errorObject(Response response) async {
  final String raw = await response.readAsString();
  final Map<String, Object?> decoded =
      jsonDecode(raw) as Map<String, Object?>;
  return decoded['error'] as Map<String, Object?>;
}

/// Convenience: the value carried by an `Ok` (the parse must have succeeded).
ChatCompletionRequest _okValue(
  Result<ChatCompletionRequest, ChatCompletionParseError> r,
) =>
    (r as Ok<ChatCompletionRequest, ChatCompletionParseError>).value;

/// Convenience: the error carried by an `Err` (the parse must have failed).
ChatCompletionParseError _errValue(
  Result<ChatCompletionRequest, ChatCompletionParseError> r,
) =>
    (r as Err<ChatCompletionRequest, ChatCompletionParseError>).error;

void main() {
  group('ChatCompletionRequest.parse — field extraction (E.12)', () {
    test('reads model, last user prompt, and stream flag', () {
      final ChatCompletionRequest req = _okValue(
        ChatCompletionRequest.parse(<String, Object?>{
          'model': 'tom-assistant:terse',
          'stream': true,
          'messages': <Object?>[
            <String, Object?>{'role': 'system', 'content': 'be nice'},
            <String, Object?>{'role': 'user', 'content': 'first'},
            <String, Object?>{'role': 'assistant', 'content': 'ok'},
            <String, Object?>{'role': 'user', 'content': 'the real prompt'},
          ],
        }),
      );
      expect(req.model, 'tom-assistant:terse');
      expect(req.prompt, 'the real prompt');
      expect(req.stream, isTrue);
    });

    test('stream defaults to false when absent', () {
      final ChatCompletionRequest req = _okValue(
        ChatCompletionRequest.parse(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hi'},
          ],
        }),
      );
      expect(req.stream, isFalse);
    });

    test('model is null when omitted (default persona resolves at E.15)', () {
      final ChatCompletionRequest req = _okValue(
        ChatCompletionRequest.parse(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hi'},
          ],
        }),
      );
      expect(req.model, isNull);
    });

    test('the prompt is trimmed', () {
      final ChatCompletionRequest req = _okValue(
        ChatCompletionRequest.parse(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': '  spaced  '},
          ],
        }),
      );
      expect(req.prompt, 'spaced');
    });

    test('content-part array form concatenates its text parts', () {
      final ChatCompletionRequest req = _okValue(
        ChatCompletionRequest.parse(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{
              'role': 'user',
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': 'part one '},
                <String, Object?>{'type': 'image_url', 'image_url': 'x'},
                <String, Object?>{'type': 'text', 'text': 'part two'},
              ],
            },
          ],
        }),
      );
      expect(req.prompt, 'part one part two');
    });
  });

  group('ChatCompletionRequest.parse — failure branches (E.12)', () {
    test('non-object body → invalid_body, no param', () {
      final ChatCompletionParseError e =
          _errValue(ChatCompletionRequest.parse(<Object?>['not', 'object']));
      expect(e.code, 'invalid_body');
      expect(e.param, isNull);
    });

    test('missing messages → missing_messages on the messages param', () {
      final ChatCompletionParseError e = _errValue(
        ChatCompletionRequest.parse(<String, Object?>{'model': 'x'}),
      );
      expect(e.code, 'missing_messages');
      expect(e.param, 'messages');
    });

    test('empty messages array → invalid_messages', () {
      final ChatCompletionParseError e = _errValue(
        ChatCompletionRequest.parse(<String, Object?>{
          'messages': <Object?>[],
        }),
      );
      expect(e.code, 'invalid_messages');
      expect(e.param, 'messages');
    });

    test('messages not an array → invalid_messages', () {
      final ChatCompletionParseError e = _errValue(
        ChatCompletionRequest.parse(<String, Object?>{'messages': 'nope'}),
      );
      expect(e.code, 'invalid_messages');
    });

    test('no user message → no_user_message', () {
      final ChatCompletionParseError e = _errValue(
        ChatCompletionRequest.parse(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'system', 'content': 'only system'},
            <String, Object?>{'role': 'assistant', 'content': 'only bot'},
          ],
        }),
      );
      expect(e.code, 'no_user_message');
      expect(e.param, 'messages');
    });

    test('user message with whitespace-only content → no_user_message', () {
      final ChatCompletionParseError e = _errValue(
        ChatCompletionRequest.parse(<String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': '   '},
          ],
        }),
      );
      expect(e.code, 'no_user_message');
    });

    test('non-string model → invalid_model', () {
      final ChatCompletionParseError e = _errValue(
        ChatCompletionRequest.parse(<String, Object?>{
          'model': 42,
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hi'},
          ],
        }),
      );
      expect(e.code, 'invalid_model');
      expect(e.param, 'model');
    });

    test('non-bool stream → invalid_stream', () {
      final ChatCompletionParseError e = _errValue(
        ChatCompletionRequest.parse(<String, Object?>{
          'stream': 'yes',
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hi'},
          ],
        }),
      );
      expect(e.code, 'invalid_stream');
      expect(e.param, 'stream');
    });
  });

  group('ChatCompletionRequest.toInboundRequest (E.12)', () {
    test('maps prompt → text and stream → streaming', () {
      const ChatCompletionRequest req = ChatCompletionRequest(
        prompt: 'hello world',
        model: 'tom-assistant',
        stream: true,
      );
      final InboundRequest inbound = req.toInboundRequest();
      expect(inbound.text, 'hello world');
      expect(inbound.streaming, isTrue);
    });

    test('carries optional channel identity when supplied', () {
      const ChatCompletionRequest req = ChatCompletionRequest(
        prompt: 'hi',
        model: null,
        stream: false,
      );
      final InboundRequest inbound = req.toInboundRequest(
        conversationId: 'conv-1',
        messageId: 'msg-1',
      );
      expect(inbound.conversationId, 'conv-1');
      expect(inbound.messageId, 'msg-1');
      expect(inbound.streaming, isFalse);
    });
  });

  group('OpenAiHttpSseAdapter chat/completions parsing (E.12)', () {
    late OpenAiHttpSseAdapter adapter;

    setUp(() => adapter = OpenAiHttpSseAdapter());

    test('invalid JSON body → 400 invalid_body', () async {
      final Response response = await _call(
        adapter,
        'POST',
        '/v1/chat/completions',
        body: '{not json',
      );
      expect(response.statusCode, 400);
      expect(response.headers['content-type'], contains('application/json'));
      final Map<String, Object?> error = await _errorObject(response);
      expect(error['type'], 'invalid_request_error');
      expect(error['code'], 'invalid_body');
    });

    test('empty body → 400 invalid_body', () async {
      final Response response =
          await _call(adapter, 'POST', '/v1/chat/completions', body: '');
      expect(response.statusCode, 400);
      final Map<String, Object?> error = await _errorObject(response);
      expect(error['code'], 'invalid_body');
    });

    test('missing messages → 400 with messages param', () async {
      final Response response = await _call(
        adapter,
        'POST',
        '/v1/chat/completions',
        body: jsonEncode(<String, Object?>{'model': 'tom-assistant'}),
      );
      expect(response.statusCode, 400);
      final Map<String, Object?> error = await _errorObject(response);
      expect(error['code'], 'missing_messages');
      expect(error['param'], 'messages');
    });

    test('well-formed request gets past parsing → 501 (E.13 – E.15)',
        () async {
      final Response response = await _call(
        adapter,
        'POST',
        '/v1/chat/completions',
        body: jsonEncode(<String, Object?>{
          'model': 'tom-assistant',
          'stream': false,
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hello'},
          ],
        }),
      );
      expect(response.statusCode, 501);
      final Map<String, Object?> error = await _errorObject(response);
      expect(error['type'], 'not_implemented');
    });
  });
}
