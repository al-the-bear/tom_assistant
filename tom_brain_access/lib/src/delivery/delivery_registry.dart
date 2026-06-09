// DeliveryRegistry — the channel-agnostic outbound-delivery dispatcher
// (E.36; proto spec § 10.1; AC-2).
//
// What this file owns:
//
//   * `DeliveryRegistry` — "one registry, two delivery paths" (proto spec
//     § 10.1). It holds at most one `ChannelDelivery` per `AccessChannel`,
//     and per inbound request produces the per-`Access` `DeliverCallback` the
//     engine streams the answer through. It does not itself translate an
//     `OutboundChunk` to any wire format — it *knows which* registered path
//     does, and dispatches to it. The concrete translators are E.37 (SSE) and
//     E.38 (Telegram).
//
//   * `UnknownDeliveryChannel` — thrown when `deliverFor` is asked for a
//     channel no path has been registered for. That is a boot wiring error
//     (every channel an adapter accepts must have a registered delivery path),
//     surfaced loudly rather than silently dropping the answer.
//
// The `AccessDelivered` emission (proto spec § 13.2; the access edge's
// terminal-success event): the registry is the one channel-agnostic point in
// the outbound path, so it is where `AccessDelivered` is emitted — on the
// final chunk of a fully-streamed answer (AccessEvent doc, D.12). The event
// *sink* is injected (`onDelivered`); boot wires it to the `AccessEventBus`
// at E.41. With no sink the registry is a pure dispatcher (the mechanism is
// testable without the observability wiring).
//
// What this file does NOT do:
//
//   * No wire formatting (E.37 / E.38 own it through `ChannelDelivery`).
//   * No backpressure detection — the stall signal (`DeliveryStalled`, E.39)
//     is raised by the concrete paths; the registry passes the path's
//     backpressure `Stream<OutboundChunk>` straight through, untouched, to the
//     engine. (The terminal-success `AccessDelivered` it emits keys on
//     `chunk.isFinal`, so a chunk whose backpressure stream carries a stall is
//     never counted as delivered.)
//   * No `Access` construction or boot wiring (E.41+).

import 'package:tom_core_agentic/tom_core_agentic.dart' show systemClock;
import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../identity/session_manager.dart' show AccessChannel;
import 'channel_delivery.dart';

/// Thrown when [DeliveryRegistry.deliverFor] is asked to deliver to a
/// [channel] that has no registered [ChannelDelivery].
///
/// This is a boot wiring fault — an adapter accepts requests on a channel
/// whose delivery path was never registered — not a per-request condition, so
/// it surfaces as a thrown exception rather than a graceful channel message.
final class UnknownDeliveryChannel implements Exception {
  /// The channel that has no registered delivery path.
  final AccessChannel channel;

  /// Builds the exception for [channel].
  const UnknownDeliveryChannel(this.channel);

  @override
  String toString() =>
      'UnknownDeliveryChannel: no delivery path registered for channel '
      "'${channel.wireName}'";
}

/// The channel-agnostic outbound-delivery dispatcher (proto spec § 10.1).
///
/// Boot registers one [ChannelDelivery] per originating channel (the SSE path
/// at E.37, the Telegram path at E.38). Per inbound request an adapter / boot
/// calls [deliverFor] with that request's [DeliveryBinding] to obtain the
/// per-`Access` [DeliverCallback] the engine streams the answer through
/// (AC-2: every outbound byte goes through `Access.deliver`).
///
/// When an [onDelivered] sink is supplied the registry wraps each produced
/// callback so it emits a correlated [AccessDelivered] once the answer's
/// final chunk passes through (the edge's terminal-success event); with no
/// sink it is a pure dispatcher.
final class DeliveryRegistry {
  final Map<AccessChannel, ChannelDelivery> _paths =
      <AccessChannel, ChannelDelivery>{};

  /// Optional sink for the terminal-success [AccessDelivered] event. `null`
  /// (the default) makes the registry a pure dispatcher; boot wires this to
  /// the `AccessEventBus` at E.41.
  final void Function(AccessDelivered event)? _onDelivered;

  /// Clock for the emitted event's `occurredAt`. Defaults to [DateTime.now];
  /// tests inject a fixed clock. The emitted instant is always normalised to
  /// UTC, as `BrainEvent` requires.
  final DateTime Function() _clock;

  /// Builds a registry.
  ///
  /// [onDelivered] — when supplied — receives an [AccessDelivered] on the
  /// final chunk of every fully-streamed answer. [clock] stamps that event;
  /// it defaults to [systemClock].
  DeliveryRegistry({
    void Function(AccessDelivered event)? onDelivered,
    DateTime Function()? clock,
  })  : _onDelivered = onDelivered,
        _clock = clock ?? systemClock;

  /// Registers [delivery] as the delivery path for its
  /// [ChannelDelivery.channel].
  ///
  /// "One registry, two delivery paths" (proto spec § 10.1): exactly one path
  /// per channel. Registering a second path for a channel that already has one
  /// is a configuration error and throws [StateError] rather than silently
  /// replacing it.
  void register(ChannelDelivery delivery) {
    final AccessChannel channel = delivery.channel;
    if (_paths.containsKey(channel)) {
      throw StateError(
        "a delivery path is already registered for channel '"
        "${channel.wireName}'",
      );
    }
    _paths[channel] = delivery;
  }

  /// Whether a delivery path has been registered for [channel].
  bool supports(AccessChannel channel) => _paths.containsKey(channel);

  /// The channels that currently have a registered delivery path.
  Set<AccessChannel> get channels => _paths.keys.toSet();

  /// Produces the per-`Access` [DeliverCallback] for [binding].
  ///
  /// Looks up the [ChannelDelivery] registered for `binding.channel` and binds
  /// it to [binding]. Throws [UnknownDeliveryChannel] when no path is
  /// registered for that channel.
  ///
  /// When this registry was built with an `onDelivered` sink the returned
  /// callback is wrapped so that the answer's final chunk (`isFinal`) emits a
  /// correlated [AccessDelivered] carrying the number of chunks delivered;
  /// without a sink the path's own callback is returned unwrapped.
  DeliverCallback deliverFor(DeliveryBinding binding) {
    final ChannelDelivery? path = _paths[binding.channel];
    if (path == null) {
      throw UnknownDeliveryChannel(binding.channel);
    }

    final DeliverCallback inner = path.bindDeliver(binding);
    final void Function(AccessDelivered event)? onDelivered = _onDelivered;
    if (onDelivered == null) {
      return inner;
    }

    final _DeliveryProgress progress = _DeliveryProgress();
    return (OutboundChunk chunk) {
      final Stream<OutboundChunk> backpressure = inner(chunk);
      progress.countChunk();
      if (chunk.isFinal && progress.markDeliveredOnce()) {
        onDelivered(
          AccessDelivered(
            occurredAt: _clock().toUtc(),
            accessId: binding.envelope.messageId,
            principalId: binding.identity.principalId,
            chunkCount: progress.chunkCount,
            conversationId: binding.envelope.conversationId,
          ),
        );
      }
      return backpressure;
    };
  }
}

/// The per-`Access` progress the `onDelivered`-wrapping callback tracks
/// (G.4.3): how many chunks have streamed through, and whether the once-only
/// terminal-success [AccessDelivered] has already been emitted.
///
/// Names the small state machine the wrapper used to keep as a bare
/// `int chunkCount` / `bool delivered` pair in its closure, so the
/// "count every chunk, emit exactly once on the final one" intent reads
/// directly at the call site.
final class _DeliveryProgress {
  int _chunkCount = 0;
  bool _delivered = false;

  /// The number of chunks streamed through so far — the `chunkCount` the
  /// emitted [AccessDelivered] carries.
  int get chunkCount => _chunkCount;

  /// Records one more chunk streamed through the wrapped callback.
  void countChunk() => _chunkCount++;

  /// Latches the once-only terminal-success emission: returns `true` the first
  /// time it is called (the final chunk should emit), `false` thereafter (a
  /// stray later final chunk must not re-emit).
  bool markDeliveredOnce() {
    if (_delivered) return false;
    _delivered = true;
    return true;
  }
}
