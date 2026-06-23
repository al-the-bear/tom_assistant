// TelegramSessionRegistry — per-Telegram-user session continuity and the four
// session slash-commands (access spec § 6.5; memory/session profiles § 9.2 tail,
// MSP-6).
//
// What is proven (the prefixed-id model, step 11 / MSPP-37):
//   1. First contact silently creates `global` + an active `default` (no
//      notice — the answer stays the only reply).
//   2. `global` is always present, always first (index 000), and stays a
//      no-id session the user can pick and stay in (its effective id is null).
//   3. A named session's effective id is `sessionPrefix + name`, derived per
//      call from the chat's scope — never minted or stored — and is adopted
//      into the SessionManager as a known dedicated session.
//   4. `/create_session` registers + activates and acknowledges with the
//      prefixed id; `/list_sessions` numbers from 000 and marks the active one
//      with each line's effective id; `/pick_session` activates by three-digit
//      index; `/rename_session` renames the active session, refusing `global`.
//   5. A session name is an in-scope selector: a `_`-bearing / path-unsafe name
//      is rejected (MSP-6), so a command can never address a cross-prefix id.
//   6. State persists across a "restart" (a new registry over the same store);
//      the same bare name re-derives the same effective id with no minting.
//   7. A legacy `[{name,id}]` row forward-migrates to bare names on load.
//
// The shared command parser (`parseTelegramCommand`) + help text live in their
// own suite (`telegram_command_test.dart`).

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';

/// The chat's session namespace under test. A non-default prefix proves the
/// effective id is `sessionPrefix + name`, not the bare name.
const String prefix = 'tg_';

void main() {
  group('TelegramSessionRegistry', () {
    ({TelegramSessionRegistry registry, List<String> adopted}) build({
      MapEdgeStateStore? store,
    }) {
      final adopted = <String>[];
      return (
        registry: TelegramSessionRegistry(
          store: store ?? MapEdgeStateStore(),
          adoptSession: adopted.add,
        ),
        adopted: adopted,
      );
    }

    test('first contact silently creates global + active default', () {
      final f = build();
      final active = f.registry.resolveActive('u1', sessionPrefix: prefix);
      expect(active.activeName, 'default');
      expect(active.sessionId, 'tg_default'); // prefix + name
      expect(f.adopted, ['tg_default']); // the default id is adopted
    });

    test('global is always first (000) and listed', () {
      final f = build();
      final list = f.registry.listSessions('u1', sessionPrefix: prefix);
      final lines = list.split('\n');
      expect(lines.first, 'Sessions:');
      expect(lines[1], startsWith('000'));
      expect(lines[1], contains('global'));
    });

    test('/create_session registers, activates, acknowledges, and adopts', () {
      final f = build();
      f.registry.resolveActive('u1', sessionPrefix: prefix); // first contact
      final reply = f.registry.createSession(
        'u1',
        'work',
        sessionPrefix: prefix,
      );
      expect(reply, 'New session tg_work named work created and is in use now');
      // The new id is the active one and was adopted.
      final active = f.registry.resolveActive('u1', sessionPrefix: prefix);
      expect(active.activeName, 'work');
      expect(active.sessionId, 'tg_work');
      expect(f.adopted, contains('tg_work'));
    });

    test('a `_`-bearing / path-unsafe session name is rejected (MSP-6)', () {
      final f = build();
      f.registry.resolveActive('u1', sessionPrefix: prefix);
      expect(
        f.registry.createSession('u1', 'a_b', sessionPrefix: prefix),
        contains('no "_"'),
      );
      expect(
        f.registry.createSession('u1', '../escape', sessionPrefix: prefix),
        contains('no "_"'),
      );
      // The rejected names never became sessions.
      final list = f.registry.listSessions('u1', sessionPrefix: prefix);
      expect(list, isNot(contains('a_b')));
      expect(list, isNot(contains('escape')));
    });

    test('/list_sessions numbers from 000, marks active, shows prefixed ids',
        () {
      final f = build();
      f.registry.resolveActive('u1', sessionPrefix: prefix);
      f.registry.createSession('u1', 'work', sessionPrefix: prefix);
      final list = f.registry.listSessions('u1', sessionPrefix: prefix);
      final lines = list.split('\n');
      // 000 global, 001 default, 002 work — work is active.
      expect(lines[1], allOf(startsWith('000'), contains('global')));
      expect(lines[2], allOf(startsWith('001'), contains('default')));
      expect(
        lines[3],
        allOf(startsWith('002'), contains('work'), contains('tg_work')),
      );
      expect(lines[3], contains('*')); // active marker on work
      expect(lines[2], isNot(contains('*')));
    });

    test('/pick_session activates by three-digit index', () {
      final f = build();
      f.registry.resolveActive('u1', sessionPrefix: prefix);
      f.registry.createSession('u1', 'work', sessionPrefix: prefix);
      final reply = f.registry.pickSession('u1', '001', sessionPrefix: prefix);
      expect(reply, contains('default'));
      expect(
        f.registry.resolveActive('u1', sessionPrefix: prefix).activeName,
        'default',
      );
    });

    test('/pick_session 000 stays in the global session (no id)', () {
      final f = build();
      f.registry.resolveActive('u1', sessionPrefix: prefix);
      final reply = f.registry.pickSession('u1', '000', sessionPrefix: prefix);
      expect(reply, 'Now in session global');
      final active = f.registry.resolveActive('u1', sessionPrefix: prefix);
      expect(active.activeName, 'global');
      expect(active.sessionId, isNull); // global ⇒ null id (prefix-less)
    });

    test('/pick_session rejects an out-of-range index', () {
      final f = build();
      f.registry.resolveActive('u1', sessionPrefix: prefix);
      expect(
        f.registry.pickSession('u1', '099', sessionPrefix: prefix),
        contains('No session'),
      );
      expect(
        f.registry.pickSession('u1', 'abc', sessionPrefix: prefix),
        contains('No session'),
      );
    });

    test('/rename_session renames the active session', () {
      final f = build();
      f.registry.resolveActive('u1', sessionPrefix: prefix); // active = default
      final reply = f.registry.renameSession(
        'u1',
        'project x',
        sessionPrefix: prefix,
      );
      expect(reply, 'Session renamed to project x');
      final active = f.registry.resolveActive('u1', sessionPrefix: prefix);
      expect(active.activeName, 'project x');
      expect(active.sessionId, 'tg_project x');
    });

    test('/rename_session refuses to rename the global session', () {
      final f = build();
      f.registry.resolveActive('u1', sessionPrefix: prefix);
      f.registry.pickSession('u1', '000', sessionPrefix: prefix); // active=global
      final reply = f.registry.renameSession(
        'u1',
        'whatever',
        sessionPrefix: prefix,
      );
      expect(reply, contains('global session cannot be renamed'));
      // Global is unchanged and still pickable.
      expect(
        f.registry.resolveActive('u1', sessionPrefix: prefix).activeName,
        'global',
      );
    });

    test('state persists across a restart (new registry, same store)', () {
      final store = MapEdgeStateStore();
      final first = build(store: store).registry;
      first.resolveActive('u1', sessionPrefix: prefix); // default
      first.createSession('u1', 'work', sessionPrefix: prefix); // active = work

      // "Restart": a fresh registry over the same store re-derives the SAME
      // effective id from the persisted bare name — no minting.
      final adopted = <String>[];
      final second = TelegramSessionRegistry(
        store: store,
        adoptSession: adopted.add,
      );
      final active = second.resolveActive('u1', sessionPrefix: prefix);
      expect(active.activeName, 'work');
      expect(active.sessionId, 'tg_work');
      expect(adopted, contains('tg_work'));
    });

    test('a legacy [{name,id}] row forward-migrates to bare names on load', () {
      final store = MapEdgeStateStore();
      // Seed a pre-step-11 row whose sessions carry minted ids.
      store.save({
        'u1': {
          'active': 'work',
          'sessions': [
            {'name': 'global', 'id': null},
            {'name': 'work', 'id': '260608-000000.000001'},
          ],
        },
      });
      final f = build(store: store);
      final active = f.registry.resolveActive('u1', sessionPrefix: prefix);
      // The minted id is dropped; the effective id derives from the bare name.
      expect(active.activeName, 'work');
      expect(active.sessionId, 'tg_work');
      expect(f.adopted, contains('tg_work'));
      // global is still present and first.
      final lines =
          f.registry.listSessions('u1', sessionPrefix: prefix).split('\n');
      expect(lines[1], allOf(startsWith('000'), contains('global')));
    });

    test('the same bare name resolves under whichever prefix the chat carries',
        () {
      final f = build();
      f.registry.resolveActive('u1', sessionPrefix: prefix);
      f.registry.createSession('u1', 'work', sessionPrefix: prefix);
      // Same registry, different chat namespace ⇒ different effective id.
      expect(
        f.registry.resolveActive('u1', sessionPrefix: 'other_').sessionId,
        'other_work',
      );
      expect(
        f.registry.resolveActive('u1', sessionPrefix: prefix).sessionId,
        'tg_work',
      );
    });

    test('trace-memory defaults off and toggles on/off with the right reply',
        () {
      final f = build();
      f.registry.resolveActive('u1', sessionPrefix: prefix);
      expect(f.registry.isTraceMemoryEnabled('u1'), isFalse);

      final onReply = f.registry.toggleTraceMemory('u1');
      expect(f.registry.isTraceMemoryEnabled('u1'), isTrue);
      expect(onReply, contains('ON'));

      final offReply = f.registry.toggleTraceMemory('u1');
      expect(f.registry.isTraceMemoryEnabled('u1'), isFalse);
      expect(offReply, contains('OFF'));
    });

    test('trace-memory state persists across a restart (same store)', () {
      final store = MapEdgeStateStore();
      build(store: store).registry
        ..resolveActive('u1', sessionPrefix: prefix)
        ..toggleTraceMemory('u1'); // → ON, persisted

      final second = TelegramSessionRegistry(
        store: store,
        adoptSession: (_) {},
      );
      expect(second.isTraceMemoryEnabled('u1'), isTrue);
    });

    test('trace-memory is per-user', () {
      final f = build();
      f.registry.resolveActive('u1', sessionPrefix: prefix);
      f.registry.resolveActive('u2', sessionPrefix: prefix);
      f.registry.toggleTraceMemory('u1');
      expect(f.registry.isTraceMemoryEnabled('u1'), isTrue);
      expect(f.registry.isTraceMemoryEnabled('u2'), isFalse);
    });

    test('per-user isolation: two users keep independent sessions', () {
      final f = build();
      f.registry.resolveActive('u1', sessionPrefix: prefix); // u1 default
      f.registry.createSession('u2', 'solo', sessionPrefix: prefix);
      // u1 is unaffected by u2's session.
      expect(
        f.registry.resolveActive('u1', sessionPrefix: prefix).activeName,
        'default',
      );
      expect(
        f.registry.resolveActive('u2', sessionPrefix: prefix).activeName,
        'solo',
      );
    });
  });
}
