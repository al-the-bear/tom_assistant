// Outbound delivery.
//
// Owns the `DeliveryRegistry` (translates each per-`Access`
// `OutboundChunk` into the originating channel's wire format), the SSE
// delivery path (OpenAI), the Telegram delivery path (buffered
// single-message + chunked overflow), and backpressure — when a channel
// cannot accept further chunks (Telegram rate limit, SSE client
// disconnected) the engine receives a `DeliveryStalled` signal and
// yields, and a disconnected SSE client propagates cancellation rather
// than leaking the run. See
// `tom_brain_access_prototype_specification.md` § Delivery and Plan
// steps E.36 – E.40 (`OutboundChunk` / `DeliveryStalled` are E.52
// extraction candidates for `tom_brain_shared`).
//
// At E.8 this folder is intentionally empty. No exports yet.
