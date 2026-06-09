// Tests for the `procedure/` module's Todo-7 lifecycle vocabulary.
//
// Surface under test (cross-component value types — `procedure_specification.md`
// § 6, § 7, § 10.3):
//   * `ProcedureStatus` — the closed lifecycle alphabet
//     (`authored → draft → active → preferred → demoted`) with token
//     round-trip and the forward-only + demotion transition rule.
//   * `CapabilitySet` — the `requires`-name set with the overlap measure the
//     selector re-rank scores on.
//
// Why here and not in `tom_brain_procedure`: memory stores these, the selector
// ranks on them, and the authoring loop stamps them — none owns them, so they
// are shared vocabulary (spec § 14, Todo-7 placement).

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('ProcedureStatus', () {
    test('exposes exactly the five lifecycle stages', () {
      expect(ProcedureStatus.values, <ProcedureStatus>[
        ProcedureStatus.authored,
        ProcedureStatus.draft,
        ProcedureStatus.active,
        ProcedureStatus.preferred,
        ProcedureStatus.demoted,
      ]);
    });

    test('token round-trips for every stage', () {
      for (final status in ProcedureStatus.values) {
        expect(ProcedureStatus.fromToken(status.token), status);
      }
    });

    test('fromToken rejects an unknown token loudly', () {
      expect(() => ProcedureStatus.fromToken('running'), throwsArgumentError);
    });

    test('forward progression authored → draft → active → preferred', () {
      expect(ProcedureStatus.authored.canTransitionTo(ProcedureStatus.draft),
          isTrue);
      expect(ProcedureStatus.draft.canTransitionTo(ProcedureStatus.active),
          isTrue);
      expect(ProcedureStatus.active.canTransitionTo(ProcedureStatus.preferred),
          isTrue);
    });

    test('demotion is reachable from draft, active, and preferred', () {
      expect(ProcedureStatus.draft.canTransitionTo(ProcedureStatus.demoted),
          isTrue);
      expect(ProcedureStatus.active.canTransitionTo(ProcedureStatus.demoted),
          isTrue);
      expect(ProcedureStatus.preferred.canTransitionTo(ProcedureStatus.demoted),
          isTrue);
    });

    test('the sleep cycle may demote a preferred back to active', () {
      expect(ProcedureStatus.preferred.canTransitionTo(ProcedureStatus.active),
          isTrue);
    });

    test('demoted is terminal (a replacement is a new revision, not a revival)',
        () {
      for (final to in ProcedureStatus.values) {
        expect(ProcedureStatus.demoted.canTransitionTo(to), isFalse,
            reason: 'demoted should not transition to ${to.token}');
      }
    });

    test('skipping a stage is rejected (authored cannot jump to active)', () {
      expect(ProcedureStatus.authored.canTransitionTo(ProcedureStatus.active),
          isFalse);
      expect(ProcedureStatus.authored.canTransitionTo(ProcedureStatus.preferred),
          isFalse);
    });

    test('a stage never transitions to itself', () {
      for (final status in ProcedureStatus.values) {
        expect(status.canTransitionTo(status), isFalse);
      }
    });

    test('only active and preferred are retrievable by default', () {
      expect(ProcedureStatus.active.isRetrievable, isTrue);
      expect(ProcedureStatus.preferred.isRetrievable, isTrue);
      expect(ProcedureStatus.authored.isRetrievable, isFalse);
      expect(ProcedureStatus.draft.isRetrievable, isFalse);
      expect(ProcedureStatus.demoted.isRetrievable, isFalse);
    });
  });

  group('CapabilitySet', () {
    test('membership and containsAll reflect the underlying requires names', () {
      const caps = CapabilitySet({'recall', 'llm', 'persist'});
      expect(caps.contains('recall'), isTrue);
      expect(caps.contains('edge'), isFalse);
      expect(caps.containsAll(const CapabilitySet({'recall', 'llm'})), isTrue);
      expect(caps.containsAll(const CapabilitySet({'recall', 'edge'})), isFalse);
    });

    test('coverageBy is the fraction of required names the caller can supply',
        () {
      const required = CapabilitySet({'recall', 'llm', 'persist', 'edge'});
      const available = CapabilitySet({'recall', 'llm', 'note'});
      // 2 of 4 required names (recall, llm) are available.
      expect(required.coverageBy(available), closeTo(0.5, 1e-9));
    });

    test('an empty requirement is fully covered by anything (needs nothing)',
        () {
      const empty = CapabilitySet({});
      expect(empty.coverageBy(const CapabilitySet({'recall'})), 1.0);
      expect(empty.coverageBy(const CapabilitySet({})), 1.0);
    });

    test('full coverage when every required name is available', () {
      const required = CapabilitySet({'recall', 'llm'});
      const available = CapabilitySet({'recall', 'llm', 'persist'});
      expect(required.coverageBy(available), 1.0);
    });

    test('value equality and hashCode are set-based, order-independent', () {
      const a = CapabilitySet({'recall', 'llm'});
      const b = CapabilitySet({'llm', 'recall'});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('fromIterable de-duplicates into the canonical set', () {
      final caps = CapabilitySet.fromIterable(['recall', 'recall', 'llm']);
      expect(caps, const CapabilitySet({'recall', 'llm'}));
    });
  });
}
