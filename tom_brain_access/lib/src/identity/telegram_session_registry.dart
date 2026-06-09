// TelegramSessionRegistry — per-Telegram-user session continuity and the four
// session slash-commands (access spec § 6.5).
//
// ── Why this exists ──────────────────────────────────────────────────
//
// An OpenAI client carries an `X-Tom-Session` header and so owns its session
// continuity explicitly (§ 21.9). Telegram has no such header — a Telegram
// user is a single long-lived chat — so the access layer keeps the session
// continuity *on the user's behalf*. This registry maps each Telegram user id
// to a small, persisted record: the name of the session they are currently in
// (`active`) and the ordered list of their sessions (each a `(name, id)` pair,
// with the synthetic `global` session — `id == null` — always first).
//
// ── How it fits the SessionManager ───────────────────────────────────
//
// The brain owns the session-id space (§ 7.2): the `SessionManager` re-mints
// any id it never minted. This registry mints ids on the user's behalf, so it
// is *inside* the brain — but it mints in the registry, not the manager. The
// [adoptSession] seam (`SessionManager.ensureSession`) bridges that: the
// registry registers every non-null id it hands out, so the manager treats
// them as known and their dedicated history accumulates. `global` (id `null`)
// is never adopted — it stamps `sessionId: null`, which the manager answers
// from the per-(principal, channel) global history.
//
// ── Persistence ──────────────────────────────────────────────────────
//
// Backed by the same `EdgeStateStore` seam as the edge limiters: a
// `JsonFileEdgeStateStore` under `config.edgeStateDirectory` (file
// `telegram_sessions.json`) when configured, an in-memory store otherwise.
// Loads on construction; saves the whole set on every mutation. So a user
// silently resumes their active session after a restart — the remembered id is
// re-adopted, not re-minted.
//
// ── "Invalid" means malformed, not forgotten ─────────────────────────
//
// A well-formed remembered id is never treated as invalid — it is re-adopted.
// "Invalid" is reserved for a stored id that no longer parses as a
// `TimestampId` (corruption, a hand-edit, a format change). [resolveActive]
// then mints a fresh id in place, persists, and returns a notice the edge
// sends to the user.

import 'package:tom_brain_shared/tom_brain_shared.dart' show TimestampId;

import '../edge_security/edge_state_store.dart';
import 'session_manager.dart' show SessionIdMinter;

/// The always-present, synthetic session every user can stay in. It maps to the
/// `SessionManager`'s per-(principal, channel) global history (§ 7.2), so it
/// carries no minted id (`id == null`) and is always listed first.
const String globalSessionName = 'global';

/// The session a user's very first contact silently creates and activates
/// (§ 6.5). A normal minted session — distinguished from [globalSessionName]
/// only by being the conventional starting point.
const String defaultSessionName = 'default';

/// The `EdgeStateStore` row key for the active session's name.
const String _activeRowKey = 'active';

/// The `EdgeStateStore` row key for the ordered session list.
const String _sessionsRowKey = 'sessions';

/// The per-session-entry key for its name.
const String _sessionNameKey = 'name';

/// The per-session-entry key for its minted id (`null` for `global`).
const String _sessionIdKey = 'id';

/// One of a user's sessions: a [name] and the brain-minted [id] it maps to
/// (`null` for the synthetic [globalSessionName]).
class _SessionRef {
  String name;
  String? id;
  _SessionRef(this.name, this.id);
}

/// One Telegram user's session state: the [active] session name and the ordered
/// [sessions] list (always led by `global`).
class _UserSessions {
  String active;
  final List<_SessionRef> sessions;
  _UserSessions({required this.active, required this.sessions});
}

/// The active session resolved for one inbound Telegram message (§ 6.5).
///
/// [sessionId] is the id to stamp onto the `InboundRequest` — `null` when the
/// user is in the `global` session (the manager then answers from the global
/// history). [notice], when non-null, is a message the edge sends the user
/// (the only case: a malformed stored id was recreated).
final class TelegramActiveSession {
  /// The id to stamp onto the outgoing `InboundRequest`, or `null` for the
  /// `global` session.
  final String? sessionId;

  /// The name of the active session (for diagnostics / logging).
  final String activeName;

  /// A user-facing notice to send before answering, or `null` when there is
  /// nothing to tell the user. Currently set only when a malformed stored id
  /// was recreated.
  final String? notice;

  /// Builds the resolved active-session result.
  const TelegramActiveSession({
    required this.sessionId,
    required this.activeName,
    this.notice,
  });
}

/// The four session slash-commands a Telegram user can send (§ 6.5).
enum TelegramSessionCommandKind {
  /// `/create_session <name>` — mint a new session and activate it.
  createSession,

  /// `/list_sessions` — list every session, three-digit-numbered.
  listSessions,

  /// `/pick_session <nnn>` — activate the session at a three-digit index.
  pickSession,

  /// `/rename_session <new name>` — rename the active session.
  renameSession,
}

/// A parsed session command: its [kind] and the trailing [argument]
/// (the session name, or the three-digit index; empty when the command takes
/// none or the user supplied none).
final class TelegramSessionCommand {
  /// Which of the four commands this is.
  final TelegramSessionCommandKind kind;

  /// The trailing argument text (trimmed), or `''` when absent.
  final String argument;

  /// Builds a parsed command.
  const TelegramSessionCommand({required this.kind, required this.argument});
}

/// Parses one Telegram message body into a [TelegramSessionCommand], or returns
/// `null` when the body is not one of the four session commands (an ordinary
/// prompt). Pure — no I/O, no state.
///
/// `/cmd@botname` is normalised to `/cmd` (Telegram appends the bot username to
/// commands in group chats). The match is case-insensitive on the command word.
TelegramSessionCommand? parseSessionCommand(String text) {
  final String trimmed = text.trim();
  if (!trimmed.startsWith('/')) return null;

  // Split the leading command word from the rest (the argument).
  final int firstSpace = trimmed.indexOf(RegExp(r'\s'));
  final String word =
      (firstSpace == -1 ? trimmed : trimmed.substring(0, firstSpace));
  final String argument =
      (firstSpace == -1 ? '' : trimmed.substring(firstSpace + 1)).trim();

  // Strip a `@botname` suffix and the leading slash, lower-case for matching.
  String command = word.substring(1);
  final int at = command.indexOf('@');
  if (at != -1) command = command.substring(0, at);
  command = command.toLowerCase();

  switch (command) {
    case 'create_session':
      return TelegramSessionCommand(
        kind: TelegramSessionCommandKind.createSession,
        argument: argument,
      );
    case 'list_sessions':
      return TelegramSessionCommand(
        kind: TelegramSessionCommandKind.listSessions,
        argument: argument,
      );
    case 'pick_session':
      return TelegramSessionCommand(
        kind: TelegramSessionCommandKind.pickSession,
        argument: argument,
      );
    case 'rename_session':
      return TelegramSessionCommand(
        kind: TelegramSessionCommandKind.renameSession,
        argument: argument,
      );
    default:
      return null;
  }
}

/// Maps each Telegram user id to its session continuity, persisting across
/// restarts and handling the four session commands (access spec § 6.5).
///
/// Construct one per running Telegram channel over an [EdgeStateStore]; it
/// loads on construction and saves on every mutation. The edge calls
/// [parseSessionCommand] to detect a command and dispatches to the matching
/// method (each returns the reply to send); for an ordinary prompt it calls
/// [resolveActive] to learn which session id to stamp.
final class TelegramSessionRegistry {
  final EdgeStateStore _store;
  final SessionIdMinter _mint;
  final void Function(String sessionId)? _adopt;

  /// In-memory view of every user's session state, keyed by Telegram user id.
  /// The authoritative copy lives in [_store]; this mirrors it and is rewritten
  /// to the store on every mutation.
  final Map<String, _UserSessions> _users = {};

  /// Builds the registry over [store].
  ///
  /// [mintSessionId] mints fresh session ids (default: a `TimestampId`
  /// generator, matching the `SessionManager`'s default minter so ids share one
  /// shape). [adoptSession] is the `SessionManager.ensureSession` seam — called
  /// for every non-null id the registry hands out so the manager adopts it as a
  /// known dedicated session (§ 7.2); `null` in tests that exercise the registry
  /// in isolation. Loads persisted state immediately.
  TelegramSessionRegistry({
    required EdgeStateStore store,
    SessionIdMinter? mintSessionId,
    void Function(String sessionId)? adoptSession,
  })  : _store = store,
        _mint = mintSessionId ?? (() => TimestampId.generate().value),
        _adopt = adoptSession {
    _load();
  }

  /// Resolves the active session for [userId] on an ordinary (non-command)
  /// message: the id to stamp onto the `InboundRequest` and any notice to send
  /// first (§ 6.5).
  ///
  /// First contact silently creates and activates a `default` session (no
  /// notice — the answer stays the only reply). A `global` active session
  /// resolves to `sessionId: null`. A malformed stored id is recreated in place
  /// and reported via the returned notice. Every non-null id handed out is
  /// adopted into the `SessionManager`.
  TelegramActiveSession resolveActive(String userId) {
    final _UserSessions user = _ensureUser(userId);

    final _SessionRef ref = _activeRef(user);
    if (ref.name == globalSessionName) {
      return const TelegramActiveSession(
        sessionId: null,
        activeName: globalSessionName,
      );
    }

    // A named session must carry a well-formed id. A missing or malformed one is
    // corruption: recreate it in place and tell the user.
    String? notice;
    final String? id = ref.id;
    if (id == null || !TimestampId.isValid(id)) {
      ref.id = _mint();
      _save();
      notice = 'Your session "${ref.name}" was invalid and has been recreated '
          'as ${ref.id}.';
    }

    _adopt?.call(ref.id!);
    return TelegramActiveSession(
      sessionId: ref.id,
      activeName: ref.name,
      notice: notice,
    );
  }

  /// Handles `/create_session <name>`: mints a new id, appends `(name, id)`, and
  /// activates it (§ 6.5). Returns the acknowledgement to send.
  String createSession(String userId, String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      return 'Usage: /create_session <name>';
    }
    if (trimmed == globalSessionName) {
      return 'The name "$globalSessionName" is reserved.';
    }
    final _UserSessions user = _ensureUser(userId);
    final String id = _mint();
    user.sessions.add(_SessionRef(trimmed, id));
    user.active = trimmed;
    _save();
    _adopt?.call(id);
    return 'New session $id named $trimmed created and is in use now';
  }

  /// Handles `/list_sessions`: lists every session three-digit-numbered from
  /// `000` (global is `000`), marking the active one (§ 6.5). Returns the list
  /// text to send.
  String listSessions(String userId) {
    final _UserSessions user = _ensureUser(userId);
    final StringBuffer buffer = StringBuffer('Sessions:');
    for (int i = 0; i < user.sessions.length; i++) {
      final _SessionRef ref = user.sessions[i];
      final String index = i.toString().padLeft(3, '0');
      final String marker = ref.name == user.active ? '*' : ' ';
      final String id = ref.id ?? '\u2014'; // em dash for global (no id).
      buffer.write('\n$index $marker ${ref.name}  $id');
    }
    return buffer.toString();
  }

  /// Handles `/pick_session <nnn>`: activates the session at the three-digit
  /// [index] (§ 6.5). Returns the acknowledgement, or an error when the index is
  /// out of range or not a three-digit number.
  String pickSession(String userId, String index) {
    final _UserSessions user = _ensureUser(userId);
    final int? n = int.tryParse(index.trim());
    if (n == null || n < 0 || n >= user.sessions.length) {
      return 'No session numbered "$index". Use /list_sessions to see them.';
    }
    final _SessionRef ref = user.sessions[n];
    user.active = ref.name;
    _save();
    if (ref.id != null) {
      _adopt?.call(ref.id!);
      return 'Now in session ${ref.name} (${ref.id})';
    }
    return 'Now in session ${ref.name}';
  }

  /// Handles `/rename_session <new name>`: renames the active session
  /// (§ 6.5). The `global` session cannot be renamed. Returns the
  /// acknowledgement or the refusal.
  String renameSession(String userId, String newName) {
    final String trimmed = newName.trim();
    if (trimmed.isEmpty) {
      return 'Usage: /rename_session <new name>';
    }
    if (trimmed == globalSessionName) {
      return 'The name "$globalSessionName" is reserved.';
    }
    final _UserSessions user = _ensureUser(userId);
    if (user.active == globalSessionName) {
      return 'The global session cannot be renamed.';
    }
    final _SessionRef ref = _activeRef(user);
    ref.name = trimmed;
    user.active = trimmed;
    _save();
    return 'Session renamed to $trimmed';
  }

  /// The active session reference for [user]. Falls back to `global` if the
  /// stored active name no longer matches any session (defensive — a save keeps
  /// them consistent).
  _SessionRef _activeRef(_UserSessions user) {
    for (final _SessionRef ref in user.sessions) {
      if (ref.name == user.active) return ref;
    }
    return user.sessions.first; // global is always first.
  }

  /// Returns [userId]'s state, creating the first-contact default set if absent
  /// (so a command before any prompt still has `global` + `default`).
  ///
  /// First contact mints a `default` session and **persists immediately** so the
  /// id survives a restart. The insert-then-`_save` order is load-bearing:
  /// `_save` serialises `_users`, so the new entry must be in the map before the
  /// save runs. (A `putIfAbsent` closure that saved inline persisted an empty set
  /// — the closure's value is only inserted *after* it returns — which silently
  /// dropped the minted id and re-minted it every restart.)
  _UserSessions _ensureUser(String userId) {
    final _UserSessions? existing = _users[userId];
    if (existing != null) return existing;
    final created = _UserSessions(
      active: defaultSessionName,
      sessions: [
        _SessionRef(globalSessionName, null),
        _SessionRef(defaultSessionName, _mint()),
      ],
    );
    _users[userId] = created;
    _save();
    return created;
  }

  /// Loads every user's state from [_store] into [_users]. A malformed row is
  /// surfaced by the store (it throws); a row missing fields is skipped (it is
  /// re-created on next contact) rather than crashing the channel.
  void _load() {
    final Map<String, Map<String, Object?>> rows = _store.load();
    rows.forEach((userId, row) {
      final Object? active = row[_activeRowKey];
      final Object? rawSessions = row[_sessionsRowKey];
      if (active is! String || rawSessions is! List) return;
      final List<_SessionRef> sessions = [];
      for (final Object? entry in rawSessions) {
        if (entry is! Map) continue;
        final Object? name = entry[_sessionNameKey];
        if (name is! String) continue;
        final Object? id = entry[_sessionIdKey];
        sessions.add(_SessionRef(name, id is String ? id : null));
      }
      if (sessions.isEmpty) return;
      _users[userId] = _UserSessions(active: active, sessions: sessions);
    });
  }

  /// Rewrites the whole user set to [_store]. Called on every mutation; the
  /// store writes atomically (§ 13.1).
  void _save() {
    final Map<String, Map<String, Object?>> rows = {
      for (final entry in _users.entries)
        entry.key: <String, Object?>{
          _activeRowKey: entry.value.active,
          _sessionsRowKey: [
            for (final _SessionRef ref in entry.value.sessions)
              <String, Object?>{
                _sessionNameKey: ref.name,
                _sessionIdKey: ref.id,
              },
          ],
        },
    };
    _store.save(rows);
  }
}
