// OpenAI `chat/completions` streaming (SSE) response rendering (E.13).
//
// What this file owns (Plan § Phase E, substep E.13; proto spec § 5.3):
//
//   * `ChatCompletionSseRenderer` — the pure wire-format renderer that maps
//     a `Stream<OutboundChunk>` (the unit the engine's answer step emits
//     through `Access.deliver`, D.38 / proto spec § 10.1) onto the OpenAI
//     Server-Sent-Events wire shape: one `data: {…}\n\n` frame per chunk in
//     the `chat.completion.chunk` object shape, terminated by a final
//     `data: [DONE]\n\n` line.
//
// Scope discipline (Q-E.11.2 carried forward): E.13 is *SSE rendering only*.
// This file turns chunks into frames and stops. It does NOT:
//
//   * source the chunks — the dispatcher/engine wiring is boot's job (E.41+);
//     the adapter accepts the chunk stream through an injected seam.
//   * resolve a persona — the `model` echoed into each frame is the requested
//     model string (or a literal default); the `model` → `Persona` mapping is
//     E.15's concern. The SSE `model` field is informational metadata, not a
//     persona decision.
//   * implement backpressure / `DeliveryStalled` — that is E.39 / E.40. A
//     client disconnect cancels the body subscription, which cancels the
//     `await for` here; the richer stalled-channel protocol lands later.
//   * format the non-streaming JSON body — that is E.14.

import 'dart:convert';

import 'package:tom_brain_shared/tom_brain_shared.dart';

/// Renders a stream of [OutboundChunk]s into the OpenAI SSE wire format.
///
/// Each chunk becomes exactly one `data: {…}\n\n` frame carrying a
/// `chat.completion.chunk` object (`choices[0].delta.content`). After the
/// last chunk the renderer emits the terminal `data: [DONE]\n\n` line, which
/// is always the final line on the wire (proto spec § 5.3).
///
/// Immutable; a single renderer instance describes one response stream
/// (fixed [id] / [model] / [created], as the OpenAI shape requires every
/// chunk of one completion to repeat those values).
final class ChatCompletionSseRenderer {
  /// The OpenAI streaming chunk object type, repeated on every frame.
  static const String objectType = 'chat.completion.chunk';

  /// The terminal SSE line, always emitted last and always exactly this.
  static const String doneFrame = 'data: [DONE]\n\n';

  /// The completion id (`chatcmpl-…`), repeated on every frame so a client
  /// can correlate chunks of the same response.
  final String id;

  /// The model string echoed into every frame's `model` field. This is the
  /// requested model id (or a default); persona resolution is E.15.
  final String model;

  /// The creation instant as Unix epoch seconds, repeated on every frame.
  final int created;

  /// Builds a renderer with explicit field values. Tests use this for
  /// deterministic frames; runtime callers normally use [forModel].
  const ChatCompletionSseRenderer({
    required this.id,
    required this.model,
    required this.created,
  });

  /// Builds a renderer for [model], minting a fresh `chatcmpl-<ULID>` id and
  /// stamping [createdAt] (default: now) as Unix epoch seconds.
  ///
  /// The ULID comes from `tom_brain_shared`'s [Ulid] generator — the same
  /// monotonic source the rest of Tom Brain uses for ids — rather than a
  /// bespoke random string.
  factory ChatCompletionSseRenderer.forModel(
    String model, {
    String? id,
    DateTime? createdAt,
  }) {
    return ChatCompletionSseRenderer(
      id: id ?? 'chatcmpl-${Ulid.generate()}',
      model: model,
      created: (createdAt ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// Maps [chunks] onto SSE frames: one `data: {…}\n\n` frame per chunk,
  /// then the terminal [doneFrame]. The `[DONE]` line is emitted once the
  /// chunk stream completes, regardless of whether a final-marked chunk
  /// arrived, so the wire is always correctly terminated.
  Stream<String> render(Stream<OutboundChunk> chunks) async* {
    await for (final OutboundChunk chunk in chunks) {
      yield frameFor(chunk);
    }
    yield doneFrame;
  }

  /// Builds the single `data: {…}\n\n` SSE frame for one [chunk].
  ///
  /// The chunk's [OutboundChunk.textDelta] becomes `choices[0].delta.content`
  /// when non-empty; an empty delta (e.g. a pure terminator chunk) yields an
  /// empty `delta` object, matching OpenAI's final chunk shape. A
  /// final-marked chunk sets `finish_reason: "stop"`; every other chunk
  /// carries `finish_reason: null`.
  String frameFor(OutboundChunk chunk) {
    final Map<String, Object?> delta = chunk.textDelta.isEmpty
        ? <String, Object?>{}
        : <String, Object?>{'content': chunk.textDelta};

    final Map<String, Object?> payload = <String, Object?>{
      'id': id,
      'object': objectType,
      'created': created,
      'model': model,
      'choices': <Object?>[
        <String, Object?>{
          'index': 0,
          'delta': delta,
          'finish_reason': chunk.isFinal ? 'stop' : null,
        },
      ],
    };

    return 'data: ${jsonEncode(payload)}\n\n';
  }
}
