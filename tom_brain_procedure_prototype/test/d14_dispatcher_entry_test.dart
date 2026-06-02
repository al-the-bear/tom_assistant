// Dispatcher entry-surface tests (Plan step D.14).
//
// D.14 delivers `Dispatcher.accept(Access)` — the single entry point and
// the front of the `accept → classify → select → schedule` pipeline. The
// later stages (classifier D.15, selection D.16, coordinator D.18) do not
// exist yet, so these tests pin the entry-surface contract in isolation:
//
//   1. accept hands the access to the route exactly once, unchanged.
//   2. accept fires the entry observation before routing, exactly once.
//   3. accept works with no observer.
//   4. accept's return value is void — the answer never rides it; the only
//      outbound path is `Access.deliver`, which `accept` never calls.
//   5. accept does not swallow a routing failure — it propagates.
//   6. accept awaits the route — it completes only after routing completes.

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show Dispatcher;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        DeliverCallback,
        InboundRequest,
        OutboundChunk,
        Persona,
        ResolvedIdentity,
        Session;

/// A deliver callback that records every chunk it is asked to stream, so a
/// test can prove the entry surface never invokes delivery itself.
class _RecordingDeliver {
  final List<OutboundChunk> chunks = <OutboundChunk>[];

  Stream<OutboundChunk> call(OutboundChunk chunk) {
    chunks.add(chunk);
    return Stream<OutboundChunk>.value(chunk);
  }
}

Access _accessWith({
  String text = 'what is the time?',
  String? kindHint,
  DeliverCallback? deliver,
}) =>
    Access(
      envelope: InboundRequest(text: text, kindHint: kindHint),
      identity: ResolvedIdentity(principalId: 'p1'),
      session: Session(sessionId: 's1'),
      persona: Persona.assistant(),
      deliver: deliver ?? (chunk) => Stream<OutboundChunk>.value(chunk),
    );

void main() {
  group('D.14 entry surface — routing delegation', () {
    test('hands the access to the route exactly once, unchanged', () async {
      final routed = <Access>[];
      final dispatcher = Dispatcher(
        route: (access) async => routed.add(access),
      );
      final access = _accessWith();

      await dispatcher.accept(access);

      expect(routed, hasLength(1));
      expect(identical(routed.single, access), isTrue,
          reason: 'the entry surface routes the same object, never a copy');
    });

    test('routes each accepted access independently', () async {
      final routed = <Access>[];
      final dispatcher = Dispatcher(
        route: (access) async => routed.add(access),
      );
      final first = _accessWith(text: 'first');
      final second = _accessWith(text: 'second');

      await dispatcher.accept(first);
      await dispatcher.accept(second);

      expect(routed, hasLength(2));
      expect(routed[0].envelope.text, 'first');
      expect(routed[1].envelope.text, 'second');
    });
  });

  group('D.14 entry surface — entry observation', () {
    test('fires the entry observation once, before the route', () async {
      final order = <String>[];
      final observed = <Access>[];
      final dispatcher = Dispatcher(
        onAccepted: (access) {
          observed.add(access);
          order.add('observed');
        },
        route: (access) async => order.add('routed'),
      );
      final access = _accessWith();

      await dispatcher.accept(access);

      expect(observed, hasLength(1));
      expect(identical(observed.single, access), isTrue);
      expect(order, <String>['observed', 'routed'],
          reason: 'admission is recorded before any routing work');
    });

    test('routes normally when no observer is supplied', () async {
      final routed = <Access>[];
      final dispatcher = Dispatcher(
        route: (access) async => routed.add(access),
      );

      await dispatcher.accept(_accessWith());

      expect(routed, hasLength(1));
    });
  });

  group('D.14 entry surface — outbound discipline', () {
    test('never invokes Access.deliver itself', () async {
      final deliver = _RecordingDeliver();
      final dispatcher = Dispatcher(
        route: (access) async {/* route does nothing with deliver */},
      );

      await dispatcher.accept(_accessWith(deliver: deliver.call));

      expect(deliver.chunks, isEmpty,
          reason: 'delivery is the engine/answer-step job, not the entry '
              'surface; accept must not stream anything back');
    });
  });

  group('D.14 entry surface — failure + ordering', () {
    test('propagates a routing failure to the caller (never swallowed)',
        () async {
      final dispatcher = Dispatcher(
        route: (access) async => throw StateError('route failed'),
      );

      await expectLater(
        dispatcher.accept(_accessWith()),
        throwsA(isA<StateError>()),
      );
    });

    test('still records admission even when the route fails', () async {
      final observed = <Access>[];
      final dispatcher = Dispatcher(
        onAccepted: observed.add,
        route: (access) async => throw StateError('route failed'),
      );

      await expectLater(
        dispatcher.accept(_accessWith()),
        throwsA(isA<StateError>()),
      );
      expect(observed, hasLength(1),
          reason: 'the observation fires before the route runs');
    });

    test('completes only after the route completes (accept awaits it)',
        () async {
      final gate = Completer<void>();
      var routeDone = false;
      final dispatcher = Dispatcher(
        route: (access) async {
          await gate.future;
          routeDone = true;
        },
      );

      final pending = dispatcher.accept(_accessWith());
      // The route is parked on the gate; accept must not have completed.
      expect(routeDone, isFalse);

      gate.complete();
      await pending;
      expect(routeDone, isTrue);
    });
  });
}
