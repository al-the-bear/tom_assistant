// Anthropic Messages non-streaming (JSON) response rendering (plan item #28).
//
// What this file owns:
//
//   * `AnthropicJsonRenderer` — the renderer that buffers the answer's
//     `Stream<OutboundChunk>` into one JSON body in the Anthropic Message
//     shape: a single `content[0]` text block carrying the full answer, plus
//     a `usage` block. This is the body a `stream: false` client receives.
//
// Where [AnthropicSseRenderer] frames each chunk as its own named SSE event,
// this renderer buffers the whole answer and returns a single Message object.
//
// `usage` (Q-E.2.1): the prototype's chunk stream carries no real effort
// metrics, so token counts are a deliberately approximate, tokeniser-free
// char/4 estimate — the same heuristic the SSE renderer and the OpenAI
// renderers use.
//
// Scope discipline (mirrors the OpenAI / Ollama renderers): this is
// *non-streaming JSON rendering only*. It buffers chunks into one body and
// stops — it does not source the chunks, resolve a persona (the `model` it
// stamps is the already-resolved id the adapter hands it), or implement
// backpressure.

import 'dart:convert';

import 'package:tom_core_agentic/tom_core_agentic.dart' as agentic;
import 'package:tom_brain_shared/tom_brain_shared.dart';

/// Renders a stream of [OutboundChunk]s into one Anthropic Message JSON body.
///
/// `content[0]` is a single `{type: "text", text: …}` block whose text is the
/// concatenation of every chunk's [OutboundChunk.textDelta]; `stop_reason` is
/// `"end_turn"`; `usage` carries approximate `input_tokens` / `output_tokens`.
///
/// Immutable; one renderer instance describes one response (fixed [id] /
/// [model]).
final class AnthropicJsonRenderer {
  /// The Anthropic message object type.
  static const String messageType = 'message';

  /// The role stamped on the buffered message.
  static const String assistantRole = 'assistant';

  /// The content-block type the prototype emits (text only).
  static const String textBlockType = 'text';

  /// The `stop_reason` of a buffered (always-complete) answer.
  static const String stopReason = 'end_turn';

  /// The message id (`msg_…`).
  final String id;

  /// The model string echoed into the body. This is the resolved
  /// persona-as-model id the adapter supplies.
  final String model;

  /// Builds a renderer with an explicit [id] / [model]. Tests use this for
  /// deterministic bodies; runtime callers normally use [forModel].
  const AnthropicJsonRenderer({
    required this.id,
    required this.model,
  });

  /// Builds a renderer for [model], minting a fresh `msg_<ULID>` id.
  ///
  /// The ULID comes from `tom_brain_shared`'s [Ulid] generator — the same
  /// monotonic source the SSE renderer and the rest of Tom Brain use.
  factory AnthropicJsonRenderer.forModel(String model, {String? id}) =>
      AnthropicJsonRenderer(
        id: id ?? 'msg_${Ulid.generate()}',
        model: model,
      );

  /// Buffers [chunks] into the full answer text, then returns the encoded
  /// Anthropic Message JSON body. [prompt] is the request prompt, used only to
  /// estimate `usage.input_tokens`.
  ///
  /// The [OutboundChunk.isFinal] marker is irrelevant to the buffered body:
  /// every chunk's [OutboundChunk.textDelta] is concatenated regardless, and
  /// the stream completing is what ends buffering.
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

  /// Builds the Anthropic Message body map for an already-buffered answer
  /// [content], with `usage` estimated from [prompt] + [content]. Pure — no
  /// I/O, no stream.
  Map<String, Object?> bodyMap({
    required String prompt,
    required String content,
  }) {
    final int inputTokens = estimateTokens(prompt);
    final int outputTokens = estimateTokens(content);
    return <String, Object?>{
      'id': id,
      'type': messageType,
      'role': assistantRole,
      'model': model,
      'content': <Object?>[
        <String, Object?>{'type': textBlockType, 'text': content},
      ],
      'stop_reason': stopReason,
      'stop_sequence': null,
      'usage': <String, Object?>{
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
      },
    };
  }

  /// Encodes [bodyMap] to the JSON string the wire layer sends.
  String bodyJson({required String prompt, required String content}) =>
      jsonEncode(bodyMap(prompt: prompt, content: content));

  /// Approximate, tokeniser-free token count for [text] (Q-E.2.1):
  /// `ceil(length / 4)`, empty text counting as zero. Delegates to
  /// `tom_core_agentic`'s shared [agentic.estimateTokens].
  static int estimateTokens(String text) => agentic.estimateTokens(text);
}
