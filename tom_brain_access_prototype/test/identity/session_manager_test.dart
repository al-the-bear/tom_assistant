// E.25 contract test — the `SessionManager` edge session step.
//
// Five surfaces are exercised:
//   * `AccessChannel`: the wire names match the sibling resolver's `channel`
//     strings (so logs read consistently across E.24 / E.25).
//   * `SessionKey`: the non-empty `principalId` guard; structural equality
//     and the record form used as the store key (distinct triples never
//     collide, including the delimiter-ambiguous case).
//   * `SessionNode`: turn recording, the sliding window at capacity, the
//     running `totalTurns` vs the capped `windowLength`, the `Session`
//     handle projection.
//   * `SessionManager.resolve`: create-on-first-contact; reuse-by-key (same
//     node, same `sessionId`, AC-8); the channel discriminator and the
//     conversation id each split the key; the `null`-conversation rolling
//     session.
//   * Injected clock + id factory: deterministic timestamps and ids.
//
// Per the E.25 scope ruling this test deliberately does NOT assert identity
// resolution (E.24), persona resolution (E.26), memory-node persistence
// (E.27 / E.55), or dispatcher / boot wiring (E.41+).

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// A resolved identity fixture — E.25 consumes only its `principalId`.
ResolvedIdentity _identity(String principalId) =>
    ResolvedIdentity(principalId: principalId);

/// An inbound request fixture with the fields E.25 reads.
InboundRequest _inbound({
  required String text,
  String? conversationId,
  String? messageId,
}) =>
    InboundRequest(
      text: text,
      conversationId: conversationId,
      messageId: messageId,
    );

void main() {
  group('AccessChannel — channel discriminator', () {
    test('wire names match the E.24 channel strings', () {
      expect(AccessChannel.openai.wireName, 'openai');
      expect(AccessChannel.telegram.wireName, 'telegram');
    });
  });

  group('SessionKey — the (principal, channel, conversation) triple', () {
    test('rejects an empty principalId', () {
      expect(
        () => SessionKey(principalId: '', channel: AccessChannel.openai),
        throwsArgumentError,
      );
    });

    test('structural equality over all three components', () {
      final a = SessionKey(
        principalId: 'p1',
        channel: AccessChannel.openai,
        conversationId: 'c1',
      );
      final b = SessionKey(
        principalId: 'p1',
        channel: AccessChannel.openai,
        conversationId: 'c1',
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('the channel distinguishes otherwise-identical keys', () {
      final openai = SessionKey(
        principalId: 'p1',
        channel: AccessChannel.openai,
        conversationId: 'c1',
      );
      final telegram = SessionKey(
        principalId: 'p1',
        channel: AccessChannel.telegram,
        conversationId: 'c1',
      );
      expect(openai, isNot(equals(telegram)));
    });

    test('the record form keys distinct delimiter-ambiguous triples apart',
        () {
      // A delimited-string key would collide these two; the record does not.
      final left = SessionKey(
        principalId: 'a|b',
        channel: AccessChannel.openai,
        conversationId: 'c',
      ).record;
      final right = SessionKey(
        principalId: 'a',
        channel: AccessChannel.openai,
        conversationId: 'b|c',
      ).record;
      expect(left, isNot(equals(right)));
    });
  });

  group('SessionManager.resolve — create / reuse', () {
    test('creates a node on first contact and records the first turn', () {
      final manager = SessionManager();
      final node = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'hello', conversationId: 'c1'),
      );

      expect(manager.sessionCount, 1);
      expect(node.totalTurns, 1);
      expect(node.windowLength, 1);
      expect(node.window.single.text, 'hello');
      expect(node.window.single.index, 0);
      expect(node.conversationId, 'c1');
    });

    test('reuses the same node for the same key (AC-8 — by key, not '
        're-creation)', () {
      final manager = SessionManager();
      final first = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'one', conversationId: 'c1'),
      );
      final second = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'two', conversationId: 'c1'),
      );

      expect(identical(first, second), isTrue);
      expect(second.sessionId, first.sessionId);
      expect(manager.sessionCount, 1);
      expect(second.totalTurns, 2);
      expect(second.window.map((t) => t.text), ['one', 'two']);
      expect(second.window.map((t) => t.index), [0, 1]);
    });

    test('the channel discriminator splits one principal into two sessions',
        () {
      final manager = SessionManager();
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'oa', conversationId: 'c1'),
      );
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.telegram,
        envelope: _inbound(text: 'tg', conversationId: 'c1'),
      );
      expect(manager.sessionCount, 2);
    });

    test('different conversation ids on one channel are different sessions',
        () {
      final manager = SessionManager();
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a', conversationId: 'c1'),
      );
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'b', conversationId: 'c2'),
      );
      expect(manager.sessionCount, 2);
    });

    test('a null conversation id is one rolling session per (principal, '
        'channel)', () {
      final manager = SessionManager();
      final first = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a'),
      );
      final second = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'b'),
      );
      expect(identical(first, second), isTrue);
      expect(manager.sessionCount, 1);
      expect(second.conversationId, isNull);
      expect(second.totalTurns, 2);
    });

    test('different principals never share a session', () {
      final manager = SessionManager();
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a', conversationId: 'c1'),
      );
      manager.resolve(
        identity: _identity('p2'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'b', conversationId: 'c1'),
      );
      expect(manager.sessionCount, 2);
    });

    test('carries the message id onto the turn', () {
      final manager = SessionManager();
      final node = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.telegram,
        envelope: _inbound(text: 'hi', conversationId: 'c1', messageId: 'm7'),
      );
      expect(node.window.single.messageId, 'm7');
    });
  });

  group('SessionNode — sliding window', () {
    test('slides the window at capacity while totalTurns keeps counting', () {
      final manager = SessionManager(maxWindowTurns: 3);
      late SessionNode node;
      for (var i = 0; i < 5; i++) {
        node = manager.resolve(
          identity: _identity('p1'),
          channel: AccessChannel.openai,
          envelope: _inbound(text: 'turn$i', conversationId: 'c1'),
        );
      }
      // Five turns seen, window capped at 3, oldest two evicted.
      expect(node.totalTurns, 5);
      expect(node.windowLength, 3);
      expect(node.window.map((t) => t.text), ['turn2', 'turn3', 'turn4']);
      // Index keeps counting past eviction.
      expect(node.window.map((t) => t.index), [2, 3, 4]);
    });

    test('window getter is unmodifiable', () {
      final manager = SessionManager();
      final node = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a', conversationId: 'c1'),
      );
      expect(
        () => node.window.add(
          SessionTurn(index: 1, text: 'x', at: DateTime(2026)),
        ),
        throwsUnsupportedError,
      );
    });

    test('projects onto the shared Session handle', () {
      final manager = SessionManager();
      final node = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a', conversationId: 'c1'),
      );
      final handle = node.toSessionHandle();
      expect(handle, isA<Session>());
      expect(handle.sessionId, node.sessionId);
      expect(handle.conversationId, 'c1');
    });
  });

  group('SessionManager — construction guards & injected seams', () {
    test('rejects a maxWindowTurns below 1', () {
      expect(
        () => SessionManager(maxWindowTurns: 0),
        throwsArgumentError,
      );
    });

    test('uses the injected clock for turn timestamps and activity', () {
      final t0 = DateTime(2026, 6, 2, 12, 0, 0);
      var ticks = 0;
      final manager = SessionManager(
        now: () => t0.add(Duration(seconds: ticks++)),
      );
      final node = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a', conversationId: 'c1'),
      );
      expect(node.createdAt, t0);
      expect(node.window.single.at, t0);

      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'b', conversationId: 'c1'),
      );
      expect(node.lastActivityAt, t0.add(const Duration(seconds: 1)));
    });

    test('uses the injected session-id factory', () {
      var counter = 0;
      final manager = SessionManager(
        sessionIdFactory: (key) => 'id-${counter++}',
      );
      final node = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a', conversationId: 'c1'),
      );
      expect(node.sessionId, 'id-0');
      // Reuse does not re-generate the id.
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'b', conversationId: 'c1'),
      );
      expect(node.sessionId, 'id-0');
      expect(counter, 1);
    });

    test('default session id is readable, deterministic, and non-empty', () {
      final manager = SessionManager();
      final node = manager.resolve(
        identity: _identity('alexis'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a', conversationId: 'c1'),
      );
      expect(node.sessionId, 'sess:openai:c1:alexis');
      expect(node.sessionId, isNotEmpty);
    });

    test('peek returns the node without creating or recording a turn', () {
      final manager = SessionManager();
      final key = SessionKey(
        principalId: 'p1',
        channel: AccessChannel.openai,
        conversationId: 'c1',
      );
      expect(manager.peek(key), isNull);
      expect(manager.sessionCount, 0);

      final created = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a', conversationId: 'c1'),
      );
      final peeked = manager.peek(key);
      expect(identical(peeked, created), isTrue);
      // peek did not record a turn.
      expect(created.totalTurns, 1);
    });
  });
}
