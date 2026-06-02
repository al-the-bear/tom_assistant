// Telegram inbound/outbound adapter.
//
// Owns the `TelegramAdapter` built on `tom_chattools`' `ChatApi` +
// `TelegramChatConfig` (long-polling for the prototype): inbound
// Telegram-message → `InboundRequest` mapping, outbound streamed-answer
// → consolidated-message mapping (Stage-1 limits — no edits, typing
// indicators, or inline buttons), and the configured user-id whitelist
// enforced at the edge. See
// `tom_brain_access_prototype_specification.md` § Telegram adapter and
// Plan steps E.19 – E.23.
//
// E.19 lands the adapter scaffold: the long-polling lifecycle
// (`TelegramAdapter.start` / `stop`) over `tom_chattools`' `ChatApi` and
// the raw inbound relay (`inboundMessages`). E.20 adds the `ChatMessage` →
// `InboundRequest` mapping (`TelegramInboundMapping.toInboundRequest`,
// surfaced on the adapter as `inboundRequests`). E.21 adds the outbound
// mapping (`TelegramOutboundConsolidator`, surfaced on the adapter as
// `sendAnswer`): a streamed answer → one consolidated message, or on
// overflow the minimum number of size-compliant messages. The user-id
// whitelist (E.22) builds on it in the following substep.

export 'telegram_adapter.dart';
export 'telegram_inbound_mapping.dart';
export 'telegram_outbound_mapping.dart';
