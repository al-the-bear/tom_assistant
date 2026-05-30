// A.57 — Reciprocal Rank Fusion (pure-function tests).
//
// Plan step A.57:
//   "Implement RRF fusion (`k_rrf = 60`) — pure function,
//    property-tested."
//
// Spec § 6.2 (memory_specification.md):
//   score(d) = Σ_modes 1 / (k_rrf + rank_mode(d)),  k_rrf = 60
//
// What this file covers (one `test(...)` per row):
//
//   Default / surface
//   -----------------
//   * `kDefaultRrfK` is 60 and matches `FusionPolicy.defaultRrf.rrfK`.
//   * Empty `rankedLists` → empty result.
//   * Empty per-mode list → empty result.
//   * `cap == 0` → empty result.
//   * Negative `kRrf` throws ArgumentError.
//
//   Scoring math
//   ------------
//   * Single mode, single node: score == 1 / (k + 1).
//   * Single mode, two nodes: top rank gets 1/(k+1); second gets 1/(k+2).
//   * Two modes that agree on the top node: score doubles
//     (1/(k+1) + 1/(k+1)).
//   * Two modes that disagree: node appearing only in one mode
//     gets its single mode's contribution; node in both modes
//     accumulates both contributions.
//   * `perModeRanks` carries the 1-indexed rank for every mode the
//     node appeared in, and omits modes it didn't.
//
//   Determinism / tie-break
//   -----------------------
//   * Tied scores are broken by ascending `NodeId.compareTo`.
//   * Permuting the input mode-map's key order does not change the
//     output (property test — many random permutations).
//
//   Defensive shape
//   ---------------
//   * Duplicate `NodeId` within one mode's list uses the first
//     (best) rank, ignores the rest.
//   * `cap` truncates to the top-N.
//   * Sole-mode candidates outside the cap are dropped (not
//     mysteriously promoted).
//
//   Property: monotonicity in rank
//   ------------------------------
//   * For any single-mode list, the output's score order matches the
//     input's rank order strictly (no ties possible in a single mode).
//
//   Property: agreement boost
//   -------------------------
//   * For any pair of disjoint-rank assignments across two modes, a
//     node ranked r in both modes scores ≥ a node ranked r in only
//     one mode (>= because if r is huge the contribution shrinks but
//     never inverts).

import 'dart:math';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId;

void main() {
  group('A.57 RRF fusion (pure function)', () {
    // Deterministic NodeId mint for tests — every call returns a
    // distinct id with predictable lexicographic order.
    int seed = 0;
    NodeId mintId() {
      seed += 1;
      // Spread across enough bytes that ULID's lexicographic order
      // tracks our seed counter. Use the time component for the
      // ordering — fakeTime advances by seed minutes.
      final at = DateTime.utc(2026, 1, 1).add(Duration(minutes: seed));
      final randomness =
          List<int>.generate(16, (i) => (seed * 31 + i * 7) & 0x1F);
      return NodeId.generate(at: at, randomness: randomness);
    }

    setUp(() {
      seed = 0;
    });

    // ─── Default / surface ────────────────────────────────────────

    test('kDefaultRrfK is 60', () {
      expect(kDefaultRrfK, 60);
    });

    test('default rrfK matches FusionPolicy.defaultRrf.rrfK', () {
      expect(kDefaultRrfK, FusionPolicy.defaultRrf.rrfK);
    });

    test('empty rankedLists returns empty', () {
      expect(rrfFuse(rankedLists: const {}), isEmpty);
    });

    test('all per-mode lists empty returns empty', () {
      final fused = rrfFuse(
        rankedLists: {
          RecallMode.bm25: const <NodeId>[],
          RecallMode.vector: const <NodeId>[],
        },
      );
      expect(fused, isEmpty);
    });

    test('cap == 0 returns empty', () {
      final id = mintId();
      final fused = rrfFuse(
        rankedLists: {
          RecallMode.bm25: <NodeId>[id],
        },
        cap: 0,
      );
      expect(fused, isEmpty);
    });

    test('cap < 0 returns empty', () {
      final id = mintId();
      final fused = rrfFuse(
        rankedLists: {
          RecallMode.bm25: <NodeId>[id],
        },
        cap: -1,
      );
      expect(fused, isEmpty);
    });

    test('negative kRrf throws ArgumentError', () {
      final id = mintId();
      expect(
        () => rrfFuse(
          rankedLists: {
            RecallMode.bm25: <NodeId>[id],
          },
          kRrf: -1,
        ),
        throwsArgumentError,
      );
    });

    test('kRrf == 0 is permitted (1-indexed ranks keep denominator > 0)',
        () {
      final id = mintId();
      final fused = rrfFuse(
        rankedLists: {
          RecallMode.bm25: <NodeId>[id],
        },
        kRrf: 0,
      );
      expect(fused, hasLength(1));
      expect(fused.single.score, 1.0); // 1 / (0 + 1)
    });

    // ─── Scoring math ─────────────────────────────────────────────

    test('single mode, single node: score == 1 / (k + 1)', () {
      final id = mintId();
      final fused = rrfFuse(
        rankedLists: {
          RecallMode.bm25: <NodeId>[id],
        },
      );
      expect(fused, hasLength(1));
      expect(fused.single.nodeId, id);
      expect(fused.single.score, closeTo(1.0 / (60 + 1), 1e-12));
      expect(fused.single.perModeRanks, {RecallMode.bm25: 1});
    });

    test('single mode, two nodes: ranks 1 and 2 → 1/61 and 1/62', () {
      final a = mintId();
      final b = mintId();
      final fused = rrfFuse(
        rankedLists: {
          RecallMode.bm25: <NodeId>[a, b],
        },
      );
      expect(fused.map((f) => f.nodeId), [a, b]);
      expect(fused[0].score, closeTo(1.0 / 61, 1e-12));
      expect(fused[1].score, closeTo(1.0 / 62, 1e-12));
    });

    test('two modes that agree on the top node double its score', () {
      final a = mintId();
      final fused = rrfFuse(
        rankedLists: {
          RecallMode.bm25: <NodeId>[a],
          RecallMode.vector: <NodeId>[a],
        },
      );
      expect(fused, hasLength(1));
      expect(fused.single.score, closeTo(2.0 / 61, 1e-12));
      expect(
        fused.single.perModeRanks,
        {RecallMode.bm25: 1, RecallMode.vector: 1},
      );
    });

    test('two modes that disagree: per-mode contributions accumulate', () {
      // a is rank 1 in bm25, rank 2 in vector
      // b is rank 2 in bm25, rank 1 in vector
      // c is only in vector at rank 3
      final a = mintId();
      final b = mintId();
      final c = mintId();
      final fused = rrfFuse(
        rankedLists: {
          RecallMode.bm25: <NodeId>[a, b],
          RecallMode.vector: <NodeId>[b, a, c],
        },
      );
      final byId = <NodeId, RrfFusedCandidate>{
        for (final f in fused) f.nodeId: f,
      };
      expect(byId[a]!.score, closeTo(1.0 / 61 + 1.0 / 62, 1e-12));
      expect(byId[b]!.score, closeTo(1.0 / 62 + 1.0 / 61, 1e-12));
      expect(byId[c]!.score, closeTo(1.0 / 63, 1e-12));
      // a and b have identical fused scores → tie-break by NodeId asc.
      expect(fused[0].score, closeTo(fused[1].score, 1e-12));
      expect(fused[0].nodeId.compareTo(fused[1].nodeId), lessThan(0));
      expect(fused.last.nodeId, c);
    });

    test('perModeRanks omits modes the node did not appear in', () {
      final a = mintId();
      final b = mintId();
      final fused = rrfFuse(
        rankedLists: {
          RecallMode.bm25: <NodeId>[a],
          RecallMode.vector: <NodeId>[b],
        },
      );
      final byId = <NodeId, RrfFusedCandidate>{
        for (final f in fused) f.nodeId: f,
      };
      expect(byId[a]!.perModeRanks.keys, [RecallMode.bm25]);
      expect(byId[b]!.perModeRanks.keys, [RecallMode.vector]);
    });

    // ─── Determinism / tie-break ──────────────────────────────────

    test('tied scores are broken by ascending NodeId.compareTo', () {
      // Three nodes, each appearing exactly once at rank 1 in three
      // different modes → identical scores.
      final ids = List.generate(3, (_) => mintId());
      final fused = rrfFuse(
        rankedLists: {
          RecallMode.bm25: <NodeId>[ids[2]],
          RecallMode.vector: <NodeId>[ids[0]],
          RecallMode.symbolic: <NodeId>[ids[1]],
        },
      );
      expect(fused, hasLength(3));
      // All scores equal
      expect(fused[0].score, closeTo(fused[1].score, 1e-12));
      expect(fused[1].score, closeTo(fused[2].score, 1e-12));
      // Output order is NodeId ascending
      final outIds = fused.map((f) => f.nodeId).toList();
      final sorted = List<NodeId>.from(outIds)
        ..sort((x, y) => x.compareTo(y));
      expect(outIds, sorted);
    });

    test('input mode-map ordering does not change the output (property)',
        () {
      final rng = Random(20260530);
      // Build a fixed input set; permute the map's key order many
      // times and confirm the output is stable.
      final a = mintId();
      final b = mintId();
      final c = mintId();
      final d = mintId();

      final base = <RecallMode, List<NodeId>>{
        RecallMode.bm25: <NodeId>[a, b, c],
        RecallMode.vector: <NodeId>[b, d, a],
        RecallMode.symbolic: <NodeId>[c, a],
      };

      // Canonical output (sorted-by-enum key insertion).
      final canonical = rrfFuse(rankedLists: base);

      for (var trial = 0; trial < 32; trial++) {
        final keys = base.keys.toList()..shuffle(rng);
        final permuted = <RecallMode, List<NodeId>>{
          for (final k in keys) k: base[k]!,
        };
        final out = rrfFuse(rankedLists: permuted);
        expect(out.length, canonical.length);
        for (var i = 0; i < out.length; i++) {
          expect(out[i].nodeId, canonical[i].nodeId, reason: 'trial $trial');
          expect(out[i].score, closeTo(canonical[i].score, 1e-12),
              reason: 'trial $trial');
          expect(out[i].perModeRanks, canonical[i].perModeRanks);
        }
      }
    });

    test('permuting tied candidates does not change the output (property)',
        () {
      // All ten ids in one mode at rank 1..10. Then in a second mode
      // we put them in *shuffled* order at rank 1..10. The result
      // depends only on each id's rank-pair, not on the order we
      // listed them in the input map.
      final rng = Random(20260601);
      final ids = List.generate(10, (_) => mintId());

      // Build a stable reference: bm25 = ids in order, vector = ids
      // reversed.
      final reference = rrfFuse(
        rankedLists: {
          RecallMode.bm25: List<NodeId>.from(ids),
          RecallMode.vector: List<NodeId>.from(ids.reversed),
        },
      );

      // Now do 32 shuffles of the second list and verify the *scores*
      // of each id stay identical to scoring that id's two ranks
      // directly.
      for (var trial = 0; trial < 32; trial++) {
        final shuffled = List<NodeId>.from(ids)..shuffle(rng);
        final fused = rrfFuse(
          rankedLists: {
            RecallMode.bm25: List<NodeId>.from(ids),
            RecallMode.vector: shuffled,
          },
        );
        // For every id, score == 1/(60 + bm25Rank) + 1/(60 + vectorRank)
        for (final id in ids) {
          final bm25Rank = ids.indexOf(id) + 1;
          final vecRank = shuffled.indexOf(id) + 1;
          final expected = 1.0 / (60 + bm25Rank) + 1.0 / (60 + vecRank);
          final row = fused.firstWhere((f) => f.nodeId == id);
          expect(row.score, closeTo(expected, 1e-12),
              reason: 'trial $trial id $id');
        }

        // And every fused candidate from the reference still appears
        // exactly once.
        expect(
          fused.map((f) => f.nodeId).toSet(),
          reference.map((f) => f.nodeId).toSet(),
        );
      }
    });

    // ─── Defensive shape ──────────────────────────────────────────

    test('duplicate NodeId within one mode uses first (best) rank', () {
      final a = mintId();
      final b = mintId();
      final fused = rrfFuse(
        rankedLists: {
          // a appears at rank 1 AND rank 3 — only rank 1 should count.
          RecallMode.bm25: <NodeId>[a, b, a],
        },
      );
      expect(fused, hasLength(2));
      final byId = <NodeId, RrfFusedCandidate>{
        for (final f in fused) f.nodeId: f,
      };
      expect(byId[a]!.score, closeTo(1.0 / 61, 1e-12));
      expect(byId[b]!.score, closeTo(1.0 / 62, 1e-12));
      expect(byId[a]!.perModeRanks, {RecallMode.bm25: 1});
    });

    test('cap truncates to the top-N (preserves descending order)', () {
      final ids = List.generate(5, (_) => mintId());
      final fused = rrfFuse(
        rankedLists: {
          RecallMode.bm25: ids,
        },
        cap: 3,
      );
      expect(fused.map((f) => f.nodeId), ids.take(3));
    });

    test('cap drops lower-ranked candidates, never promotes them', () {
      // Three nodes in bm25 only.
      final a = mintId();
      final b = mintId();
      final c = mintId();
      final fused = rrfFuse(
        rankedLists: {
          RecallMode.bm25: <NodeId>[a, b, c],
        },
        cap: 2,
      );
      expect(fused.map((f) => f.nodeId), [a, b]);
    });

    test('returned list is unmodifiable', () {
      final id = mintId();
      final fused = rrfFuse(
        rankedLists: {
          RecallMode.bm25: <NodeId>[id],
        },
      );
      expect(
        () => fused.add(fused.first),
        throwsUnsupportedError,
      );
    });

    test('returned perModeRanks map is unmodifiable', () {
      final id = mintId();
      final fused = rrfFuse(
        rankedLists: {
          RecallMode.bm25: <NodeId>[id],
        },
      );
      expect(
        () => fused.first.perModeRanks[RecallMode.vector] = 99,
        throwsUnsupportedError,
      );
    });

    // ─── Property: monotonicity in rank ───────────────────────────

    test('single-mode output preserves strict rank order (property)', () {
      final rng = Random(20260615);
      for (var trial = 0; trial < 16; trial++) {
        final n = 3 + rng.nextInt(10);
        final ids = List.generate(n, (_) => mintId());
        final fused = rrfFuse(
          rankedLists: {RecallMode.bm25: ids},
        );
        expect(fused.map((f) => f.nodeId).toList(), ids,
            reason: 'trial $trial');
        // Scores must strictly decrease.
        for (var i = 1; i < fused.length; i++) {
          expect(fused[i].score, lessThan(fused[i - 1].score),
              reason: 'trial $trial pos $i');
        }
      }
    });

    // ─── Property: agreement boost ────────────────────────────────

    test(
        'a node appearing in two modes at rank r outscores a node '
        'appearing in only one mode at rank r (property)', () {
      final rng = Random(20260620);
      for (var trial = 0; trial < 32; trial++) {
        final r = 1 + rng.nextInt(20);
        // both appears in bm25 AND vector at rank r;
        // only appears only in bm25 at rank r. We put 'both' and
        // 'only' in different positions in bm25 to avoid duplicate
        // ids; the second mode contains only 'both'.
        final both = mintId();
        final only = mintId();
        final padBm25 = List.generate(r - 1, (_) => mintId());
        final padVec = List.generate(r - 1, (_) => mintId());
        final fused = rrfFuse(
          rankedLists: {
            // bm25: padding, then both at rank r → only must be at a
            // different position; put only at rank r+1.
            RecallMode.bm25: <NodeId>[...padBm25, both, only],
            RecallMode.vector: <NodeId>[...padVec, both],
          },
        );
        final byId = <NodeId, RrfFusedCandidate>{
          for (final f in fused) f.nodeId: f,
        };
        // both: 1/(60+r) + 1/(60+r)
        // only: 1/(60+r+1)
        // We need both's score > only's score. Since 2/(60+r) >
        // 1/(60+r+1) for any r >= 1, this is guaranteed.
        expect(byId[both]!.score, greaterThan(byId[only]!.score),
            reason: 'trial $trial rank $r');
      }
    });
  });
}
