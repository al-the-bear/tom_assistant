// E.51 — Phase-E code-review pass E1 sentinel.
//
// E.51 is a review pass, not a feature: every Phase-E file was read against
// the spec section that owns it (`tom_brain_access_prototype_specification.md`),
// and the divergence report lives in `prototype_implementation_details.md`
// § E.51. The report's value erodes the moment it is prose only — a later edit
// could silently widen a closed set or drop a wire-format field and the report
// would still read "clean". This sentinel pins the review's *closed-set*
// conclusions as code so they stay enforced:
//
//   * the persona-as-model vocabulary (§ 5.5 / AC-5),
//   * the OpenAI route set (§ 5.1 / AC-6),
//   * the chat-completion wire object types + the documented wire-format gaps
//     (no `system_fingerprint`, no `logprobs`) the review flagged (§ 5.3 /
//     5.4). The streaming first-chunk `delta.role` gap the review noted was
//     closed by todo #33 (Q-E.51.2); the sentinel now pins that role *is*
//     stamped on the first chunk and omitted on the rest,
//   * the models-list shape + its documented gaps (no `permission` / `root` /
//     `parent`) (§ 5.7),
//   * the closed enums the edge depends on — `KindHintDecision` (§ 9 / AC-9),
//     `AccessChannel`, `BearerAuthFailureReason` (§ 7 / § 8),
//   * the edge-security HTTP status vocabulary (§ 8).
//
// Pinning the *known gaps* (the missing OpenAI fields) is deliberate: the
// review accepted them as prototype-scope simplifications, so the assertion
// is "this field is still absent" — a future contributor who adds it trips the
// test and is forced to update the divergence record in the same change
// (AC-12, no silent contract drift). The test is pure: no socket, no booted
// process; it drives the package barrel + the shared barrel only.

import 'dart:convert';

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// Decodes one `data: {…}\n\n` SSE frame into its JSON map.
Map<String, Object?> _decodeFrame(String frame) {
  expect(frame, startsWith('data: '));
  expect(frame, endsWith('\n\n'));
  final String json = frame.substring('data: '.length, frame.length - 2);
  return jsonDecode(json) as Map<String, Object?>;
}

void main() {
  group('E.51-1 — persona-as-model vocabulary (§ 5.5 / AC-5)', () {
    test('knownModels is exactly the three prototype personas, in order', () {
      expect(OpenAiPersonaMapping.knownModels, <String>[
        'tom-assistant',
        'tom-assistant:terse',
        'tom-assistant:verbose',
      ]);
      expect(OpenAiPersonaMapping.knownModels.length, 3);
      expect(OpenAiPersonaMapping.baseModel, 'tom-assistant');
      expect(OpenAiPersonaMapping.baseModel, Persona.defaultPersonaId);
    });

    test('every known model resolves to substrateRole assistant_to_user', () {
      for (final String model in OpenAiPersonaMapping.knownModels) {
        final Persona persona = OpenAiPersonaMapping.resolve(model);
        expect(persona.personaId, model);
        expect(persona.substrateRole, Persona.defaultSubstrateRole);
        expect(persona.substrateRole, 'assistant_to_user');
        expect(OpenAiPersonaMapping.isKnown(model), isTrue);
      }
    });

    test('absent / unknown model falls back to Persona.assistant (AC-5)', () {
      expect(OpenAiPersonaMapping.resolve(null), Persona.assistant());
      expect(OpenAiPersonaMapping.resolve('gpt-4o'), Persona.assistant());
      expect(OpenAiPersonaMapping.isKnown(null), isFalse);
      expect(OpenAiPersonaMapping.isKnown('gpt-4o'), isFalse);
    });
  });

  group('E.51-2 — OpenAI route set (§ 5.1 / AC-6)', () {
    test('exactly three routes hang under /v1', () {
      expect(OpenAiHttpSseAdapter.basePath, '/v1');
      expect(OpenAiHttpSseAdapter.chatCompletionsPath, '/v1/chat/completions');
      expect(OpenAiHttpSseAdapter.embeddingsPath, '/v1/embeddings');
      expect(OpenAiHttpSseAdapter.modelsPath, '/v1/models');
    });
  });

  group('E.51-3 — chat-completion wire object types + documented gaps', () {
    test('SSE / JSON object-type constants are the OpenAI spellings', () {
      expect(ChatCompletionSseRenderer.objectType, 'chat.completion.chunk');
      expect(ChatCompletionSseRenderer.doneFrame, 'data: [DONE]\n\n');
      expect(ChatCompletionJsonRenderer.objectType, 'chat.completion');
      expect(ChatCompletionJsonRenderer.assistantRole, 'assistant');
      expect(ChatCompletionJsonRenderer.finishReason, 'stop');
    });

    test('a streaming chunk frame carries the closed top-level key set', () {
      const renderer = ChatCompletionSseRenderer(
        id: 'chatcmpl-test',
        model: 'tom-assistant',
        created: 1735689600,
      );
      final Map<String, Object?> frame =
          _decodeFrame(renderer.frameFor(OutboundChunk(textDelta: 'hi')));
      expect(frame.keys.toSet(),
          <String>{'id', 'object', 'created', 'model', 'choices'});
      // Documented E.51 wire-format gaps: the prototype omits system_fingerprint.
      expect(frame.containsKey('system_fingerprint'), isFalse);

      final Map<String, Object?> choice =
          (frame['choices']! as List<Object?>).single as Map<String, Object?>;
      expect(choice.keys.toSet(),
          <String>{'index', 'delta', 'finish_reason'});
      // Documented gap: no logprobs key on the streaming choice.
      expect(choice.containsKey('logprobs'), isFalse);

      final Map<String, Object?> delta = choice['delta']! as Map<String, Object?>;
      expect(delta['content'], 'hi');
      // A non-first chunk carries no `role` — only content.
      expect(delta.containsKey('role'), isFalse);
    });

    test('the streaming first chunk stamps delta.role:"assistant" (Q-E.51.2)',
        () {
      const renderer = ChatCompletionSseRenderer(
        id: 'chatcmpl-test',
        model: 'tom-assistant',
        created: 1735689600,
      );
      // Closed by todo #33: the real OpenAI API announces the assistant role on
      // the opening chunk; the prototype now matches. The first frame carries
      // role:"assistant"; every later frame omits it (asserted above).
      final Map<String, Object?> firstDelta = ((_decodeFrame(renderer.frameFor(
                  OutboundChunk(textDelta: 'hi'),
                  firstChunk: true))['choices']! as List<Object?>)
              .single as Map<String, Object?>)['delta']!
          as Map<String, Object?>;
      expect(firstDelta['role'], 'assistant');
      expect(firstDelta['content'], 'hi');
    });

    test('finish_reason is "stop" on final, null otherwise; empty terminator '
        'yields an empty delta', () {
      const renderer = ChatCompletionSseRenderer(
        id: 'chatcmpl-test',
        model: 'tom-assistant',
        created: 1735689600,
      );
      final Map<String, Object?> nonFinal =
          _decodeFrame(renderer.frameFor(OutboundChunk(textDelta: 'x')));
      expect(((nonFinal['choices']! as List<Object?>).single
          as Map<String, Object?>)['finish_reason'], isNull);

      final Map<String, Object?> finalFrame = _decodeFrame(
          renderer.frameFor(OutboundChunk(textDelta: '', isFinal: true)));
      final Map<String, Object?> finalChoice =
          (finalFrame['choices']! as List<Object?>).single
              as Map<String, Object?>;
      expect(finalChoice['finish_reason'], 'stop');
      expect(finalChoice['delta'], <String, Object?>{});
    });
  });

  group('E.51-4 — non-streaming chat.completion body shape + documented gaps',
      () {
    test('body carries the closed key set and the OpenAI usage block', () {
      const renderer = ChatCompletionJsonRenderer(
        id: 'chatcmpl-test',
        model: 'tom-assistant',
        created: 1735689600,
      );
      final Map<String, Object?> body =
          renderer.bodyMap(prompt: 'ping', content: 'pong');
      expect(body.keys.toSet(),
          <String>{'id', 'object', 'created', 'model', 'choices', 'usage'});
      // Documented gap: no top-level system_fingerprint.
      expect(body.containsKey('system_fingerprint'), isFalse);

      final Map<String, Object?> choice =
          (body['choices']! as List<Object?>).single as Map<String, Object?>;
      expect(choice.keys.toSet(),
          <String>{'index', 'message', 'finish_reason'});
      // Documented gap: no logprobs key on the choice.
      expect(choice.containsKey('logprobs'), isFalse);

      final Map<String, Object?> message =
          choice['message']! as Map<String, Object?>;
      expect(message['role'], 'assistant');
      expect(message['content'], 'pong');

      final Map<String, Object?> usage = body['usage']! as Map<String, Object?>;
      expect(usage.keys.toSet(),
          <String>{'prompt_tokens', 'completion_tokens', 'total_tokens'});
    });
  });

  group('E.51-5 — models-list shape + documented gaps (§ 5.7)', () {
    test('list/model object-type and owner constants are the OpenAI spellings',
        () {
      expect(ModelsResponseRenderer.listObjectType, 'list');
      expect(ModelsResponseRenderer.modelObjectType, 'model');
      expect(ModelsResponseRenderer.ownedBy, 'tom-brain');
    });

    test('each model item carries the closed key set; documented gaps absent',
        () {
      const renderer = ModelsResponseRenderer();
      final Map<String, Object?> body = renderer.bodyMap();
      expect(body['object'], 'list');
      final List<Object?> data = body['data']! as List<Object?>;
      expect(data.length, OpenAiPersonaMapping.knownModels.length);
      for (final Object? raw in data) {
        final Map<String, Object?> item = raw! as Map<String, Object?>;
        expect(item.keys.toSet(),
            <String>{'id', 'object', 'created', 'owned_by'});
        expect(item['object'], 'model');
        // Documented E.51 gaps vs the real OpenAI model object.
        expect(item.containsKey('permission'), isFalse);
        expect(item.containsKey('root'), isFalse);
        expect(item.containsKey('parent'), isFalse);
      }
    });
  });

  group('E.51-6 — KindHintDecision closed set (§ 9 / AC-9)', () {
    test('exactly three decision bands, in declared order', () {
      expect(KindHintDecision.values, <KindHintDecision>[
        KindHintDecision.confident,
        KindHintDecision.uncertain,
        KindHintDecision.unknown,
      ]);
    });
  });

  group('E.51-7 — AccessChannel closed set (§ 7.2 / § 10.1)', () {
    test('exactly two channels with their wire names', () {
      expect(AccessChannel.values, <AccessChannel>[
        AccessChannel.openai,
        AccessChannel.telegram,
      ]);
      expect(AccessChannel.openai.wireName, 'openai');
      expect(AccessChannel.telegram.wireName, 'telegram');
    });
  });

  group('E.51-8 — BearerAuthFailureReason closed set (§ 8 / E.28)', () {
    test('exactly three failure reasons, in declared order', () {
      expect(BearerAuthFailureReason.values, <BearerAuthFailureReason>[
        BearerAuthFailureReason.missing,
        BearerAuthFailureReason.malformed,
        BearerAuthFailureReason.rejected,
      ]);
    });
  });

  group('E.51-9 — edge-security HTTP status vocabulary (§ 8)', () {
    test('auth 401, rate 429, quota == rate, anchor 400', () {
      expect(bearerAuthHttpStatus, 401);
      expect(rateLimitHttpStatus, 429);
      expect(quotaHttpStatus, rateLimitHttpStatus);
      expect(anchorPreCheckHttpStatus, 400);
    });

    test('the four checks collapse to exactly three distinct status codes', () {
      // quota intentionally reuses the rate-limit 429 (asserted above), so the
      // four edge checks expose three distinct statuses: 401 / 429 / 400.
      expect(<int>{bearerAuthHttpStatus, rateLimitHttpStatus, anchorPreCheckHttpStatus},
          <int>{401, 429, 400});
    });
  });
}
