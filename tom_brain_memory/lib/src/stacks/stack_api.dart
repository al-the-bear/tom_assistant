// StackApi — the dedicated CRUD surface for the system's mind state
// (memory_specification.md § 5.1).
//
// `TomBrainMemory.stacks` returns the live `StackApi` instance. The
// dispatcher consumes this directly; the MCP server exposes only
// `list` and `peek` (§ 3.2).
//
// At A.24 the API is declared but unimplemented. The atomicity of
// `push`/`pop`, the four priority policies, and the three retention
// policies all land at A.40 – A.45.
//
// `streamArchived` (A.42) is the read window over the demoted half
// of a stack. § 5.3 specifies that `bounded_n` overflow archives
// the lowest-priority entries (status flipped to `archived`,
// underlying node untouched), and that the archive "remains
// queryable via `streamArchived()`". The method is part of the
// abstract surface — anyone re-implementing `StackApi` (e.g. an
// in-memory test double, or a future isolate-bridged adapter)
// MUST provide it.

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show NodeId, StackEntryId;

import 'stack_types.dart';

/// Dedicated CRUD surface for the brain's stacks.
///
/// The six bootstrap stacks (`questions_open`, `automation_ideas`,
/// `interests`, `inflight`, `recent_runs`, `restructure_backlog`)
/// are created on first `open()` and cannot be deleted. Non-bootstrap
/// stacks may be created and removed by procedures.
abstract class StackApi {
  // Catalogue --------------------------------------------------------

  /// Returns a summary row per stack — names + sizes + top
  /// priority + bootstrap-flag.
  Future<List<StackSummary>> list();

  /// Returns detailed info for one stack, or `null` when no stack
  /// of that name exists.
  Future<StackInfo?> info(String name);

  /// Creates a non-bootstrap stack.
  ///
  /// Rejects (errors with `BootstrapStackImmutable`) when the name
  /// collides with a bootstrap stack.
  Future<void> create(StackDecl decl);

  /// Replaces the policy of an existing stack. Takes effect for
  /// subsequent `peek` / `pop` calls.
  Future<void> updatePolicy(String name, StackPolicy policy);

  /// Deletes a non-bootstrap stack outright — removes the catalogue
  /// row, the canonical `Stack` node, and every `stack_entries` row
  /// owned by it (active and archived). The underlying nodes that
  /// the entries referenced are left intact (spec § 5: stack
  /// membership is bookkeeping; deletion only erases the
  /// membership, not the contents).
  ///
  /// Refuses bootstrap names with `BootstrapStackImmutable`
  /// (spec § 5.4: the six reserved stacks are installed on first
  /// open and cannot be deleted). Refuses unknown names with
  /// `StackNotFound`.
  Future<void> delete(String name);

  // Entries ----------------------------------------------------------

  /// Atomically pushes [entry] onto [name] with [priority].
  ///
  /// `priority` is the *raw* priority (no decay applied here). The
  /// returned id can be used for later `update` / `remove`.
  Future<StackEntryId> push(
    String name,
    NodeId entry, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
  });

  /// Top-K read. Honours the stack's current priority policy.
  Future<List<StackEntry>> peek(String name, {int k = 16});

  /// Atomically pops the top entry. Returns `null` when the stack
  /// is empty. Concurrent peeks see the entry until it's popped.
  Future<StackEntry?> pop(String name);

  /// Updates priority / status / attrs of an existing entry.
  Future<void> update(
    String name,
    NodeId entry, {
    double? priority,
    StackEntryStatus? status,
    Map<String, Object?>? attrs,
  });

  /// Removes the entry's membership — the underlying node stays.
  Future<void> remove(String name, NodeId entry);

  // Archive read window ---------------------------------------------

  /// Yields the archived entries of [name] (`status = archived`),
  /// most recently archived first.
  ///
  /// Archival is produced exclusively by retention enforcement on
  /// [push] (`bounded_n` → lowest-priority entries; `bounded_age` →
  /// entries older than `maxAge`) and by explicit
  /// `update(..., status: archived)` calls. Demotion never deletes
  /// the underlying node (`memory_specification.md` § 5.3); this
  /// stream is the read path into that archive.
  ///
  /// [limit] caps the number of rows emitted. `null` = unlimited.
  /// The stream is finite (closes after the snapshot is drained);
  /// it is NOT a live feed of new archivals — for that, subscribe
  /// to [events] and filter on `StackEventKind.overflowDemoted`.
  ///
  /// Throws `StackNotFound` (synchronously, as the first stream
  /// event) when [name] is not a registered stack.
  Stream<StackEntry> streamArchived(String name, {int? limit});

  // Observability ----------------------------------------------------

  /// Lifecycle stream for [name]: push / pop / update /
  /// overflow-demotion events.
  Stream<StackEvent> events(String name);
}
