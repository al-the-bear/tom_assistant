// TelegramSessionRegistry — per-Telegram-user session continuity and the four
// session slash-commands (access spec § 6.5).
//
// What is proven:
//   1. First contact silently creates `global` + an active `default` (no
//      notice — the answer stays the only reply).
//   2. `global` is always present, always first (index 000), and stays a
//      no-id session the user can pick and stay in.
//   3. `/create_session` mints + activates and acknowledges with the exact
//      wording; the minted id is adopted into the SessionManager.
//   4. `/list_sessions` numbers from 000 and marks the active one.
//   5. `/pick_session` activates by three-digit index, rejecting out-of-range.
//   6. `/rename_session` renames the active session, refusing `global`.
//   7. State persists across a "restart" (a new registry over the same store).
//   8. A malformed stored id is recreated with a notice; a well-formed one is
//      re-adopted silently.
//
// The shared command parser (`parseTelegramCommand`) + help text live in their
// own suite (`telegram_command_test.dart`).

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show TimestampId;

/// A deterministic, *valid* `TimestampId`-shaped id so assertions can name ids
/// without tripping `resolveActive`'s malformed-id corruption guard
/// (`TimestampId.isValid`). The registry mints these on the user's behalf, so a
/// test minter must hand out the same shape the production minter does.
String _vid(int n) => '260608-000000.${n.toString().padLeft(6, '0')}';

void main() {
  group('TelegramSessionRegistry', () {
    // A deterministic minter so assertions can name ids.
    ({TelegramSessionRegistry registry, List<String> adopted}) build({
      MapEdgeStateStore? store,
      List<String>? ids,
    }) {
      final adopted = <String>[];
      var i = 0;
      final pool = ids ?? [_vid(0), _vid(1), _vid(2), _vid(3)];
      return (
        registry: TelegramSessionRegistry(
          store: store ?? MapEdgeStateStore(),
          mintSessionId: () => pool[i++],
          adoptSession: adopted.add,
        ),
        adopted: adopted,
      );
    }

    test('first contact silently creates global + active default', () {
      final f = build();
      final active = f.registry.resolveActive('u1');
      expect(active.activeName, 'default');
      expect(active.sessionId, _vid(0));
      expect(active.notice, isNull); // silent — no extra message
      expect(f.adopted, [_vid(0)]); // the default id is adopted
    });

    test('global is always first (000) and listed', () {
      final f = build();
      final list = f.registry.listSessions('u1');
      final lines = list.split('\n');
      expect(lines.first, 'Sessions:');
      expect(lines[1], startsWith('000'));
      expect(lines[1], contains('global'));
    });

    test('/create_session mints, activates, acknowledges, and adopts', () {
      final f = build();
      f.registry.resolveActive('u1'); // first contact → default = id-000
      final reply = f.registry.createSession('u1', 'work');
      expect(reply, 'New session ${_vid(1)} named work created and is in use now');
      // The new id is the active one and was adopted.
      final active = f.registry.resolveActive('u1');
      expect(active.activeName, 'work');
      expect(active.sessionId, _vid(1));
      expect(f.adopted, contains(_vid(1)));
    });

    test('/list_sessions numbers from 000 and marks the active session', () {
      final f = build();
      f.registry.resolveActive('u1');
      f.registry.createSession('u1', 'work'); // active = work
      final list = f.registry.listSessions('u1');
      final lines = list.split('\n');
      // 000 global, 001 default, 002 work — work is active.
      expect(lines[1], allOf(startsWith('000'), contains('global')));
      expect(lines[2], allOf(startsWith('001'), contains('default')));
      expect(lines[3], allOf(startsWith('002'), contains('work')));
      expect(lines[3], contains('*')); // active marker on work
      expect(lines[2], isNot(contains('*')));
    });

    test('/pick_session activates by three-digit index', () {
      final f = build();
      f.registry.resolveActive('u1');
      f.registry.createSession('u1', 'work'); // active = work
      final reply = f.registry.pickSession('u1', '001'); // back to default
      expect(reply, contains('default'));
      expect(f.registry.resolveActive('u1').activeName, 'default');
    });

    test('/pick_session 000 stays in the global session (no id)', () {
      final f = build();
      f.registry.resolveActive('u1');
      final reply = f.registry.pickSession('u1', '000');
      expect(reply, 'Now in session global');
      final active = f.registry.resolveActive('u1');
      expect(active.activeName, 'global');
      expect(active.sessionId, isNull); // global ⇒ null id
    });

    test('/pick_session rejects an out-of-range index', () {
      final f = build();
      f.registry.resolveActive('u1');
      expect(f.registry.pickSession('u1', '099'), contains('No session'));
      expect(f.registry.pickSession('u1', 'abc'), contains('No session'));
    });

    test('/rename_session renames the active session', () {
      final f = build();
      f.registry.resolveActive('u1'); // active = default
      final reply = f.registry.renameSession('u1', 'project x');
      expect(reply, 'Session renamed to project x');
      expect(f.registry.resolveActive('u1').activeName, 'project x');
    });

    test('/rename_session refuses to rename the global session', () {
      final f = build();
      f.registry.resolveActive('u1');
      f.registry.pickSession('u1', '000'); // active = global
      final reply = f.registry.renameSession('u1', 'whatever');
      expect(reply, contains('global session cannot be renamed'));
      // Global is unchanged and still pickable.
      expect(f.registry.resolveActive('u1').activeName, 'global');
    });

    test('state persists across a restart (new registry, same store)', () {
      final store = MapEdgeStateStore();
      final first = build(store: store).registry;
      first.resolveActive('u1'); // default = id-000
      first.createSession('u1', 'work'); // active = work, id-001

      // "Restart": a fresh registry over the same store re-adopts the
      // remembered active id silently.
      final adopted = <String>[];
      final second = TelegramSessionRegistry(
        store: store,
        mintSessionId: () => fail('restart must not mint a fresh id'),
        adoptSession: adopted.add,
      );
      final active = second.resolveActive('u1');
      expect(active.activeName, 'work');
      expect(active.sessionId, _vid(1));
      expect(active.notice, isNull); // re-adopted, not "invalid"
      expect(adopted, contains(_vid(1)));
    });

    test('a malformed stored id is recreated with a notice', () {
      final store = MapEdgeStateStore();
      // Seed a corrupt active session id directly into the store.
      store.save({
        'u1': {
          'active': 'work',
          'sessions': [
            {'name': 'global', 'id': null},
            {'name': 'work', 'id': 'not-a-timestamp-id'},
          ],
        },
      });
      final f = build(store: store, ids: [_vid(9)]);
      final active = f.registry.resolveActive('u1');
      expect(TimestampId.isValid('not-a-timestamp-id'), isFalse);
      expect(active.activeName, 'work');
      expect(active.sessionId, _vid(9)); // recreated
      expect(active.notice, isNotNull);
      expect(active.notice, contains('invalid'));
      expect(f.adopted, contains(_vid(9)));
    });

    test('per-user isolation: two users keep independent sessions', () {
      final f = build();
      f.registry.resolveActive('u1'); // u1 default = id-000
      f.registry.createSession('u2', 'solo'); // u2 first-contact + create
      // u1 is unaffected by u2's session.
      expect(f.registry.resolveActive('u1').activeName, 'default');
      expect(f.registry.resolveActive('u2').activeName, 'solo');
    });
  });
}
