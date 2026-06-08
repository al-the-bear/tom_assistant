// `InboundRequest.copyWith` — the sentinel-based copy that lets a caller
// replace some fields while distinguishing "omit" (keep) from "pass null"
// (clear). The Telegram edge relies on the latter to stamp `sessionId: null`
// (the global session, access spec § 6.5).

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show InboundRequest, PriorTurn;

void main() {
  group('InboundRequest.copyWith', () {
    InboundRequest base() => InboundRequest(
          text: 'hello',
          kindHint: 'k1',
          conversationId: 'c1',
          messageId: 'm1',
          streaming: true,
          metadata: const {'a': 1},
          priorTurns: [PriorTurn(role: 'user', text: 'prior')],
          sessionId: 's1',
        );

    test('with no arguments returns an equal copy', () {
      final original = base();
      final copy = original.copyWith();
      expect(copy, equals(original));
      expect(identical(copy, original), isFalse);
    });

    test('replaces only the named field, keeping the rest', () {
      final copy = base().copyWith(text: 'changed');
      expect(copy.text, 'changed');
      expect(copy.kindHint, 'k1');
      expect(copy.conversationId, 'c1');
      expect(copy.messageId, 'm1');
      expect(copy.streaming, isTrue);
      expect(copy.sessionId, 's1');
    });

    test('omitting a nullable field keeps its current value', () {
      final copy = base().copyWith(text: 'changed');
      expect(copy.sessionId, 's1');
      expect(copy.kindHint, 'k1');
      expect(copy.conversationId, 'c1');
      expect(copy.messageId, 'm1');
    });

    test('passing null to a nullable field clears it', () {
      final copy = base().copyWith(sessionId: null);
      expect(copy.sessionId, isNull);
      // The other fields are untouched.
      expect(copy.kindHint, 'k1');
      expect(copy.conversationId, 'c1');
    });

    test('clears each nullable field independently', () {
      expect(base().copyWith(kindHint: null).kindHint, isNull);
      expect(base().copyWith(conversationId: null).conversationId, isNull);
      expect(base().copyWith(messageId: null).messageId, isNull);
      expect(base().copyWith(sessionId: null).sessionId, isNull);
      // Clearing one leaves the others intact.
      final cleared = base().copyWith(sessionId: null);
      expect(cleared.kindHint, 'k1');
      expect(cleared.messageId, 'm1');
    });

    test('replaces a non-null nullable field with a new non-null value', () {
      final copy = base().copyWith(sessionId: 's2');
      expect(copy.sessionId, 's2');
    });

    test('replaces the list and bool fields', () {
      final copy = base().copyWith(
        streaming: false,
        priorTurns: [PriorTurn(role: 'assistant', text: 'a')],
      );
      expect(copy.streaming, isFalse);
      expect(copy.priorTurns, hasLength(1));
      expect(copy.priorTurns.single.role, 'assistant');
    });
  });
}
