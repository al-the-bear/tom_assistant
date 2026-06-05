// Anthropic Messages inbound request parsing (plan item #28).
//
// The Anthropic wire format has ONE request shape (`POST /v1/messages`)
// feeding the same reduced DTO the other channels use:
//
//   * `{model, max_tokens, messages:[{role,content}], system?, stream}` — the
//     prompt is the last `user` message's content, where content is a bare
//     string OR the `[{type:"text",text:"…"}]` content-part array (the SAME
//     shape OpenAI uses; the two share `lastUserText`).
//
// `AnthropicRequest` carries the three fields the prototype consumes — the
// prompt text, the `model` string (a persona id), and the `stream` flag.
// There is no shape discriminator (unlike Ollama): one endpoint, one carrier.
//
// Three wire-format facts pinned here:
//
//   1. `stream` defaults to **false** when absent (like OpenAI, unlike
//      Ollama's true). An Anthropic SDK opts into streaming explicitly.
//   2. Content is a string OR an OpenAI-shaped content-part array — so the
//      reduction is `lastUserText`, shared with the OpenAI parser.
//   3. `max_tokens` and `system` are **tolerated and ignored**: the prototype
//      cognition owns answer length and the system prompt, so these wire
//      fields never reach the DTO. A request carrying them parses exactly as
//      one without them. (Reduction discipline — the access layer forwards a
//      prompt, not the caller's generation knobs.)
//
// The parser reuses the access-local generic field readers
// (`requireJsonObject` / `optionalStringField` / `optionalBoolField`) the
// OpenAI parser established, so the `invalid_body` / `invalid_model` /
// `invalid_stream` failure vocabulary stays one implementation across every
// channel (DRY). `AnthropicParseError.code` / `param` are internal
// diagnostics — Anthropic's wire error renders `{"type":"error","error":
// {"type":"invalid_request_error","message":<message>}}`, carrying only the
// message — but they let the shared readers build the error type and let
// these tests assert the precise failure.

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// Unwraps an `Ok`, failing the test if the result was an `Err`.
AnthropicRequest _ok(Result<AnthropicRequest, AnthropicParseError> result) =>
    switch (result) {
      Ok(:final value) => value,
      Err(:final error) => fail('expected Ok, got Err($error)'),
    };

/// Unwraps an `Err`, failing the test if the result was an `Ok`.
AnthropicParseError _err(
        Result<AnthropicRequest, AnthropicParseError> result) =>
    switch (result) {
      Ok(:final value) => fail('expected Err, got Ok($value)'),
      Err(:final error) => error,
    };

void main() {
  group('AnthropicRequest.parse — POST /v1/messages success', () {
    test('reduces the last user message to the prompt', () {
      final AnthropicRequest request = _ok(AnthropicRequest.parse(
        <String, Object?>{
          'model': 'tom-assistant',
          'max_tokens': 1024,
          'stream': false,
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'first'},
            <String, Object?>{'role': 'assistant', 'content': 'ok'},
            <String, Object?>{'role': 'user', 'content': 'the real prompt'},
          ],
        },
      ));
      expect(request.prompt, 'the real prompt');
      expect(request.model, 'tom-assistant');
      expect(request.stream, isFalse);
    });

    test('content-part array form concatenates its text parts', () {
      final AnthropicRequest request = _ok(AnthropicRequest.parse(
        <String, Object?>{
          'messages': <Object?>[
            <String, Object?>{
              'role': 'user',
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': 'Hello, '},
                <String, Object?>{'type': 'image', 'source': 'ignored'},
                <String, Object?>{'type': 'text', 'text': 'world'},
              ],
            },
          ],
        },
      ));
      expect(request.prompt, 'Hello, world');
    });

    test('stream defaults to FALSE when the field is absent (Anthropic '
        'opt-in)', () {
      final AnthropicRequest request = _ok(AnthropicRequest.parse(
        <String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hi'},
          ],
        },
      ));
      expect(request.stream, isFalse);
      expect(request.model, isNull);
    });

    test('the prompt is trimmed', () {
      final AnthropicRequest request = _ok(AnthropicRequest.parse(
        <String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': '  spaced  '},
          ],
        },
      ));
      expect(request.prompt, 'spaced');
    });

    test('max_tokens and system are tolerated and ignored', () {
      // A request carrying both knobs parses identically to one without
      // them: the prototype cognition owns length and the system prompt, so
      // neither field reaches the DTO and neither is a validation target
      // (a non-int max_tokens / non-string system is not a parse error).
      final AnthropicRequest withKnobs = _ok(AnthropicRequest.parse(
        <String, Object?>{
          'model': 'tom-assistant',
          'max_tokens': 'not-an-int',
          'system': <Object?>['not', 'a', 'string'],
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hello'},
          ],
        },
      ));
      expect(withKnobs.prompt, 'hello');
      expect(withKnobs.model, 'tom-assistant');
      expect(withKnobs.stream, isFalse);
    });
  });

  group('AnthropicRequest.parse — failure branches', () {
    test('a non-object body is invalid_body', () {
      expect(_err(AnthropicRequest.parse(<Object?>['not', 'an', 'object']))
          .code, 'invalid_body');
      expect(_err(AnthropicRequest.parse(null)).code, 'invalid_body');
    });

    test('a missing messages array is missing_messages', () {
      final AnthropicParseError error = _err(AnthropicRequest.parse(
        <String, Object?>{'model': 'tom-assistant', 'max_tokens': 16},
      ));
      expect(error.code, 'missing_messages');
      expect(error.param, 'messages');
    });

    test('a non-array / empty messages value is invalid_messages', () {
      expect(_err(AnthropicRequest.parse(<String, Object?>{'messages': 'x'}))
          .code, 'invalid_messages');
      expect(
          _err(AnthropicRequest.parse(<String, Object?>{
            'messages': <Object?>[],
          })).code,
          'invalid_messages');
    });

    test('messages with no usable user content is no_user_message', () {
      final AnthropicParseError error = _err(AnthropicRequest.parse(
        <String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'assistant', 'content': 'hello'},
            <String, Object?>{'role': 'user', 'content': 42},
            <String, Object?>{'role': 'user', 'content': '   '},
          ],
        },
      ));
      expect(error.code, 'no_user_message');
      expect(error.param, 'messages');
    });

    test('a non-string model is invalid_model', () {
      final AnthropicParseError error = _err(AnthropicRequest.parse(
        <String, Object?>{
          'model': 7,
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hi'},
          ],
        },
      ));
      expect(error.code, 'invalid_model');
      expect(error.param, 'model');
    });

    test('a non-bool stream is invalid_stream', () {
      final AnthropicParseError error = _err(AnthropicRequest.parse(
        <String, Object?>{
          'stream': 'yes',
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hi'},
          ],
        },
      ));
      expect(error.code, 'invalid_stream');
      expect(error.param, 'stream');
    });
  });

  group('AnthropicRequest.toInboundRequest', () {
    test('maps prompt → text and stream → streaming; channel ids optional', () {
      final AnthropicRequest request = _ok(AnthropicRequest.parse(
        <String, Object?>{
          'stream': true,
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hello'},
          ],
        },
      ));
      final InboundRequest inbound = request.toInboundRequest();
      expect(inbound.text, 'hello');
      expect(inbound.streaming, isTrue);
      expect(inbound.conversationId, isNull);
      expect(inbound.messageId, isNull);

      final InboundRequest withIds = request.toInboundRequest(
        conversationId: 'conv-1',
        messageId: 'msg-1',
      );
      expect(withIds.conversationId, 'conv-1');
      expect(withIds.messageId, 'msg-1');
    });
  });

  group('AnthropicParseError value semantics', () {
    test('equality and toString carry code / param / message', () {
      const AnthropicParseError a = AnthropicParseError(
        message: "'messages' must be a non-empty array.",
        code: 'invalid_messages',
        param: 'messages',
      );
      const AnthropicParseError b = AnthropicParseError(
        message: "'messages' must be a non-empty array.",
        code: 'invalid_messages',
        param: 'messages',
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a.toString(), contains('invalid_messages'));
    });
  });
}
