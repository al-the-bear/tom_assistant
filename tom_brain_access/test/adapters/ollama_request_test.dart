// Ollama inbound request parsing (plan item #27).
//
// The Ollama wire format has TWO request shapes feeding one reduced DTO:
//
//   * `POST /api/chat`     — `{model, messages:[{role,content}], stream}`;
//     the prompt is the last `user` message's (plain-string) content.
//   * `POST /api/generate` — `{model, prompt, stream}`; the prompt is the
//     `prompt` string directly.
//
// Both decode to one `OllamaRequest` carrying the three fields the prototype
// consumes — the prompt text, the `model` string (a persona id), and the
// `stream` flag — plus the `OllamaApiShape` discriminator the NDJSON / JSON
// renderers read to place the answer text in the right content carrier
// (chat → `message.content`, generate → `response`).
//
// Two wire-format facts distinguish Ollama from OpenAI and are pinned here:
//
//   1. `stream` defaults to **true** when the field is absent (Ollama
//      streams by default; OpenAI defaults to non-streaming). A parse that
//      defaulted it to false would silently turn an `ollama run` client's
//      streamed request into a single buffered body.
//   2. Ollama content is a plain string — there is no OpenAI content-part
//      array — so a non-string `content` contributes no prompt text.
//
// The parser reuses the access-local generic field readers
// (`requireJsonObject` / `optionalStringField` / `optionalBoolField`) the
// OpenAI parser already established, so the `invalid_body` / `invalid_model`
// / `invalid_stream` failure vocabulary stays one implementation across both
// channels (DRY). `OllamaParseError.code` / `param` are internal diagnostics
// — Ollama's wire error is only `{"error": <message>}` — but they let the
// shared readers build the error type and let these tests assert the precise
// failure.

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// Unwraps an `Ok`, failing the test if the result was an `Err`.
OllamaRequest _ok(Result<OllamaRequest, OllamaParseError> result) =>
    switch (result) {
      Ok(:final value) => value,
      Err(:final error) => fail('expected Ok, got Err($error)'),
    };

/// Unwraps an `Err`, failing the test if the result was an `Ok`.
OllamaParseError _err(Result<OllamaRequest, OllamaParseError> result) =>
    switch (result) {
      Ok(:final value) => fail('expected Err, got Ok($value)'),
      Err(:final error) => error,
    };

void main() {
  group('OllamaRequest.parseChat — POST /api/chat', () {
    test('reduces the last user message to the prompt, shape chat', () {
      final OllamaRequest request = _ok(OllamaRequest.parseChat(
        <String, Object?>{
          'model': 'tom-assistant',
          'stream': false,
          'messages': <Object?>[
            <String, Object?>{'role': 'system', 'content': 'be brief'},
            <String, Object?>{'role': 'user', 'content': 'first'},
            <String, Object?>{'role': 'assistant', 'content': 'ok'},
            <String, Object?>{'role': 'user', 'content': 'the real prompt'},
          ],
        },
      ));
      expect(request.prompt, 'the real prompt');
      expect(request.model, 'tom-assistant');
      expect(request.stream, isFalse);
      expect(request.shape, OllamaApiShape.chat);
    });

    test('stream defaults to TRUE when the field is absent (Ollama default)',
        () {
      final OllamaRequest request = _ok(OllamaRequest.parseChat(
        <String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'user', 'content': 'hi'},
          ],
        },
      ));
      expect(request.stream, isTrue);
      expect(request.model, isNull);
    });

    test('a missing messages array is missing_messages', () {
      final OllamaParseError error = _err(OllamaRequest.parseChat(
        <String, Object?>{'model': 'tom-assistant'},
      ));
      expect(error.code, 'missing_messages');
      expect(error.param, 'messages');
    });

    test('a non-array / empty messages value is invalid_messages', () {
      expect(_err(OllamaRequest.parseChat(<String, Object?>{'messages': 'x'}))
          .code, 'invalid_messages');
      expect(
          _err(OllamaRequest.parseChat(
                  <String, Object?>{'messages': <Object?>[]}))
              .code,
          'invalid_messages');
    });

    test('messages with no usable user content is no_user_message', () {
      final OllamaParseError error = _err(OllamaRequest.parseChat(
        <String, Object?>{
          'messages': <Object?>[
            <String, Object?>{'role': 'assistant', 'content': 'hello'},
            // A non-string content contributes no prompt (Ollama has no
            // content-part array).
            <String, Object?>{'role': 'user', 'content': 42},
            <String, Object?>{'role': 'user', 'content': '   '},
          ],
        },
      ));
      expect(error.code, 'no_user_message');
      expect(error.param, 'messages');
    });

    test('a non-string model is invalid_model', () {
      final OllamaParseError error = _err(OllamaRequest.parseChat(
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
      final OllamaParseError error = _err(OllamaRequest.parseChat(
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

    test('a non-object body is invalid_body', () {
      expect(_err(OllamaRequest.parseChat(<Object?>['not', 'an', 'object']))
          .code, 'invalid_body');
      expect(_err(OllamaRequest.parseChat(null)).code, 'invalid_body');
    });
  });

  group('OllamaRequest.parseGenerate — POST /api/generate', () {
    test('reads the prompt string directly, shape generate', () {
      final OllamaRequest request = _ok(OllamaRequest.parseGenerate(
        <String, Object?>{
          'model': 'tom-assistant:terse',
          'prompt': 'why is the sky blue?',
          'stream': false,
        },
      ));
      expect(request.prompt, 'why is the sky blue?');
      expect(request.model, 'tom-assistant:terse');
      expect(request.stream, isFalse);
      expect(request.shape, OllamaApiShape.generate);
    });

    test('stream defaults to TRUE when absent', () {
      final OllamaRequest request = _ok(OllamaRequest.parseGenerate(
        <String, Object?>{'prompt': 'hello'},
      ));
      expect(request.stream, isTrue);
      expect(request.model, isNull);
    });

    test('a missing prompt is missing_prompt', () {
      final OllamaParseError error = _err(OllamaRequest.parseGenerate(
        <String, Object?>{'model': 'tom-assistant'},
      ));
      expect(error.code, 'missing_prompt');
      expect(error.param, 'prompt');
    });

    test('a non-string / blank prompt is invalid_prompt', () {
      expect(_err(OllamaRequest.parseGenerate(<String, Object?>{'prompt': 9}))
          .code, 'invalid_prompt');
      expect(
          _err(OllamaRequest.parseGenerate(<String, Object?>{'prompt': '  '}))
              .code,
          'invalid_prompt');
    });

    test('a non-bool stream is invalid_stream', () {
      final OllamaParseError error = _err(OllamaRequest.parseGenerate(
        <String, Object?>{'prompt': 'hi', 'stream': 1},
      ));
      expect(error.code, 'invalid_stream');
      expect(error.param, 'stream');
    });

    test('a non-object body is invalid_body', () {
      expect(_err(OllamaRequest.parseGenerate('nope')).code, 'invalid_body');
    });
  });

  group('OllamaRequest.toInboundRequest', () {
    test('maps prompt → text and stream → streaming; channel ids optional', () {
      final OllamaRequest request = _ok(OllamaRequest.parseChat(
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

  group('OllamaApiShape', () {
    test('exactly two shapes with their Ollama route paths', () {
      expect(OllamaApiShape.values, <OllamaApiShape>[
        OllamaApiShape.chat,
        OllamaApiShape.generate,
      ]);
      expect(OllamaApiShape.chat.path, '/api/chat');
      expect(OllamaApiShape.generate.path, '/api/generate');
    });

    test('contentFields places text in the per-shape carrier', () {
      expect(OllamaApiShape.chat.contentFields('hi'), <String, Object?>{
        'message': <String, Object?>{'role': 'assistant', 'content': 'hi'},
      });
      expect(OllamaApiShape.generate.contentFields('hi'),
          <String, Object?>{'response': 'hi'});
    });
  });
}
