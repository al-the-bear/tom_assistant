// E.25 / Extension-G contract test — the two-history `SessionManager`.
//
// Extension G (plan step #22; access spec § 7.2 / § 21.2) replaces the slim
// 20-turn sliding window with two `ConversationHistory` stores and an
// id-minting resolver. This suite pins that contract:
//
//   * `AccessChannel`: the wire names match the sibling resolver's `channel`
//     strings (so logs read consistently across E.24 / E.25).
//   * Sessionless minting + the global history: a request with no session id
//     resolves to the default session, mints a *fresh* id, and appends to the
//     per-(principal, channel) global history ("all prompts").
//   * Echoed ids: a known minted id resolves the dedicated per-session
//     history; an unknown id resolves gracefully to the default session
//     (`access.session.unknown`, § 14) — never a throw.
//   * Restart persistence: `snapshot` / `restore` round-trip both histories
//     (the in-process stand-in for the memory-node persistence the real layer
//     wires at E.27 / E.55).
//   * The map-bound seams (`sessionCount`, `clear`, `evictIdle`) and the
//     injected minter / clock.
//
// Per the E.25 scope ruling this test deliberately does NOT assert identity
// resolution (E.24), persona resolution (E.26), memory-node persistence
// (E.27 / E.55), or dispatcher / boot wiring (E.41+). The brain answer is
// back-filled downstream by the engine (hub § 21.1); the manager records the
// prompt only.

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
  String? sessionId,
}) =>
    InboundRequest(
      text: text,
      conversationId: conversationId,
      sessionId: sessionId,
    );

/// A deterministic, monotonically-unique minter for assertable ids.
SessionIdMinter _counterMinter() {
  var n = 0;
  return () => 'sess-${n++}';
}

/// Shorthand for the prompts recorded on a history's durable record.
List<String> _prompts(ConversationHistory? h) =>
    h == null ? const [] : [for (final t in h.durableRecord) t.userPrompt];

void main() {
  group('AccessChannel — channel discriminator', () {
    test('wire names match the E.24 channel strings', () {
      expect(AccessChannel.openai.wireName, 'openai');
      expect(AccessChannel.telegram.wireName, 'telegram');
      expect(AccessChannel.ollama.wireName, 'ollama');
      expect(AccessChannel.anthropic.wireName, 'anthropic');
    });
  });

  group('resolve — sessionless minting + global history (§ 21.2)', () {
    test('a sessionless call mints a fresh id and appends to global history',
        () {
      final manager = SessionManager(sessionIdMinter: _counterMinter());
      final res = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'hello'),
      );

      expect(res.mintedNewId, isTrue);
      expect(res.unknownSessionId, isFalse);
      expect(res.sessionId, 'sess-0');

      // Answered from the default session's global history.
      final global =
          manager.peekGlobal(principalId: 'p1', channel: AccessChannel.openai);
      expect(global, isNotNull);
      expect(identical(res.history, global), isTrue);
      expect(_prompts(global), ['hello']);

      // The minted id registers an attachable (empty) per-session; the
      // originating turn went to the global history only.
      final perSession = manager.peekSession(res.sessionId);
      expect(perSession, isNotNull);
      expect(perSession!.durableRecord, isEmpty);
    });

    test('a second sessionless call mints a NEW id but global accumulates both',
        () {
      final manager = SessionManager(sessionIdMinter: _counterMinter());
      final first = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'one'),
      );
      final second = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'two'),
      );

      expect(second.sessionId, isNot(first.sessionId));
      final global =
          manager.peekGlobal(principalId: 'p1', channel: AccessChannel.openai);
      expect(_prompts(global), ['one', 'two']);
    });
  });

  group('resolve — echoed ids (§ 7.2)', () {
    test('an echoed known id resolves the per-session history', () {
      final manager = SessionManager(sessionIdMinter: _counterMinter());
      final minted = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'first'),
      );
      final id = minted.sessionId;

      final res = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'second', sessionId: id),
      );

      expect(res.mintedNewId, isFalse);
      expect(res.unknownSessionId, isFalse);
      expect(res.sessionId, id);

      // Answered from the dedicated per-session history.
      final perSession = manager.peekSession(id);
      expect(perSession, isNotNull);
      expect(identical(res.history, perSession), isTrue);
      // The attach appends to the per-session (which started empty at mint).
      expect(_prompts(perSession), ['second']);

      // The global history accumulated both prompts.
      final global =
          manager.peekGlobal(principalId: 'p1', channel: AccessChannel.openai);
      expect(_prompts(global), ['first', 'second']);
    });

    test('an unknown echoed id resolves to the default session without error',
        () {
      final manager = SessionManager(sessionIdMinter: _counterMinter());
      final res = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'hi', sessionId: 'never-minted'),
      );

      // Graceful: flagged, not thrown; answered from the global history.
      expect(res.unknownSessionId, isTrue);
      expect(res.mintedNewId, isTrue,
          reason: 'a fresh attachable id is handed back for recovery');
      final global =
          manager.peekGlobal(principalId: 'p1', channel: AccessChannel.openai);
      expect(identical(res.history, global), isTrue);
      expect(_prompts(global), ['hi']);

      // The bogus id was never registered as a per-session.
      expect(manager.peekSession('never-minted'), isNull);
      // The freshly minted id is attachable but empty.
      final fresh = manager.peekSession(res.sessionId);
      expect(fresh, isNotNull);
      expect(fresh!.durableRecord, isEmpty);
    });
  });

  group('snapshot / restore — both histories persist across a restart', () {
    test('a fresh manager restored from a snapshot carries both histories', () {
      final original = SessionManager(sessionIdMinter: _counterMinter());
      final minted = original.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'g1'),
      );
      original.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 's1', sessionId: minted.sessionId),
      );

      final snapshot = original.snapshot();

      // A post-snapshot turn on the original must NOT leak into the restored
      // copy (the snapshot is a point-in-time deep copy).
      original.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'after'),
      );

      // Simulated restart: a brand-new manager rehydrated from the snapshot.
      final restarted = SessionManager(sessionIdMinter: _counterMinter())
        ..restore(snapshot);

      final global = restarted.peekGlobal(
          principalId: 'p1', channel: AccessChannel.openai);
      expect(_prompts(global), ['g1', 's1']);
      expect(_prompts(global), isNot(contains('after')));

      final perSession = restarted.peekSession(minted.sessionId);
      expect(_prompts(perSession), ['s1']);
    });

    test('a restored per-session is still attachable (resolves as known)', () {
      final original = SessionManager(sessionIdMinter: _counterMinter());
      final minted = original.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'hi'),
      );
      original.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'again', sessionId: minted.sessionId),
      );
      final snapshot = original.snapshot();

      final restarted = SessionManager()..restore(snapshot);
      final res = restarted.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'resumed', sessionId: minted.sessionId),
      );

      expect(res.unknownSessionId, isFalse);
      expect(res.mintedNewId, isFalse);
      expect(_prompts(res.history), ['again', 'resumed']);
    });
  });

  group('SessionManager — counts, channel/principal split, clear', () {
    test('sessionCount counts dedicated per-session histories, not the global',
        () {
      final manager = SessionManager(sessionIdMinter: _counterMinter());
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a'),
      );
      expect(manager.sessionCount, 1);
    });

    test('the channel discriminator splits one principal into two globals', () {
      final manager = SessionManager(sessionIdMinter: _counterMinter());
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'oa'),
      );
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.telegram,
        envelope: _inbound(text: 'tg'),
      );
      final oa =
          manager.peekGlobal(principalId: 'p1', channel: AccessChannel.openai);
      final tg = manager.peekGlobal(
          principalId: 'p1', channel: AccessChannel.telegram);
      expect(oa, isNotNull);
      expect(tg, isNotNull);
      expect(identical(oa, tg), isFalse);
    });

    test('different principals never share a global history', () {
      final manager = SessionManager(sessionIdMinter: _counterMinter());
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a'),
      );
      expect(
        manager.peekGlobal(principalId: 'p2', channel: AccessChannel.openai),
        isNull,
      );
    });

    test('clear() drops every per-session and global history', () {
      final manager = SessionManager(sessionIdMinter: _counterMinter());
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a'),
      );
      expect(manager.sessionCount, 1);
      manager.clear();
      expect(manager.sessionCount, 0);
      expect(
        manager.peekGlobal(principalId: 'p1', channel: AccessChannel.openai),
        isNull,
      );
    });
  });

  group('SessionManager — evictIdle (idle per-session reclamation)', () {
    test('evicts only per-session histories idle longer than the cutoff', () {
      var now = DateTime(2026, 6, 2, 12);
      final manager = SessionManager(
        now: () => now,
        sessionIdMinter: _counterMinter(),
      );
      final old = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'old'),
      );
      now = DateTime(2026, 6, 2, 14);
      final fresh = manager.resolve(
        identity: _identity('p2'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'fresh'),
      );
      expect(manager.sessionCount, 2);

      final evicted = manager.evictIdle(const Duration(hours: 1));
      expect(evicted, 1);
      expect(manager.peekSession(old.sessionId), isNull);
      expect(manager.peekSession(fresh.sessionId), isNotNull);
    });

    test('attaching refreshes a per-session activity clock', () {
      var now = DateTime(2026, 6, 2, 12);
      final manager = SessionManager(
        now: () => now,
        sessionIdMinter: _counterMinter(),
      );
      final minted = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'mint'),
      );
      now = DateTime(2026, 6, 2, 13, 30);
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'attach', sessionId: minted.sessionId),
      );
      now = DateTime(2026, 6, 2, 14);
      // Last activity 13:30, only 30 min idle at 14:00 → kept.
      expect(manager.evictIdle(const Duration(hours: 1)), 0);
      expect(manager.peekSession(minted.sessionId), isNotNull);
    });

    test('the global history is never evicted by evictIdle', () {
      var now = DateTime(2026, 6, 2, 12);
      final manager = SessionManager(
        now: () => now,
        sessionIdMinter: _counterMinter(),
      );
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'g'),
      );
      now = DateTime(2026, 6, 2, 20);
      manager.evictIdle(const Duration(hours: 1));
      expect(
        manager.peekGlobal(principalId: 'p1', channel: AccessChannel.openai),
        isNotNull,
      );
    });

    test('evictIdle rejects a negative duration', () {
      final manager = SessionManager();
      expect(
        () => manager.evictIdle(const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });
  });

  group('SessionManager — construction & injected seams', () {
    test('uses the injected minter for fresh ids', () {
      final manager = SessionManager(sessionIdMinter: _counterMinter());
      final a = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a'),
      );
      final b = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'b'),
      );
      expect(a.sessionId, 'sess-0');
      expect(b.sessionId, 'sess-1');
    });

    test('the default minter yields a unique id on every sessionless call', () {
      final manager = SessionManager();
      final ids = <String>{
        for (var i = 0; i < 50; i++)
          manager
              .resolve(
                identity: _identity('p1'),
                channel: AccessChannel.openai,
                envelope: _inbound(text: 'x'),
              )
              .sessionId,
      };
      expect(ids, hasLength(50));
    });

    test('the resolved Session handle mirrors the conversation id', () {
      final manager = SessionManager(sessionIdMinter: _counterMinter());
      final res = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a', conversationId: 'c9'),
      );
      expect(res.session.sessionId, res.sessionId);
      expect(res.session.conversationId, 'c9');
    });

    test('turns record the prompt with an empty brain answer '
        '(back-filled downstream)', () {
      final manager = SessionManager(sessionIdMinter: _counterMinter());
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'hello'),
      );
      final turn = manager
          .peekGlobal(principalId: 'p1', channel: AccessChannel.openai)!
          .durableRecord
          .single;
      expect(turn.userPrompt, 'hello');
      expect(turn.brainAnswer, isEmpty);
    });

    test('uses the configured sizing for new histories', () {
      const sizing = HistorySizing(rawCount: 2, compactionThreshold: 3);
      final manager = SessionManager(
        sizing: sizing,
        sessionIdMinter: _counterMinter(),
      );
      final res = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'a'),
      );
      expect(res.history.sizing, sizing);
    });
  });
}
