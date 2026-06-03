// SqliteStackApi — concrete `StackApi` backed by `memory.db`
// (Plan steps A.40 + A.42).
//
// What this file owns:
//
//   - The full CRUD surface declared by `StackApi`
//     (`memory_specification.md` § 5.1): list, info, create,
//     updatePolicy, push, peek, pop, update, remove,
//     streamArchived, events.
//   - Read-time priority ordering for all four policies
//     (`fifo`, `lifo`, `priority`, `timeDecayedPriority`). The
//     ordering lives in SQL (`ORDER BY` clause derived per policy)
//     and so naturally honours a policy change mid-life — the next
//     `peek` / `pop` sees the new ordering immediately, per spec
//     § 5.2. Property-test coverage of the pure ordering functions
//     lands at A.41.
//   - Push / pop atomicity. Pop reads + deletes inside a single
//     `BEGIN…COMMIT` so a concurrent peeker either sees the entry
//     or sees it gone — never a partially-consumed row.
//   - Retention enforcement (Plan A.42). All three policies from
//     spec § 5.3 are honoured on every `push`:
//       * `unbounded` — no-op.
//       * `bounded_n` — after the new row is inserted, the
//         lowest-priority active entries (per the current priority
//         policy, the inverse of the peek ordering) are flipped to
//         `archived` until the active count equals `maxCount`.
//         The just-pushed entry is itself a candidate: under FIFO
//         with `bounded_n`, the new push is the lowest-priority
//         entry (FIFO ranks oldest-first), so a push into a full
//         FIFO+bounded_n stack archives the just-inserted entry.
//         This is the spec's literal reading — § 5.3 says "lowest-
//         priority entries are demoted" without exempting fresh
//         arrivals.
//       * `bounded_age` — every active entry whose `pushed_at_ms`
//         is older than `at − maxAgeMs` (where `at` is the push
//         wall-clock) is archived. Sweep runs on every push so the
//         archive catches up incrementally; a stack that is never
//         pushed-to will accumulate stale active rows until the
//         next write touches it, which is acceptable — § 5.3
//         describes the behaviour as "entries older than maxAge
//         are archived" without committing to a continuous timer.
//     Demotion is **never** delete: the `nodes` row referenced by
//     the archived `StackEntry` is untouched. Each enforcement
//     pass emits one `StackOverflowDemoted` `MemoryEvent` carrying
//     every demoted id, plus one per-stack
//     `StackEvent(kind: overflowDemoted, demotedIds: [...])` so
//     observers see the batch as a single overflow.
//   - Policy-bundle validation. The four invalid combinations
//     enumerated in `StackPolicyConfigInvalidReason` are refused
//     at `create` and `updatePolicy`.
//   - Bootstrap-name guard. The six reserved names from spec § 5.4
//     are refused by `create` with [BootstrapStackImmutable]; the
//     *creation* of bootstrap stacks themselves on first open is
//     A.43's job (separate `installBootstrapStacks` path; not
//     called by this writer).
//   - Per-stack `Stream<StackEvent>` plumbing — one
//     `StreamController.broadcast` minted lazily on first
//     `events(name)` call, closed when the api is `close`d.
//   - `MemoryEvent` emission via a caller-supplied sink (mirrors
//     `NodePersister` / `EdgeWriter`). The two streams (per-stack
//     `StackEvent` + global `MemoryEvent`) are independent: a single
//     push emits one `StackPushed` always plus one
//     `StackOverflowDemoted` per enforcement pass that actually
//     archives at least one row.
//   - `streamArchived` — finite read window over `status='archived'`
//     ordered by `updated_at_ms DESC`. Not a live feed; consumers
//     wanting incremental archival events subscribe to [events]
//     and filter on `StackEventKind.overflowDemoted`.
//
// What this file does NOT own:
//
//   - Bootstrap stack auto-installation on first `open`. A.43.
//   - The canonical `Stack` node's full type-registry validation.
//     A.40 writes the `nodes` row directly with `type_name='Stack'`
//     so the api works without depending on bootstrap-node-type
//     loading having already happened. The full
//     `register → propose → persist` round-trip becomes available
//     once the higher-level `SqliteTomBrainMemory` exists.
//
// Layering:
//
//   - Takes a raw `sqlite3.Database` handle on `memory.db`. The
//     handle is owned by the store opener; SqliteStackApi does NOT
//     close it.
//   - The `now` and `idMint` injection mirrors `NodePersister` —
//     production uses defaults, tests override for determinism.
//   - The `eventSink` is optional; the higher-level store wires it
//     to the same `StreamController` that backs
//     `TomBrainMemory.events()`.

import 'dart:async';
import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart' show CloseGuard;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeId, StackEntryId;

import '../api/memory_event.dart';
import '../api/scope.dart';
import '../budget/write_budget_tracker.dart';
import '../cognitive_agents/agent_registry.dart';
import 'priority_policy.dart';
import 'stack_api.dart';
import 'stack_events.dart';
import 'stack_exception.dart';
import 'stack_types.dart';

/// The six reserved bootstrap stack names from
/// `memory_specification.md` § 5.4. `create` rejects these; the
/// per-name installation path lives in A.43.
const Set<String> bootstrapStackNames = <String>{
  'questions_open',
  'automation_ideas',
  'interests',
  'inflight',
  'recent_runs',
  'restructure_backlog',
};

/// Concrete `StackApi` backed by `memory.db` (Plan step A.40).
final class SqliteStackApi with CloseGuard implements StackApi {
  /// Live SQLite handle on `memory.db`. Owned by the store; the
  /// api does NOT close it.
  final Database _db;

  /// `StackEntryId` factory. Defaults to [StackEntryId.generate];
  /// tests override for determinism.
  final StackEntryId Function() _entryIdMint;

  /// `NodeId` factory used when minting the canonical `Stack`
  /// node alongside `create`. Defaults to [NodeId.generate]; tests
  /// override for determinism.
  final NodeId Function() _stackNodeIdMint;

  /// Wall-clock source for `created_at_*` / `updated_at_*`
  /// columns. Defaults to `DateTime.now`; tests override.
  final DateTime Function() _now;

  /// Optional sink for global `MemoryEvent`s.
  final void Function(MemoryEvent)? _eventSink;

  /// Optional `WriteBudget` enforcement (A.68; spec § 9.3). When
  /// non-null and `push` is called with a `Scope`, the push
  /// consumes one unit of the registered run's `maxStackEntries`.
  /// When null, pushes do not enforce a budget regardless of
  /// whether a `Scope` was supplied.
  final WriteBudgetTracker? _budgetTracker;

  /// Optional `AgentRegistry` scope enforcement (A.70; spec § 9.5).
  /// When non-null AND `scope.agentName` is non-null, the registry
  /// resolves the agent and enforces `writeScopes` against
  /// `"stack:<name>"`. When null, pushes do not enforce scopes.
  final AgentRegistry? _agentRegistry;

  /// Per-stack `StackEvent` broadcast controllers, minted lazily
  /// on first `events(name)` call.
  final Map<String, StreamController<StackEvent>> _eventStreams =
      <String, StreamController<StackEvent>>{};

  SqliteStackApi({
    required Database memoryDb,
    StackEntryId Function()? entryIdMint,
    NodeId Function()? stackNodeIdMint,
    DateTime Function()? now,
    void Function(MemoryEvent)? eventSink,
    WriteBudgetTracker? budgetTracker,
    AgentRegistry? agentRegistry,
  })  : _db = memoryDb,
        _entryIdMint = entryIdMint ?? StackEntryId.generate,
        _stackNodeIdMint = stackNodeIdMint ?? NodeId.generate,
        _now = now ?? DateTime.now,
        _eventSink = eventSink,
        _budgetTracker = budgetTracker,
        _agentRegistry = agentRegistry;

  /// Releases stream controllers. Called by the higher-level store
  /// during `close`. Does NOT close the underlying database handle.
  Future<void> close() async {
    if (!markClosed()) return;
    final controllers = _eventStreams.values.toList();
    _eventStreams.clear();
    for (final controller in controllers) {
      await controller.close();
    }
  }

  // ─── Catalogue ────────────────────────────────────────────────

  @override
  Future<List<StackSummary>> list() async {
    _assertOpen();
    final rows = _db.select(
      'SELECT s.name, s.is_bootstrap, '
      '  (SELECT COUNT(*) FROM stack_entries e '
      "    WHERE e.stack_name = s.name AND e.status = 'active'"
      '  ) AS size, '
      '  (SELECT IFNULL(MAX(e.priority), 0.0) FROM stack_entries e '
      "    WHERE e.stack_name = s.name AND e.status = 'active'"
      '  ) AS top_priority '
      'FROM stacks s '
      'ORDER BY s.name ASC',
    );
    return rows
        .map(
          (row) => StackSummary(
            name: row['name'] as String,
            size: (row['size'] as int),
            topPriority: (row['top_priority'] as num).toDouble(),
            bootstrap: (row['is_bootstrap'] as int) == 1,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<StackInfo?> info(String name) async {
    _assertOpen();
    final rows = _db.select(
      'SELECT s.name, s.entry_node_type, s.priority_policy, '
      '  s.priority_policy_attrs_json, s.retention_policy, '
      '  s.retention_policy_attrs_json, s.harvester_hook, '
      '  s.is_bootstrap, '
      '  (SELECT n.attrs_json FROM nodes n WHERE n.id = s.stack_node_id) '
      '    AS stack_node_attrs_json, '
      '  (SELECT COUNT(*) FROM stack_entries e '
      "    WHERE e.stack_name = s.name AND e.status = 'active'"
      '  ) AS size '
      'FROM stacks s WHERE s.name = ? LIMIT 1',
      <Object?>[name],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final policy = _policyFromRow(row);
    final summary = _summaryFromCanonicalNode(
      row['stack_node_attrs_json'] as String?,
    );
    return StackInfo(
      name: row['name'] as String,
      summary: summary,
      policy: policy,
      entryNodeType: row['entry_node_type'] as String,
      size: row['size'] as int,
      bootstrap: (row['is_bootstrap'] as int) == 1,
      harvesterHook: row['harvester_hook'] as String?,
    );
  }

  // ─── Mutation: create / updatePolicy ──────────────────────────

  @override
  Future<void> create(StackDecl decl) async {
    _assertOpen();
    if (bootstrapStackNames.contains(decl.name)) {
      throw BootstrapStackImmutable(
        stackName: decl.name,
        message:
            '"${decl.name}" is a reserved bootstrap stack name and '
            'cannot be created via StackApi.create. Bootstrap stacks '
            'are installed on first open (Plan step A.43).',
      );
    }
    _validatePolicy(decl.name, decl.policy);

    // Check existence — non-bootstrap collision is a separate
    // error from bootstrap collision.
    final existing = _db.select(
      'SELECT 1 FROM stacks WHERE name = ? LIMIT 1',
      <Object?>[decl.name],
    );
    if (existing.isNotEmpty) {
      throw StackAlreadyExists(
        stackName: decl.name,
        message:
            'a stack named "${decl.name}" already exists. Use '
            'updatePolicy to change its policy, or pick a different '
            'name.',
      );
    }

    final at = _now().toUtc();
    final atMs = at.millisecondsSinceEpoch;
    final atIso = at.toIso8601String();
    final stackNodeId = _stackNodeIdMint();
    final scopeJson = jsonEncode(
      <String, Object?>{'producer': 'memory:stacks.create'},
    );
    final attrsJson = jsonEncode(
      <String, Object?>{
        'name': decl.name,
        'summary': decl.summary,
      },
    );

    _db.execute('BEGIN');
    try {
      // 1. Canonical Stack node.
      _db.execute(
        'INSERT INTO nodes ('
        'id, type_name, scope_json, produced_by, attrs_json, status, '
        'created_at_ms, created_at_iso, updated_at_ms, updated_at_iso, '
        'idempotency_key, embedding_model_id'
        ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          stackNodeId.toString(),
          'Stack',
          scopeJson,
          'memory:stacks.create',
          attrsJson,
          'active',
          atMs,
          atIso,
          atMs,
          atIso,
          'stack:${decl.name}',
          null,
        ],
      );
      // 2. Catalogue row.
      _db.execute(
        'INSERT INTO stacks ('
        'name, stack_node_id, entry_node_type, '
        'priority_policy, priority_policy_attrs_json, '
        'retention_policy, retention_policy_attrs_json, '
        'harvester_hook, is_bootstrap, created_at_ms, created_at_iso'
        ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          decl.name,
          stackNodeId.toString(),
          decl.entryNodeType,
          decl.policy.priority.name,
          _priorityAttrsJson(decl.policy),
          decl.policy.retention.name,
          _retentionAttrsJson(decl.policy),
          decl.harvesterHook,
          0,
          atMs,
          atIso,
        ],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }

    _eventSink?.call(
      StackCreated(
        stackName: decl.name,
        stackNodeId: stackNodeId,
        entryNodeType: decl.entryNodeType,
        policy: decl.policy,
        bootstrap: false,
        occurredAt: at,
      ),
    );
  }

  @override
  Future<void> updatePolicy(String name, StackPolicy policy) async {
    _assertOpen();
    _validatePolicy(name, policy);

    final rows = _db.select(
      'SELECT 1 FROM stacks WHERE name = ? LIMIT 1',
      <Object?>[name],
    );
    if (rows.isEmpty) {
      throw StackNotFound(
        stackName: name,
        message:
            'updatePolicy: stack "$name" does not exist. Create it '
            'first via StackApi.create (or wait for A.43 bootstrap '
            'installation if this is a reserved name).',
      );
    }

    _db.execute(
      'UPDATE stacks SET '
      'priority_policy = ?, priority_policy_attrs_json = ?, '
      'retention_policy = ?, retention_policy_attrs_json = ? '
      'WHERE name = ?',
      <Object?>[
        policy.priority.name,
        _priorityAttrsJson(policy),
        policy.retention.name,
        _retentionAttrsJson(policy),
        name,
      ],
    );

    _eventSink?.call(
      StackPolicyChanged(
        stackName: name,
        policy: policy,
        occurredAt: _now().toUtc(),
      ),
    );
  }

  @override
  Future<void> delete(String name) async {
    _assertOpen();
    final rows = _db.select(
      'SELECT stack_node_id, is_bootstrap FROM stacks '
      'WHERE name = ? LIMIT 1',
      <Object?>[name],
    );
    if (rows.isEmpty) {
      throw StackNotFound(
        stackName: name,
        message:
            'delete: stack "$name" does not exist (already deleted, '
            'or never created).',
      );
    }
    final row = rows.first;
    final isBootstrap = (row['is_bootstrap'] as int) == 1;
    // Bootstrap immutability is checked via the catalogue flag
    // rather than the `bootstrapStackNames` constant so a future
    // operator-imported stack that mirrors a bootstrap name (via
    // direct SQL ingestion) is still protected by the same path.
    // The two should agree by construction — the installer is the
    // only writer of `is_bootstrap = 1`.
    if (isBootstrap) {
      throw BootstrapStackImmutable(
        stackName: name,
        message:
            '"$name" is a bootstrap stack and cannot be deleted '
            '(spec § 5.4). Bootstrap stacks are installed on first '
            'open and remain for the lifetime of the memory.',
      );
    }
    final stackNodeId = row['stack_node_id'] as String;
    _db.execute('BEGIN');
    try {
      _db.execute(
        'DELETE FROM stack_entries WHERE stack_name = ?',
        <Object?>[name],
      );
      _db.execute(
        'DELETE FROM stacks WHERE name = ?',
        <Object?>[name],
      );
      _db.execute(
        'DELETE FROM nodes WHERE id = ?',
        <Object?>[stackNodeId],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    // Close the per-stack event stream if one was minted — no one
    // should be subscribed to a deleted stack, and dangling
    // controllers would leak.
    final controller = _eventStreams.remove(name);
    if (controller != null) {
      await controller.close();
    }
  }

  // ─── Entries: push / peek / pop ───────────────────────────────

  @override
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    Scope? scope,
  }) async {
    _assertOpen();
    final stackRow = _selectStackRow(name);
    if (stackRow == null) {
      throw StackNotFound(
        stackName: name,
        message:
            'push: stack "$name" does not exist. Create it via '
            'StackApi.create first.',
      );
    }
    // Agent-scope enforcement (A.70; spec § 9.5). After the stack-
    // existence guard (a push to a missing stack fails structurally,
    // not as a scope violation) and *before* the budget charge so
    // a denied scope does not consume `maxStackEntries`. Pass-
    // through when no scope was supplied, no registry is wired,
    // or `scope.agentName` is null.
    if (scope != null) {
      _agentRegistry?.guardStackPush(
        agentName: scope.agentName,
        stackName: name,
      );
    }
    // WriteBudget enforcement (A.68; spec § 9.3). After the
    // stack-existence guard (a push at a missing stack does NOT
    // consume budget) and before the INSERT (a budget exception
    // leaves no row behind). Pass-through when no scope was
    // supplied, no tracker is wired, the scope has no runId, or the
    // run is unregistered.
    if (scope != null) {
      _budgetTracker?.chargeStackEntry(
        runId: scope.runId,
        producer: scope.producer,
      );
    }
    final id = _entryIdMint();
    final at = _now().toUtc();
    final atMs = at.millisecondsSinceEpoch;
    final atIso = at.toIso8601String();
    final effectiveAttrs = attrs ?? const <String, Object?>{};

    List<StackEntryId> demotedIds = const <StackEntryId>[];
    _db.execute('BEGIN');
    try {
      _db.execute(
        'INSERT INTO stack_entries ('
        'id, stack_name, entry_node, priority, status, attrs_json, '
        'pushed_at_ms, pushed_at_iso, updated_at_ms, updated_at_iso'
        ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          id.toString(),
          name,
          entry.toString(),
          priority,
          'active',
          effectiveAttrs.isEmpty ? null : jsonEncode(effectiveAttrs),
          atMs,
          atIso,
          atMs,
          atIso,
        ],
      );
      // Retention enforcement is part of the push transaction so a
      // concurrent peeker never sees `size > maxCount` between INSERT
      // and demotion (spec § 5.3).
      demotedIds = _enforceRetention(name, stackRow, at);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }

    final event = StackPushed(
      stackName: name,
      entryId: id,
      nodeId: entry,
      priority: priority,
      attrs: effectiveAttrs,
      occurredAt: at,
    );
    _eventSink?.call(event);
    _emitStackEvent(
      name,
      StackEvent(
        stackName: name,
        kind: StackEventKind.pushed,
        at: at,
        entryId: id,
      ),
    );

    if (demotedIds.isNotEmpty) {
      _eventSink?.call(
        StackOverflowDemoted(
          stackName: name,
          demotedIds: demotedIds,
          occurredAt: at,
        ),
      );
      _emitStackEvent(
        name,
        StackEvent(
          stackName: name,
          kind: StackEventKind.overflowDemoted,
          at: at,
          demotedIds: demotedIds,
        ),
      );
    }
    return id;
  }

  @override
  Future<List<StackEntry>> peek(String name, {int k = 16}) async {
    _assertOpen();
    if (k <= 0) return const <StackEntry>[];
    final stackRow = _selectStackRow(name);
    if (stackRow == null) {
      throw StackNotFound(
        stackName: name,
        message: 'peek: stack "$name" does not exist.',
      );
    }
    return _readTopActive(name, stackRow, k);
  }

  @override
  Future<StackEntry?> pop(String name) async {
    _assertOpen();
    final stackRow = _selectStackRow(name);
    if (stackRow == null) {
      throw StackNotFound(
        stackName: name,
        message: 'pop: stack "$name" does not exist.',
      );
    }

    StackEntry? popped;
    _db.execute('BEGIN');
    try {
      final top = _readTopActive(name, stackRow, 1);
      if (top.isEmpty) {
        _db.execute('COMMIT');
        return null;
      }
      final entry = top.single;
      _db.execute(
        'DELETE FROM stack_entries WHERE id = ?',
        <Object?>[entry.id.toString()],
      );
      _db.execute('COMMIT');
      popped = entry;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }

    final at = _now().toUtc();
    _eventSink?.call(
      StackPopped(
        stackName: name,
        entryId: popped.id,
        nodeId: popped.nodeId,
        occurredAt: at,
      ),
    );
    _emitStackEvent(
      name,
      StackEvent(
        stackName: name,
        kind: StackEventKind.popped,
        at: at,
        entryId: popped.id,
      ),
    );
    return popped;
  }

  @override
  Future<void> update(
    String name,
    NodeId entry, {
    double? priority,
    StackEntryStatus? status,
    Map<String, Object?>? attrs,
  }) async {
    _assertOpen();
    if (priority == null && status == null && attrs == null) {
      return;
    }
    final stackRow = _selectStackRow(name);
    if (stackRow == null) {
      throw StackNotFound(
        stackName: name,
        message: 'update: stack "$name" does not exist.',
      );
    }
    final rows = _db.select(
      'SELECT id FROM stack_entries '
      'WHERE stack_name = ? AND entry_node = ? '
      'ORDER BY pushed_at_ms DESC LIMIT 1',
      <Object?>[name, entry.toString()],
    );
    if (rows.isEmpty) {
      throw StackEntryNotFound(
        stackName: name,
        nodeIdString: entry.toString(),
        message:
            'update: no entry in "$name" references node '
            '${entry.toString()}.',
      );
    }
    final entryId = StackEntryId.fromString(rows.first['id'] as String);
    final at = _now().toUtc();
    final atMs = at.millisecondsSinceEpoch;
    final atIso = at.toIso8601String();

    final sets = <String>[];
    final args = <Object?>[];
    if (priority != null) {
      sets.add('priority = ?');
      args.add(priority);
    }
    if (status != null) {
      sets.add('status = ?');
      args.add(status.name);
    }
    if (attrs != null) {
      sets.add('attrs_json = ?');
      args.add(attrs.isEmpty ? null : jsonEncode(attrs));
    }
    sets.add('updated_at_ms = ?');
    args.add(atMs);
    sets.add('updated_at_iso = ?');
    args.add(atIso);
    args.add(entryId.toString());

    _db.execute(
      'UPDATE stack_entries SET ${sets.join(', ')} WHERE id = ?',
      args,
    );

    _eventSink?.call(
      StackEntryUpdated(
        stackName: name,
        entryId: entryId,
        priority: priority,
        status: status,
        attrsReplaced: attrs != null,
        occurredAt: at,
      ),
    );
    _emitStackEvent(
      name,
      StackEvent(
        stackName: name,
        kind: StackEventKind.updated,
        at: at,
        entryId: entryId,
      ),
    );
  }

  @override
  Future<void> remove(String name, NodeId entry) async {
    _assertOpen();
    final stackRow = _selectStackRow(name);
    if (stackRow == null) {
      throw StackNotFound(
        stackName: name,
        message: 'remove: stack "$name" does not exist.',
      );
    }
    final rows = _db.select(
      'SELECT id FROM stack_entries '
      'WHERE stack_name = ? AND entry_node = ?',
      <Object?>[name, entry.toString()],
    );
    if (rows.isEmpty) {
      throw StackEntryNotFound(
        stackName: name,
        nodeIdString: entry.toString(),
        message:
            'remove: no entry in "$name" references node '
            '${entry.toString()}.',
      );
    }
    final at = _now().toUtc();
    final removedIds = <StackEntryId>[];
    for (final row in rows) {
      final id = StackEntryId.fromString(row['id'] as String);
      _db.execute(
        'DELETE FROM stack_entries WHERE id = ?',
        <Object?>[id.toString()],
      );
      removedIds.add(id);
    }
    for (final id in removedIds) {
      _eventSink?.call(
        StackEntryRemoved(
          stackName: name,
          entryId: id,
          nodeId: entry,
          occurredAt: at,
        ),
      );
    }
  }

  // ─── Archive read window ──────────────────────────────────────

  @override
  Stream<StackEntry> streamArchived(String name, {int? limit}) async* {
    _assertOpen();
    final stackRow = _selectStackRow(name);
    if (stackRow == null) {
      throw StackNotFound(
        stackName: name,
        message: 'streamArchived: stack "$name" does not exist.',
      );
    }
    if (limit != null && limit <= 0) return;
    // Snapshot read — `streamArchived` is documented as a finite
    // window over the current archive, not a live feed. Yielding row
    // by row lets very large archives stream out without
    // materialising into a single allocation.
    final sql = StringBuffer(
      'SELECT id, stack_name, entry_node, priority, status, '
      'attrs_json, pushed_at_ms FROM stack_entries '
      "WHERE stack_name = ? AND status = 'archived' "
      'ORDER BY updated_at_ms DESC, id ASC',
    );
    final args = <Object?>[name];
    if (limit != null) {
      sql.write(' LIMIT ?');
      args.add(limit);
    }
    final rows = _db.select(sql.toString(), args);
    for (final row in rows) {
      yield _rowToEntry(row);
    }
  }

  // ─── Observability ────────────────────────────────────────────

  @override
  Stream<StackEvent> events(String name) {
    if (isClosed) {
      throw StateError(
        'SqliteStackApi.events: api is closed; cannot subscribe to '
        '"$name".',
      );
    }
    final controller = _eventStreams.putIfAbsent(
      name,
      () => StreamController<StackEvent>.broadcast(),
    );
    return controller.stream;
  }

  // ─── Internal helpers ─────────────────────────────────────────

  void _assertOpen() {
    if (isClosed) {
      throw StateError('SqliteStackApi: api is closed.');
    }
  }

  void _emitStackEvent(String name, StackEvent event) {
    final controller = _eventStreams[name];
    if (controller != null && controller.hasListener) {
      controller.add(event);
    }
  }

  Row? _selectStackRow(String name) {
    final rows = _db.select(
      'SELECT name, priority_policy, priority_policy_attrs_json, '
      'retention_policy, retention_policy_attrs_json '
      'FROM stacks WHERE name = ? LIMIT 1',
      <Object?>[name],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Reads the top [k] *active* entries ordered per the stack's
  /// current priority policy. Used by both `peek` and the
  /// transactional read-half of `pop`.
  ///
  /// Static policies (`fifo`, `lifo`, `priority`) push the
  /// ordering into SQL — those `ORDER BY` clauses match the
  /// pure-function comparators in `priority_policy.dart` 1:1.
  /// `timeDecayedPriority` cannot express `exp(-Δt / halflife)`
  /// in SQLite (no built-in `exp`), so the implementation fetches
  /// every active row and post-sorts with the shared
  /// `sortByPolicy` helper from the A.41 pure-function module.
  /// Bootstrap stacks are bounded (n ≤ 1000 per spec § 5.4); the
  /// full-set fetch is the simplest correct choice. A heuristic
  /// candidate window (raw priority is an upper bound on effective
  /// score, so a top-N pre-filter is safe) can replace it later
  /// if profiling demands it.
  List<StackEntry> _readTopActive(String name, Row stackRow, int k) {
    final policyName = stackRow['priority_policy'] as String;
    final priorityAttrs = _decodeAttrsJson(
      stackRow['priority_policy_attrs_json'] as String?,
    );

    if (policyName == PriorityPolicyKind.timeDecayedPriority.name) {
      return _readTimeDecayedTop(name, priorityAttrs, k);
    }

    final orderClause = _staticOrderClause(policyName);
    final rows = _db.select(
      'SELECT id, stack_name, entry_node, priority, status, '
      'attrs_json, pushed_at_ms '
      'FROM stack_entries '
      "WHERE stack_name = ? AND status = 'active' "
      '$orderClause '
      'LIMIT ?',
      <Object?>[name, k],
    );
    return rows.map(_rowToEntry).toList(growable: false);
  }

  /// Time-decayed top-K read. Fetches the full active set, applies
  /// the pure-function `sortByPolicy` evaluator (which implements
  /// `priority * exp(-Δt / halflife)` per spec § 5.2), then takes
  /// the top [k]. See `_readTopActive` for the bounded-stack
  /// rationale.
  List<StackEntry> _readTimeDecayedTop(
    String name,
    Map<String, Object?> priorityAttrs,
    int k,
  ) {
    final halflifeMs =
        (priorityAttrs['halflifeMs'] as num?)?.toInt();
    if (halflifeMs == null || halflifeMs <= 0) {
      // Bypassed `_validatePolicy`. Fall back to raw-priority
      // ordering so the read does not throw; the misconfiguration
      // surfaces via `info`.
      final orderClause =
          _staticOrderClause(PriorityPolicyKind.priority.name);
      final rows = _db.select(
        'SELECT id, stack_name, entry_node, priority, status, '
        'attrs_json, pushed_at_ms '
        'FROM stack_entries '
        "WHERE stack_name = ? AND status = 'active' "
        '$orderClause '
        'LIMIT ?',
        <Object?>[name, k],
      );
      return rows.map(_rowToEntry).toList(growable: false);
    }

    final rows = _db.select(
      'SELECT id, stack_name, entry_node, priority, status, '
      'attrs_json, pushed_at_ms '
      'FROM stack_entries '
      "WHERE stack_name = ? AND status = 'active'",
      <Object?>[name],
    );
    if (rows.isEmpty) return const <StackEntry>[];
    final entries = rows.map(_rowToEntry).toList();
    final policy = StackPolicy(
      priority: PriorityPolicyKind.timeDecayedPriority,
      // Retention is irrelevant for sort — `unbounded` is the
      // value-type-safe placeholder.
      retention: RetentionPolicyKind.unbounded,
      halflifeMs: halflifeMs,
    );
    final sorted = sortByPolicy(entries, policy, now: _now().toUtc());
    return sorted.take(k).toList(growable: false);
  }

  StackEntry _rowToEntry(Row row) {
    final attrsJson = row['attrs_json'] as String?;
    return StackEntry(
      id: StackEntryId.fromString(row['id'] as String),
      stackName: row['stack_name'] as String,
      nodeId: NodeId.fromString(row['entry_node'] as String),
      priority: (row['priority'] as num).toDouble(),
      pushedAt: DateTime.fromMillisecondsSinceEpoch(
        row['pushed_at_ms'] as int,
        isUtc: true,
      ),
      status: _statusFromName(row['status'] as String),
      attrs: attrsJson == null
          ? const <String, Object?>{}
          : Map<String, Object?>.from(jsonDecode(attrsJson) as Map),
    );
  }

  StackEntryStatus _statusFromName(String name) =>
      StackEntryStatus.values.firstWhere((s) => s.name == name);

  /// Returns the SQL `ORDER BY` clause for one of the three
  /// *static* policies (`fifo`, `lifo`, `priority`). These map
  /// directly to SQL because their comparators only reference
  /// per-row columns. `timeDecayedPriority` is handled in Dart by
  /// `_readTimeDecayedTop` — SQLite has no `exp()` so the
  /// continuous decay cannot be expressed as a single `ORDER BY`.
  /// The clauses here are an optimisation; the canonical ordering
  /// reference is `priority_policy.dart`.
  String _staticOrderClause(String policy) {
    switch (policy) {
      case 'fifo':
        return 'ORDER BY pushed_at_ms ASC, id ASC';
      case 'lifo':
        return 'ORDER BY pushed_at_ms DESC, id DESC';
      case 'priority':
        return 'ORDER BY priority DESC, pushed_at_ms ASC, id ASC';
      default:
        // Unknown policy — fall through to FIFO so the catalogue
        // is still queryable. A surprised operator gets ordered
        // results; the misconfiguration surfaces via `info`.
        return 'ORDER BY pushed_at_ms ASC, id ASC';
    }
  }

  StackPolicy _policyFromRow(Row row) {
    final priorityName = row['priority_policy'] as String;
    final retentionName = row['retention_policy'] as String;
    final priorityAttrs = _decodeAttrsJson(
      row['priority_policy_attrs_json'] as String?,
    );
    final retentionAttrs = _decodeAttrsJson(
      row['retention_policy_attrs_json'] as String?,
    );
    return StackPolicy(
      priority: PriorityPolicyKind.values
          .firstWhere((p) => p.name == priorityName),
      retention: RetentionPolicyKind.values
          .firstWhere((r) => r.name == retentionName),
      maxCount: (retentionAttrs['maxCount'] as num?)?.toInt(),
      maxAgeMs: (retentionAttrs['maxAgeMs'] as num?)?.toInt(),
      halflifeMs: (priorityAttrs['halflifeMs'] as num?)?.toInt(),
    );
  }

  String _summaryFromCanonicalNode(String? attrsJsonRaw) {
    if (attrsJsonRaw == null) return '';
    final attrs = jsonDecode(attrsJsonRaw) as Map<String, Object?>;
    return (attrs['summary'] as String?) ?? '';
  }

  Map<String, Object?> _decodeAttrsJson(String? raw) {
    if (raw == null || raw.isEmpty) return const <String, Object?>{};
    return Map<String, Object?>.from(jsonDecode(raw) as Map);
  }

  String? _priorityAttrsJson(StackPolicy policy) {
    if (policy.halflifeMs == null) return null;
    return jsonEncode(<String, Object?>{'halflifeMs': policy.halflifeMs});
  }

  String? _retentionAttrsJson(StackPolicy policy) {
    final out = <String, Object?>{};
    if (policy.maxCount != null) out['maxCount'] = policy.maxCount;
    if (policy.maxAgeMs != null) out['maxAgeMs'] = policy.maxAgeMs;
    return out.isEmpty ? null : jsonEncode(out);
  }

  /// Refuses a policy bundle that crosses the
  /// [StackPolicyConfigInvalidReason] axes.
  void _validatePolicy(String name, StackPolicy policy) {
    if (policy.retention == RetentionPolicyKind.boundedN &&
        (policy.maxCount == null || policy.maxCount! <= 0)) {
      throw StackPolicyConfigInvalid(
        stackName: name,
        reason:
            StackPolicyConfigInvalidReason.boundedNWithoutMaxCount,
        message:
            'policy on "$name": retention=boundedN requires a '
            'positive maxCount; got ${policy.maxCount}.',
      );
    }
    if (policy.retention == RetentionPolicyKind.boundedAge &&
        (policy.maxAgeMs == null || policy.maxAgeMs! <= 0)) {
      throw StackPolicyConfigInvalid(
        stackName: name,
        reason:
            StackPolicyConfigInvalidReason.boundedAgeWithoutMaxAgeMs,
        message:
            'policy on "$name": retention=boundedAge requires a '
            'positive maxAgeMs; got ${policy.maxAgeMs}.',
      );
    }
    if (policy.priority == PriorityPolicyKind.timeDecayedPriority &&
        (policy.halflifeMs == null || policy.halflifeMs! <= 0)) {
      throw StackPolicyConfigInvalid(
        stackName: name,
        reason: StackPolicyConfigInvalidReason
            .timeDecayedWithoutHalflifeMs,
        message:
            'policy on "$name": priority=timeDecayedPriority requires '
            'a positive halflifeMs; got ${policy.halflifeMs}.',
      );
    }
    if (policy.retention == RetentionPolicyKind.unbounded &&
        (policy.maxCount != null || policy.maxAgeMs != null)) {
      throw StackPolicyConfigInvalid(
        stackName: name,
        reason: StackPolicyConfigInvalidReason
            .unboundedWithBoundSupplied,
        message:
            'policy on "$name": retention=unbounded must not '
            'carry maxCount or maxAgeMs (got maxCount='
            '${policy.maxCount}, maxAgeMs=${policy.maxAgeMs}).',
      );
    }
    if (policy.priority != PriorityPolicyKind.timeDecayedPriority &&
        policy.halflifeMs != null) {
      throw StackPolicyConfigInvalid(
        stackName: name,
        reason: StackPolicyConfigInvalidReason
            .staticPriorityWithHalflifeSupplied,
        message:
            'policy on "$name": halflifeMs is only meaningful for '
            'priority=timeDecayedPriority; got priority='
            '${policy.priority.name}.',
      );
    }
  }

  // ─── Retention enforcement (Plan A.42) ────────────────────────
  //
  // Called from inside the `push` transaction after the new row is
  // INSERTed. Returns the list of entry ids that were flipped to
  // `archived` (in archival order — lowest-priority first for
  // `bounded_n`, oldest first for `bounded_age`). Demotion is a
  // status flip; the underlying `nodes` row is never touched.

  /// Top-level dispatcher. Branches on the stack's retention policy
  /// and delegates to the kind-specific helper.
  List<StackEntryId> _enforceRetention(
    String name,
    Row stackRow,
    DateTime at,
  ) {
    final retentionName = stackRow['retention_policy'] as String;
    if (retentionName == RetentionPolicyKind.unbounded.name) {
      return const <StackEntryId>[];
    }
    final retentionAttrs = _decodeAttrsJson(
      stackRow['retention_policy_attrs_json'] as String?,
    );
    if (retentionName == RetentionPolicyKind.boundedN.name) {
      final maxCount = (retentionAttrs['maxCount'] as num?)?.toInt();
      // `_validatePolicy` guarantees a positive maxCount on every
      // bounded_n stack; the defensive `<= 0` branch is for
      // belt-and-braces against future config corruption (a row
      // hand-edited outside the api would otherwise crash push).
      if (maxCount == null || maxCount <= 0) {
        return const <StackEntryId>[];
      }
      return _enforceBoundedN(name, stackRow, maxCount, at);
    }
    if (retentionName == RetentionPolicyKind.boundedAge.name) {
      final maxAgeMs = (retentionAttrs['maxAgeMs'] as num?)?.toInt();
      if (maxAgeMs == null || maxAgeMs <= 0) {
        return const <StackEntryId>[];
      }
      return _enforceBoundedAge(name, maxAgeMs, at);
    }
    // Unknown retention name — be conservative and do nothing rather
    // than crash the push. `info()` surfaces the misconfiguration to
    // operators.
    return const <StackEntryId>[];
  }

  /// `bounded_n`: count active rows; if over maxCount, archive the
  /// excess lowest-priority entries under the stack's priority
  /// policy.
  List<StackEntryId> _enforceBoundedN(
    String name,
    Row stackRow,
    int maxCount,
    DateTime at,
  ) {
    final countRow = _db.select(
      'SELECT COUNT(*) AS c FROM stack_entries '
      "WHERE stack_name = ? AND status = 'active'",
      <Object?>[name],
    ).first;
    final count = countRow['c'] as int;
    if (count <= maxCount) return const <StackEntryId>[];
    final excess = count - maxCount;
    final victims = _readBottomActive(name, stackRow, excess, at);
    if (victims.isEmpty) return const <StackEntryId>[];
    final ids = victims
        .map((e) => e.id)
        .toList(growable: false);
    _archiveEntries(ids, at);
    return ids;
  }

  /// `bounded_age`: archive every active entry whose `pushed_at_ms`
  /// is older than `at − maxAgeMs`. Sweep is per-push; the policy
  /// does not commit to a continuous timer.
  List<StackEntryId> _enforceBoundedAge(
    String name,
    int maxAgeMs,
    DateTime at,
  ) {
    final cutoffMs = at.millisecondsSinceEpoch - maxAgeMs;
    final rows = _db.select(
      'SELECT id FROM stack_entries '
      "WHERE stack_name = ? AND status = 'active' "
      'AND pushed_at_ms < ? '
      'ORDER BY pushed_at_ms ASC, id ASC',
      <Object?>[name, cutoffMs],
    );
    if (rows.isEmpty) return const <StackEntryId>[];
    final ids = rows
        .map((r) => StackEntryId.fromString(r['id'] as String))
        .toList(growable: false);
    _archiveEntries(ids, at);
    return ids;
  }

  /// Flips [ids] to `archived`, refreshing `updated_at_*` to [at].
  /// The id list determines `streamArchived` ordering — most
  /// recently archived first when sorted by `updated_at_ms DESC`.
  void _archiveEntries(List<StackEntryId> ids, DateTime at) {
    final atMs = at.millisecondsSinceEpoch;
    final atIso = at.toIso8601String();
    for (final id in ids) {
      _db.execute(
        "UPDATE stack_entries SET status = 'archived', "
        'updated_at_ms = ?, updated_at_iso = ? WHERE id = ?',
        <Object?>[atMs, atIso, id.toString()],
      );
    }
  }

  /// Bottom-[k] read — the inverse of `_readTopActive`. Used by
  /// `bounded_n` retention to find the entries that should be
  /// demoted first.
  ///
  /// Static policies (`fifo`, `lifo`, `priority`) push the inverted
  /// ordering into SQL. `timeDecayedPriority` fetches the full
  /// active set, sorts with the shared `sortByPolicy`, then takes
  /// the tail [k]. The bootstrap stacks are n ≤ 1000 (spec § 5.4);
  /// the full-set scan is acceptable for the bounded sizes we care
  /// about — same rationale as `_readTopActive`.
  List<StackEntry> _readBottomActive(
    String name,
    Row stackRow,
    int k,
    DateTime now,
  ) {
    if (k <= 0) return const <StackEntry>[];
    final policyName = stackRow['priority_policy'] as String;
    final priorityAttrs = _decodeAttrsJson(
      stackRow['priority_policy_attrs_json'] as String?,
    );

    if (policyName == PriorityPolicyKind.timeDecayedPriority.name) {
      return _readTimeDecayedBottom(name, priorityAttrs, k, now);
    }

    final orderClause = _staticBottomOrderClause(policyName);
    final rows = _db.select(
      'SELECT id, stack_name, entry_node, priority, status, '
      'attrs_json, pushed_at_ms '
      'FROM stack_entries '
      "WHERE stack_name = ? AND status = 'active' "
      '$orderClause '
      'LIMIT ?',
      <Object?>[name, k],
    );
    return rows.map(_rowToEntry).toList(growable: false);
  }

  /// Time-decayed bottom-[k] read. Sorts the full active set via
  /// the canonical `sortByPolicy` evaluator (so this stays in step
  /// with `_readTimeDecayedTop`), then reverses + takes [k]. The
  /// reversal yields lowest-effective-score first.
  List<StackEntry> _readTimeDecayedBottom(
    String name,
    Map<String, Object?> priorityAttrs,
    int k,
    DateTime now,
  ) {
    final halflifeMs = (priorityAttrs['halflifeMs'] as num?)?.toInt();
    if (halflifeMs == null || halflifeMs <= 0) {
      // Misconfigured — mirror `_readTimeDecayedTop`'s fallback by
      // ordering on raw priority ASC.
      final rows = _db.select(
        'SELECT id, stack_name, entry_node, priority, status, '
        'attrs_json, pushed_at_ms '
        'FROM stack_entries '
        "WHERE stack_name = ? AND status = 'active' "
        'ORDER BY priority ASC, pushed_at_ms DESC, id DESC '
        'LIMIT ?',
        <Object?>[name, k],
      );
      return rows.map(_rowToEntry).toList(growable: false);
    }
    final rows = _db.select(
      'SELECT id, stack_name, entry_node, priority, status, '
      'attrs_json, pushed_at_ms '
      'FROM stack_entries '
      "WHERE stack_name = ? AND status = 'active'",
      <Object?>[name],
    );
    if (rows.isEmpty) return const <StackEntry>[];
    final entries = rows.map(_rowToEntry).toList();
    final policy = StackPolicy(
      priority: PriorityPolicyKind.timeDecayedPriority,
      retention: RetentionPolicyKind.unbounded,
      halflifeMs: halflifeMs,
    );
    final sorted = sortByPolicy(entries, policy, now: now);
    // Tail of the sorted list = lowest scores. Reverse so the
    // returned list is in archival order (lowest score first).
    return sorted.reversed.take(k).toList(growable: false);
  }

  /// Inverted SQL `ORDER BY` clauses for the three static priority
  /// policies. Mirrors `_staticOrderClause` (top) — keep these two
  /// in sync; the bottom is the exact reversal of the top.
  String _staticBottomOrderClause(String policy) {
    switch (policy) {
      case 'fifo':
        // Top of FIFO = oldest first; bottom = newest first.
        return 'ORDER BY pushed_at_ms DESC, id DESC';
      case 'lifo':
        // Top of LIFO = newest first; bottom = oldest first.
        return 'ORDER BY pushed_at_ms ASC, id ASC';
      case 'priority':
        // Top = priority DESC, pushed_at ASC. Bottom = priority ASC,
        // pushed_at DESC (so within a tied-lowest priority the
        // newest goes first, matching the inverse of the peek order).
        return 'ORDER BY priority ASC, pushed_at_ms DESC, id DESC';
      default:
        return 'ORDER BY pushed_at_ms DESC, id DESC';
    }
  }
}
