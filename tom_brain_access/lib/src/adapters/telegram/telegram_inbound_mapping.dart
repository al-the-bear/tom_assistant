// Telegram inbound mapping — `ChatMessage` → `InboundRequest` (E.20).
//
// What this file owns (Plan § Phase E, substep E.20; proto spec § 6.2):
//
//   * The pure projection of one inbound `tom_chattools` `ChatMessage`
//     onto the channel-agnostic `InboundRequest` the dispatcher consumes —
//     symmetric with the OpenAI adapter's `ChatCompletionRequest
//     .toInboundRequest` (E.12). Exposed as an extension on `ChatMessage`
//     because `ChatMessage` is a foreign type we cannot add a method to.
//   * `TelegramInboundError` / `TelegramInboundRejection` — the typed
//     reason a `ChatMessage` cannot become an `InboundRequest` (a non-text
//     Stage-1 message: sticker, photo with no caption, an empty body).
//     Per proto spec § 12 (`access.wire.malformed` → Telegram) such a
//     message is *ignored + logged*, never an error surfaced to the user;
//     the typed `Err` is the structured "why" a logger-aware consumer
//     (boot, E.41) records.
//
// The field mapping (proto spec § 6.2):
//
//   * `text`          ← `ChatMessage.text` (the message body).
//   * `messageId`     ← `ChatMessage.platformMessageId ?? ChatMessage.id`
//                       (the Telegram message id; `platformMessageId` is the
//                       canonical Telegram id, `id` the `tom_chattools`
//                       mirror — both are the same value for Telegram).
//   * `conversationId`← the chat id (see [_telegramConversationId]).
//   * sender id       → carried on `metadata` under
//                       [telegramSenderIdMetadataKey], for `IdentityResolver`
//                       (E.24) to map to a `TomPrincipal`. The dispatcher
//                       never reads it — it is channel-specific identity, not
//                       part of the dispatcher's closed read-surface, so it
//                       rides `InboundRequest.metadata` rather than becoming a
//                       new top-level field (the shared `InboundRequest` field
//                       policy is deliberate; see Q-D.11.1).
//   * `streaming`     ← `false`. Telegram is single-message — one consolidated
//                       answer, no SSE (def § Q13; proto spec § 6.2 / § 6.3).
//   * `sessionId`     ← the chat id (same value as `conversationId`). Telegram
//                       has no `X-Tom-Session` header, so the chat *is* the
//                       kept session (proto spec § 5.2; step #20: "Telegram
//                       fills only `sessionId`, chat-id keyed"). The other
//                       Extension-G fidelity fields stay empty (single-message
//                       channel, no client tool loop).
//
// Scope discipline (per-substep posture carried from E.19). E.20 is the
// inbound mapping and nothing downstream:
//
//   * NO outbound consolidation (E.21), NO whitelist auth (E.22), NO
//     identity / session / persona resolution (E.24–E.27), NO dispatcher
//     wiring (boot, E.41+). This file turns a wire object into the canonical
//     envelope and stops.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_chattools/tom_chattools.dart';

/// `InboundRequest.metadata` key under which a mapped Telegram message
/// carries its sender's id.
///
/// `IdentityResolver` (E.24) reads this to map a Telegram user id to an
/// internal `TomPrincipal`. The dispatcher never reads it: a sender id is
/// channel-specific identity, not part of the dispatcher's closed
/// read-surface, so it rides the envelope's opaque metadata rather than
/// becoming a new top-level `InboundRequest` field.
const String telegramSenderIdMetadataKey = 'telegram_sender_id';

/// `ChatMessage.rawData` key the prototype reads to derive the conversation
/// (chat) id, when the backend supplies it flat.
///
/// The E.5 `LoopbackChatApi` stamps this key in [LoopbackChatApi.injectText]
/// (E.19) so the mapping is exercised without the Telegram network. The real
/// `tom_chattools` Telegram backend (2.0.0 and later) stamps it too, from the
/// Bot API message's `chat.id`, beside the message itself as JSON under
/// `rawData['telegram_message']` — so a group chat maps to its own
/// conversation. When the key is absent (an older backend) the chat id of the
/// prototype's single-user **private-chat** whitelist equals the sender id, so
/// [_telegramConversationId] falls back to the sender id. (Q-E.20.1.)
const String telegramChatIdRawDataKey = 'telegram_chat_id';

/// Why a [ChatMessage] could not be mapped to an [InboundRequest].
enum TelegramInboundRejection {
  /// The message carried no usable prompt text — `null`, empty, or
  /// whitespace-only. A non-text Stage-1 message (sticker, photo with no
  /// caption, …) or an empty body. Per proto spec § 12 it is ignored +
  /// logged; it never becomes an `Access`.
  noText,
}

/// A typed reason one inbound [ChatMessage] cannot become an
/// [InboundRequest].
///
/// Carried by the `Err` arm of [TelegramInboundMapping.toInboundRequest].
/// The Telegram edge *ignores + logs* such a message (proto spec § 12 —
/// `access.wire.malformed` for Telegram); this type is the structured
/// record a logger-aware consumer (boot, E.41) writes, not a user-facing
/// error.
final class TelegramInboundError {
  /// The category of rejection.
  final TelegramInboundRejection reason;

  /// A human-readable explanation, safe to log (carries the message id, not
  /// the — absent — body).
  final String message;

  /// Builds a typed inbound rejection.
  const TelegramInboundError({
    required this.reason,
    required this.message,
  });

  @override
  String toString() => 'TelegramInboundError($reason: $message)';
}

/// Projects an inbound `tom_chattools` [ChatMessage] onto the
/// channel-agnostic [InboundRequest] the dispatcher consumes.
extension TelegramInboundMapping on ChatMessage {
  /// Maps this Telegram message to an [InboundRequest] (proto spec § 6.2).
  ///
  /// Returns:
  ///   * `Ok(InboundRequest)` for a text message — `text` from the body,
  ///     `messageId` from the Telegram message id, `conversationId` from the
  ///     chat id, the sender id on `metadata[telegramSenderIdMetadataKey]`,
  ///     and `streaming: false`.
  ///   * `Err(TelegramInboundError)` for a message with no usable text
  ///     ([TelegramInboundRejection.noText]) — the Stage-1 Telegram path is
  ///     text-only (def § Q13), so a sticker / photo / empty body is ignored
  ///     + logged, never surfaced to the user.
  ///
  /// Pure: no I/O, no throwing on a non-text message.
  Result<InboundRequest, TelegramInboundError> toInboundRequest() {
    final String? body = text;
    if (body == null || body.trim().isEmpty) {
      return Err(TelegramInboundError(
        reason: TelegramInboundRejection.noText,
        message: 'Telegram message ${platformMessageId ?? id} carried no '
            'text; ignored (Stage-1 Telegram is text-only, def § Q13).',
      ));
    }

    final String conversationId = _telegramConversationId();
    return Ok(InboundRequest(
      text: body,
      conversationId: conversationId,
      messageId: platformMessageId ?? id,
      streaming: false,
      metadata: {telegramSenderIdMetadataKey: sender.id},
      // Telegram has no `X-Tom-Session` header (it is not an HTTP gateway), so
      // it keys the session on the chat id — the single-user private chat *is*
      // the kept session (proto spec § 5.2; step #20: "Telegram fills only
      // `sessionId`, chat-id keyed"). The other Extension-G fidelity fields
      // (priorTurns / toolResults / remoteTools) stay empty: Telegram is a
      // single-message channel with no client-side tool loop.
      sessionId: conversationId,
    ));
  }

  /// Derives the conversation (chat) id for this message.
  ///
  /// Prefers a flat `rawData['telegram_chat_id']` when the backend supplies
  /// one (the loopback does); otherwise falls back to the sender id, which —
  /// for the prototype's single-user **private-chat** whitelist — equals the
  /// chat id. The group-chat case (sender id ≠ chat id) is out of Stage-1
  /// scope and tracked as Q-E.20.1.
  String _telegramConversationId() {
    final Object? rawChatId = rawData?[telegramChatIdRawDataKey];
    if (rawChatId != null) return rawChatId.toString();
    return sender.id;
  }
}
