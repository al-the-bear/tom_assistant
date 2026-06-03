// B.2.1 — `BrainEventBus<E>`: the generic broadcast fan-in promoted to
// tom_brain_shared.
//
// Five Tom Brain components grew a verbatim shape-mirror of the same
// broadcast bus (`SubstrateEventBus`, `MemoryEventBus`, `EngineEventBus`,
// `DispatcherEventBus`, `AccessEventBus`) — identical apart from the
// element type and the bus label in the emit-after-close message. This
// test locks the generic's contract: broadcast fan-out to many
// subscribers, asynchronous emission, an idempotent close that ends the
// stream, and a labelled `StateError` on emit-after-close.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// Minimal concrete [BrainEvent] for exercising the generic bus.
final class _Ping extends BrainEvent {
  final int seq;
  _Ping(this.seq) : super(occurredAt: DateTime.now().toUtc());

  @override
  String get kind => 'test.ping';

  @override
  Map<String, Object?> payloadJson() => {'seq': seq};
}

void main() {
  group('BrainEventBus<E>', () {
    test('fans every emission out to multiple subscribers', () async {
      final bus = BrainEventBus<_Ping>(busLabel: 'TestBus');
      final a = <int>[];
      final b = <int>[];
      bus.events().listen((e) => a.add(e.seq));
      bus.events().listen((e) => b.add(e.seq));

      bus.emit(_Ping(1));
      bus.emit(_Ping(2));
      await bus.close();

      expect(a, [1, 2]);
      expect(b, [1, 2]);
    });

    test('emission is asynchronous — subscribers see events on a later '
        'microtask, not inside the emit call', () async {
      final bus = BrainEventBus<_Ping>(busLabel: 'TestBus');
      final seen = <int>[];
      bus.events().listen((e) => seen.add(e.seq));

      bus.emit(_Ping(1));
      // Still empty synchronously after emit returns.
      expect(seen, isEmpty);
      await bus.close();
      expect(seen, [1]);
    });

    test('close ends the stream for live subscribers', () async {
      final bus = BrainEventBus<_Ping>(busLabel: 'TestBus');
      var done = false;
      bus.events().listen((_) {}, onDone: () => done = true);
      await bus.close();
      expect(done, isTrue);
      expect(bus.isClosed, isTrue);
    });

    test('close is idempotent', () async {
      final bus = BrainEventBus<_Ping>(busLabel: 'TestBus');
      await bus.close();
      await bus.close();
      expect(bus.isClosed, isTrue);
    });

    test('emit after close throws a labelled StateError carrying the '
        'event kind', () async {
      final bus = BrainEventBus<_Ping>(busLabel: 'TestBus');
      await bus.close();
      expect(
        () => bus.emit(_Ping(9)),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('TestBus.emit'),
            contains('after close'),
            contains('test.ping'),
          ),
        )),
      );
    });
  });
}
