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
// the raw inbound relay (`inboundMessages`). The `ChatMessage` →
// `InboundRequest` mapping (E.20), outbound consolidation (E.21), and the
// user-id whitelist (E.22) build on it in the following substeps.

export 'telegram_adapter.dart';
