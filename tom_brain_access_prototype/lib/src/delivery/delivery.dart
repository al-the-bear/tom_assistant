// Outbound delivery.
//
// Owns the `DeliveryRegistry` (the channel-agnostic dispatcher that, per
// inbound request, produces the per-`Access` `deliver` callback the engine
// streams the answer through) and the `ChannelDelivery` contract its two
// delivery paths implement, translating each `OutboundChunk` into the
// originating channel's wire format. See
// `tom_brain_access_prototype_specification.md` § 10 and Plan steps
// E.36 – E.40 (`OutboundChunk` / `DeliveryStalled` are E.52 extraction
// candidates for `tom_brain_shared`).
//
// - E.36 ✅ — `DeliveryRegistry` (one registry, two delivery paths): registers
//   one `ChannelDelivery` per `AccessChannel`, produces the per-`Access`
//   `DeliverCallback` via `deliverFor`, throws `UnknownDeliveryChannel` for an
//   unregistered channel, and emits the terminal-success `AccessDelivered`
//   (through an injected `onDelivered` sink) on the final chunk. The
//   `ChannelDelivery` / `DeliveryBinding` contract is the seam the concrete
//   paths fill.
// - E.37 ⏳ — the SSE delivery path (OpenAI `chat.completion.chunk` frames).
// - E.38 ⏳ — the Telegram delivery path (buffered single-message + overflow).
// - E.39 / E.40 ⏳ — backpressure (`DeliveryStalled`) + SSE-disconnect
//   cancellation, and the delivery test sweep.

export 'channel_delivery.dart' show ChannelDelivery, DeliveryBinding;
export 'delivery_registry.dart' show DeliveryRegistry, UnknownDeliveryChannel;
