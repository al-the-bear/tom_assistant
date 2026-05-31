// A.41 — Priority-policy pure-function property tests.
//
// Coverage map (one or more `test(...)` per row):
//
//   Determinism / totality
//   ----------------------
//   * Sorting an empty iterable yields an empty list for all four
//     policies.
//   * Sorting a single-entry iterable yields exactly that entry
//     for all four policies.
//   * `comparePolicy(a, b) == -comparePolicy(b, a)` for all four
//     policies across 200 random pairs.
//   * `sortByPolicy` is idempotent: sorting twice yields the same
//     result as sorting once (200 random lists × 4 policies).
//
//   FIFO
//   ----
//   * 200 random lists: result is non-decreasing in `pushedAt`;
//     ties broken by `id` ascending.
//   * Inserting a new entry at any position preserves the
//     pushed-at ordering — i.e., post-sort order is independent of
//     input order.
//
//   LIFO
//   ----
//   * 200 random lists: result is non-increasing in `pushedAt`;
//     ties broken by `id` descending.
//   * `sortByPolicy(fifo).reversed` produces the same order as
//     `sortByPolicy(lifo)` *only when all pushed-at values are
//     distinct* — when ties exist the id-tiebreak direction
//     flips, so the property is qualified accordingly.
//
//   PRIORITY
//   --------
//   * 200 random lists: result is non-increasing in `priority`;
//     priority ties broken by `pushedAt` ascending; full ties
//     broken by `id` ascending.
//   * `effectivePriority` equals raw `priority` for every entry
//     under a static-priority policy.
//
//   TIME-DECAYED PRIORITY
//   ---------------------
//   * 200 random lists: result is non-increasing in
//     `effectivePriority(now)`.
//   * `effective = raw * exp(-Δt / halflife)` — checked against
//     `dart:math.exp` for 200 random (raw, Δt, halflife) triples.
//   * As halflife → ∞ the order converges to the static-priority
//     order (test with halflife = 10¹² ms over a small Δt range).
//   * Older entries with high raw priority can be overtaken by
//     newer entries with lower raw priority — checked with a
//     two-entry crafted example that demonstrates the *intended*
//     overtake behaviour the SQL linear approximation could not
//     deliver.
//   * Future-pushed entries (pushedAt > now) get the *raw* score
//     — the envelope is clamped at Δt = 0 to avoid amplification.
//   * Misconfigured policy (halflifeMs null / non-positive) falls
//     back to raw `priority` ordering rather than throwing.

import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:tom_brain_memory/src/stacks/priority_policy.dart';
import 'package:tom_brain_memory/src/stacks/stack_types.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

// ─── Fixtures ────────────────────────────────────────────────────

final DateTime _t0 = DateTime.utc(2026, 5, 30, 12);

const StackPolicy _fifoPolicy = StackPolicy(
  priority: PriorityPolicyKind.fifo,
  retention: RetentionPolicyKind.unbounded,
);

const StackPolicy _lifoPolicy = StackPolicy(
  priority: PriorityPolicyKind.lifo,
  retention: RetentionPolicyKind.unbounded,
);

const StackPolicy _priorityPolicy = StackPolicy(
  priority: PriorityPolicyKind.priority,
  retention: RetentionPolicyKind.unbounded,
);

StackPolicy _decayedPolicy(int halflifeMs) => StackPolicy(
      priority: PriorityPolicyKind.timeDecayedPriority,
      retention: RetentionPolicyKind.unbounded,
      halflifeMs: halflifeMs,
    );

/// Builds an entry with a deterministic id derived from [seed]. The
/// id is a ULID-shape `se_<26-char>` string built by minting
/// against a synthetic randomness vector — `StackEntryId.generate`
/// supports this for tests.
StackEntry _entry({
  required int seed,
  required double priority,
  required DateTime pushedAt,
}) {
  // Encode `seed` into the 16-entry, [0..31]-valued randomness
  // vector ULID expects. We pack the seed in base-32 right-to-left
  // so equal `pushedAt` + monotonically-increasing `seed` produces
  // monotonically-increasing ids (good for predictable tie-breaks
  // in the property tests).
  final randomness = List<int>.filled(16, 0);
  var s = seed;
  for (var i = 15; i >= 0 && s > 0; i--) {
    randomness[i] = s & 0x1f;
    s >>= 5;
  }
  final id = StackEntryId.generate(
    at: pushedAt,
    randomness: randomness,
  );
  return StackEntry(
    id: id,
    stackName: 'test',
    nodeId: NodeId.generate(at: pushedAt, randomness: randomness),
    priority: priority,
    pushedAt: pushedAt,
  );
}

// Helper that does not depend on NodeId encoding — many tests
// don't care about it but the constructor needs *some* valid one.
StackEntry _e({
  int seed = 0,
  double priority = 0.0,
  int offsetMs = 0,
}) =>
    _entry(
      seed: seed,
      priority: priority,
      pushedAt: _t0.add(Duration(milliseconds: offsetMs)),
    );

/// Generates a list of [n] random entries with controllable
/// distributions. Used by the property tests.
List<StackEntry> _randomEntries(
  math.Random rng,
  int n, {
  double priorityMax = 100.0,
  int timeSpanMs = 60 * 60 * 1000, // one hour
}) {
  final out = <StackEntry>[];
  for (var i = 0; i < n; i++) {
    out.add(
      _e(
        seed: i,
        priority: rng.nextDouble() * priorityMax,
        offsetMs: rng.nextInt(timeSpanMs),
      ),
    );
  }
  return out;
}

// ─── Tests ────────────────────────────────────────────────────────

void main() {
  group('priority_policy — totality & determinism', () {
    final policies = <String, StackPolicy>{
      'fifo': _fifoPolicy,
      'lifo': _lifoPolicy,
      'priority': _priorityPolicy,
      'timeDecayedPriority': _decayedPolicy(60000),
    };

    policies.forEach((name, policy) {
      test('$name: empty input → empty output', () {
        expect(sortByPolicy(<StackEntry>[], policy, now: _t0), isEmpty);
      });

      test('$name: single-entry input → single-entry output', () {
        final e = _e(seed: 1, priority: 1.0, offsetMs: 0);
        final sorted = sortByPolicy(<StackEntry>[e], policy, now: _t0);
        expect(sorted, hasLength(1));
        expect(sorted.single.id, equals(e.id));
      });

      test('$name: comparator is antisymmetric (200 random pairs)', () {
        final rng = math.Random(name.hashCode);
        for (var i = 0; i < 200; i++) {
          final a = _e(
            seed: i * 2,
            priority: rng.nextDouble() * 10,
            offsetMs: rng.nextInt(10000),
          );
          final b = _e(
            seed: i * 2 + 1,
            priority: rng.nextDouble() * 10,
            offsetMs: rng.nextInt(10000),
          );
          final ab = comparePolicy(a, b, policy, now: _t0);
          final ba = comparePolicy(b, a, policy, now: _t0);
          expect(ab, equals(-ba), reason: 'pair $i under $name');
        }
      });

      test('$name: sortByPolicy is idempotent (50 random lists)', () {
        final rng = math.Random(name.hashCode ^ 0x55);
        for (var i = 0; i < 50; i++) {
          final input = _randomEntries(rng, 20);
          final once = sortByPolicy(input, policy, now: _t0);
          final twice = sortByPolicy(once, policy, now: _t0);
          expect(
            twice.map((e) => e.id.toString()).toList(),
            equals(once.map((e) => e.id.toString()).toList()),
            reason: 'iteration $i under $name',
          );
        }
      });
    });
  });

  group('priority_policy — fifo', () {
    test('200 random lists: non-decreasing in pushedAt', () {
      final rng = math.Random(1);
      for (var iter = 0; iter < 200; iter++) {
        final n = 1 + rng.nextInt(20);
        final input = _randomEntries(rng, n);
        final sorted = sortByPolicy(input, _fifoPolicy, now: _t0);
        for (var i = 1; i < sorted.length; i++) {
          final prev = sorted[i - 1];
          final curr = sorted[i];
          final cmp = prev.pushedAt.compareTo(curr.pushedAt);
          expect(cmp, lessThanOrEqualTo(0),
              reason: 'iter $iter: pushedAt non-monotone at i=$i');
          if (cmp == 0) {
            expect(prev.id.toString().compareTo(curr.id.toString()),
                lessThanOrEqualTo(0),
                reason:
                    'iter $iter: tie-break id non-monotone at i=$i');
          }
        }
      }
    });

    test('order independent of input order', () {
      final rng = math.Random(2);
      final base = _randomEntries(rng, 20);
      final shuffled = base.toList()..shuffle(math.Random(3));
      final baseSorted =
          sortByPolicy(base, _fifoPolicy, now: _t0).map((e) => e.id);
      final shuffledSorted = sortByPolicy(shuffled, _fifoPolicy, now: _t0)
          .map((e) => e.id);
      expect(shuffledSorted.toList(), equals(baseSorted.toList()));
    });
  });

  group('priority_policy — lifo', () {
    test('200 random lists: non-increasing in pushedAt', () {
      final rng = math.Random(4);
      for (var iter = 0; iter < 200; iter++) {
        final n = 1 + rng.nextInt(20);
        final input = _randomEntries(rng, n);
        final sorted = sortByPolicy(input, _lifoPolicy, now: _t0);
        for (var i = 1; i < sorted.length; i++) {
          final prev = sorted[i - 1];
          final curr = sorted[i];
          final cmp = prev.pushedAt.compareTo(curr.pushedAt);
          expect(cmp, greaterThanOrEqualTo(0),
              reason: 'iter $iter: pushedAt non-monotone at i=$i');
          if (cmp == 0) {
            expect(prev.id.toString().compareTo(curr.id.toString()),
                greaterThanOrEqualTo(0),
                reason:
                    'iter $iter: tie-break id non-monotone at i=$i');
          }
        }
      }
    });

    test('lifo with all-distinct pushedAt is fifo reversed', () {
      // Build entries with strictly distinct pushed-at so the
      // id-tiebreak does not flip directions on us.
      final entries = <StackEntry>[
        _e(seed: 0, priority: 0.0, offsetMs: 0),
        _e(seed: 1, priority: 0.0, offsetMs: 1),
        _e(seed: 2, priority: 0.0, offsetMs: 2),
        _e(seed: 3, priority: 0.0, offsetMs: 3),
      ];
      final fifoIds =
          sortByPolicy(entries, _fifoPolicy, now: _t0).map((e) => e.id);
      final lifoIds =
          sortByPolicy(entries, _lifoPolicy, now: _t0).map((e) => e.id);
      expect(lifoIds.toList(), equals(fifoIds.toList().reversed.toList()));
    });
  });

  group('priority_policy — priority', () {
    test('200 random lists: non-increasing in priority; ties by time then id',
        () {
      final rng = math.Random(5);
      for (var iter = 0; iter < 200; iter++) {
        final n = 1 + rng.nextInt(20);
        final input = _randomEntries(rng, n,
            priorityMax: 5.0); // small range → many ties
        final sorted = sortByPolicy(input, _priorityPolicy, now: _t0);
        for (var i = 1; i < sorted.length; i++) {
          final prev = sorted[i - 1];
          final curr = sorted[i];
          final cmp = prev.priority.compareTo(curr.priority);
          expect(cmp, greaterThanOrEqualTo(0),
              reason: 'iter $iter: priority non-monotone at i=$i');
          if (cmp == 0) {
            final t = prev.pushedAt.compareTo(curr.pushedAt);
            expect(t, lessThanOrEqualTo(0),
                reason:
                    'iter $iter: priority-tied pair time non-monotone at i=$i');
            if (t == 0) {
              expect(
                  prev.id.toString().compareTo(curr.id.toString()),
                  lessThanOrEqualTo(0),
                  reason:
                      'iter $iter: priority+time-tied pair id non-monotone at i=$i');
            }
          }
        }
      }
    });

    test('effectivePriority == raw priority under static-priority policy',
        () {
      final rng = math.Random(6);
      for (var i = 0; i < 50; i++) {
        final e = _e(
            seed: i, priority: rng.nextDouble() * 100, offsetMs: i * 1000);
        expect(effectivePriority(e, _priorityPolicy, _t0),
            equals(e.priority));
      }
    });
  });

  group('priority_policy — timeDecayedPriority', () {
    test('200 random lists: non-increasing in effective score', () {
      final rng = math.Random(7);
      const halflifeMs = 60 * 1000; // one minute
      final policy = _decayedPolicy(halflifeMs);
      // Use a `now` far enough after `_t0` that decay is non-trivial.
      final now = _t0.add(const Duration(minutes: 30));
      for (var iter = 0; iter < 200; iter++) {
        final n = 1 + rng.nextInt(20);
        final input = _randomEntries(rng, n);
        final sorted = sortByPolicy(input, policy, now: now);
        for (var i = 1; i < sorted.length; i++) {
          final a = effectivePriority(sorted[i - 1], policy, now);
          final b = effectivePriority(sorted[i], policy, now);
          expect(a, greaterThanOrEqualTo(b),
              reason: 'iter $iter: effective non-monotone at i=$i');
        }
      }
    });

    test('effective = raw * exp(-Δt / halflife) — 200 random triples', () {
      final rng = math.Random(8);
      for (var i = 0; i < 200; i++) {
        final halflifeMs = 1000 + rng.nextInt(60 * 60 * 1000);
        final raw = rng.nextDouble() * 100;
        final dtMs = rng.nextInt(10 * halflifeMs);
        final pushedAt = _t0;
        final now = pushedAt.add(Duration(milliseconds: dtMs));
        final e = StackEntry(
          id: StackEntryId.generate(
            at: pushedAt,
            randomness: List<int>.filled(16, i & 0x1f),
          ),
          stackName: 'test',
          nodeId: NodeId.generate(at: pushedAt),
          priority: raw,
          pushedAt: pushedAt,
        );
        final expected = raw * math.exp(-dtMs / halflifeMs);
        final actual =
            effectivePriority(e, _decayedPolicy(halflifeMs), now);
        expect(actual, closeTo(expected, 1e-9),
            reason: 'triple $i: raw=$raw dt=$dtMs hl=$halflifeMs');
      }
    });

    test('long halflife → order converges to static priority', () {
      // halflife of 10^12 ms ≈ 31 years. Over a 1-hour Δt the decay
      // factor differs from 1 by less than 4e-6 — small enough that
      // raw priority differences > 1 dominate.
      final policy = _decayedPolicy(1000000000000);
      final entries = <StackEntry>[
        _e(seed: 1, priority: 10.0, offsetMs: 0),
        _e(seed: 2, priority: 5.0, offsetMs: 1000),
        _e(seed: 3, priority: 1.0, offsetMs: 2000),
      ];
      final now = _t0.add(const Duration(hours: 1));
      final decayedOrder =
          sortByPolicy(entries, policy, now: now).map((e) => e.priority);
      final staticOrder = sortByPolicy(entries, _priorityPolicy, now: now)
          .map((e) => e.priority);
      expect(decayedOrder.toList(), equals(staticOrder.toList()));
    });

    test('overtake: new low-raw entry beats old high-raw entry', () {
      // The SQL linear-approximation A.40 used could not deliver this
      // case correctly. Verify the pure-function evaluator does.
      //
      // halflife = 1000 ms. Old entry: raw 100, Δt = 5000 ms →
      // effective = 100 * exp(-5) ≈ 0.674. New entry: raw 10, Δt = 0
      // → effective = 10. The new entry wins.
      final policy = _decayedPolicy(1000);
      final old = _e(seed: 1, priority: 100.0, offsetMs: 0);
      final young = _e(seed: 2, priority: 10.0, offsetMs: 5000);
      final now = _t0.add(const Duration(milliseconds: 5000));
      final sorted = sortByPolicy(<StackEntry>[old, young], policy, now: now);
      expect(sorted.first.id, equals(young.id));
      expect(sorted.last.id, equals(old.id));
    });

    test('future-pushed entry: envelope clamped at Δt = 0', () {
      // A synthetic now that is *before* pushedAt would otherwise
      // amplify the score via a negative Δt. The implementation
      // clamps Δt to zero.
      final policy = _decayedPolicy(1000);
      final future = _e(seed: 1, priority: 7.5, offsetMs: 10000);
      final now = _t0; // before pushedAt
      final score = effectivePriority(future, policy, now);
      expect(score, equals(7.5));
    });

    test('misconfigured (null halflifeMs) → falls back to raw priority', () {
      // The validator refuses this combination at create/updatePolicy
      // time, but the comparator must remain total if a caller
      // bypasses the validator.
      const misconfigured = StackPolicy(
        priority: PriorityPolicyKind.timeDecayedPriority,
        retention: RetentionPolicyKind.unbounded,
        // halflifeMs deliberately omitted.
      );
      final entries = <StackEntry>[
        _e(seed: 1, priority: 1.0, offsetMs: 0),
        _e(seed: 2, priority: 5.0, offsetMs: 1000),
        _e(seed: 3, priority: 3.0, offsetMs: 2000),
      ];
      final sorted = sortByPolicy(entries, misconfigured, now: _t0)
          .map((e) => e.priority)
          .toList();
      expect(sorted, equals(<double>[5.0, 3.0, 1.0]));
    });

    test('misconfigured (zero halflifeMs) → falls back to raw priority',
        () {
      final misconfigured = _decayedPolicy(0);
      final entries = <StackEntry>[
        _e(seed: 1, priority: 1.0, offsetMs: 0),
        _e(seed: 2, priority: 5.0, offsetMs: 1000),
      ];
      final sorted = sortByPolicy(entries, misconfigured, now: _t0)
          .map((e) => e.priority)
          .toList();
      expect(sorted, equals(<double>[5.0, 1.0]));
    });
  });
}
