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
// At E.8 this folder is intentionally empty. No exports yet.
