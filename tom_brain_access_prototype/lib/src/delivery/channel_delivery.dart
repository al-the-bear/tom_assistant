// Channel-delivery contract — the seam the per-channel delivery paths fill
// (E.36; proto spec § 10.1).
//
// What this file owns:
//
//   * `DeliveryBinding` — the per-`Access` channel-bound context a delivery
//     path needs to stream one answer back to one inbound request. It is
//     built by the adapter / boot *before* the `Access` is assembled (the
//     `Access.deliver` callback is produced *from* a binding, so the binding
//     cannot itself reference the not-yet-built `Access` — it carries the
//     `ResolvedIdentity` + `InboundRequest` that already exist).
//
//   * `ChannelDelivery` — the contract one originating channel's delivery
//     path implements: it declares the `AccessChannel` it serves and knows
//     how to produce a per-`Access` `DeliverCallback` bound to a binding.
//     This is the "knows how to translate `OutboundChunk` to the channel's
//     wire format" responsibility the plan names — but the *concrete*
//     translators are E.37 (SSE) and E.38 (Telegram); this file is only the
//     contract they implement and the `DeliveryRegistry` (E.36) dispatches to.
//
// Why a binding object rather than loose parameters: a per-`Access` deliver
// callback must be bound to channel-specific state (which SSE response sink /
// which Telegram chat). That state is the binding; one binding per inbound
// request. Keeping it a typed object (subclassed per channel at E.37 / E.38)
// lets the registry stay channel-agnostic while each path narrows the binding
// to its own concrete subtype via a `covariant` parameter.
//
// What this file does NOT do:
//
//   * No wire formatting. Translating an `OutboundChunk` to an SSE `data:`
//     frame / a Telegram message flush is the concrete paths' job (E.37 /
//     E.38). `ChannelDelivery` is the interface they implement.
//   * No backpressure protocol. `DeliveryStalled` and SSE-disconnect
//     cancellation are E.39 / E.40; the `DeliverCallback` already returns the
//     backpressure `Stream<OutboundChunk>` those steps fill in.

import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../identity/session_manager.dart' show AccessChannel;

/// The per-`Access` channel-bound context one delivery path needs to stream
/// an answer back to one inbound request.
///
/// A concrete channel subclasses this to carry its channel-specific sink —
/// e.g. the SSE response controller (E.37) or the Telegram chat target
/// (E.38). The base carries only what the channel-agnostic
/// [DeliveryRegistry] needs: the originating [channel] (so the registry can
/// look up the path that serves it) and the [identity] / [envelope] of the
/// inbound request (so the registry can emit a correlated [AccessDelivered]
/// when the answer finishes streaming).
///
/// It deliberately does **not** carry the [Access]: the `Access.deliver`
/// callback is produced *from* a binding (`DeliveryRegistry.deliverFor`), so
/// the binding is built before the `Access` exists. The two fields it does
/// carry ([identity] / [envelope]) are both resolved before the `Access` is
/// assembled (E.24 / E.20–E.12), so there is no construction-order cycle.
abstract class DeliveryBinding {
  /// The originating channel this binding belongs to. The registry routes on
  /// it to find the [ChannelDelivery] that serves the channel.
  AccessChannel get channel;

  /// The resolved principal (E.24). The registry reads
  /// [ResolvedIdentity.principalId] for the correlated [AccessDelivered].
  ResolvedIdentity get identity;

  /// The normalised inbound request (E.12 / E.20). The registry reads its
  /// `messageId` (as the [AccessDelivered] correlation handle) and
  /// `conversationId`.
  InboundRequest get envelope;
}

/// One originating channel's outbound delivery path.
///
/// A `ChannelDelivery` is registered once with the [DeliveryRegistry] (at
/// boot, E.41) and serves every inbound request on its [channel]. Per inbound
/// request the registry calls [bindDeliver] with that request's
/// [DeliveryBinding] to mint the per-`Access` [DeliverCallback] the engine
/// streams the answer through.
///
/// The concrete implementations are E.37 (SSE, OpenAI) and E.38 (Telegram);
/// each narrows the [bindDeliver] parameter to its own [DeliveryBinding]
/// subtype with `covariant` and owns the wire-format translation. This
/// interface is only the contract the registry dispatches to.
abstract interface class ChannelDelivery {
  /// The originating channel this path serves. The registry keys on it; two
  /// paths for the same channel is a configuration error
  /// (`DeliveryRegistry.register` rejects it).
  AccessChannel get channel;

  /// Produces the per-`Access` [DeliverCallback] bound to [binding].
  ///
  /// The engine calls the returned callback once per [OutboundChunk]; the
  /// callback translates the chunk to [channel]'s wire format and returns the
  /// backpressure `Stream<OutboundChunk>`. The concrete path narrows
  /// [binding] to its own [DeliveryBinding] subtype (`covariant`).
  DeliverCallback bindDeliver(DeliveryBinding binding);
}
