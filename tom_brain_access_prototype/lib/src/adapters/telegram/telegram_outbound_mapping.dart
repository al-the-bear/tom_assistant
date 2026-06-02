// Telegram outbound mapping — streamed answer → one consolidated message
// (E.21).
//
// What this file owns (Plan § Phase E, substep E.21; proto spec § 6.3):
//
//   * The pure consolidation of an answer's `Stream<OutboundChunk>` (the
//     unit the engine's answer step emits through `Access.deliver`, D.38 /
//     proto spec § 10.1) into the **minimum number of size-compliant
//     Telegram messages** — symmetric with the OpenAI adapter's
//     `ChatCompletionJsonRenderer` (E.14), which buffers the same stream
//     into one JSON body. Exposed as `TelegramOutboundConsolidator`.
//
// Why a list of messages, not one string: the Stage-1 Telegram rule
// (def § Q13) is *one consolidated answer* — no edits, no typing
// indicators, no inline buttons. An answer that fits in a single message
// is exactly that single message. An answer that exceeds Telegram's
// per-message size limit cannot be sent as one message and cannot be
// edited in (no edits), so it is split into the fewest size-compliant
// messages that hold it (Q-E.2.6). The "no edits" invariant is preserved:
// we never edit a message, we send N append-only messages.
//
// Telegram measures a message's length in **UTF-16 code units**, not
// Unicode code points — a character outside the BMP (an emoji) counts as
// two toward the 4096 limit. The split therefore packs by UTF-16 length
// while never cutting a character in half (it breaks only on whole-rune
// boundaries). This keeps every emitted message both Telegram-compliant
// (≤ [telegramMaxMessageLength] code units) and character-correct, and is
// minimal among character-safe splits.
//
// Scope discipline (per-substep posture carried from E.20). E.21 is the
// outbound consolidation mapping and the adapter's send-it method, nothing
// downstream:
//
//   * NO `DeliveryRegistry` wiring — translating per-`Access` chunks to the
//     channel and owning both delivery paths is E.36 – E.38.
//   * NO backpressure / `DeliveryStalled` — that is E.39 / E.40.
//   * NO whitelist auth (E.22), NO identity / session / persona (E.24–E.27),
//     NO dispatcher wiring (boot, E.41+).

import 'package:tom_brain_shared/tom_brain_shared.dart';

/// Telegram's maximum length for a single text message, in **UTF-16 code
/// units** (the unit Telegram itself counts). An answer longer than this
/// cannot be delivered as one message.
const int telegramMaxMessageLength = 4096;

/// Consolidates an answer's `Stream<OutboundChunk>` into the messages a
/// Telegram chat receives (proto spec § 6.3).
///
/// Where [ChatCompletionJsonRenderer] (E.14) buffers the same stream into
/// one JSON body, this consolidator buffers it into the full answer text and
/// then splits that text into the **minimum number of size-compliant
/// Telegram messages**: one message when the answer fits, the fewest
/// whole-character messages that hold it when it does not.
///
/// Immutable; a single instance describes the splitting policy (its
/// [maxMessageLength]) and can consolidate any number of answers.
final class TelegramOutboundConsolidator {
  /// The per-message UTF-16-code-unit budget. Defaults to Telegram's
  /// [telegramMaxMessageLength]; tests lower it to force the overflow split
  /// without building a 4096-character answer.
  final int maxMessageLength;

  /// Builds a consolidator with the given per-message [maxMessageLength]
  /// (default: Telegram's [telegramMaxMessageLength]).
  ///
  /// [maxMessageLength] must be `>= 2` so that any single Unicode character
  /// (at most two UTF-16 code units) always fits in a message — a limit of
  /// `1` could never hold an astral character without splitting it.
  const TelegramOutboundConsolidator({
    this.maxMessageLength = telegramMaxMessageLength,
  }) : assert(maxMessageLength >= 2, 'maxMessageLength must be >= 2');

  /// Buffers [chunks] into the full answer text, then returns the messages
  /// to send, in order.
  ///
  /// The [OutboundChunk.isFinal] marker is irrelevant to the buffered
  /// result: every chunk's [OutboundChunk.textDelta] is concatenated
  /// regardless, and the stream *completing* is what ends buffering (a
  /// final-marked chunk may still carry text, which is included). This
  /// mirrors [ChatCompletionJsonRenderer.render].
  ///
  /// Returns an empty list for an empty answer — Telegram rejects an empty
  /// message body, so "nothing to say" means "send nothing" rather than an
  /// empty message (Q-E.21.1).
  Future<List<String>> consolidate(Stream<OutboundChunk> chunks) async {
    final StringBuffer answer = StringBuffer();
    await for (final OutboundChunk chunk in chunks) {
      answer.write(chunk.textDelta);
    }
    return split(answer.toString());
  }

  /// Splits an already-buffered [answer] into the minimum number of
  /// size-compliant Telegram messages. Pure — no I/O, no stream.
  ///
  /// Packs whole Unicode characters greedily, counting each character's
  /// UTF-16 length (1 for a BMP character, 2 for an astral one) against
  /// [maxMessageLength], and never splits a character across a message
  /// boundary. An empty [answer] yields an empty list.
  List<String> split(String answer) {
    if (answer.isEmpty) return const <String>[];
    // Fast path: the whole answer fits in one message. `String.length` is the
    // UTF-16 code-unit count — exactly what Telegram measures.
    if (answer.length <= maxMessageLength) return <String>[answer];

    final List<String> messages = <String>[];
    final StringBuffer current = StringBuffer();
    int currentUnits = 0;
    for (final int rune in answer.runes) {
      final int runeUnits = rune > 0xFFFF ? 2 : 1;
      if (currentUnits + runeUnits > maxMessageLength && current.isNotEmpty) {
        messages.add(current.toString());
        current.clear();
        currentUnits = 0;
      }
      current.writeCharCode(rune);
      currentUnits += runeUnits;
    }
    if (current.isNotEmpty) messages.add(current.toString());
    return messages;
  }
}
