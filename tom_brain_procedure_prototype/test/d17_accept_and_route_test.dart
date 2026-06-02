// Accept-and-route integration tests (Plan step D.17;
// `tom_brain_procedure_prototype_specification.md` § 10.1–10.2).
//
// D.14–D.16 landed the three dispatcher pipeline stages as standalone,
// independently tested units:
//
//   - D.14 — `Dispatcher.accept(Access)` entry surface (admit → observe →
//     route, over an injected `DispatchRoute`).
//   - D.15 — `InboundClassifier.classify(Access)` (kind-hint pass-through +
//     `classify_inbound_v1` fallback).
//   - D.16 — `ProcedureSelector.select(kind)` (`user_prompt` →
//     `answer_with_memory_v1`; else `UnsupportedProcedureKind`).
//
// D.17 is the *integration* step the plan calls for: prove the three stages
// compose correctly through the single entry point. The real coordinator
// (`RunCoordinator`, D.18) does not exist yet, so the schedule stage is a
// fake that records the resolved procedure id — exactly the seam the
// coordinator will fill (Q-D.14.1). The route built here is the
// `classify → select → schedule` chain `Dispatcher.accept` hands an
// admitted access to.
//
// The two contracts D.17 pins (Plan D.17 verbatim):
//
//   1. "accept-and-route succeeds for `user_prompt`" — an inbound carrying
//      a `user_prompt` hint, and an un-hinted inbound (fallback →
//      `user_prompt`), both reach the schedule stage with
//      `answer_with_memory_v1`.
//   2. "unknown kinds rejected loudly" — an inbound carrying any other kind
//      raises `UnsupportedProcedureKind`, the error propagates *unchanged*
//      through `accept` (the D.14 failure-propagation contract), the
//      schedule stage never runs, and nothing is delivered back to the
//      channel.

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show
        Dispatcher,
        InboundClassifier,
        ProcedureSelector,
        SystemProcedures,
        UnsupportedProcedureKind;
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

/// Records every chunk a route is asked to deliver, so the unknown-kind
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

/// Builds a [Dispatcher] whose route is the real `classify → select →
/// schedule` chain: the D.15 classifier and D.16 selector wired together,
/// with [schedule] standing in for the D.18 coordinator.
///
/// This mirrors how the production wiring (D.18+) composes the stages behind
/// the `DispatchRoute` seam (Q-D.14.1); D.17 exercises that composition
/// through the single `Dispatcher.accept` entry point.
Dispatcher _wiredDispatcher({
  required _RecordingSchedule schedule,
  void Function(Access)? onAccepted,
}) {
  final classifier = InboundClassifier();
  final selector = ProcedureSelector();
  return Dispatcher(
    onAccepted: onAccepted,
    route: (access) async {
      final kind = classifier.classify(access);
      final procedureId = selector.select(kind);
      await schedule(procedureId, access);
    },
  );
}

void main() {
  group('D.17 accept-and-route — succeeds for user_prompt', () {
    test('an explicit user_prompt hint routes to answer_with_memory_v1',
        () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await dispatcher.accept(_accessWith(kindHint: InboundKinds.userPrompt));

      expect(schedule.scheduled,
          <String>[SystemProcedures.answerWithMemoryV1],
          reason: 'classify (user_prompt) → select (answer_with_memory_v1) → '
              'schedule, end to end through accept');
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

    test('a whitespace-only hint is treated as absent and still routes',
        () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await dispatcher.accept(_accessWith(kindHint: '   '));

      expect(schedule.scheduled,
          <String>[SystemProcedures.answerWithMemoryV1],
          reason: 'a blank hint is no hint; fallback → user_prompt → '
              'answer_with_memory_v1');
    });

    test('a padded user_prompt hint is trimmed before selection', () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await dispatcher.accept(_accessWith(kindHint: '  user_prompt  '));

      expect(schedule.scheduled,
          <String>[SystemProcedures.answerWithMemoryV1],
          reason: 'the classifier trims the hint so selection sees the '
              'canonical kind, not an unsupported padded variant');
    });

    test('admission is observed before the route schedules', () async {
      final order = <String>[];
      final schedule = _RecordingSchedule();
      final classifier = InboundClassifier();
      final selector = ProcedureSelector();
      final dispatcher = Dispatcher(
        onAccepted: (_) => order.add('observed'),
        route: (access) async {
          final kind = classifier.classify(access);
          final id = selector.select(kind);
          order.add('routed');
          await schedule(id, access);
        },
      );

      await dispatcher.accept(_accessWith(kindHint: InboundKinds.userPrompt));

      expect(order, <String>['observed', 'routed'],
          reason: 'the entry observation fires before any pipeline work');
      expect(schedule.scheduled,
          <String>[SystemProcedures.answerWithMemoryV1]);
    });

    test('successive prompts route independently in order', () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await dispatcher.accept(_accessWith(text: 'first'));
      await dispatcher.accept(
          _accessWith(text: 'second', kindHint: InboundKinds.userPrompt));

      expect(schedule.scheduled, <String>[
        SystemProcedures.answerWithMemoryV1,
        SystemProcedures.answerWithMemoryV1,
      ]);
    });
  });

  group('D.17 accept-and-route — unknown kinds rejected loudly', () {
    test('an unknown kind raises UnsupportedProcedureKind through accept',
        () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await expectLater(
        dispatcher.accept(_accessWith(kindHint: 'background_research')),
        throwsA(isA<UnsupportedProcedureKind>()),
        reason: 'selection rejects a non-routed kind and the error '
            'propagates unchanged through accept (D.14 contract)',
      );
    });

    test('the rejection names the offending kind and the supported set',
        () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await expectLater(
        dispatcher.accept(_accessWith(kindHint: 'mystery_kind')),
        throwsA(
          isA<UnsupportedProcedureKind>()
              .having((e) => e.kind, 'kind', 'mystery_kind')
              .having((e) => e.supportedKinds, 'supportedKinds',
                  <String>[InboundKinds.userPrompt])
              .having((e) => e.toString(), 'toString',
                  contains('mystery_kind')),
        ),
      );
    });

    test('the schedule stage never runs for an unknown kind', () async {
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await expectLater(
        dispatcher.accept(_accessWith(kindHint: 'unsupported')),
        throwsA(isA<UnsupportedProcedureKind>()),
      );

      expect(schedule.scheduled, isEmpty,
          reason: 'rejection happens at selection, before scheduling');
    });

    test('a rejected request streams nothing back to the channel', () async {
      final deliver = _RecordingDeliver();
      final schedule = _RecordingSchedule();
      final dispatcher = _wiredDispatcher(schedule: schedule);

      await expectLater(
        dispatcher.accept(
            _accessWith(kindHint: 'unsupported', deliver: deliver.call)),
        throwsA(isA<UnsupportedProcedureKind>()),
      );

      expect(deliver.chunks, isEmpty,
          reason: 'a loud rejection delivers no answer to the channel');
    });

    test('admission is still observed even when the kind is rejected',
        () async {
      final observed = <Access>[];
      final schedule = _RecordingSchedule();
      final classifier = InboundClassifier();
      final selector = ProcedureSelector();
      final dispatcher = Dispatcher(
        onAccepted: observed.add,
        route: (access) async {
          final kind = classifier.classify(access);
          final id = selector.select(kind);
          await schedule(id, access);
        },
      );

      await expectLater(
        dispatcher.accept(_accessWith(kindHint: 'unsupported')),
        throwsA(isA<UnsupportedProcedureKind>()),
      );

      expect(observed, hasLength(1),
          reason: 'the entry observation fires before the route rejects');
    });
  });
}
