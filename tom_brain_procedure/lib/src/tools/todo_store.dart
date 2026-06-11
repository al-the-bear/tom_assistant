// TodoStore — the in-process, run/session-scoped scratch list the `todo.*`
// tools route through
// (`tom_brain_procedure_specification.md` § 21.4).
//
// The four `todo.*` tools are the one basic-tool family that touches no
// existing primitive: they manage an ephemeral working list the scripted LLM
// loop can keep its own bookkeeping in. It is deliberately *not* persisted to
// memory — a todo is loop scratch, not a memory node. The store hangs off the
// `ToolContext` (built once per run); the tools stay stateless descriptors that
// read `ctx.todos` (PE-1).
//
// What the store is *scoped to* is the engine's decision, not the store's: for
// a user turn the engine binds the run's `ToolContext.todos` to the
// conversation session's persistent store ([SessionTodoStores], so the working
// list survives from one prompt to the next within a conversation); for a
// turn-less / internal / dream run it binds a fresh per-run store. Either way
// the store stays a plain in-memory list — never written to memory.

/// One entry in a [TodoStore].
///
/// [id] is stable for the entry's lifetime; [text] and [done] are mutable so
/// `todo.update` can edit an entry in place.
final class TodoEntry {
  /// Builds an entry with a stable [id] and initial [text] / [done].
  TodoEntry({required this.id, required this.text, this.done = false});

  /// The stable, store-assigned id (`todo.update` / `todo.remove` key).
  final String id;

  /// The entry's text. Mutable: `todo.update` may replace it.
  String text;

  /// Whether the entry is done. Mutable: `todo.update` may toggle it.
  bool done;

  /// The JSON-serialisable view a `todo.*` tool returns.
  Map<String, Object?> toMap() =>
      <String, Object?>{'id': id, 'text': text, 'done': done};
}

/// An ordered, in-process todo list scoped to one run (§ 21.4).
///
/// Append-ordered: [list] returns entries in insertion order so the loop sees
/// a stable view. Ephemeral — discarded with the [ToolContext] at run end, and
/// never written to memory.
final class TodoStore {
  final List<TodoEntry> _entries = <TodoEntry>[];
  int _sequence = 0;

  /// Appends a new entry carrying [text] and returns its assigned id.
  String add(String text) {
    final id = 't${++_sequence}';
    _entries.add(TodoEntry(id: id, text: text));
    return id;
  }

  /// The entries in insertion order. The returned list is a snapshot — the
  /// entries themselves are the live objects (`todo.update` edits in place).
  List<TodoEntry> list() => List<TodoEntry>.unmodifiable(_entries);

  /// Updates the entry under [id], setting [text] and/or [done] when supplied.
  ///
  /// Returns `true` when an entry matched, `false` when [id] is unknown.
  bool update(String id, {String? text, bool? done}) {
    final entry = _find(id);
    if (entry == null) return false;
    if (text != null) entry.text = text;
    if (done != null) entry.done = done;
    return true;
  }

  /// Removes the entry under [id]. Returns `true` when one was removed.
  bool remove(String id) {
    final before = _entries.length;
    _entries.removeWhere((e) => e.id == id);
    return _entries.length != before;
  }

  /// Removes every entry, resetting the list to empty (the `/todos_clear`
  /// command's effect). The id sequence is preserved, so a later [add] never
  /// reuses an id a cleared entry held. Editing in place — an in-flight run
  /// holding this store sees the cleared list.
  void clear() => _entries.clear();

  TodoEntry? _find(String id) {
    for (final entry in _entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }
}
