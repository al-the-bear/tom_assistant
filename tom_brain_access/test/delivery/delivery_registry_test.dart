// E.36 — `DeliveryRegistry` contract suite.
//
// Locks the channel-agnostic outbound-delivery dispatcher (proto spec
// § 10.1; AC-2): registration is one path per channel; `deliverFor`
// dispatches to the registered path and returns its per-`Access`
// `DeliverCallback`; an unregistered channel throws `UnknownDeliveryChannel`;
// and (when an `onDelivered` sink is wired) the answer's final chunk emits a
// correlated `AccessDelivered` carrying the chunk count. The concrete wire
// translation (SSE E.37 / Telegram E.38) and backpressure (E.39 / E.40) are
// reached here only through a fake `ChannelDelivery`, so this suite imports
// no wire layer.

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

/// A fake delivery path: declares the channel it serves and produces a
/// `DeliverCallback` that records every chunk handed to it and echoes the
/// chunk back through a single-element backpressure stream (so callers can
/// observe that the path's own stream is passed straight through).
final class _FakeChannelDelivery implements ChannelDelivery {
  _FakeChannelDelivery(this.channel);

  @override
  final AccessChannel channel;

  /// Bindings this path was asked to bind, in call order.
  final List<DeliveryBinding> boundWith = <DeliveryBinding>[];

  /// Every chunk the produced callbacks were handed, in call order.
  final List<OutboundChunk> seen = <OutboundChunk>[];

  @override
  DeliverCallback bindDeliver(DeliveryBinding binding) {
    boundWith.add(binding);
    return (OutboundChunk chunk) {
      seen.add(chunk);
      return Stream<OutboundChunk>.value(chunk);
    };
  }
}

/// A minimal concrete [DeliveryBinding] for the suite — carries the channel,
/// identity, and envelope the registry needs, with no channel-specific sink
/// (the SSE / Telegram sinks arrive at E.37 / E.38).
final class _FakeBinding implements DeliveryBinding {
  _FakeBinding({
    required this.channel,
    required this.identity,
    required this.envelope,
  });

  @override
  final AccessChannel channel;

  @override
  final ResolvedIdentity identity;

  @override
  final InboundRequest envelope;
}

_FakeBinding _binding({
  AccessChannel channel = AccessChannel.openai,
  String principalId = 'principal-1',
  String? conversationId = 'conv-1',
  String? messageId = 'msg-1',
}) {
  return _FakeBinding(
    channel: channel,
    identity: ResolvedIdentity(principalId: principalId),
    envelope: InboundRequest(
      text: 'hello',
      conversationId: conversationId,
      messageId: messageId,
    ),
  );
}

void main() {
  group('E.36 DeliveryRegistry — registration', () {
    test('a freshly built registry supports no channel', () {
      final DeliveryRegistry registry = DeliveryRegistry();
      expect(registry.channels, isEmpty);
      expect(registry.supports(AccessChannel.openai), isFalse);
      expect(registry.supports(AccessChannel.telegram), isFalse);
    });

    test('register adds a path keyed by its own channel', () {
      final DeliveryRegistry registry = DeliveryRegistry();
      registry.register(_FakeChannelDelivery(AccessChannel.openai));
      expect(registry.supports(AccessChannel.openai), isTrue);
      expect(registry.supports(AccessChannel.telegram), isFalse);
      expect(registry.channels, <AccessChannel>{AccessChannel.openai});
    });

    test('one registry holds two delivery paths (proto spec § 10.1)', () {
      final DeliveryRegistry registry = DeliveryRegistry();
      registry.register(_FakeChannelDelivery(AccessChannel.openai));
      registry.register(_FakeChannelDelivery(AccessChannel.telegram));
      expect(
        registry.channels,
        <AccessChannel>{AccessChannel.openai, AccessChannel.telegram},
      );
    });

    test('registering a second path for a channel is a StateError', () {
      final DeliveryRegistry registry = DeliveryRegistry();
      registry.register(_FakeChannelDelivery(AccessChannel.openai));
      expect(
        () => registry.register(_FakeChannelDelivery(AccessChannel.openai)),
        throwsStateError,
      );
    });
  });

  group('E.36 DeliveryRegistry — deliverFor dispatch', () {
    test('deliverFor binds the path registered for the binding channel', () {
      final _FakeChannelDelivery path =
          _FakeChannelDelivery(AccessChannel.openai);
      final DeliveryRegistry registry = DeliveryRegistry()..register(path);
      final _FakeBinding binding = _binding();

      registry.deliverFor(binding);

      expect(path.boundWith, hasLength(1));
      expect(identical(path.boundWith.single, binding), isTrue);
    });

    test('the produced callback dispatches chunks to the registered path',
        () async {
      final _FakeChannelDelivery path =
          _FakeChannelDelivery(AccessChannel.openai);
      final DeliveryRegistry registry = DeliveryRegistry()..register(path);

      final DeliverCallback deliver = registry.deliverFor(_binding());
      final OutboundChunk chunk = OutboundChunk(textDelta: 'hi', index: 0);
      final List<OutboundChunk> back = await deliver(chunk).toList();

      expect(path.seen, <OutboundChunk>[chunk]);
      // With no onDelivered sink the path's own backpressure stream is passed
      // straight through unwrapped.
      expect(back, <OutboundChunk>[chunk]);
    });

    test('deliverFor on an unregistered channel throws UnknownDeliveryChannel',
        () {
      final DeliveryRegistry registry = DeliveryRegistry()
        ..register(_FakeChannelDelivery(AccessChannel.openai));

      expect(
        () => registry.deliverFor(_binding(channel: AccessChannel.telegram)),
        throwsA(
          isA<UnknownDeliveryChannel>().having(
            (UnknownDeliveryChannel e) => e.channel,
            'channel',
            AccessChannel.telegram,
          ),
        ),
      );
    });

    test('UnknownDeliveryChannel names the missing channel in its message', () {
      const UnknownDeliveryChannel error =
          UnknownDeliveryChannel(AccessChannel.telegram);
      expect(error.toString(), contains('telegram'));
    });
  });

  group('E.36 DeliveryRegistry — AccessDelivered emission', () {
    test('no onDelivered sink → no event and the callback is unwrapped',
        () async {
      final _FakeChannelDelivery path =
          _FakeChannelDelivery(AccessChannel.openai);
      final DeliveryRegistry registry = DeliveryRegistry()..register(path);

      final DeliverCallback deliver = registry.deliverFor(_binding());
      await deliver(OutboundChunk(textDelta: 'done', isFinal: true)).toList();
      // Nothing to assert beyond the absence of a crash: with no sink there is
      // no event channel. The dispatch itself is covered above.
      expect(path.seen, hasLength(1));
    });

    test('the final chunk emits one AccessDelivered with the chunk count',
        () async {
      final List<AccessDelivered> events = <AccessDelivered>[];
      final DateTime fixed = DateTime.utc(2026, 6, 2, 12);
      final DeliveryRegistry registry = DeliveryRegistry(
        onDelivered: events.add,
        clock: () => fixed,
      )..register(_FakeChannelDelivery(AccessChannel.openai));

      final DeliverCallback deliver = registry.deliverFor(
        _binding(
          principalId: 'principal-7',
          conversationId: 'conv-7',
          messageId: 'msg-7',
        ),
      );

      await deliver(OutboundChunk(textDelta: 'a', index: 0)).toList();
      expect(events, isEmpty); // not final yet
      await deliver(OutboundChunk(textDelta: 'b', index: 1)).toList();
      await deliver(OutboundChunk(textDelta: '', isFinal: true, index: 2))
          .toList();

      expect(events, hasLength(1));
      final AccessDelivered event = events.single;
      expect(event.chunkCount, 3);
      expect(event.principalId, 'principal-7');
      expect(event.conversationId, 'conv-7');
      expect(event.accessId, 'msg-7');
      expect(event.occurredAt, fixed);
      expect(event.kind, 'access.delivered');
    });

    test('a single consolidated final chunk emits chunkCount == 1', () async {
      final List<AccessDelivered> events = <AccessDelivered>[];
      final DeliveryRegistry registry = DeliveryRegistry(onDelivered: events.add)
        ..register(_FakeChannelDelivery(AccessChannel.telegram));

      final DeliverCallback deliver =
          registry.deliverFor(_binding(channel: AccessChannel.telegram));
      await deliver(OutboundChunk(textDelta: 'whole answer', isFinal: true))
          .toList();

      expect(events.single.chunkCount, 1);
    });

    test('chunks after the final one do not emit a second AccessDelivered',
        () async {
      final List<AccessDelivered> events = <AccessDelivered>[];
      final DeliveryRegistry registry =
          DeliveryRegistry(onDelivered: events.add)
            ..register(_FakeChannelDelivery(AccessChannel.openai));

      final DeliverCallback deliver = registry.deliverFor(_binding());
      await deliver(OutboundChunk(textDelta: 'a', isFinal: true)).toList();
      await deliver(OutboundChunk(textDelta: 'stray')).toList();

      expect(events, hasLength(1));
      expect(events.single.chunkCount, 1);
    });

    test('a non-terminated stream emits no AccessDelivered', () async {
      final List<AccessDelivered> events = <AccessDelivered>[];
      final DeliveryRegistry registry =
          DeliveryRegistry(onDelivered: events.add)
            ..register(_FakeChannelDelivery(AccessChannel.openai));

      final DeliverCallback deliver = registry.deliverFor(_binding());
      await deliver(OutboundChunk(textDelta: 'a')).toList();
      await deliver(OutboundChunk(textDelta: 'b')).toList();

      expect(events, isEmpty);
    });

    test('the emitted occurredAt is normalised to UTC', () async {
      final List<AccessDelivered> events = <AccessDelivered>[];
      final DateTime local = DateTime(2026, 6, 2, 12); // local, non-UTC
      final DeliveryRegistry registry = DeliveryRegistry(
        onDelivered: events.add,
        clock: () => local,
      )..register(_FakeChannelDelivery(AccessChannel.openai));

      final DeliverCallback deliver = registry.deliverFor(_binding());
      await deliver(OutboundChunk(textDelta: '', isFinal: true)).toList();

      expect(events.single.occurredAt.isUtc, isTrue);
      expect(events.single.occurredAt, local.toUtc());
    });

    test('each Access gets an independent chunk counter', () async {
      final List<AccessDelivered> events = <AccessDelivered>[];
      final DeliveryRegistry registry =
          DeliveryRegistry(onDelivered: events.add)
            ..register(_FakeChannelDelivery(AccessChannel.openai));

      final DeliverCallback first =
          registry.deliverFor(_binding(messageId: 'msg-a'));
      await first(OutboundChunk(textDelta: 'a')).toList();
      await first(OutboundChunk(textDelta: 'b', isFinal: true)).toList();

      final DeliverCallback second =
          registry.deliverFor(_binding(messageId: 'msg-b'));
      await second(OutboundChunk(textDelta: 'x', isFinal: true)).toList();

      expect(events.map((AccessDelivered e) => e.chunkCount), <int>[2, 1]);
      expect(events.map((AccessDelivered e) => e.accessId), <String>[
        'msg-a',
        'msg-b',
      ]);
    });
  });
}
