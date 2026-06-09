// MemoryWriteGuard unit tests (spec § 5.4).
//
// The guard is the per-run, NON-FATAL backstop against an unbounded
// memory-write loop. These tests pin the model:
//
//   * within-run edge dedup catches an identical-edge loop on its second
//     iteration regardless of the count cap (the primary loop detector);
//   * a diverging-edge loop is bounded by maxEdgesPerRun;
//   * all writes are bounded by maxWritesPerRun;
//   * reaching any cap is a *skip* (counts nothing, never throws), so the
//     run can continue with a partial write;
//   * the unlimited limit set admits everything.

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';

void main() {
  group('MemoryWriteGuard edge dedup (loop detection)', () {
    test('skips a repeated identical edge regardless of the count cap', () {
      final guard = MemoryWriteGuard(
        const MemoryWriteLimits(maxEdgesPerRun: 1000, dedupEdgesWithinRun: true),
      );

      expect(guard.admitEdge('a', 'derived_from', 'b'), MemoryWriteOutcome.allow);
      // The same edge a second time is the loop signal — skipped, not counted.
      expect(guard.admitEdge('a', 'derived_from', 'b'),
          MemoryWriteOutcome.skipDuplicateEdge);
      expect(guard.admitEdge('a', 'derived_from', 'b'),
          MemoryWriteOutcome.skipDuplicateEdge);
      // Only the first was counted.
      expect(guard.edgeCount, 1);
      expect(guard.writeCount, 1);

      // A different edge (different `to`) is admitted — dedup is per-triple.
      expect(guard.admitEdge('a', 'derived_from', 'c'), MemoryWriteOutcome.allow);
      expect(guard.edgeCount, 2);
    });

    test('with dedup off, an identical edge is admitted (bounded only by caps)',
        () {
      final guard = MemoryWriteGuard(
        const MemoryWriteLimits(maxEdgesPerRun: 3, dedupEdgesWithinRun: false),
      );
      expect(guard.admitEdge('a', 'derived_from', 'b'), MemoryWriteOutcome.allow);
      expect(guard.admitEdge('a', 'derived_from', 'b'), MemoryWriteOutcome.allow);
      expect(guard.admitEdge('a', 'derived_from', 'b'), MemoryWriteOutcome.allow);
      expect(guard.edgeCount, 3);
      // The fourth trips the edge cap.
      expect(guard.admitEdge('a', 'derived_from', 'b'),
          MemoryWriteOutcome.skipEdgeCap);
      expect(guard.edgeCount, 3);
    });
  });

  group('MemoryWriteGuard caps (the loop backstop)', () {
    test('a diverging-edge loop is bounded by maxEdgesPerRun', () {
      final guard = MemoryWriteGuard(
        const MemoryWriteLimits(maxEdgesPerRun: 2, dedupEdgesWithinRun: true),
      );
      expect(guard.admitEdge('c', 'derived_from', 'n0'),
          MemoryWriteOutcome.allow);
      expect(guard.admitEdge('c', 'derived_from', 'n1'),
          MemoryWriteOutcome.allow);
      // Third distinct edge exceeds the edge cap — skipped, not fatal.
      expect(guard.admitEdge('c', 'derived_from', 'n2'),
          MemoryWriteOutcome.skipEdgeCap);
      expect(guard.edgeCount, 2);
    });

    test('non-edge writes are bounded by maxWritesPerRun', () {
      final guard = MemoryWriteGuard(
        const MemoryWriteLimits(maxWritesPerRun: 2),
      );
      expect(guard.admitWrite(), MemoryWriteOutcome.allow);
      expect(guard.admitWrite(), MemoryWriteOutcome.allow);
      expect(guard.admitWrite(), MemoryWriteOutcome.skipWriteCap);
      expect(guard.writeCount, 2);
    });

    test('edges and non-edge writes share the total write cap', () {
      final guard = MemoryWriteGuard(
        const MemoryWriteLimits(maxWritesPerRun: 2, dedupEdgesWithinRun: true),
      );
      expect(guard.admitWrite(), MemoryWriteOutcome.allow); // a persist
      expect(guard.admitEdge('a', 'derived_from', 'b'),
          MemoryWriteOutcome.allow); // an edge — total now 2
      // The total cap is reached: a further edge is skipped on the write cap,
      // even though the edge cap is unset.
      expect(guard.admitEdge('a', 'derived_from', 'c'),
          MemoryWriteOutcome.skipWriteCap);
      expect(guard.writeCount, 2);
    });
  });

  group('MemoryWriteLimits presets', () {
    test('standard admits a realistic request worth of writes', () {
      final guard = MemoryWriteGuard(MemoryWriteLimits.standard);
      // A "who are you" answer writes ~2 nodes + up to 24 derived_from edges +
      // an interest item — far below the standard caps.
      for (var i = 0; i < 24; i++) {
        expect(guard.admitEdge('conclusion', 'derived_from', 'node$i'),
            MemoryWriteOutcome.allow);
      }
      expect(guard.admitWrite(), MemoryWriteOutcome.allow);
      expect(guard.edgeCount, 24);
    });

    test('unlimited admits everything', () {
      final guard = MemoryWriteGuard(MemoryWriteLimits.unlimited);
      for (var i = 0; i < 5000; i++) {
        expect(guard.admitEdge('a', 'derived_from', 'b'),
            MemoryWriteOutcome.allow);
      }
      expect(guard.edgeCount, 5000);
    });
  });

  group('MemoryWriteOutcome predicates', () {
    test('allow is allowed, every skip is a skip', () {
      expect(MemoryWriteOutcome.allow.isAllowed, isTrue);
      expect(MemoryWriteOutcome.allow.isSkip, isFalse);
      for (final o in <MemoryWriteOutcome>[
        MemoryWriteOutcome.skipDuplicateEdge,
        MemoryWriteOutcome.skipEdgeCap,
        MemoryWriteOutcome.skipWriteCap,
      ]) {
        expect(o.isSkip, isTrue);
        expect(o.isAllowed, isFalse);
      }
    });
  });
}
