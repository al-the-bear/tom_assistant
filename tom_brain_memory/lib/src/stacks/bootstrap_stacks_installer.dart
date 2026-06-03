// BootstrapStacksInstaller — installs the six reserved stacks on
// first `Memory.open()` (Plan step A.43, spec § 5.4).
//
// What this file owns:
//
//   - The canonical `BootstrapStackSpec` list — six rows mapping
//     directly to the spec § 5.4 table (`questions_open`,
//     `automation_ideas`, `interests`, `inflight`, `recent_runs`,
//     `restructure_backlog`). One source of truth; the wildcard
//     `entryNodeType: '*'` is the in-code marker for the spec's
//     "(any)" cell on `restructure_backlog`.
//   - `installBootstrapStacks(db, ...)` — the idempotent installer.
//     Per spec: stacks are created on first `open()`, and the call
//     is a no-op on subsequent opens. Implementation: each stack is
//     checked individually so a partially-installed catalogue (e.g.
//     a crash mid-install in a prior run, or a future schema change
//     that adds new bootstrap rows) self-heals on next call.
//
// Why a separate file instead of folding into `SqliteStackApi`:
//
//   - `SqliteStackApi.create` *rejects* bootstrap names by design
//     (those names are immutable from any caller-driven path). The
//     installer is the *single privileged path* that mints them.
//     Putting it on the same class would mean either weakening the
//     rejection or exposing a "create-via-back-door" method that
//     blurs the contract. A free function on its own file keeps
//     the rejection rule strict and the privileged path obvious.
//   - The installer needs to write `is_bootstrap = 1` rows; the
//     normal `create` writes `is_bootstrap = 0`. One code path
//     per `is_bootstrap` value is clearer than a flag-shaped
//     branch inside `create`.
//
// Why direct SQL instead of going through `SqliteStackApi.create`:
//
//   - `create` would reject the names (correctly). The installer
//     mirrors create's INSERT pattern but commits with
//     `is_bootstrap = 1` and a distinct `produced_by` provenance
//     so reads downstream can distinguish bootstrap-minted Stack
//     nodes from caller-created ones.
//
// Layering:
//
//   - Takes a raw `sqlite3.Database` handle on `memory.db`. The
//     handle is owned by the store opener; the installer does not
//     close it.
//   - `now` and `stackNodeIdMint` injection mirrors
//     `SqliteStackApi`. Tests override for determinism.
//   - The optional `eventSink` receives one `StackCreated` event
//     per *newly* installed stack (no event for idempotent skips,
//     so an operator subscribed to the global event stream sees
//     "install happened" only the first time).

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;

import '../api/memory_event.dart';
import '../observability/memory_log.dart';
import '../store/transaction_support.dart';
import 'sqlite_stack_api.dart' show bootstrapStackNames;
import 'stack_events.dart';
import 'stack_types.dart';

/// Wildcard sentinel for the `entryNodeType` field on stacks that
/// accept any node type (the spec § 5.4 "(any)" cell on
/// `restructure_backlog`).
///
/// Push-time type enforcement against this marker is a no-op — any
/// node type is accepted. Symbolic so callers can branch on it
/// without string-magic at the call site.
const String stackEntryNodeTypeAny = '*';

/// Declarative spec of one bootstrap stack, used by
/// [installBootstrapStacks] to mint a row when absent.
///
/// One instance per row in spec § 5.4. The `summary` text appears
/// on the canonical `Stack` node so operators reading the brain
/// inspector see a human-meaningful explanation alongside the
/// machine-readable name.
final class BootstrapStackSpec {
  /// Stack name (the reserved identifier).
  final String name;

  /// One-line summary kept on the underlying `Stack` node.
  final String summary;

  /// Node type push accepts. [stackEntryNodeTypeAny] for
  /// `restructure_backlog`.
  final String entryNodeType;

  /// Policy bundle as committed.
  final StackPolicy policy;

  const BootstrapStackSpec({
    required this.name,
    required this.summary,
    required this.entryNodeType,
    required this.policy,
  });
}

/// 30 days in milliseconds — halflife for `automation_ideas`.
const int _halflife30dMs = 30 * 24 * 60 * 60 * 1000;

/// 14 days in milliseconds — halflife for `interests`.
const int _halflife14dMs = 14 * 24 * 60 * 60 * 1000;

/// The canonical bootstrap stack table from
/// `memory_specification.md` § 5.4. Order is preserved when the
/// installer commits, so the resulting `StackApi.list()` (sorted
/// alphabetically) is deterministic.
///
/// Any change to this list must be matched in the spec table; both
/// sides reference each other.
const List<BootstrapStackSpec> bootstrapStackSpecs = <BootstrapStackSpec>[
  // 1. `questions_open` — open inquiries the brain pulls from when
  //    self-directed work needs a target. Priority on raw priority
  //    score, never bounded (the brain decides what to drop via
  //    `Pruner`, not via stack overflow).
  BootstrapStackSpec(
    name: 'questions_open',
    summary: 'Open questions for the brain to investigate (spec § 5.4).',
    entryNodeType: 'Question',
    policy: StackPolicy(
      priority: PriorityPolicyKind.priority,
      retention: RetentionPolicyKind.unbounded,
    ),
  ),

  // 2. `automation_ideas` — candidate procedures to author. Decay
  //    by 30 days so a long-stale idea naturally settles to the
  //    bottom; cap at 1000 so the operator UI stays bounded.
  BootstrapStackSpec(
    name: 'automation_ideas',
    summary:
        'Candidate procedures the brain may author (decay 30d, cap 1000).',
    entryNodeType: 'AutomationIdea',
    policy: StackPolicy(
      priority: PriorityPolicyKind.timeDecayedPriority,
      retention: RetentionPolicyKind.boundedN,
      maxCount: 1000,
      halflifeMs: _halflife30dMs,
    ),
  ),

  // 3. `interests` — topics the brain is curious about. Shorter
  //    14-day decay reflects "interest" being more volatile than
  //    "automation idea"; cap at 500.
  BootstrapStackSpec(
    name: 'interests',
    summary:
        'Topics the brain is curious about (decay 14d, cap 500).',
    entryNodeType: 'InterestItem',
    policy: StackPolicy(
      priority: PriorityPolicyKind.timeDecayedPriority,
      retention: RetentionPolicyKind.boundedN,
      maxCount: 500,
      halflifeMs: _halflife14dMs,
    ),
  ),

  // 4. `inflight` — runs currently being executed. FIFO so the
  //    operator UI surfaces oldest-not-yet-finished first; cap at
  //    64 (small because the dispatcher only allows a bounded
  //    concurrency level).
  BootstrapStackSpec(
    name: 'inflight',
    summary:
        'Procedure runs currently being executed (FIFO, cap 64).',
    entryNodeType: 'ProcedureRun',
    policy: StackPolicy(
      priority: PriorityPolicyKind.fifo,
      retention: RetentionPolicyKind.boundedN,
      maxCount: 64,
    ),
  ),

  // 5. `recent_runs` — the just-completed-runs feed. LIFO so the
  //    UI shows newest-first; cap at 512 (small archive that
  //    rolls forward).
  BootstrapStackSpec(
    name: 'recent_runs',
    summary: 'Most recent procedure runs (LIFO, cap 512).',
    entryNodeType: 'ProcedureRun',
    policy: StackPolicy(
      priority: PriorityPolicyKind.lifo,
      retention: RetentionPolicyKind.boundedN,
      maxCount: 512,
    ),
  ),

  // 6. `restructure_backlog` — accepts any node type
  //    (`(any)` in the spec table → wildcard sentinel here). FIFO,
  //    unbounded — the dream cycles drain it.
  BootstrapStackSpec(
    name: 'restructure_backlog',
    summary:
        'Nodes flagged for restructuring by the dream cycles '
        '(FIFO, unbounded).',
    entryNodeType: stackEntryNodeTypeAny,
    policy: StackPolicy(
      priority: PriorityPolicyKind.fifo,
      retention: RetentionPolicyKind.unbounded,
    ),
  ),
];

/// Compile-time guard: the installer's spec list and the
/// `sqlite_stack_api.dart` rejection set must always agree on the
/// six reserved names. If anyone adds a row to one without the
/// other, this assertion trips on first use.
///
/// Implemented as a top-level `final` rather than a `const` because
/// `Set` equality is not const-evaluable.
final bool _bootstrapNameSetsAgree = () {
  final declared = bootstrapStackSpecs.map((s) => s.name).toSet();
  if (declared.length != bootstrapStackSpecs.length) {
    throw StateError(
      'bootstrapStackSpecs has duplicate names: $declared',
    );
  }
  if (declared.difference(bootstrapStackNames).isNotEmpty ||
      bootstrapStackNames.difference(declared).isNotEmpty) {
    throw StateError(
      'bootstrap stack name lists disagree. Specs declare: '
      '$declared. Rejection set has: $bootstrapStackNames. '
      'Both must reference the same six names.',
    );
  }
  return true;
}();

/// Report from [installBootstrapStacks] — which stacks were
/// newly minted and which were skipped because they were already
/// present from a prior open.
final class BootstrapInstallReport {
  /// Names minted by this call (in [bootstrapStackSpecs] order).
  /// Empty list on a second open of the same memory root.
  final List<String> installed;

  /// Names already present at call time (skipped). On a first
  /// open against a fresh DB this is empty; on a second open it
  /// contains all six names.
  final List<String> skipped;

  const BootstrapInstallReport({
    required this.installed,
    required this.skipped,
  });

  /// `true` iff the installer was a no-op (every name was already
  /// present).
  bool get wasNoOp => installed.isEmpty;

  /// `true` iff this was a from-scratch install of all six rows.
  bool get wasFreshInstall => skipped.isEmpty && installed.length == 6;
}

/// Installs the six bootstrap stacks against [db].
///
/// Idempotent: each name is checked individually before insert,
/// so the installer is safe to call on every `open()`. The first
/// call against a fresh DB inserts all six; subsequent calls are
/// no-ops.
///
/// Each newly-inserted row commits two records inside one
/// transaction:
///
///   1. A `nodes` row of `type_name = 'Stack'`, with
///      `produced_by = 'memory:stacks.bootstrap'` and
///      `idempotency_key = 'stack:<name>'`. The idempotency key
///      makes the node insert itself replay-safe via the
///      `uniq_nodes_idempotency_key` partial index — a crash
///      between the `nodes` insert and the `stacks` insert leaves
///      the node behind, and a re-run reuses it rather than
///      doubling up.
///   2. A `stacks` catalogue row with `is_bootstrap = 1`. The
///      flag is what the future delete path checks against to raise
///      `BootstrapStackImmutable` (see [SqliteStackApi.delete]).
///
/// [eventSink], if supplied, receives one [StackCreated] event per
/// newly inserted stack (with `bootstrap: true`). No event fires
/// for skipped names — observers see the install pattern only on
/// the first open.
///
/// [stackNodeIdMint] / [now] mirror the corresponding constructor
/// args on `SqliteStackApi` and exist for test determinism.
BootstrapInstallReport installBootstrapStacks(
  Database db, {
  NodeId Function()? stackNodeIdMint,
  DateTime Function()? now,
  void Function(MemoryEvent)? eventSink,
}) {
  // The assertion is referenced here so the Dart tree-shaker keeps
  // it; without a touchpoint the top-level `final` could be
  // dropped from a `dart compile` output (unlikely for test-mode
  // runs but the cost is zero).
  assert(_bootstrapNameSetsAgree);

  final mintNode = stackNodeIdMint ?? NodeId.generate;
  final clock = now ?? DateTime.now;

  final installed = <String>[];
  final skipped = <String>[];

  // Each spec gets its own transaction. Per-spec atomicity keeps
  // a single corrupt row from blocking the rest of the install.
  for (final spec in bootstrapStackSpecs) {
    final existing = db.select(
      'SELECT 1 FROM stacks WHERE name = ? LIMIT 1',
      <Object?>[spec.name],
    );
    if (existing.isNotEmpty) {
      skipped.add(spec.name);
      continue;
    }

    final at = clock().toUtc();
    final atMs = at.millisecondsSinceEpoch;
    final atIso = at.toIso8601String();
    final stackNodeId = mintNode();
    final scopeJson = jsonEncode(
      <String, Object?>{'producer': 'memory:stacks.bootstrap'},
    );
    final attrsJson = jsonEncode(
      <String, Object?>{
        'name': spec.name,
        'summary': spec.summary,
      },
    );

    db.execute('BEGIN');
    try {
      db.execute(
        'INSERT INTO nodes ('
        'id, type_name, scope_json, produced_by, attrs_json, status, '
        'created_at_ms, created_at_iso, updated_at_ms, updated_at_iso, '
        'idempotency_key, embedding_model_id'
        ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          stackNodeId.toString(),
          'Stack',
          scopeJson,
          'memory:stacks.bootstrap',
          attrsJson,
          'active',
          atMs,
          atIso,
          atMs,
          atIso,
          'stack:${spec.name}',
          null,
        ],
      );
      db.execute(
        'INSERT INTO stacks ('
        'name, stack_node_id, entry_node_type, '
        'priority_policy, priority_policy_attrs_json, '
        'retention_policy, retention_policy_attrs_json, '
        'harvester_hook, is_bootstrap, created_at_ms, created_at_iso'
        ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          spec.name,
          stackNodeId.toString(),
          spec.entryNodeType,
          spec.policy.priority.name,
          spec.policy.priorityAttrsJson(),
          spec.policy.retention.name,
          spec.policy.retentionAttrsJson(),
          null, // harvesterHook — none at bootstrap time.
          1, // is_bootstrap
          atMs,
          atIso,
        ],
      );
      db.execute('COMMIT');
    } catch (error, stack) {
      rollbackQuietly(db);
      Error.throwWithStackTrace(error, stack);
    }

    eventSink?.call(
      StackCreated(
        stackName: spec.name,
        stackNodeId: stackNodeId,
        entryNodeType: spec.entryNodeType,
        policy: spec.policy,
        bootstrap: true,
        occurredAt: at,
      ),
    );
    installed.add(spec.name);
  }

  // A.84 — one status line per call. `status` is visible even at the
  // `silent` level, so an operator always sees the install summary
  // on first open without having to enable debug logging.
  if (installed.isEmpty) {
    MemoryLog.stacks.debug(
      'bootstrap stacks: nothing to install '
      '(all ${skipped.length} already present)',
    );
  } else {
    MemoryLog.stacks.status(
      'installed ${installed.length} bootstrap stack(s): '
      '${installed.join(", ")}'
      '${skipped.isEmpty ? "" : " (skipped ${skipped.length} existing)"}',
    );
  }

  return BootstrapInstallReport(installed: installed, skipped: skipped);
}
