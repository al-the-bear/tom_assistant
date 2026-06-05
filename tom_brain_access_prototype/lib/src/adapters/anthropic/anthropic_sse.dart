// Anthropic Messages streaming (SSE) response rendering (plan item #28).
//
// What this file owns:
//
//   * `AnthropicSseRenderer` — the pure wire-format renderer that maps a
//     `Stream<OutboundChunk>` (the unit the engine's answer step emits through
//     `Access.deliver`) onto the canonical Anthropic Messages streaming event
//     sequence an Anthropic SDK consumes:
//
//       message_start → content_block_start → content_block_delta × N →
//       content_block_stop → message_delta → message_stop
//
// Anthropic's streaming wire differs from OpenAI's SSE in three ways this
// renderer encodes:
//
//   1. Each frame is a *named* SSE event — `event: <name>\ndata: <json>\n\n`
//      — not OpenAI's anonymous `data: <json>\n\n`.
//   2. There is NO `[DONE]` sentinel; a `message_stop` event closes the
//      stream. The whole message rides inside a `message_start` /
//      `message_stop` envelope, with the text in `content_block_delta` events
//      between a `content_block_start` / `content_block_stop` pair.
//   3. Usage is split across two events: `input_tokens` on `message_start`
//      (estimated from the prompt) and `output_tokens` on `message_delta`
//      (estimated from the buffered answer). Both are the same char/4 estimate
//      the OpenAI JSON renderer uses (Q-E.2.1) — the prototype's chunk stream
//      carries no real effort metrics.
//
// Scope discipline (mirrors the OpenAI / Ollama renderers): this is *SSE
// rendering only*. It turns chunks into frames and stops — it does not source
// the chunks (the adapter injects the stream), resolve a persona (the `model`
// it stamps is the already-resolved id the adapter hands it), or implement
// backpressure.

import 'dart:convert';

import 'package:tom_core_agentic/tom_core_agentic.dart' as agentic;
import 'package:tom_brain_shared/tom_brain_shared.dart';

/// Renders a stream of [OutboundChunk]s into the Anthropic Messages streaming
/// event sequence.
///
/// The opening `message_start` envelope carries [id] / [model] and the
/// prompt's `input_tokens`; each chunk becomes one `content_block_delta`
/// `text_delta`; the closing `message_delta` carries `stop_reason: end_turn`
/// and the answer's `output_tokens`; `message_stop` terminates. No `[DONE]`.
///
/// Immutable; one renderer instance describes one response stream (fixed
/// [id] / [model], which the Anthropic envelope repeats).
final class AnthropicSseRenderer {
  /// The Anthropic message object type, stamped on the `message_start`
  /// envelope.
  static const String messageType = 'message';

  /// The role of the streamed message.
  static const String assistantRole = 'assistant';

  /// The content-block type the prototype emits (text only — no tool use).
  static const String textBlockType = 'text';

  /// The delta type carrying streamed text.
  static const String textDeltaType = 'text_delta';

  /// The `stop_reason` of a normally-completed answer.
  static const String stopReason = 'end_turn';

  /// The single content-block index the prototype uses (one text block).
  static const int blockIndex = 0;

  /// The message id (`msg_…`), repeated through the envelope so a client can
  /// correlate the events of one message.
  final String id;

  /// The model string echoed into the `message_start` envelope. This is the
  /// resolved persona-as-model id the adapter supplies.
  final String model;

  /// Builds a renderer with an explicit [id] / [model]. Tests use this for
  /// deterministic frames; runtime callers normally use [forModel].
  const AnthropicSseRenderer({
    required this.id,
    required this.model,
  });

  /// Builds a renderer for [model], minting a fresh `msg_<ULID>` id.
  ///
  /// The ULID comes from `tom_brain_shared`'s [Ulid] generator — the same
  /// monotonic source the OpenAI / Ollama renderers use — rather than a
  /// bespoke random string.
  factory AnthropicSseRenderer.forModel(String model, {String? id}) =>
      AnthropicSseRenderer(
        id: id ?? 'msg_${Ulid.generate()}',
        model: model,
      );

  /// Maps [chunks] onto the Anthropic event sequence. [prompt] is the request
  /// prompt, used only to estimate `message_start`'s `input_tokens`.
  ///
  /// The chunk stream's text is buffered as it streams so the terminal
  /// `message_delta` can carry the answer's `output_tokens`; each chunk is
  /// still emitted as its own `content_block_delta` as it arrives. The
  /// [OutboundChunk.isFinal] marker is irrelevant — the stream completing is
  /// what closes the content block and the message.
  Stream<String> render({
    required String prompt,
    required Stream<OutboundChunk> chunks,
  }) async* {
    yield _frame('message_start', <String, Object?>{
      'type': 'message_start',
      'message': <String, Object?>{
        'id': id,
        'type': messageType,
        'role': assistantRole,
        'model': model,
        'content': <Object?>[],
        'stop_reason': null,
        'stop_sequence': null,
        'usage': <String, Object?>{
          'input_tokens': estimateTokens(prompt),
          'output_tokens': 0,
        },
      },
    });

    yield _frame('content_block_start', <String, Object?>{
      'type': 'content_block_start',
      'index': blockIndex,
      'content_block': <String, Object?>{'type': textBlockType, 'text': ''},
    });

    final StringBuffer answer = StringBuffer();
    await for (final OutboundChunk chunk in chunks) {
      answer.write(chunk.textDelta);
      yield _frame('content_block_delta', <String, Object?>{
        'type': 'content_block_delta',
        'index': blockIndex,
        'delta': <String, Object?>{
          'type': textDeltaType,
          'text': chunk.textDelta,
        },
      });
    }

    yield _frame('content_block_stop', <String, Object?>{
      'type': 'content_block_stop',
      'index': blockIndex,
    });

    yield _frame('message_delta', <String, Object?>{
      'type': 'message_delta',
      'delta': <String, Object?>{
        'stop_reason': stopReason,
        'stop_sequence': null,
      },
      'usage': <String, Object?>{
        'output_tokens': estimateTokens(answer.toString()),
      },
    });

    yield _frame('message_stop', <String, Object?>{'type': 'message_stop'});
  }

  /// Builds one `event: <name>\ndata: <json>\n\n` SSE frame.
  String _frame(String event, Map<String, Object?> data) =>
      'event: $event\ndata: ${jsonEncode(data)}\n\n';

  /// Approximate, tokeniser-free token count for [text] (Q-E.2.1):
  /// `ceil(length / 4)`, empty text counting as zero. Delegates to
  /// `tom_core_agentic`'s shared [agentic.estimateTokens] — the same char/4
  /// heuristic the OpenAI JSON renderer uses.
  static int estimateTokens(String text) => agentic.estimateTokens(text);
}
