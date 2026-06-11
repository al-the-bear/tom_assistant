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

import 'todo_store.dart';

/// A process-lifetime registry of per-session [TodoStore]s.
///
/// One instance is held by the engine for the whole process. [forSession]
/// returns the live store for a session id, creating it on first ask, so the
/// list persists across every run of that session. Different ids get different
/// stores; the same id always gets the same store.
final class SessionTodoStores {
  final Map<String, TodoStore> _bySession = <String, TodoStore>{};

  /// The live [TodoStore] for [sessionId], created on first request.
  ///
  /// Returns the same instance for the same id on every call, so a todo added
  /// in one run of the session is visible in the next.
  TodoStore forSession(String sessionId) =>
      _bySession.putIfAbsent(sessionId, TodoStore.new);

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
