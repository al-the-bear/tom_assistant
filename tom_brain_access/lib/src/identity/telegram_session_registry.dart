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
// (`active`) and the ordered list of their session **names** (the synthetic
// `global` session always first).
//
// ── The prefixed-id model (MSPP-37) ──────────────────────────────────
//
// Session ids are **not minted or stored** — they are *derived* per call from
// the chat's namespace: `effectiveSessionId(name) = sessionPrefix + name` for a
// named session, and `null` for `global` (the prefix-less escape hatch, D-8).
// The registry stores only the bare name; the chat's `sessionPrefix` is applied
// at resolve / render time, so one registry serves chats with different
// namespaces and a restart re-derives the SAME id with no minting. This is the
// session twin of the memory-profile model (MSPP-33).
//
// ── How it fits the SessionManager ───────────────────────────────────
//
// The brain owns the session-id space (§ 7.2): the `SessionManager` treats any
// id it was told about via [adoptSession] (`SessionManager.ensureSession`) as a
// known dedicated session. The registry adopts every non-null effective id it
// hands out, so the manager accumulates that session's dedicated history.
// `global` (effective id `null`) is never adopted — it stamps `sessionId: null`,
// which the manager answers from the per-(principal, channel) global history.
//
// ── Persistence ──────────────────────────────────────────────────────
//
// Backed by the same `EdgeStateStore` seam as the edge limiters: a
// `JsonFileEdgeStateStore` under `config.edgeStateDirectory` (file
// `telegram_sessions.json`) when configured, an in-memory store otherwise.
// Loads on construction; saves the whole set on every mutation. A legacy
// `[{name, id}]` row forward-migrates to bare names on load (MSPP-39): the
// minted id is dropped and the effective id re-derives from the bare name.

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show isValidMemoryProfileName;

import '../edge_security/edge_state_store.dart';

/// The always-present, synthetic session every user can stay in. It maps to the
/// `SessionManager`'s per-(principal, channel) global history (§ 7.2), so it
/// carries no id (effective id `null`, D-8) and is always listed first.
const String globalSessionName = 'global';

/// The session a user's very first contact silently creates and activates
/// (§ 6.5). A normal named session — distinguished from [globalSessionName]
/// only by being the conventional starting point.
const String defaultSessionName = 'default';

/// The memory-profile selector a user's first contact starts on (§ 9.2). Stored
/// **bare** (no prefix): the chat's `memoryPrefix` is applied at stamp / render
/// time, so the same registry serves chats with different namespaces (MSPP-33).
/// Combined with the default `defaultmemory_` prefix it yields
/// `defaultmemory_default` — the profile a brand-new chat resolves to (MSP-4),
/// which the engine routes to the boot default store.
const String defaultMemoryName = 'default';

/// The `EdgeStateStore` row key for the active session's name.
const String _activeRowKey = 'active';

/// The `EdgeStateStore` row key for the ordered session-name list.
const String _sessionsRowKey = 'sessions';

/// The per-session-entry key for a legacy `[{name, id}]` row's name — read only
/// while forward-migrating an old row to bare names (MSPP-39).
const String _legacySessionNameKey = 'name';

/// The `EdgeStateStore` row key for the per-user memory-recall trace toggle
/// (the `/trace_memory` command). Absent / non-`true` means tracing is off.
const String _traceMemoryRowKey = 'traceMemory';

/// The `EdgeStateStore` row key for the active memory profile's **bare** name
/// (the `/switch_memory` / `/create_memory` selection). Absent ⇒
/// [defaultMemoryName].
const String _activeMemoryRowKey = 'activeMemory';

/// The `EdgeStateStore` row key for the ordered list of the user's **bare**
/// memory-profile names. Absent ⇒ `[defaultMemoryName]`.
const String _memoriesRowKey = 'memories';

/// One Telegram user's session state: the [active] session name, the ordered
/// [sessions] list of **bare names** (always led by `global`), the
/// [traceMemory] toggle (the `/trace_memory` command), and the memory-profile
/// selection — [activeMemory] (the bare active profile name) over the ordered
/// [memories] list of bare names (§ 9.2). Both session and memory names are
/// stored bare; the chat's prefix is applied at resolve / render time
/// (MSPP-37 / MSPP-33).
class _UserSessions {
  String active;
  final List<String> sessions;
  bool traceMemory;
  String activeMemory;
  final List<String> memories;
  _UserSessions({
    required this.active,
    required this.sessions,
    this.traceMemory = false,
    this.activeMemory = defaultMemoryName,
    List<String>? memories,
  }) : memories = memories ?? <String>[defaultMemoryName];
}

/// The active session resolved for one inbound Telegram message (§ 6.5).
///
/// [sessionId] is the id to stamp onto the `InboundRequest` — `null` when the
/// user is in the `global` session (the manager then answers from the global
/// history).
final class TelegramActiveSession {
  /// The id to stamp onto the outgoing `InboundRequest`, or `null` for the
  /// `global` session.
  final String? sessionId;

  /// The name of the active session (for diagnostics / logging).
  final String activeName;

  /// Builds the resolved active-session result.
  const TelegramActiveSession({
    required this.sessionId,
    required this.activeName,
  });
}

/// Maps each Telegram user id to its session continuity, persisting across
/// restarts and handling the four session commands (access spec § 6.5).
///
/// Construct one per running Telegram channel over an [EdgeStateStore]; it
/// loads on construction and saves on every mutation. The edge parses the
/// shared Telegram command vocabulary (`parseTelegramCommand`) to detect a
/// command and dispatches the four session kinds to the matching method here
/// (each returns the reply to send); for an ordinary prompt it calls
/// [resolveActive] to learn which session id to stamp. The chat's
/// `sessionPrefix` is passed in per call so the effective id is always derived,
/// never stored (MSPP-37).
final class TelegramSessionRegistry {
  final EdgeStateStore _store;
  final void Function(String sessionId)? _adopt;

  /// In-memory view of every user's session state, keyed by Telegram user id.
  /// The authoritative copy lives in [_store]; this mirrors it and is rewritten
  /// to the store on every mutation.
  final Map<String, _UserSessions> _users = {};

  /// Builds the registry over [store].
  ///
  /// [adoptSession] is the `SessionManager.ensureSession` seam — called for
  /// every non-null effective id the registry hands out so the manager adopts
  /// it as a known dedicated session (§ 7.2); `null` in tests that exercise the
  /// registry in isolation. Loads persisted state immediately.
  TelegramSessionRegistry({
    required EdgeStateStore store,
    void Function(String sessionId)? adoptSession,
  })  : _store = store,
        _adopt = adoptSession {
    _load();
  }

  /// The effective session id for [name] under [sessionPrefix]: `null` for the
  /// `global` session (the prefix-less escape hatch, D-8), `sessionPrefix +
  /// name` for any named session (MSPP-37).
  String? _effectiveSessionId(String name, String sessionPrefix) =>
      name == globalSessionName ? null : sessionPrefix + name;

  /// Resolves the active session for [userId] on an ordinary (non-command)
  /// message: the id to stamp onto the `InboundRequest` (§ 6.5).
  ///
  /// First contact silently creates and activates a `default` session (the
  /// answer stays the only reply). A `global` active session resolves to
  /// `sessionId: null`. Every non-null effective id is adopted into the
  /// `SessionManager`. The effective id is derived from the bare name and
  /// [sessionPrefix] — never minted or stored (MSPP-37).
  TelegramActiveSession resolveActive(
    String userId, {
    required String sessionPrefix,
  }) {
    final _UserSessions user = _ensureUser(userId);
    final String name = _activeName(user);
    final String? id = _effectiveSessionId(name, sessionPrefix);
    if (id != null) _adopt?.call(id);
    return TelegramActiveSession(sessionId: id, activeName: name);
  }

  /// Handles `/create_session <name>`: registers the bare [name], activates it,
  /// and acknowledges with its effective id (`sessionPrefix + name`) (§ 6.5).
  ///
  /// A name carrying the prefix delimiter (`_`) or a path separator would
  /// address an id outside the chat's scope and is rejected (MSP-6). A name
  /// already in the list is not duplicated — it is simply re-activated.
  String createSession(
    String userId,
    String name, {
    required String sessionPrefix,
  }) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      return 'Usage: /create_session <name>';
    }
    if (trimmed == globalSessionName) {
      return 'The name "$globalSessionName" is reserved.';
    }
    if (!_isValidScopedName(trimmed)) {
      return 'Invalid session name "$trimmed": use a name with no "_" or path '
          'separators.';
    }
    final _UserSessions user = _ensureUser(userId);
    if (!user.sessions.contains(trimmed)) {
      user.sessions.add(trimmed);
    }
    user.active = trimmed;
    _save();
    final String id = sessionPrefix + trimmed;
    _adopt?.call(id);
    return 'New session $id named $trimmed created and is in use now';
  }

  /// Handles `/list_sessions`: lists every session three-digit-numbered from
  /// `000` (global is `000`), marking the active one and showing each line's
  /// effective id (§ 6.5). Returns the list text to send.
  String listSessions(String userId, {required String sessionPrefix}) {
    final _UserSessions user = _ensureUser(userId);
    final StringBuffer buffer = StringBuffer('Sessions:');
    for (int i = 0; i < user.sessions.length; i++) {
      final String name = user.sessions[i];
      final String index = i.toString().padLeft(3, '0');
      final String marker = name == user.active ? '*' : ' ';
      final String id =
          _effectiveSessionId(name, sessionPrefix) ?? '\u2014'; // em dash.
      buffer.write('\n$index $marker $name  $id');
    }
    return buffer.toString();
  }

  /// Handles `/pick_session <nnn>`: activates the session at the three-digit
  /// [index] (§ 6.5). Returns the acknowledgement, or an error when the index is
  /// out of range or not a three-digit number.
  String pickSession(
    String userId,
    String index, {
    required String sessionPrefix,
  }) {
    final _UserSessions user = _ensureUser(userId);
    final int? n = int.tryParse(index.trim());
    if (n == null || n < 0 || n >= user.sessions.length) {
      return 'No session numbered "$index". Use /list_sessions to see them.';
    }
    final String name = user.sessions[n];
    user.active = name;
    _save();
    final String? id = _effectiveSessionId(name, sessionPrefix);
    if (id != null) {
      _adopt?.call(id);
      return 'Now in session $name ($id)';
    }
    return 'Now in session $name';
  }

  /// Handles `/rename_session <new name>`: renames the active session
  /// (§ 6.5). The `global` session cannot be renamed. Returns the
  /// acknowledgement or the refusal.
  String renameSession(
    String userId,
    String newName, {
    required String sessionPrefix,
  }) {
    final String trimmed = newName.trim();
    if (trimmed.isEmpty) {
      return 'Usage: /rename_session <new name>';
    }
    if (trimmed == globalSessionName) {
      return 'The name "$globalSessionName" is reserved.';
    }
    if (!_isValidScopedName(trimmed)) {
      return 'Invalid session name "$trimmed": use a name with no "_" or path '
          'separators.';
    }
    final _UserSessions user = _ensureUser(userId);
    if (user.active == globalSessionName) {
      return 'The global session cannot be renamed.';
    }
    final int idx = user.sessions.indexOf(user.active);
    if (idx >= 0) user.sessions[idx] = trimmed;
    user.active = trimmed;
    _save();
    return 'Session renamed to $trimmed';
  }

  /// Whether [userId] currently has memory-recall tracing on (the
  /// `/trace_memory` toggle, § 6.5). The edge reads this before admitting an
  /// ordinary prompt and stamps the trace flag onto the request when it is on.
  bool isTraceMemoryEnabled(String userId) => _ensureUser(userId).traceMemory;

  /// Handles `/trace_memory`: flips [userId]'s memory-recall trace toggle,
  /// persists it, and returns the confirmation stating the resulting state.
  String toggleTraceMemory(String userId) {
    final _UserSessions user = _ensureUser(userId);
    user.traceMemory = !user.traceMemory;
    _save();
    return user.traceMemory
        ? 'Memory tracing is now ON — each memory search will report what it '
            'found.'
        : 'Memory tracing is now OFF.';
  }

  /// Resolves the prefixed active memory profile for [userId] on an ordinary
  /// (non-command) message: `memoryPrefix + <active bare name>` (§ 9.2, MSP-4).
  ///
  /// The edge passes the chat's [memoryPrefix]; the registry stores only the
  /// bare name, so the same active selection resolves under whatever namespace
  /// the chat is configured with (MSPP-33). First contact starts on
  /// [defaultMemoryName], so a brand-new chat resolves to
  /// `<memoryPrefix>default` (the default prefix yields `defaultmemory_default`,
  /// which the engine routes to the boot default store).
  String resolveActiveMemory(String userId, {required String memoryPrefix}) =>
      memoryPrefix + _ensureUser(userId).activeMemory;

  /// Handles `/create_memory <name>`: registers the bare profile [name], makes
  /// it the active memory, and switches to it (§ 9.2). Returns the
  /// acknowledgement naming the prefixed profile id (`memoryPrefix + name`).
  ///
  /// The store materialises on first write (Option B / MSPP-24), so the access
  /// layer only records the name — it never opens the database. A name carrying
  /// the prefix delimiter (`_`) or a path separator would address a raw global
  /// id and is rejected (MSP-6 / path-traversal guard). A name already in the
  /// list is not duplicated — it is simply re-activated.
  String createMemory(
    String userId,
    String name, {
    required String memoryPrefix,
  }) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      return 'Usage: /create_memory <name>';
    }
    if (!_isValidScopedName(trimmed)) {
      return 'Invalid memory name "$trimmed": use a name with no "_" or path '
          'separators.';
    }
    final _UserSessions user = _ensureUser(userId);
    if (!user.memories.contains(trimmed)) {
      user.memories.add(trimmed);
    }
    user.activeMemory = trimmed;
    _save();
    return 'New memory $memoryPrefix$trimmed named $trimmed created and is in '
        'use now';
  }

  /// Handles `/list_memory`: lists the chat's memory profiles three-digit-
  /// numbered from `000`, marking the active one (§ 9.2). Each line shows the
  /// bare name and the prefixed profile id it resolves to. Returns the list text.
  ///
  /// Every listed name is in-scope by construction — the registry stores only
  /// bare names and renders each as `memoryPrefix + name`, so the list can never
  /// surface a profile outside the chat's prefix (MSP-6).
  String listMemory(String userId, {required String memoryPrefix}) {
    final _UserSessions user = _ensureUser(userId);
    final StringBuffer buffer = StringBuffer('Memories:');
    for (int i = 0; i < user.memories.length; i++) {
      final String name = user.memories[i];
      final String index = i.toString().padLeft(3, '0');
      final String marker = name == user.activeMemory ? '*' : ' ';
      buffer.write('\n$index $marker $name  $memoryPrefix$name');
    }
    return buffer.toString();
  }

  /// Handles `/switch_memory <nnn|name>`: sets the chat's active memory profile
  /// to the indexed or named profile *within the prefix scope* (§ 9.2). Returns
  /// the acknowledgement, or an error for an out-of-range index, an unknown
  /// name, or an out-of-scope argument.
  ///
  /// A numeric argument is a three-digit index into the prefix-scoped list
  /// (mirroring `/pick_session`). A non-numeric argument is a bare selector: a
  /// name carrying the prefix delimiter (`_`) or a path separator would address
  /// a raw global id and is rejected (MSP-6); a well-formed name not yet created
  /// is rejected too (use `/create_memory` to make it).
  String switchMemory(
    String userId,
    String argument, {
    required String memoryPrefix,
  }) {
    final String trimmed = argument.trim();
    if (trimmed.isEmpty) {
      return 'Usage: /switch_memory <nnn|name>';
    }
    final _UserSessions user = _ensureUser(userId);

    // Numeric: a three-digit index into the prefix-scoped list.
    final int? n = int.tryParse(trimmed);
    if (n != null) {
      if (n < 0 || n >= user.memories.length) {
        return 'No memory numbered "$trimmed". Use /list_memory to see them.';
      }
      user.activeMemory = user.memories[n];
      _save();
      return 'Now using memory ${user.activeMemory} '
          '($memoryPrefix${user.activeMemory})';
    }

    // Named: a bare selector within the chat's scope. A name carrying the prefix
    // delimiter or a path separator would address a raw global id — reject it.
    if (!_isValidScopedName(trimmed)) {
      return 'Out-of-scope memory "$trimmed": a memory name has no "_" or path '
          'separators.';
    }
    if (!user.memories.contains(trimmed)) {
      return 'No memory named "$trimmed". Use /list_memory to see them, or '
          '/create_memory to make it.';
    }
    user.activeMemory = trimmed;
    _save();
    return 'Now using memory $trimmed ($memoryPrefix$trimmed)';
  }

  /// Whether [name] is a valid **bare** scoped selector for a session or memory
  /// profile: free of the prefix delimiter (`_`) and path-safe (no separators,
  /// not `.`/`..`). A bare name combines with the chat's prefix to a
  /// `_`-delimited id, so a name containing `_` would let a command address an
  /// id outside its prefix scope (MSP-6); [isValidMemoryProfileName] guards the
  /// filesystem path the name ultimately maps onto.
  bool _isValidScopedName(String name) =>
      !name.contains('_') && isValidMemoryProfileName(name);

  /// The active session name for [user]. Falls back to `global` if the stored
  /// active name no longer matches any session (defensive — a save keeps them
  /// consistent).
  String _activeName(_UserSessions user) {
    if (user.sessions.contains(user.active)) return user.active;
    return user.sessions.first; // global is always first.
  }

  /// Returns [userId]'s state, creating the first-contact default set if absent
  /// (so a command before any prompt still has `global` + `default`).
  ///
  /// The insert-then-`_save` order is load-bearing: `_save` serialises
  /// `_users`, so the new entry must be in the map before the save runs. (A
  /// `putIfAbsent` closure that saved inline persisted an empty set — the
  /// closure's value is only inserted *after* it returns.)
  _UserSessions _ensureUser(String userId) {
    final _UserSessions? existing = _users[userId];
    if (existing != null) return existing;
    final created = _UserSessions(
      active: defaultSessionName,
      sessions: [globalSessionName, defaultSessionName],
    );
    _users[userId] = created;
    _save();
    return created;
  }

  /// Loads every user's state from [_store] into [_users]. A malformed row is
  /// surfaced by the store (it throws); a row missing fields is skipped (it is
  /// re-created on next contact) rather than crashing the channel.
  ///
  /// Both the bare-name shape (`[name, ...]`) and the legacy `[{name, id}]`
  /// shape are read: a legacy row's minted id is dropped and the bare name kept
  /// (MSPP-39), so the effective id re-derives deterministically from the name.
  void _load() {
    final Map<String, Map<String, Object?>> rows = _store.load();
    rows.forEach((userId, row) {
      final Object? active = row[_activeRowKey];
      final Object? rawSessions = row[_sessionsRowKey];
      if (active is! String || rawSessions is! List) return;
      final List<String> sessions = [];
      for (final Object? entry in rawSessions) {
        if (entry is String) {
          sessions.add(entry);
        } else if (entry is Map) {
          // Legacy `[{name, id}]` row: keep the name, drop the minted id.
          final Object? name = entry[_legacySessionNameKey];
          if (name is String) sessions.add(name);
        }
      }
      if (sessions.isEmpty) return;
      // `global` must be present and first.
      sessions.remove(globalSessionName);
      sessions.insert(0, globalSessionName);
      // The active name must be a known session (a hand-edit could drop it).
      final String activeName =
          sessions.contains(active) ? active : globalSessionName;

      // Memory selection (§ 9.2): bare active name + bare list. A row written
      // before memory support is missing both — fall back to the first-contact
      // default (`default` active over `[default]`) so older state migrates in
      // place (MSPP-34).
      final Object? rawActiveMemory = row[_activeMemoryRowKey];
      final String activeMemory =
          rawActiveMemory is String && rawActiveMemory.isNotEmpty
              ? rawActiveMemory
              : defaultMemoryName;
      final Object? rawMemories = row[_memoriesRowKey];
      final List<String> memories = [
        if (rawMemories is List)
          for (final Object? name in rawMemories)
            if (name is String) name,
      ];
      if (memories.isEmpty) memories.add(defaultMemoryName);
      // The active name must be in the list (a hand-edit could drop it).
      if (!memories.contains(activeMemory)) memories.add(activeMemory);

      _users[userId] = _UserSessions(
        active: activeName,
        sessions: sessions,
        traceMemory: row[_traceMemoryRowKey] == true,
        activeMemory: activeMemory,
        memories: memories,
      );
    });
  }

  /// Rewrites the whole user set to [_store]. Called on every mutation; the
  /// store writes atomically (§ 13.1). Sessions persist as a bare-name list.
  void _save() {
    final Map<String, Map<String, Object?>> rows = {
      for (final entry in _users.entries)
        entry.key: <String, Object?>{
          _activeRowKey: entry.value.active,
          _traceMemoryRowKey: entry.value.traceMemory,
          _activeMemoryRowKey: entry.value.activeMemory,
          _memoriesRowKey: <Object?>[...entry.value.memories],
          _sessionsRowKey: <Object?>[...entry.value.sessions],
        },
    };
    _store.save(rows);
  }
}
