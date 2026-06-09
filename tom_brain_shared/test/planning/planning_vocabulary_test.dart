// Todo 8 (G-P1 / G-P6) — the shared planning vocabulary
// (`planning_specification.md` § 4.2, § 5.1, § 5.2, § 10.1).
//
// Pins: the four closed token alphabets (`PlanKind` / `PlanStatus` /
// `StepKind` / `StepStatus`) round-trip through their tokens and throw loudly on
// an unknown one; the `isOpen` predicates; the `PlanView` / `PlanStepView`
// node-boundary decode (happy path, nullable fields, loud failures); and the
// `PlanningEvent` sealed family — nine leaves, the `kind` discriminators match
// `planningEventKinds`, the UTC + payload contract, and `planId` correlation.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

Node _planNode({
  required String goal,
  String? summary,
  String? kind,
  String? status,
  num? confidence,
  String? createdBy,
  Vec? embedding,
}) =>
    Node(
      id: NodeId.generate(),
      typeName: planNodeTypeName,
      createdAt: DateTime.utc(2026, 1, 1),
      embedding: embedding,
      values: <String, Object?>{
        'goal': goal,
        'summary': ?summary,
        'kind': ?kind,
        'status': ?status,
        'confidence': ?confidence,
        'created_by': ?createdBy,
      },
    );

Node _stepNode({
  required String description,
  String? planId,
  int? stepIndex,
  String? title,
  String? intent,
  String? kind,
  String? owner,
  String? successCriterion,
  String? status,
}) =>
    Node(
      id: NodeId.generate(),
      typeName: planStepNodeTypeName,
      createdAt: DateTime.utc(2026, 1, 1),
      values: <String, Object?>{
        'description': description,
        'plan_id': ?planId,
        'step_index': ?stepIndex,
        'title': ?title,
        'intent': ?intent,
        'kind': ?kind,
        'owner': ?owner,
        'success_criterion': ?successCriterion,
        'status': ?status,
      },
    );

void main() {
  group('PlanKind / PlanStatus', () {
    test('every kind round-trips through its token', () {
      for (final k in PlanKind.values) {
        expect(PlanKind.fromToken(k.token), k);
      }
    });

    test('every status round-trips through its token', () {
      for (final s in PlanStatus.values) {
        expect(PlanStatus.fromToken(s.token), s);
      }
    });

    test('unknown tokens throw, never default silently', () {
      expect(() => PlanKind.fromToken('nope'), throwsArgumentError);
      expect(() => PlanStatus.fromToken('nope'), throwsArgumentError);
    });

    test('isOpen is draft|active only', () {
      expect(PlanStatus.draft.isOpen, isTrue);
      expect(PlanStatus.active.isOpen, isTrue);
      expect(PlanStatus.completed.isOpen, isFalse);
      expect(PlanStatus.superseded.isOpen, isFalse);
      expect(PlanStatus.abandoned.isOpen, isFalse);
    });
  });

  group('StepKind / StepStatus', () {
    test('every kind round-trips; external_action carries the snake token', () {
      for (final k in StepKind.values) {
        expect(StepKind.fromToken(k.token), k);
      }
      expect(StepKind.externalAction.token, 'external_action');
    });

    test('every status round-trips; in_progress carries the snake token', () {
      for (final s in StepStatus.values) {
        expect(StepStatus.fromToken(s.token), s);
      }
      expect(StepStatus.inProgress.token, 'in_progress');
    });

    test('unknown tokens throw', () {
      expect(() => StepKind.fromToken('nope'), throwsArgumentError);
      expect(() => StepStatus.fromToken('nope'), throwsArgumentError);
    });

    test('isOpen is pending|in_progress only', () {
      expect(StepStatus.pending.isOpen, isTrue);
      expect(StepStatus.inProgress.isOpen, isTrue);
      expect(StepStatus.succeeded.isOpen, isFalse);
      expect(StepStatus.failed.isOpen, isFalse);
      expect(StepStatus.superseded.isOpen, isFalse);
      expect(StepStatus.skipped.isOpen, isFalse);
    });
  });

  group('PlanView.fromNode', () {
    test('projects every field of a fully-stamped plan', () {
      final embedding = Vec.fromList(<double>[0.1, 0.2]);
      final node = _planNode(
        goal: 'Ship the export feature',
        summary: 'A four-step creation plan.',
        kind: 'creation',
        status: 'active',
        confidence: 0.7,
        createdBy: 'plan_v1',
        embedding: embedding,
      );
      final view = PlanView.fromNode(node);

      expect(view.id, node.id);
      expect(view.goal, 'Ship the export feature');
      expect(view.summary, 'A four-step creation plan.');
      expect(view.kind, PlanKind.creation);
      expect(view.status, PlanStatus.active);
      expect(view.confidence, closeTo(0.7, 1e-9));
      expect(view.createdBy, 'plan_v1');
      expect(view.embedding, embedding);
      expect(view.isOpen, isTrue);
    });

    test('tolerates a node persisted before kind/status stamping', () {
      final view = PlanView.fromNode(_planNode(goal: 'bare goal'));
      expect(view.goal, 'bare goal');
      expect(view.kind, isNull);
      expect(view.status, isNull);
      expect(view.isOpen, isFalse);
    });

    test('throws on the wrong node type and on an unknown token', () {
      final wrong = Node(
        id: NodeId.generate(),
        typeName: 'Claim',
        createdAt: DateTime.utc(2026),
        values: const <String, Object?>{'goal': 'x'},
      );
      expect(() => PlanView.fromNode(wrong), throwsArgumentError);
      expect(
        () => PlanView.fromNode(_planNode(goal: 'g', status: 'bogus')),
        throwsArgumentError,
      );
    });
  });

  group('PlanStepView.fromNode', () {
    test('projects every field of a fully-stamped step', () {
      final node = _stepNode(
        description: 'Write the exporter',
        planId: 'PLN-1',
        stepIndex: 2,
        title: 'Exporter',
        intent: 'A CSV exporter that passes the golden test.',
        kind: 'create',
        owner: 'creation',
        successCriterion: 'golden test passes',
        status: 'pending',
      );
      final view = PlanStepView.fromNode(node);

      expect(view.description, 'Write the exporter');
      expect(view.planId, 'PLN-1');
      expect(view.stepIndex, 2);
      expect(view.title, 'Exporter');
      expect(view.intent, 'A CSV exporter that passes the golden test.');
      expect(view.kind, StepKind.create);
      expect(view.owner, 'creation');
      expect(view.successCriterion, 'golden test passes');
      expect(view.status, StepStatus.pending);
      expect(view.isOpen, isTrue);
    });

    test('tolerates a bare step (description only)', () {
      final view = PlanStepView.fromNode(_stepNode(description: 'do a thing'));
      expect(view.description, 'do a thing');
      expect(view.kind, isNull);
      expect(view.status, isNull);
      expect(view.isOpen, isFalse);
    });

    test('throws on the wrong node type', () {
      expect(
        () => PlanStepView.fromNode(_planNode(goal: 'g')),
        throwsArgumentError,
      );
    });
  });

  group('PlanningEvent', () {
    final at = DateTime.utc(2026, 6, 1, 12);

    test('every leaf kind appears in planningEventKinds, in order', () {
      final leaves = <PlanningEvent>[
        PlanRequested(occurredAt: at, goal: 'g'),
        GoalClassified(occurredAt: at, planKind: PlanKind.research),
        StepsDecomposed(occurredAt: at, stepCount: 3),
        GraphEstimated(occurredAt: at, stepCount: 3, edgeCount: 2),
        PlanCritiqueProduced(occurredAt: at, accepted: false, iteration: 0),
        PlanAccepted(occurredAt: at, stepCount: 3, planId: 'PLN-1'),
        PlanRejected(occurredAt: at, iteration: 0, reason: 'coverage'),
        PlanRevised(occurredAt: at, supersededId: 'a', replacementId: 'b'),
        StepStatusChanged(
          occurredAt: at,
          stepId: 's1',
          to: StepStatus.succeeded,
          from: StepStatus.inProgress,
        ),
      ];
      expect(leaves.map((e) => e.kind).toList(), planningEventKinds);
    });

    test('toJson carries kind + payload and omits null correlation', () {
      final json = StepsDecomposed(occurredAt: at, stepCount: 4).toJson();
      expect(json['kind'], 'planning.steps-decomposed');
      expect(json.containsKey('runId'), isFalse);
      expect((json['payload'] as Map)['stepCount'], 4);
      expect((json['payload'] as Map).containsKey('planId'), isFalse);
    });

    test('planId correlates a triple through the payload', () {
      final accepted =
          PlanAccepted(occurredAt: at, stepCount: 2, planId: 'PLN-9');
      expect((accepted.toJson()['payload'] as Map)['planId'], 'PLN-9');
    });

    test('rejects a non-UTC occurredAt on serialise', () {
      final local = DateTime(2026, 6, 1, 12);
      expect(
        () => PlanRequested(occurredAt: local, goal: 'g').toJson(),
        throwsArgumentError,
      );
    });

    test('StepsDecomposed rejects a negative count', () {
      expect(
        () => StepsDecomposed(occurredAt: at, stepCount: -1),
        throwsArgumentError,
      );
    });
  });
}
