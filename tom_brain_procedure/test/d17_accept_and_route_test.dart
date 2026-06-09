// Accept-and-route integration tests (Plan step D.17;
// `tom_brain_procedure_specification.md` § 10.1–10.2; Q-E.50.1).
//
// D.14–D.16 landed the dispatcher pipeline stages as standalone, independently
// tested units:
//
//   - D.14 — `Dispatcher.accept(Access)` entry surface (admit → observe →
//     route, over an injected `DispatchRoute`).
//   - D.15 — `InboundClassifier.classify(Access)` (the no-hint
//     `classify_inbound_v1` fallback).
//   - D.16 — `ProcedureSelector` (two doors: `select(kind)` and
//     `resolveHintedProcedure(id)`).
//
// D.17 is the *integration* step the plan calls for: prove the stages compose
// correctly through the single entry point, via the one route-resolution
// function `resolveProcedureId` (Q-E.50.1) that production and these tests
// share. The real coordinator (`RunCoordinator`, D.18) does not exist yet, so
// the schedule stage is a fake that records the resolved procedure id —
// exactly the seam the coordinator will fill (Q-D.14.1).
//
// The two contracts D.17 pins:
//
//   1. "accept-and-route succeeds" — an inbound carrying a confident
//      `answer_with_memory_v1` procedure-id hint (routed directly) and an
//      un-hinted inbound (fallback → `user_prompt` → `answer_with_memory_v1`)
//      both reach the schedule stage with `answer_with_memory_v1`.
//   2. "unknown routes rejected loudly" — an inbound carrying an unknown
//      procedure-id hint raises `UnknownProcedureHint`; a no-hint inbound the
//      fallback classifies as an unknown kind raises
//      `UnsupportedProcedureKind`. Both propagate *unchanged* through `accept`
//      (the D.14 failure-propagation contract), the schedule stage never
//      runs, and nothing is delivered back to the channel.

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        Dispatcher,
        InboundClassifier,
        ProcedureSelector,
        SystemProcedures,
        UnknownProcedureHint,
        UnsupportedProcedureKind,
        resolveProcedureId;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        DeliverCallback,
        InboundKinds,
        InboundRequest,
        OutboundChunk,
        Persona,
        ResolvedIdentity,
        Session;

/// Records every chunk a route is asked to deliver, so the unknown-route
/// tests can prove a rejected request streams *nothing* back to the channel.
class _RecordingDeliver {
  final List<OutboundChunk> chunks = <OutboundChunk>[];

  Stream<OutboundChunk> call(OutboundChunk chunk) {
    chunks.add(chunk);
    return Stream<OutboundChunk>.value(chunk);
  }
}

/// Records the procedure ids the schedule stage was handed, standing in for
/// the D.18 `RunCoordinator.submitForeground` the route will eventually call.
class _RecordingSchedule {
  final List<String> scheduled = <String>[];

  Future<void> call(String procedureId, Access access) async {
    scheduled.add(procedureId);
  }
}

Access _accessWith({
  String text = 'what is the time?',
  String? kindHint,
  DeliverCallback? deliver,
}) =>
    Access(
      envelope: InboundRequest(text: text, kindHint: kindHint),
      identity: ResolvedIdentity(principalId: 'p1'),
      session: Session(sessionId: 's1'),
      persona: Persona.assistant(),
      deliver: deliver ?? (chunk) => Stream<OutboundChunk>.value(chunk),
    );

/// Builds a [Dispatcher] whose route is the real `resolveProcedureId →
/// schedule` chain: the D.15 classifier and D.16 selector wired together
/// through the production route-resolution function, with [schedule] standing
/// in for the D.18 coordinator.
///
/// This mirrors how the production wiring (`BrainProcessBoot._buildRoute`)
/// composes the stages behind the `DispatchRoute` seam (Q-D.14.1) — it calls
/// the *same* `resolveProcedureId`, so the two cannot drift.
Dispatcher _wiredDispatcher({
  required _RecordingSchedule schedule,
  void Function(Access)? onAccepted,
  InboundClassifier? classifier,
}) {
  final theClassifier = classifier ?? InboundClassifier();
  final selector = ProcedureSelector();
  return Dispatcher(
    onAccepted: onAccepted,
    route: (access) async {
      final procedureId = resolveProcedureId(
        access,
        classifier: theClassifier,
        selector: selector,
      );
      await schedule(procedureId, access);
    },
  );
}

void main() {
  group('D.17 accept-and-route — succeeds', () {
    test('a confident procedure-id hint routes directly to that procedure',
        () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await dispatcher.accept(
          _accessWith(kindHint: SystemProcedures.answerWithMemoryV1));

      expect(schedule.scheduled,
          <String>[SystemProcedures.answerWithMemoryV1],
          reason: 'a centroid procedure-id hint routes directly through '
              'resolveHintedProcedure, end to end through accept');
    });

    test('an un-hinted inbound falls back to user_prompt and routes the same',
        () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      // No kindHint: the classifier's classify_inbound_v1 fallback yields
      // user_prompt, which selection routes to answer_with_memory_v1.
      await dispatcher.accept(_accessWith());

      expect(schedule.scheduled,
          <String>[SystemProcedures.answerWithMemoryV1]);
    });

    test('a whitespace-only hint is treated as absent and falls back',
        () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await dispatcher.accept(_accessWith(kindHint: '   '));

      expect(schedule.scheduled,
          <String>[SystemProcedures.answerWithMemoryV1],
          reason: 'a blank hint is no hint; fallback → user_prompt → '
              'answer_with_memory_v1');
    });

    test('a padded procedure-id hint is trimmed before routing', () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await dispatcher.accept(_accessWith(kindHint: '  answer_with_memory_v1  '));

      expect(schedule.scheduled,
          <String>[SystemProcedures.answerWithMemoryV1],
          reason: 'the route trims the hint before matching the procedure id');
    });

    test('admission is observed before the route schedules', () async {
      final order = <String>[];
      final schedule = _RecordingSchedule();
      final classifier = InboundClassifier();
      final selector = ProcedureSelector();
      final dispatcher = Dispatcher(
        onAccepted: (_) => order.add('observed'),
        route: (access) async {
          final id = resolveProcedureId(access,
              classifier: classifier, selector: selector);
          order.add('routed');
          await schedule(id, access);
        },
      );

      await dispatcher.accept(
          _accessWith(kindHint: SystemProcedures.answerWithMemoryV1));

      expect(order, <String>['observed', 'routed'],
          reason: 'the entry observation fires before any pipeline work');
      expect(schedule.scheduled,
          <String>[SystemProcedures.answerWithMemoryV1]);
    });

    test('successive prompts route independently in order', () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await dispatcher.accept(_accessWith(text: 'first'));
      await dispatcher.accept(_accessWith(
          text: 'second', kindHint: SystemProcedures.answerWithMemoryV1));

      expect(schedule.scheduled, <String>[
        SystemProcedures.answerWithMemoryV1,
        SystemProcedures.answerWithMemoryV1,
      ]);
    });
  });

  group('D.17 accept-and-route — unknown routes rejected loudly', () {
    test('an unknown procedure-id hint raises UnknownProcedureHint through '
        'accept', () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await expectLater(
        dispatcher.accept(_accessWith(kindHint: 'background_research')),
        throwsA(isA<UnknownProcedureHint>()),
        reason: 'the hint names no shipped procedure and the error '
            'propagates unchanged through accept (D.14 contract)',
      );
    });

    test('the rejection names the offending hint and the known set', () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await expectLater(
        dispatcher.accept(_accessWith(kindHint: 'mystery_procedure')),
        throwsA(
          isA<UnknownProcedureHint>()
              .having((e) => e.procedureId, 'procedureId', 'mystery_procedure')
              .having((e) => e.knownProcedureIds, 'knownProcedureIds',
                  <String>[SystemProcedures.answerWithMemoryV1])
              .having((e) => e.toString(), 'toString',
                  contains('mystery_procedure')),
        ),
      );
    });

    test('a no-hint inbound the fallback maps to an unknown kind raises '
        'UnsupportedProcedureKind', () async {
      final schedule = _RecordingSchedule();
      // The no-hint door: a fallback emitting a kind the selector cannot map.
      final dispatcher = _wiredDispatcher(
        schedule: schedule,
        classifier: InboundClassifier(fallback: (_) => 'mystery_kind'),
      );

      await expectLater(
        dispatcher.accept(_accessWith()),
        throwsA(
          isA<UnsupportedProcedureKind>()
              .having((e) => e.kind, 'kind', 'mystery_kind')
              .having((e) => e.supportedKinds, 'supportedKinds',
                  <String>[InboundKinds.userPrompt]),
        ),
      );
    });

    test('the schedule stage never runs for an unknown hint', () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await expectLater(
        dispatcher.accept(_accessWith(kindHint: 'unsupported_procedure')),
        throwsA(isA<UnknownProcedureHint>()),
      );

      expect(schedule.scheduled, isEmpty,
          reason: 'rejection happens at routing, before scheduling');
    });

    test('a rejected request streams nothing back to the channel', () async {
      final deliver = _RecordingDeliver();
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await expectLater(
        dispatcher.accept(_accessWith(
            kindHint: 'unsupported_procedure', deliver: deliver.call)),
        throwsA(isA<UnknownProcedureHint>()),
      );

      expect(deliver.chunks, isEmpty,
          reason: 'a loud rejection delivers no answer to the channel');
    });

    test('admission is still observed even when the route is rejected',
        () async {
      final observed = <Access>[];
      final schedule = _RecordingSchedule();
      final classifier = InboundClassifier();
      final selector = ProcedureSelector();
      final dispatcher = Dispatcher(
        onAccepted: observed.add,
        route: (access) async {
          final id = resolveProcedureId(access,
              classifier: classifier, selector: selector);
          await schedule(id, access);
        },
      );

      await expectLater(
        dispatcher.accept(_accessWith(kindHint: 'unsupported_procedure')),
        throwsA(isA<UnknownProcedureHint>()),
      );

      expect(observed, hasLength(1),
          reason: 'the entry observation fires before the route rejects');
    });
  });
}
