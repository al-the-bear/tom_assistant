// Regression test for Telegram session-continuity persistence (access spec
// § 6.5 / § 21.10; umbrella Hard principle 6).
//
// The "didn't remember my name after a restart" defect had two halves. One was
// the global-history answer back-fill (session_manager_test.dart). The other
// was this: a deployment that enabled conversation-history persistence
// (`access.history.directory`) — precisely to keep remembering across a restart
// — still ran the Telegram session registry in memory unless it *also* set the
// separate `access.edgeState.directory`. So every restart re-minted the user's
// `default` session id and orphaned the persisted histories: they survived on
// disk but were no longer reachable.
//
// The fix couples session continuity to history persistence:
// [telegramSessionStoreDirectory] falls back to the history directory when no
// edge-state directory is configured, so persisting histories alone is enough
// to keep a Telegram user attached to their conversation across a restart.

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:test/test.dart';

void main() {
  group('telegramSessionStoreDirectory — continuity follows history', () {
    test('prefers the explicit edge-state directory when both are set', () {
      expect(
        telegramSessionStoreDirectory(
          edgeStateDirectory: '/state/edge',
          historyDirectory: '/state/history',
        ),
        '/state/edge',
      );
    });

    test('falls back to the history directory when no edge-state dir is set',
        () {
      // The bomber regression: history persistence on, edge-state off. Before
      // the fix this returned null → in-memory registry → orphaned sessions.
      expect(
        telegramSessionStoreDirectory(
          edgeStateDirectory: null,
          historyDirectory: '/srv/.../bomber/history',
        ),
        '/srv/.../bomber/history',
      );
    });

    test('uses the edge-state directory when only it is set', () {
      expect(
        telegramSessionStoreDirectory(
          edgeStateDirectory: '/state/edge',
          historyDirectory: null,
        ),
        '/state/edge',
      );
    });

    test('is null only when neither is set (a fully in-process deployment)', () {
      expect(
        telegramSessionStoreDirectory(
          edgeStateDirectory: null,
          historyDirectory: null,
        ),
        isNull,
      );
    });
  });
}
