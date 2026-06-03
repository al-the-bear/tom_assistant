// Pure-function priority-policy evaluators (Plan step A.41).
//
// The four `PriorityPolicyKind` variants from
// `memory_specification.md` § 5.2 expressed as deterministic,
// side-effect-free functions over `StackEntry` lists. This is the
// authoritative ordering reference; the SQL `ORDER BY` clauses
// inside `SqliteStackApi._readTopActive` are an *optimisation* for
// the three static policies that map cleanly to SQL, and the
// time-decayed policy delegates to the Dart-side post-sort in
// this file (SQLite has no built-in `exp`).
//
// The ordering contract for every policy is:
//
//   1. Primary key — the policy-specific ordering value.
//   2. Tie-break  — insertion time ascending (oldest first).
//   3. Final tie-break — entry id lexicographically ascending so
//      the sort is *stable* across runs even when two entries
//      share both primary key and pushed-at timestamp (which is
//      possible because `pushedAt` is wall-clock-millisecond
//      resolution and the test suite mints multiple entries inside
//      one millisecond on purpose).
//
// Why "raw priority, decay-at-read":
//
// `StackEntry.priority` is documented as the *raw* per-entry score
// (see `stack_types.dart`). For `timeDecayedPriority` we compute
//
//   effective = raw * exp(-(now.ms - pushedAt.ms) / halflifeMs)
//
// at read time. The spec's wording is `exp(-Δt / halflife)` —
// **not** the physics-style `exp(-ln 2 · Δt / halflife)`. We
// implement the spec literally; an entry whose Δt equals the
// halflife is worth `1/e ≈ 0.368` of its raw priority, not `0.5`.
// If anyone wants the physics convention later they can swap
// `halflifeMs` for `halflifeMs / ln(2)` in the config without
// touching this file.
//
// Why the helpers are top-level instead of static-on-an-enum:
//
// `PriorityPolicyKind` is a plain value enum exposed across the
// MCP surface and the operator UI; keeping the comparator logic
// out of the enum keeps the enum a pure data declaration the
// consumers can serialise without dragging the implementation in.

import 'dart:math' as math;

import 'package:tom_brain_shared/tom_brain_shared.dart' show PriorityPolicyKind, StackEntry, StackPolicy;

/// Sorts [entries] according to [policy] and returns a new list.
///
/// The input is not mutated. The returned list is independent —
/// the caller may sort, slice, or mutate it freely.
///
/// [now] is the read-time clock used by `timeDecayedPriority`.
/// It is ignored by `fifo`, `lifo`, and `priority`. Defaults to
/// `DateTime.now().toUtc()` so the function is callable without a
/// clock when the caller does not care about decay (e.g. when the
/// policy is statically known to be static-priority).
List<StackEntry> sortByPolicy(
  Iterable<StackEntry> entries,
  StackPolicy policy, {
  DateTime? now,
}) {
  final clock = now ?? DateTime.now().toUtc();
  final list = entries.toList();
  list.sort((a, b) => comparePolicy(a, b, policy, now: clock));
  return list;
}

/// Pair-wise comparator implementing [policy].
///
/// Returns a negative number when [a] should come before [b], a
/// positive number when [a] should come after [b], and zero only
/// when the two entries are indistinguishable along every axis
/// (primary key + pushed-at + id).
int comparePolicy(
  StackEntry a,
  StackEntry b,
  StackPolicy policy, {
  DateTime? now,
}) {
  switch (policy.priority) {
    case PriorityPolicyKind.fifo:
      return _compareFifo(a, b);
    case PriorityPolicyKind.lifo:
      return _compareLifo(a, b);
    case PriorityPolicyKind.priority:
      return _comparePriority(a, b);
    case PriorityPolicyKind.timeDecayedPriority:
      final clock = now ?? DateTime.now().toUtc();
      final halflifeMs = policy.halflifeMs;
      if (halflifeMs == null || halflifeMs <= 0) {
        // The policy validator at `SqliteStackApi._validatePolicy`
        // refuses this combination at `create`/`updatePolicy` time,
        // so reaching this branch implies a caller bypassed the
        // validator. Falling back to raw `priority` ordering keeps
        // the comparator total instead of throwing inside `sort`.
        return _comparePriority(a, b);
      }
      return _compareTimeDecayed(a, b, halflifeMs, clock);
  }
}

/// Effective priority of [e] under [policy] at clock [now].
///
/// For static policies this is simply `e.priority`. For
/// `timeDecayedPriority` it applies the `exp(-Δt / halflife)`
/// envelope. Exposed so observability surfaces (operator UI,
/// `peek` debug overlays) can display the same number the
/// comparator uses.
double effectivePriority(
  StackEntry e,
  StackPolicy policy,
  DateTime now,
) {
  if (policy.priority != PriorityPolicyKind.timeDecayedPriority) {
    return e.priority;
  }
  final halflifeMs = policy.halflifeMs;
  if (halflifeMs == null || halflifeMs <= 0) {
    return e.priority;
  }
  return _decayedScore(e, halflifeMs, now);
}

// ─── Per-policy comparators ──────────────────────────────────────

int _compareFifo(StackEntry a, StackEntry b) {
  final byTime = a.pushedAt.compareTo(b.pushedAt);
  if (byTime != 0) return byTime;
  return _compareIdAscending(a, b);
}

int _compareLifo(StackEntry a, StackEntry b) {
  final byTime = b.pushedAt.compareTo(a.pushedAt);
  if (byTime != 0) return byTime;
  return _compareIdDescending(a, b);
}

int _comparePriority(StackEntry a, StackEntry b) {
  // Descending on raw priority.
  final byPriority = b.priority.compareTo(a.priority);
  if (byPriority != 0) return byPriority;
  // Older first when priorities tie.
  final byTime = a.pushedAt.compareTo(b.pushedAt);
  if (byTime != 0) return byTime;
  return _compareIdAscending(a, b);
}

int _compareTimeDecayed(
  StackEntry a,
  StackEntry b,
  int halflifeMs,
  DateTime now,
) {
  final scoreA = _decayedScore(a, halflifeMs, now);
  final scoreB = _decayedScore(b, halflifeMs, now);
  // Descending on effective score.
  final byScore = scoreB.compareTo(scoreA);
  if (byScore != 0) return byScore;
  final byTime = a.pushedAt.compareTo(b.pushedAt);
  if (byTime != 0) return byTime;
  return _compareIdAscending(a, b);
}

double _decayedScore(StackEntry e, int halflifeMs, DateTime now) {
  final deltaMs = now.millisecondsSinceEpoch -
      e.pushedAt.millisecondsSinceEpoch;
  // Future-pushed entries (deltaMs < 0) can happen in tests with
  // synthetic clocks. Clamp to zero so the envelope cannot amplify
  // a score above its raw value.
  final delta = deltaMs < 0 ? 0.0 : deltaMs.toDouble();
  return e.priority * math.exp(-delta / halflifeMs);
}

int _compareIdAscending(StackEntry a, StackEntry b) =>
    a.id.toString().compareTo(b.id.toString());

int _compareIdDescending(StackEntry a, StackEntry b) =>
    b.id.toString().compareTo(a.id.toString());
