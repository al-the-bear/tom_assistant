// OutboundChunk — one increment of a streamed answer (Plan step D.11;
// proto spec § 10.1; E.52 reuse note).
//
// What this file owns:
//
//   * The `OutboundChunk` value type — the unit the answer step
//     (`answer_with_memory_v1`, D.38) emits through `Access.deliver` for
//     each token chunk it streams back to the originating channel.
//
// Why this lives in `tom_brain_shared`:
//
//   The dispatcher's delivery wiring reads `OutboundChunk` and the
//   Phase-E `DeliveryRegistry` (E.36) translates it to the channel's
//   wire format (SSE `data:` line / Telegram message flush). Two phases
//   reference it → shared, declared once (E.52 pulled forward to D.11
//   per D.4).
//
// What this file does NOT do:
//
//   * No wire formatting. The mapping to SSE `[DONE]` / a Telegram
//     consolidated message is Phase E's concern (E.13 / E.21); this
//     type only carries the increment and the [isFinal] marker the
//     wire layer keys on.

import 'package:tom_core_agentic/tom_core_agentic.dart' show textPreview;

/// One increment of a streamed answer.
///
/// The engine / `answer_with_memory_v1` answer step calls
/// `Access.deliver(chunk)` once per increment. The final chunk carries
/// [isFinal] `= true`, which the Phase-E wire layer maps to the SSE
/// `[DONE]` terminator or the Telegram single-message flush.
///
/// Immutable value object.
final class OutboundChunk {
  /// The incremental text to append to the answer rendered so far. May
  /// be empty on a pure terminator chunk (`textDelta: '', isFinal:
  /// true`) — the wire layer still needs the final marker.
  final String textDelta;

  /// Marks the last chunk of the answer. The wire layer flushes /
  /// terminates the stream on this. Defaults to `false`.
  final bool isFinal;

  /// Optional monotonic chunk index, useful for ordering assertions in
  /// tests and for wire layers that number their frames. `null` when the
  /// producer does not track an index.
  final int? index;

  /// Builds an immutable outbound chunk. [index], when supplied, must be
  /// non-negative — a negative chunk index is meaningless.
  OutboundChunk({
    required this.textDelta,
    this.isFinal = false,
    this.index,
  }) {
    if (index != null && index! < 0) {
      throw ArgumentError.value(index, 'index', 'must be >= 0 when supplied');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is OutboundChunk &&
      other.textDelta == textDelta &&
      other.isFinal == isFinal &&
      other.index == index;

  @override
  int get hashCode => Object.hash(textDelta, isFinal, index);

  @override
  String toString() => 'OutboundChunk('
      'textDelta: ${textPreview(textDelta, limit: 40)}, '
      'isFinal: $isFinal, '
      'index: $index)';
}
