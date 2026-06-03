// Backpressure signalling unit tests (Plan step E.39).
//
// Covers the shared types the Phase-E delivery paths surface and the engine
// reacts to:
//   * `DeliveryStalled`   — field carry, the `terminal` / `transient` named
//                           constructors, construction validation (a terminal
//                           stall cannot carry a `retryAfter`; a negative
//                           `retryAfter` is rejected), and value equality.
//   * `BackpressureSignal`— `DeliveryStalled` is-a sealed signal / Exception.
//   * `Backpressure`      — `clear` is an empty, normally-completing stream;
//                           `stalled(signal)` carries the signal as a stream
//                           error and never emits an element.

import 'package:test/test.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Backpressure,
        BackpressureSignal,
        DeliveryStalled,
        OutboundChunk,
        StallReason,
        StallReasonTerminality;

void main() {
  group('E.39 DeliveryStalled — fields and constructors', () {
    test('the primary constructor carries every field and derives terminality',
        () {
      final DeliveryStalled stalled = DeliveryStalled(
        channel: 'telegram',
        reason: StallReason.rateLimited,
        retryAfter: const Duration(seconds: 30),
        detail: 'throttled',
      );

      expect(stalled.channel, 'telegram');
      expect(stalled.reason, StallReason.rateLimited);
      expect(stalled.isTerminal, isFalse); // derived from rateLimited
      expect(stalled.retryAfter, const Duration(seconds: 30));
      expect(stalled.detail, 'throttled');
    });

    test('isTerminal is derived from the reason, not a constructor argument',
        () {
      expect(StallReason.clientDisconnected.isTerminal, isTrue);
      expect(StallReason.channelClosed.isTerminal, isTrue);
      expect(StallReason.rateLimited.isTerminal, isFalse);

      expect(
        DeliveryStalled(channel: 'openai', reason: StallReason.channelClosed)
            .isTerminal,
        isTrue,
      );
    });

    test('terminal() rejects a transient reason', () {
      expect(
        () => DeliveryStalled.terminal(
          channel: 'telegram',
          reason: StallReason.rateLimited,
        ),
        throwsArgumentError,
      );
    });

    test('transient() rejects a terminal reason', () {
      expect(
        () => DeliveryStalled.transient(
          channel: 'openai',
          reason: StallReason.clientDisconnected,
        ),
        throwsArgumentError,
      );
    });

    test('terminal() is permanent and carries no retryAfter', () {
      final DeliveryStalled stalled = DeliveryStalled.terminal(
        channel: 'openai',
        reason: StallReason.clientDisconnected,
        detail: 'client gone',
      );

      expect(stalled.isTerminal, isTrue);
      expect(stalled.retryAfter, isNull);
      expect(stalled.reason, StallReason.clientDisconnected);
    });

    test('transient() is recoverable and keeps its retryAfter', () {
      final DeliveryStalled stalled = DeliveryStalled.transient(
        channel: 'telegram',
        reason: StallReason.rateLimited,
        retryAfter: const Duration(seconds: 5),
      );

      expect(stalled.isTerminal, isFalse);
      expect(stalled.retryAfter, const Duration(seconds: 5));
    });

    test('a terminal-reason stall with a retryAfter is rejected', () {
      expect(
        () => DeliveryStalled(
          channel: 'openai',
          reason: StallReason.clientDisconnected,
          retryAfter: const Duration(seconds: 1),
        ),
        throwsArgumentError,
      );
    });

    test('a negative retryAfter is rejected', () {
      expect(
        () => DeliveryStalled.transient(
          channel: 'telegram',
          reason: StallReason.rateLimited,
          retryAfter: const Duration(seconds: -1),
        ),
        throwsArgumentError,
      );
    });
  });

  group('E.39 DeliveryStalled — value semantics and type', () {
    test('equal field sets are equal and share a hashCode', () {
      final DeliveryStalled a = DeliveryStalled.terminal(
        channel: 'openai',
        reason: StallReason.clientDisconnected,
      );
      final DeliveryStalled b = DeliveryStalled.terminal(
        channel: 'openai',
        reason: StallReason.clientDisconnected,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a different reason is unequal', () {
      final DeliveryStalled a = DeliveryStalled.terminal(
        channel: 'openai',
        reason: StallReason.clientDisconnected,
      );
      final DeliveryStalled b = DeliveryStalled.terminal(
        channel: 'openai',
        reason: StallReason.channelClosed,
      );

      expect(a, isNot(b));
    });

    test('is a BackpressureSignal and an Exception', () {
      final DeliveryStalled stalled = DeliveryStalled.terminal(
        channel: 'openai',
        reason: StallReason.clientDisconnected,
      );

      expect(stalled, isA<BackpressureSignal>());
      expect(stalled, isA<Exception>());
    });

    test('toString names the channel, reason and terminality', () {
      final String text = DeliveryStalled.transient(
        channel: 'telegram',
        reason: StallReason.rateLimited,
        retryAfter: const Duration(seconds: 2),
      ).toString();

      expect(text, contains('telegram'));
      expect(text, contains('rateLimited'));
      expect(text, contains('isTerminal: false'));
    });
  });

  group('E.39 Backpressure — the DeliverCallback stream builders', () {
    test('clear is an empty, normally-completing stream', () async {
      final List<OutboundChunk> emitted = await Backpressure.clear.toList();
      expect(emitted, isEmpty);
    });

    test('stalled carries the signal as a stream error, no element', () async {
      final BackpressureSignal signal = DeliveryStalled.terminal(
        channel: 'openai',
        reason: StallReason.clientDisconnected,
      );

      Object? caught;
      final List<OutboundChunk> emitted = <OutboundChunk>[];
      try {
        await for (final OutboundChunk chunk in Backpressure.stalled(signal)) {
          emitted.add(chunk);
        }
      } on Object catch (e) {
        caught = e;
      }

      expect(emitted, isEmpty);
      expect(caught, same(signal));
    });
  });
}
