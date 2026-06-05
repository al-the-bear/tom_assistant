// Ollama non-streaming (single-object) response rendering (plan item #27).
//
// What this file owns:
//
//   * `OllamaJsonRenderer` — the renderer that buffers the answer's
//     `Stream<OutboundChunk>` into ONE Ollama JSON object (the buffered
//     analogue of the NDJSON terminator): the full answer text in this
//     [shape]'s content carrier, plus `done: true` / `done_reason: "stop"`.
//
// Where [OllamaNdjsonRenderer] maps each chunk onto its own NDJSON line, this
// renderer buffers the whole answer and returns a single object — what an
// Ollama client that set `stream: false` receives. Ollama's non-streaming
// body carries no `usage` block in the prototype's scope (a documented gap;
// real Ollama adds timing/eval metrics the prototype's chunk stream does not
// surface).
//
// Scope discipline (mirrors the OpenAI JSON renderer, E.14): this is
// *non-streaming rendering only*. It buffers chunks into one body and stops.

import 'dart:convert';

import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'ollama_requests.dart';

/// Renders a stream of [OutboundChunk]s into one Ollama non-streaming JSON
/// body.
///
/// Buffers every chunk's [OutboundChunk.textDelta] into the full answer, then
/// returns a single object carrying that text in [shape]'s content carrier
/// (chat → `message.content`, generate → `response`), `done: true`, and
/// [doneReason]. Carries no `id` (Ollama has none).
///
/// Immutable; one renderer instance describes one response of one [shape].
final class OllamaJsonRenderer {
  /// The Ollama non-streaming media type.
  static const String contentType = 'application/json; charset=utf-8';

  /// The `done_reason` for a buffered (always-complete) answer.
  static const String doneReason = 'stop';

  /// Which content carrier the answer text rides (chat vs generate).
  final OllamaApiShape shape;

  /// The model string echoed into the body. This is the resolved
  /// persona-as-model id the adapter supplies.
  final String model;

  /// The creation instant, rendered as an RFC 3339 / ISO-8601 UTC string.
  final DateTime createdAt;

  /// Builds a renderer with explicit field values. Tests use this for
  /// deterministic bodies; runtime callers normally use [forModel].
  const OllamaJsonRenderer({
    required this.shape,
    required this.model,
    required this.createdAt,
  });

  /// Builds a renderer for [model] / [shape], stamping [createdAt]
  /// (default: now).
  factory OllamaJsonRenderer.forModel(
    String model,
    OllamaApiShape shape, {
    DateTime? createdAt,
  }) {
    return OllamaJsonRenderer(
      shape: shape,
      model: model,
      createdAt: createdAt ?? DateTime.now(),
    );
  }

  /// Buffers [chunks] into the full answer text, then returns the encoded
  /// Ollama JSON body.
  Future<String> render(Stream<OutboundChunk> chunks) async {
    final StringBuffer answer = StringBuffer();
    await for (final OutboundChunk chunk in chunks) {
      answer.write(chunk.textDelta);
    }
    return bodyJson(answer.toString());
  }

  /// Builds the Ollama JSON body map for an already-buffered answer
  /// [content]. Pure — no I/O, no stream.
  Map<String, Object?> bodyMap(String content) => <String, Object?>{
        'model': model,
        'created_at': createdAt.toUtc().toIso8601String(),
        ...shape.contentFields(content),
        'done': true,
        'done_reason': doneReason,
      };

  /// Encodes [bodyMap] to the JSON string the wire layer sends.
  String bodyJson(String content) => jsonEncode(bodyMap(content));
}
