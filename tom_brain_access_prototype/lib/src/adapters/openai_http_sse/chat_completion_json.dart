// OpenAI `chat/completions` non-streaming (JSON) response rendering (E.14).
//
// What this file owns (Plan § Phase E, substep E.14; proto spec § 5.4):
//
//   * `ChatCompletionJsonRenderer` — the renderer that buffers the answer's
//     `Stream<OutboundChunk>` (the unit the engine's answer step emits
//     through `Access.deliver`, D.38 / proto spec § 10.1) into one JSON body
//     in the OpenAI `chat.completion` shape: a single `choices[0].message`
//     with the full answer text, plus a `usage` block.
//
// Scope discipline (Q-E.11.2 carried forward): E.14 is *non-streaming JSON
// rendering only*. This file buffers chunks into one body and stops. It does
// NOT:
//
//   * source the chunks — the dispatcher/engine wiring is boot's job (E.41+);
//     the adapter accepts the chunk stream through the same injected seam the
//     SSE path (E.13) uses.
//   * resolve a persona — the `model` echoed into the body is the requested
//     model string (or a literal default); the `model` → `Persona` mapping is
//     E.15's concern. The body's `model` field is informational metadata, not
//     a persona decision.
//   * implement backpressure / `DeliveryStalled` — that is E.39 / E.40.
//   * format the streaming SSE body — that is E.13.
//
// `usage` (proto spec § 5.4, Q-E.2.1): the prototype's chunk stream does not
// carry the run's effort metrics, so token counts are a deliberately
// approximate, tokeniser-free char/4 estimate (documented as approximate).
// When the run later surfaces real effort metrics (a final implementation
// concern), this is the one method to replace.

import 'dart:convert';

import 'package:tom_brain_shared/tom_brain_shared.dart';

/// Renders a stream of [OutboundChunk]s into one OpenAI `chat.completion`
/// JSON body (proto spec § 5.4).
///
/// Where [ChatCompletionSseRenderer] (E.13) maps each chunk onto its own SSE
/// frame, this renderer **buffers** the whole answer and returns a single
/// JSON object: `choices[0].message.content` is the concatenation of every
/// chunk's [OutboundChunk.textDelta], `finish_reason` is `"stop"`, and a
/// `usage` block carries approximate token counts.
///
/// Immutable; a single renderer instance describes one response (fixed [id] /
/// [model] / [created]).
final class ChatCompletionJsonRenderer {
  /// The OpenAI non-streaming completion object type.
  static const String objectType = 'chat.completion';

  /// The role stamped on the single assistant message in the body.
  static const String assistantRole = 'assistant';

  /// The `finish_reason` for a buffered (always-complete) answer.
  static const String finishReason = 'stop';

  /// The completion id (`chatcmpl-…`).
  final String id;

  /// The model string echoed into the body's `model` field. This is the
  /// requested model id (or a default); persona resolution is E.15.
  final String model;

  /// The creation instant as Unix epoch seconds.
  final int created;

  /// Builds a renderer with explicit field values. Tests use this for
  /// deterministic bodies; runtime callers normally use [forModel].
  const ChatCompletionJsonRenderer({
    required this.id,
    required this.model,
    required this.created,
  });

  /// Builds a renderer for [model], minting a fresh `chatcmpl-<ULID>` id and
  /// stamping [createdAt] (default: now) as Unix epoch seconds.
  ///
  /// The ULID comes from `tom_brain_shared`'s [Ulid] generator — the same
  /// monotonic source the SSE renderer (E.13) and the rest of Tom Brain use
  /// for ids — rather than a bespoke random string.
  factory ChatCompletionJsonRenderer.forModel(
    String model, {
    String? id,
    DateTime? createdAt,
  }) {
    return ChatCompletionJsonRenderer(
      id: id ?? 'chatcmpl-${Ulid.generate()}',
      model: model,
      created: (createdAt ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// Buffers [chunks] into the full answer text, then returns the encoded
  /// OpenAI `chat.completion` JSON body. [prompt] is the request prompt, used
  /// only to estimate `usage.prompt_tokens`.
  ///
  /// The [OutboundChunk.isFinal] marker is irrelevant to the buffered body:
  /// every chunk's [OutboundChunk.textDelta] is concatenated regardless, and
  /// the stream completing is what ends buffering. (A final-marked chunk may
  /// still carry text, which is included.)
  Future<String> render({
    required String prompt,
    required Stream<OutboundChunk> chunks,
  }) async {
    final StringBuffer answer = StringBuffer();
    await for (final OutboundChunk chunk in chunks) {
      answer.write(chunk.textDelta);
    }
    return bodyJson(prompt: prompt, content: answer.toString());
  }

  /// Builds the OpenAI `chat.completion` body map for an already-buffered
  /// answer [content], with `usage` estimated from [prompt] + [content].
  /// Pure — no I/O, no stream.
  Map<String, Object?> bodyMap({
    required String prompt,
    required String content,
  }) {
    final int promptTokens = estimateTokens(prompt);
    final int completionTokens = estimateTokens(content);
    return <String, Object?>{
      'id': id,
      'object': objectType,
      'created': created,
      'model': model,
      'choices': <Object?>[
        <String, Object?>{
          'index': 0,
          'message': <String, Object?>{
            'role': assistantRole,
            'content': content,
          },
          'finish_reason': finishReason,
        },
      ],
      'usage': <String, Object?>{
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'total_tokens': promptTokens + completionTokens,
      },
    };
  }

  /// Encodes [bodyMap] to the JSON string the wire layer sends.
  String bodyJson({required String prompt, required String content}) =>
      jsonEncode(bodyMap(prompt: prompt, content: content));

  /// Approximate, tokeniser-free token count for [text] (proto spec § 5.4,
  /// Q-E.2.1): `ceil(length / 4)`, with empty text counting as zero. This is
  /// the single place to replace once the run surfaces real effort metrics.
  static int estimateTokens(String text) =>
      text.isEmpty ? 0 : (text.length / 4).ceil();
}
