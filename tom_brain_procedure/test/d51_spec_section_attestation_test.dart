// D.51 — Phase-D code-review-pass attestation suite.
//
// Plan step D.51 ("Code review pass D1: every file vs. the spec section
// that owns it."). The review pass produced a divergence report (recorded
// in `prototype_implementation_details.md` § D.51); this suite is the
// *sentinel* that pins the review's structural conclusions as code,
// mirroring the Phase-C C.46 spec-section-attestation precedent.
//
// The motivation matches C.46's: each closed set the review confirmed has
// its own per-step test elsewhere (D.49 the event taxonomy, D.48 the log
// categories, D.29/D.30 the fallback triggers, D.31 the sustained-fallback
// threshold, D.16 the routing, D.18/D.47 the queue depth, D.11 the Access
// shape). No single test crosses all of them into one "did the spec drift
// from the code?" attestation for the Phase-D surface. If a future change
// renames a dispatcher event, reorders the log categories, alters a
// fallback wire code, moves the sustained threshold off 3, re-routes
// `user_prompt` away from the entry router, or changes the queue-depth
// default, this suite fails with
// a message that names the spec section.
//
// Drives the package's public barrel + the shared barrel only (no
// `lib/src/` imports), per the plan's "API tests" convention.

import 'package:test/test.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        BrainEvent,
        DeliverCallback,
        InboundKinds,
        InboundRequest,
        OutboundChunk,
        Persona,
        ResolvedIdentity,
        Session;

final DateTime _at = DateTime.utc(2026, 6, 2, 10, 30, 0);

/// One of each `DispatcherEvent` variant — the canonical fixtures § 13
/// names. The exhaustive `switch` below keeps the sum closed.
List<DispatcherEvent> _oneOfEachEvent() => <DispatcherEvent>[
      AccessAccepted(occurredAt: _at, sessionId: 'sess_1', kindHint: 'user_prompt'),
      ProcedureSelected(
          occurredAt: _at,
          inboundKind: 'user_prompt',
          procedureId: 'prompt_analyzer_v1'),
      ForegroundQueued(occurredAt: _at, queueDepth: 1),
      Preempted(occurredAt: _at, runId: 'bg_1'),
      Resumed(occurredAt: _at, runId: 'bg_1'),
      RunCompleted(
          occurredAt: _at,
          runId: 'r_1',
          procedureId: 'answer_with_memory_v1',
          outcome: RunOutcome.completed,
          slot: RunSlot.foreground),
      FallbackTried(
          occurredAt: _at,
          procedureId: 'answer_with_memory_v1',
          fromVersion: 1,
          toVersion: null,
          trigger: FallbackTrigger.runtimeCrash),
    ];

void main() {
  // §13 — dispatcher event taxonomy.
  group('D.51-1: §13 DispatcherEvent sealed-sum closed set', () {
    // Spec § 13: "DispatcherEvent (AccessAccepted, ProcedureSelected,
    // ForegroundQueued, Preempted, Resumed, RunCompleted, FallbackTried)".
    test('the sum stays closed at seven variants', () {
      // Exhaustive switch with no default: adding or removing a leaf breaks
      // compilation, and dropping one fixture fails the length assertion.
      for (final e in _oneOfEachEvent()) {
        final tag = switch (e) {
          AccessAccepted() => 'access-accepted',
          ProcedureSelected() => 'procedure-selected',
          ForegroundQueued() => 'foreground-queued',
          Preempted() => 'preempted',
          Resumed() => 'resumed',
          RunCompleted() => 'run-completed',
          FallbackTried() => 'fallback-tried',
        };
        expect(tag, isNotEmpty);
      }
      expect(_oneOfEachEvent().length, 7);
    });

    test('each variant carries its canonical dispatcher.<name> kind, unique',
        () {
      final kinds = _oneOfEachEvent().map((e) => e.kind).toList(growable: false);
      expect(kinds, <String>[
        'dispatcher.access-accepted',
        'dispatcher.procedure-selected',
        'dispatcher.foreground-queued',
        'dispatcher.preempted',
        'dispatcher.resumed',
        'dispatcher.run-completed',
        'dispatcher.fallback-tried',
      ]);
      expect(kinds.toSet().length, kinds.length, reason: 'kinds must be unique');
      expect(kinds.every((k) => k.startsWith('dispatcher.')), isTrue);
    });

    test('every variant is a BrainEvent (shared observability base)', () {
      for (final e in _oneOfEachEvent()) {
        expect(e, isA<BrainEvent>());
      }
    });
  });

  // §13 — dispatcher logger categories.
  group('D.51-2: §13 DispatcherLog category closed set', () {
    // Spec § 13: "dispatcher — tom_brain.dispatcher.entry, …coordinator,
    // …fallback, …scheduler, …boot".
    const expected = <String>[
      'tom_brain.dispatcher.entry',
      'tom_brain.dispatcher.coordinator',
      'tom_brain.dispatcher.fallback',
      'tom_brain.dispatcher.scheduler',
      'tom_brain.dispatcher.boot',
    ];

    test('exactly the five spec categories, in spec order', () {
      final names = DispatcherLogCategory.values
          .map((c) => c.name)
          .toList(growable: false);
      expect(names, equals(expected));
    });

    test('DispatcherLog.all mirrors the enum 1:1', () {
      expect(DispatcherLog.all.length, DispatcherLogCategory.values.length);
      expect(
        DispatcherLog.all.map((l) => l.category.name).toList(growable: false),
        equals(expected),
      );
    });
  });

  // §10.4 / PE-6 — the four fallback-trigger failure classes.
  group('D.51-3: §10.4 FallbackTrigger closed set', () {
    // Spec § 10.4: "the four typed failure classes (procedure.contract.
    // violation, procedure.critique.rejected, procedure.deadline.exceeded …,
    // procedure.runtime.crash); environmental failures do NOT trigger
    // fallback".
    test('exactly the four spec failure-kind strings, in spec order', () {
      final kinds =
          FallbackTrigger.values.map((t) => t.failureKind).toList(growable: false);
      expect(kinds, <String>[
        'procedure.contract.violation',
        'procedure.critique.rejected',
        'procedure.deadline.exceeded',
        'procedure.runtime.crash',
      ]);
    });

    test('the four kinds are distinct and namespaced under procedure.', () {
      final kinds = FallbackTrigger.values.map((t) => t.failureKind).toSet();
      expect(kinds.length, 4);
      expect(kinds.every((k) => k.startsWith('procedure.')), isTrue);
    });

    test('environmental failures never trigger fallback (PE-6)', () {
      expect(defaultFallbackClassifier(_EnvDown()), isNull);
    });

    test('an unmarked uncaught error classifies as a runtime crash (§14)', () {
      expect(defaultFallbackClassifier(StateError('boom')),
          FallbackTrigger.runtimeCrash);
    });
  });

  // §10.4 — sustained-fallback threshold + window + target stack/node.
  group('D.51-4: §10.4 sustained-fallback constants', () {
    test('the threshold is 3 within a 24 h window', () {
      expect(defaultSustainedFallbackThreshold, 3);
      expect(defaultSustainedFallbackWindow, const Duration(hours: 24));
    });

    test('the idea lands on automation_ideas as an AutomationIdea node', () {
      expect(automationIdeasStackName, 'automation_ideas');
      expect(automationIdeaNodeType, 'AutomationIdea');
    });
  });

  // §10.2 / §4.0.1 — classification + selection routing (route-flip).
  group('D.51-5: §10.2 routing table', () {
    // Spec § 10.2 / § 4.0.1: after the route-flip every inbound classified as
    // user_prompt routes to the entry router prompt_analyzer_v1; the router's
    // two-phase run then selects the answer branch. Anything else surfaces
    // UnsupportedProcedureKind.
    test('the default routing is the single user_prompt entry', () {
      expect(defaultProcedureRouting,
          <String, String>{'user_prompt': 'prompt_analyzer_v1'});
    });

    test('the well-known ids carry their spec spellings', () {
      expect(InboundKinds.userPrompt, 'user_prompt');
      expect(SystemProcedures.promptAnalyzerV1, 'prompt_analyzer_v1');
      expect(SystemProcedures.answerWithMemoryV1, 'answer_with_memory_v1');
    });

    test('user_prompt selects prompt_analyzer_v1', () {
      expect(ProcedureSelector().select(InboundKinds.userPrompt),
          SystemProcedures.promptAnalyzerV1);
    });

    test('any non-user_prompt kind is rejected loudly', () {
      expect(() => ProcedureSelector().select('telegram_command'),
          throwsA(isA<UnsupportedProcedureKind>()));
    });

    // Spec § 10.2 (Q-E.50.1): a confident centroid hint names a *procedure id*
    // and routes directly through resolveHintedProcedure, bypassing the
    // kind → procedure map; an unknown id surfaces UnknownProcedureHint. After
    // the route-flip the only routable id is the entry router.
    test('a confident procedure-id hint routes directly to that procedure',
        () {
      expect(
          ProcedureSelector()
              .resolveHintedProcedure(SystemProcedures.promptAnalyzerV1),
          SystemProcedures.promptAnalyzerV1);
    });

    test('the known-procedure set is the single shipped procedure', () {
      expect(ProcedureSelector().knownProcedureIds,
          <String>[SystemProcedures.promptAnalyzerV1]);
    });

    test('an unknown procedure-id hint is rejected loudly', () {
      expect(() => ProcedureSelector().resolveHintedProcedure('telegram_v1'),
          throwsA(isA<UnknownProcedureHint>()));
    });

    test('the unknown-procedure-hint wire code carries its spec spelling', () {
      expect(unknownProcedureHintCode, 'procedure.hint.unknown');
    });
  });

  // §10.3 / §13 — foreground queue depth default agrees across runtime/config.
  group('D.51-6: §10.3 foreground queue-depth default', () {
    test('the config default is 1000000 (effectively unlimited)', () {
      expect(defaultForegroundQueueDepth, 1000000);
      expect(DispatcherConfig().foregroundQueueDepth, 1000000);
    });

    test('a default RunCoordinator honours the same depth', () {
      // The coordinator constructor defaults to 1000000 (§ 10.3); a config
      // built from defaults must not silently disagree with it.
      expect(RunCoordinator().foregroundQueueDepth, 1000000);
    });
  });

  // §13 — DispatcherConfig non-queue defaults.
  group('D.51-7: §13 DispatcherConfig defaults', () {
    test('the hard step deadline default is 24 h + 5 s and the scheduler is off',
        () {
      final cfg = DispatcherConfig();
      expect(cfg.hardStepDeadline, const Duration(hours: 24, seconds: 5));
      expect(cfg.schedulerEnabled, isFalse);
    });
  });

  // §10.1 — the Access shape shared by Phases D + E.
  group('D.51-8: §10.1 Access shape', () {
    Stream<OutboundChunk> deliver(OutboundChunk chunk) =>
        Stream<OutboundChunk>.value(chunk);

    Access build() => Access(
          envelope: InboundRequest(text: 'hello', kindHint: 'user_prompt'),
          identity: ResolvedIdentity(principalId: 'user_1'),
          session: Session(sessionId: 'sess_1'),
          persona: Persona.assistant(),
          deliver: deliver,
        );

    test('all five fields carry their declared types (§ 10.1 / def § 1.5)', () {
      final access = build();
      // Each assignment is a compile-time pin: a field-type change in
      // tom_brain_shared breaks this test's compilation.
      final InboundRequest envelope = access.envelope;
      final ResolvedIdentity identity = access.identity;
      final Session session = access.session;
      final Persona persona = access.persona;
      final DeliverCallback deliverFn = access.deliver;
      expect(envelope, isA<InboundRequest>());
      expect(identity, isA<ResolvedIdentity>());
      expect(session, isA<Session>());
      expect(persona, isA<Persona>());
      expect(deliverFn, isA<DeliverCallback>());
    });

    test('deliver returns a Stream<OutboundChunk> (§ 10.1)', () {
      final access = build();
      final stream = access.deliver(OutboundChunk(textDelta: 'hi'));
      expect(stream, isA<Stream<OutboundChunk>>());
    });
  });
}

/// An environmental failure (substrate-down / network / billing) — PE-6
/// says these never step the fallback chain.
class _EnvDown implements EnvironmentalFailure {}
