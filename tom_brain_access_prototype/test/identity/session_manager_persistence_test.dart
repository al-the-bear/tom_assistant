// SessionManager durable persistence — the JSON snapshot codec + the
// HistoryStore-backed load/persist seam (persistence of history; umbrella Hard
// principle 6 — "nothing is ever lost"; access spec § 21.10).
//
// The sibling `session_manager_test.dart` pins the in-process snapshot/restore
// round-trip. This suite pins the *durable* path the live process uses:
//
//   1. `SessionHistoriesSnapshot.toJson` / `fromJson` round-trip both stores
//      (the global per-(principal, channel) histories and the per-session
//      entries, including their Extension-H selection state) through a JSON
//      document.
//   2. A manager wired with a `HistoryStore` rehydrates from it on
//      construction — the restart seam: a brand-new manager over a store that
//      already holds a conversation resolves an echoed session id as *known*
//      (the "doesn't remember after restart" defect this layer fixes).
//   3. `persist()` writes the live histories to the store; a no-op when no
//      store is wired.

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

ResolvedIdentity _identity(String principalId) =>
    ResolvedIdentity(principalId: principalId);

InboundRequest _inbound({required String text, String? sessionId}) =>
    InboundRequest(text: text, sessionId: sessionId);

SessionIdMinter _counterMinter() {
  var n = 0;
  return () => 'sess-${n++}';
}

List<String> _prompts(ConversationHistory? h) =>
    h == null ? const [] : [for (final t in h.durableRecord) t.userPrompt];

void main() {
  group('SessionHistoriesSnapshot JSON codec', () {
    test('round-trips both histories through JSON', () {
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

      final json = original.snapshot().toJson();
      final restored = SessionHistoriesSnapshot.fromJson(json);

      expect(restored.globalCount, 1);
      expect(restored.sessionCount, 1);

      // Rehydrate a fresh manager from the decoded snapshot and confirm both
      // histories survived the JSON trip.
      final restarted = SessionManager(sessionIdMinter: _counterMinter())
        ..restore(restored);
      final global = restarted.peekGlobal(
          principalId: 'p1', channel: AccessChannel.openai);
      expect(_prompts(global), ['g1', 's1']);
      expect(_prompts(restarted.peekSession(minted.sessionId)), ['s1']);
    });

    test('preserves the back-filled brain answer across the JSON trip', () {
      final original = SessionManager(sessionIdMinter: _counterMinter());
      original.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'What is my name?'),
      );
      // The engine back-fills the answer into the live history after the run.
      original
          .peekGlobal(principalId: 'p1', channel: AccessChannel.openai)!
          .amendLastTurnAnswer('Your name is Alexis.');

      final restored = SessionHistoriesSnapshot.fromJson(
        original.snapshot().toJson(),
      );
      final restarted = SessionManager()..restore(restored);
      final turn = restarted
          .peekGlobal(principalId: 'p1', channel: AccessChannel.openai)!
          .durableRecord
          .single;
      expect(turn.brainAnswer, 'Your name is Alexis.');
    });

    test('an empty manager round-trips to an empty snapshot', () {
      final json = SessionManager().snapshot().toJson();
      final restored = SessionHistoriesSnapshot.fromJson(json);
      expect(restored.globalCount, 0);
      expect(restored.sessionCount, 0);
    });
  });

  group('HistoryStore-backed SessionManager', () {
    test('rehydrates from a store on construction (restart seam)', () {
      final store = MapHistoryStore();

      // First process: a conversation is held and persisted.
      final first = SessionManager(
        sessionIdMinter: _counterMinter(),
        historyStore: store,
      );
      final minted = first.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.telegram,
        envelope: _inbound(text: 'My name is Alexis'),
      );
      first.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.telegram,
        envelope: _inbound(text: 'remember it', sessionId: minted.sessionId),
      );
      first.persist();

      // Simulated restart: a brand-new manager over the same store.
      final second = SessionManager(
        sessionIdMinter: _counterMinter(),
        historyStore: store,
      );

      // The echoed session id resolves as KNOWN — the brain remembers.
      final res = second.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.telegram,
        envelope: _inbound(text: 'resumed', sessionId: minted.sessionId),
      );
      expect(res.unknownSessionId, isFalse);
      expect(res.mintedNewId, isFalse);
      expect(_prompts(res.history), ['remember it', 'resumed']);

      final global = second.peekGlobal(
          principalId: 'p1', channel: AccessChannel.telegram);
      expect(_prompts(global), contains('My name is Alexis'));
    });

    test('persist() writes the live snapshot to the store', () {
      final store = MapHistoryStore();
      final manager = SessionManager(
        sessionIdMinter: _counterMinter(),
        historyStore: store,
      );
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'hello'),
      );

      // Nothing persisted until persist() runs.
      expect(store.load(), isEmpty);
      manager.persist();
      expect(store.load(), isNotEmpty);

      final reloaded = SessionHistoriesSnapshot.fromJson(store.load());
      expect(reloaded.globalCount, 1);
    });

    test('persist() is a no-op when no store is wired', () {
      final manager = SessionManager(sessionIdMinter: _counterMinter());
      manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'hello'),
      );
      // Must not throw.
      expect(manager.persist, returnsNormally);
    });

    test('an empty store leaves a fresh manager empty', () {
      final store = MapHistoryStore();
      final manager = SessionManager(historyStore: store);
      expect(manager.sessionCount, 0);
    });
  });
}
