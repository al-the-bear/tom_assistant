// SessionTodoStores — the process-lifetime registry that keeps each
// conversation session's working [TodoStore] alive across the runs of that
// session (`tom_brain_procedure_specification.md` § 21.4).
//
// A `TodoStore` is loop scratch (never persisted to memory), but the user's
// working todo list must survive from one prompt to the next *within the same
// conversation*: it is session scratch, not run scratch. The engine builds a
// fresh `ToolContext` per run, so if each context defaulted to a fresh store the
// list would reset on every prompt — the brain would forget the plan it had
// just written down. This registry is the single process-lifetime owner: the
// engine asks it for the store bound to a run's session id, so every run of one
// session shares one list while different sessions stay isolated.
//
// A turn-less / internal / dream run carries no session id; the engine keeps the
// old run-scoped behaviour for those (a fresh store per run), so a background
// agent's scratch never leaks into — or out of — a user session. The registry
// therefore only ever holds the stores of real conversation sessions.
//
// The Telegram inspector surface (`/todos_list` / `/todos_clear`) reads and
// resets a session's list through this same registry — [peek] for the read,
// [clearSession] for the reset — so the user inspects exactly the list the next
// prompt will continue from.
//
// Durability across a restart is the persistent backend's job
// ([SessionTodoStores.persistentAt]). The user's working list must outlive a
// brain restart — a plan written down before a stop must still be there on the
// way back up — so the persistent registry rehydrates every session's list from
// a JSON file at construction and flushes the whole registry after every
// mutation (through each store's [TodoStore.onChanged] hook). This mirrors the
// brain-mode agent-SDK session store (`agent_sdk_sessions.json`): a tiny JSON
// map, written whole on each change, degrading to empty on a missing / corrupt
// file rather than failing the boot. The default [SessionTodoStores] keeps the
// old in-memory-only behaviour for tests and for a cognition booted without a
// durable memory root.

import 'dart:convert';
import 'dart:io';

import 'todo_store.dart';

/// A process-lifetime registry of per-session [TodoStore]s.
///
/// One instance is held by the engine for the whole process. [forSession]
/// returns the live store for a session id, creating it on first ask, so the
/// list persists across every run of that session. Different ids get different
/// stores; the same id always gets the same store.
///
/// The default constructor is in-memory only — a session's list is lost when the
/// process exits. [SessionTodoStores.persistentAt] backs the registry with a
/// JSON file so a session's list survives a restart.
final class SessionTodoStores {
  final Map<String, TodoStore> _bySession = <String, TodoStore>{};

  /// The on-disk JSON file backing this registry, or `null` for an in-memory
  /// registry that persists nothing.
  final File? _file;

  /// An in-memory registry that persists nothing. A session's list lives only
  /// for the process lifetime.
  SessionTodoStores() : _file = null;

  /// A registry whose session lists are persisted to [file] (JSON): rehydrated
  /// from disk at construction and flushed after every mutation, so a session's
  /// working todo list survives a process restart.
  ///
  /// A missing file reads as empty; a corrupt / unreadable file also degrades to
  /// empty rather than throwing, so a damaged store can only ever cost the saved
  /// lists, never crash the boot.
  SessionTodoStores.persistentAt(File file) : _file = file {
    _rehydrate();
  }

  /// The live [TodoStore] for [sessionId], created on first request.
  ///
  /// Returns the same instance for the same id on every call, so a todo added
  /// in one run of the session is visible in the next.
  TodoStore forSession(String sessionId) =>
      _bySession.putIfAbsent(sessionId, _newStore);

  /// Builds a fresh store, wiring its [TodoStore.onChanged] flush hook when this
  /// registry is persistent so every later mutation is written to disk.
  TodoStore _newStore() {
    final store = TodoStore();
    if (_file != null) store.onChanged = _persist;
    return store;
  }

  /// Loads every session's list from [_file] into the registry, attaching the
  /// flush hook to each rehydrated store. Degrades to an empty registry on a
  /// missing / corrupt / unreadable file.
  void _rehydrate() {
    final file = _file;
    if (file == null) return;
    try {
      if (!file.existsSync()) return;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        if (value is Map) {
          final store = TodoStore.fromJson(value.cast<String, Object?>());
          store.onChanged = _persist;
          _bySession['$key'] = store;
        }
      });
    } on FormatException {
      _bySession.clear();
    } on FileSystemException {
      _bySession.clear();
    }
  }

  /// Writes the whole registry to [_file]. A no-op for an in-memory registry.
  /// Best-effort: a failed flush leaves the in-memory lists correct for this
  /// process and only forgoes durability — it never breaks the run that wrote.
  void _persist() {
    final file = _file;
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(<String, Object?>{
        for (final entry in _bySession.entries) entry.key: entry.value.toJson(),
      }));
    } on FileSystemException {
      // Durability lost, run unaffected.
    }
  }

  /// The store for [sessionId] *without* creating one, or `null` when the
  /// session has none yet. The read-only peek the `/todos_list` command makes.
  TodoStore? peek(String sessionId) => _bySession[sessionId];

  /// Empties the session's list in place (the `/todos_clear` command's effect),
  /// preserving the store instance so an in-flight run holding it sees the
  /// cleared list. A no-op when the session has no store yet. Returns `true`
  /// when a store was present and cleared.
  bool clearSession(String sessionId) {
    final store = _bySession[sessionId];
    if (store == null) return false;
    store.clear();
    return true;
  }
}
