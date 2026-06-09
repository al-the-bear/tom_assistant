// Ollama NDJSON streaming-response rendering (plan item #27).
//
// What this file owns:
//
//   * `OllamaNdjsonRenderer` — the pure wire-format renderer that maps a
//     `Stream<OutboundChunk>` (the unit the engine's answer step emits through
//     `Access.deliver`) onto the Ollama NDJSON streaming wire: one JSON object
//     per `\n`-terminated line, each earlier object carrying `done: false`,
//     terminated by a single `done: true` object (with `done_reason: "stop"`).
//
// Ollama's streaming wire differs from OpenAI's SSE in three ways this
// renderer encodes:
//
//   1. Framing is NDJSON (`<json>\n`), not SSE (`data: <json>\n\n`), and the
//      content-type is `application/x-ndjson`.
//   2. There is NO `[DONE]` sentinel; the stream ends with a JSON object whose
//      `done` is `true` (and which carries `done_reason`).
//   3. There is no `id` field, and the content carrier is per-shape
//      ([OllamaApiShape.contentFields]): chat → `message.content`, generate →
//      `response`.
//
// Scope discipline (mirrors the OpenAI SSE renderer, E.13): this is *NDJSON
// rendering only*. It turns chunks into lines and stops — it does not source
// the chunks (the adapter injects the stream), resolve a persona (the `model`
// it stamps is whatever id the adapter hands it, already persona-resolved),
// or implement backpressure.

import 'dart:convert';

import 'package:tom_brain_shared/tom_brain_shared.dart';

import 'ollama_requests.dart';

/// Renders a stream of [OutboundChunk]s into the Ollama NDJSON wire format.
///
/// Each chunk becomes one `done: false` JSON line; after the last chunk the
/// renderer emits a single terminal `done: true` line carrying [doneReason].
/// All lines repeat [model] and [createdAt]; none carry an `id` (Ollama has
/// no completion id).
///
/// Immutable; one renderer instance describes one response stream of one
/// [shape].
final class OllamaNdjsonRenderer {
  /// The Ollama streaming media type.
  static const String contentType = 'application/x-ndjson';

  /// The `done_reason` stamped on the terminal line of a complete answer.
  static const String doneReason = 'stop';

  /// Which content carrier the answer text rides (chat vs generate).
  final OllamaApiShape shape;

  /// The model string echoed into every line. This is the resolved
  /// persona-as-model id the adapter supplies.
  final String model;

  /// The creation instant repeated (as an RFC 3339 / ISO-8601 UTC string) on
  /// every line.
  final DateTime createdAt;

  /// Builds a renderer with explicit field values. Tests use this for
  /// deterministic lines; runtime callers normally use [forModel].
  const OllamaNdjsonRenderer({
    required this.shape,
    required this.model,
    required this.createdAt,
  });

  /// Builds a renderer for [model] / [shape], stamping [createdAt]
  /// (default: now).
  factory OllamaNdjsonRenderer.forModel(
    String model,
    OllamaApiShape shape, {
    DateTime? createdAt,
  }) {
    return OllamaNdjsonRenderer(
      shape: shape,
      model: model,
      createdAt: createdAt ?? DateTime.now(),
    );
  }

  /// Maps [chunks] onto NDJSON lines: one `done: false` line per chunk, then
  /// the terminal `done: true` line. The terminator is emitted once the chunk
  /// stream completes — regardless of which chunk was marked
  /// [OutboundChunk.isFinal] — so the content deltas all ride `done: false`
  /// lines and the wire is always correctly terminated.
  Stream<String> render(Stream<OutboundChunk> chunks) async* {
    await for (final OutboundChunk chunk in chunks) {
      yield lineFor(chunk);
    }
    yield finalLine();
  }

  /// Builds the single `done: false` NDJSON line for one [chunk] — the
  /// chunk's [OutboundChunk.textDelta] placed in this [shape]'s content
  /// carrier.
  String lineFor(OutboundChunk chunk) => _encode(<String, Object?>{
        'model': model,
        'created_at': _createdAtIso,
        ...shape.contentFields(chunk.textDelta),
        'done': false,
      });

  /// Builds the terminal `done: true` line: an empty-content carrier plus
  /// [doneReason].
  String finalLine() => _encode(<String, Object?>{
        'model': model,
        'created_at': _createdAtIso,
        ...shape.contentFields(''),
        'done': true,
        'done_reason': doneReason,
      });

  String get _createdAtIso => createdAt.toUtc().toIso8601String();

  String _encode(Map<String, Object?> object) => '${jsonEncode(object)}\n';
}
