// P2.25 — the dispatcher's *reduced selection contract* as one table.
//
// prototype_implementation_plan_2.md #25:
//   "Procedure dispatcher: confirm the reduced selection contract.
//    `user_prompt` → `answer_with_memory_v1`; confident `kindHint` resolves
//    directly; absent hint falls to the `classify_inbound_v1` stub;
//    request-handling sugar verbs (`plan`, `create`, `critique`, `decide`)
//    throw an informative `ProcedureNotFound`; `think_v1` is a no-op. Test:
//    selection table tests for each branch. Verify: a prompt with no hint
//    still resolves `answer_with_memory_v1`."
//
// ── Why this is not d15–d17 / C.40 again ────────────────────────────────
//
// Each branch is already proven in isolation: d15 pins the no-hint
// `classify_inbound_v1` stub, d16 the selector's two doors, d17 the route
// composition, and C.40 (`sugar_aliases_test.dart`) the engine-level sugar
// runtime. #25 is the *confirmation* step — like d42 (consolidated body) and
// d51 (closed-set attestation): it asserts those branches compose into the one
// reduced contract the prototype actually ships, as a single table.
//
// The contract is reached through two doors:
//
//   - **Selection door** (the dispatcher route). Every inbound resolves to a
//     procedure id through the production `resolveProcedureId`. After the
//     § 4.0.1 route-flip the only id it ever yields is `prompt_analyzer_v1`
//     (the entry router): a `user_prompt` kind, an absent / blank hint (→
//     `classify_inbound_v1` → `user_prompt`), and a confident
//     `prompt_analyzer_v1` procedure-id hint all land there. The answer
//     branches (`answer_with_memory_v1` / `answer_with_thinking_v1`) are no
//     longer reachable through this door — the two-phase route runs whichever
//     one the router selects. Every other signal is rejected loudly
//     (`UnknownProcedureHint` / `UnsupportedProcedureKind`). This door needs no
//     memory — it is pure resolution.
//   - **Sugar-library door** (the `runProcedure` resolver). The sugar verbs map
//     `<verb>` → `<verb>_v1`; the shipped disk library contains all five of
//     those targets. `think_v1` is the no-op stub (`requires: []`); the other
//     four (`plan_v1` / `create_v1` / `critique_v1` / `decide_v1`) are
//     clear-error stubs (Todo 4 / G-PR6) that resolve and validate — declaring
//     `requires: [notImplemented]` — but throw `ProcedureNotImplemented` when
//     *run*, until Todos 8/9 land the real loops. The throw-at-run behaviour is
//     proven end-to-end in `g_pr_stub_verbs_and_tool_surface_test.dart`; this
//     door is a *library-shape* confirmation, so it asserts only that all five
//     targets resolve.
//
// No store, no substrate, no engine run: this is a *selection / library-shape*
// confirmation, so it drives the two production resolution surfaces directly.

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        ClassifyFallback,
        DiskProcedureStore,
        InboundClassifier,
        ProcedureResolver,
        ProcedureSelector,
        SystemProcedures,
        UnknownProcedureHint,
        UnsupportedProcedureKind,
        classifyInboundV1,
        resolveProcedureId,
        sugarAliasProcedureIds;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        InboundKinds,
        InboundRequest,
        OutboundChunk,
        Persona,
        ResolvedIdentity,
        Session;

/// A minimal admitted [Access] carrying [kindHint] (the only field selection
/// reads). The prompt body is irrelevant to selection — the classifier stub
/// ignores it (d15) — so a fixed text suffices.
Access _accessWith({String? kindHint}) => Access(
      envelope: InboundRequest(text: 'how do I configure the bomber?',
          kindHint: kindHint),
      identity: ResolvedIdentity(principalId: 'p1'),
      session: Session(sessionId: 's1'),
      persona: Persona.assistant(),
      deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
    );

/// Resolves [kindHint] through the *production* route function — the same
/// `resolveProcedureId` `BrainProcessBoot._buildRoute` wires behind
/// `Dispatcher.accept` (Q-E.50.1), so this table cannot drift from production.
/// [fallback] overrides the no-hint classifier when a branch needs to observe
/// or perturb it.
String _resolve(String? kindHint, {ClassifyFallback? fallback}) =>
    resolveProcedureId(
      _accessWith(kindHint: kindHint),
      classifier: fallback == null
          ? InboundClassifier()
          : InboundClassifier(fallback: fallback),
      selector: ProcedureSelector(),
    );

void main() {
  group('P2.25 selection door — every inbound resolves prompt_analyzer_v1',
      () {
    // The selection table: each signal → the one routed procedure id. Null /
    // empty / blank hints are "no hint" (the route trims before testing), so
    // they fall to the classify_inbound_v1 stub → user_prompt → the entry
    // router; a confident (and a padded) procedure-id hint routes directly.
    const cases = <(String label, String? hint)>[
      ('no hint (null)', null),
      ('empty hint', ''),
      ('blank hint', '   '),
      ('confident procedure-id hint', SystemProcedures.promptAnalyzerV1),
      ('padded procedure-id hint', '  prompt_analyzer_v1  '),
    ];

    for (final (label, hint) in cases) {
      test('$label → prompt_analyzer_v1', () {
        expect(_resolve(hint), SystemProcedures.promptAnalyzerV1);
      });
    }

    // The plan's explicit Verify, called out as its own headline assertion.
    // After the § 4.0.1 route-flip the entry router is what an un-hinted
    // prompt resolves to; the router then selects the answer branch.
    test('VERIFY: a prompt with no hint still resolves the entry router',
        () {
      expect(_resolve(null), 'prompt_analyzer_v1',
          reason: 'an un-hinted prompt falls to classify_inbound_v1 → '
              'user_prompt → prompt_analyzer_v1');
    });
  });

  group('P2.25 selection door — the no-hint branch runs classify_inbound_v1',
      () {
    test('the classify_inbound_v1 stub verdict is user_prompt', () {
      // The stub itself: every un-hinted inbound is a plain user prompt.
      expect(classifyInboundV1(_accessWith()), InboundKinds.userPrompt);
    });

    test('an un-hinted inbound invokes the no-hint classifier exactly once',
        () {
      var calls = 0;
      final id = _resolve(null, fallback: (access) {
        calls++;
        return classifyInboundV1(access);
      });

      expect(calls, 1,
          reason: 'no hint ⇒ the route falls through to the classifier stub');
      expect(id, SystemProcedures.promptAnalyzerV1);
    });

    test('a confident hint bypasses the classifier entirely', () {
      var calls = 0;
      final id = _resolve(SystemProcedures.promptAnalyzerV1,
          fallback: (access) {
        calls++;
        return classifyInboundV1(access);
      });

      expect(calls, 0,
          reason: 'a procedure-id hint routes directly; the no-hint '
              'classifier is never consulted (Q-E.50.1)');
      expect(id, SystemProcedures.promptAnalyzerV1);
    });
  });

  group('P2.25 selection door — every other signal is rejected loudly', () {
    test('an unknown procedure-id hint raises UnknownProcedureHint', () {
      expect(
        () => _resolve('background_research'),
        throwsA(isA<UnknownProcedureHint>()
            .having((e) => e.procedureId, 'procedureId', 'background_research')
            .having((e) => e.knownProcedureIds, 'knownProcedureIds',
                <String>[SystemProcedures.promptAnalyzerV1])),
      );
    });

    test('a no-hint inbound classified to an unknown kind raises '
        'UnsupportedProcedureKind', () {
      expect(
        () => _resolve(null, fallback: (_) => 'mystery_kind'),
        throwsA(isA<UnsupportedProcedureKind>()
            .having((e) => e.kind, 'kind', 'mystery_kind')
            .having((e) => e.supportedKinds, 'supportedKinds',
                <String>[InboundKinds.userPrompt])),
      );
    });
  });

  group('P2.25 sugar-library door — all five sugar targets are shipped', () {
    // The shipped system library, resolved through the real disk store +
    // resolver path — the same surface the engine's `runProcedure` resolves
    // against. Built once: resolution is a pure function of a fixed index.
    late ProcedureResolver library;

    setUpAll(() async {
      library = await ProcedureResolver.fromStore(
        DiskProcedureStore(systemDir: Directory('scripts/system')),
      );
    });

    test('the sugar verb → procedure-id map is exactly the five spec verbs',
        () {
      expect(
        sugarAliasProcedureIds,
        equals(<String, String>{
          'think': 'think_v1',
          'plan': 'plan_v1',
          'create': 'create_v1',
          'critique': 'critique_v1',
          'decide': 'decide_v1',
        }),
      );
    });

    test('think_v1 is shipped and is a no-op (requires nothing)', () {
      expect(library.knows('think_v1'), isTrue);
      final think = library.resolve('think_v1');
      expect(think.header.version, 1);
      expect(think.header.requires, isEmpty,
          reason: 'a no-op stub touches no primitive');
    });

    test('the routed entry router prompt_analyzer_v1 is shipped', () {
      expect(library.knows(SystemProcedures.promptAnalyzerV1), isTrue,
          reason: 'the one procedure the selection door ever yields must be '
              'present in the reduced library');
    });

    test('both answer branches the router selects are shipped', () {
      expect(library.knows(SystemProcedures.answerWithMemoryV1), isTrue,
          reason: 'the normal branch the router can select must be present');
      expect(library.knows(SystemProcedures.answerWithThinkingV1), isTrue,
          reason: 'the thinking branch the router can select must be present');
    });

    // The library-shape table: the two not-yet-real request-handling sugar
    // verbs map to `<verb>_v1` clear-error stubs (Todo 4 / G-PR6) the reduced
    // library ships. Each resolves cleanly to a version-1 procedure declaring
    // exactly `requires: [notImplemented]`; the throw-at-run
    // (`ProcedureNotImplemented`, never `ProcedureNotFound`) is proven through
    // the engine in `g_pr_stub_verbs_and_tool_surface_test.dart`. This door
    // confirms only the library shape: the target is present and validatable.
    // `create` is no longer here — `create_v1` ships as a real creation loop
    // (Todo 9). `plan` is no longer here either — `plan_v1` ships as the real
    // planning loop (Todo 8); both are covered separately below and by
    // `f_create_loop_test.dart` / `plan_v1_test.dart`.
    for (final verb in const <String>['critique', 'decide']) {
      test('$verb resolves to a shipped ${verb}_v1 clear-error stub', () {
        final targetId = sugarAliasProcedureIds[verb]!;
        expect(targetId, '${verb}_v1');
        expect(library.knows(targetId), isTrue,
            reason: 'the reduced library ships $targetId as a clear-error stub');
        final stub = library.resolve(targetId);
        expect(stub.header.version, 1);
        expect(stub.header.requires, <String>['notImplemented'],
            reason: 'a clear-error stub touches exactly the notImplemented '
                'primitive that builds the § 5.2.1 message');
      });
    }

    test('create_v1 resolves to a shipped real creation loop, not a stub', () {
      final targetId = sugarAliasProcedureIds['create']!;
      expect(targetId, 'create_v1');
      expect(library.knows(targetId), isTrue);
      final create = library.resolve(targetId);
      expect(create.header.version, 1);
      // The real loop touches the creation primitive set — never the
      // `notImplemented` clear-error primitive (Todo 9).
      expect(create.header.requires, isNot(contains('notImplemented')),
          reason: 'create_v1 is the real creation loop, not a clear-error stub');
    });

    test('plan_v1 resolves to a shipped real planning loop, not a stub', () {
      final targetId = sugarAliasProcedureIds['plan']!;
      expect(targetId, 'plan_v1');
      expect(library.knows(targetId), isTrue);
      final plan = library.resolve(targetId);
      expect(plan.header.version, 1);
      // The real loop touches the planning primitive set (recall / run /
      // runProcedure / embed / persist / edge / note) — never the
      // `notImplemented` clear-error primitive (Todo 8). The LLM stages run
      // through `sub.run('assist_user.plan.*')`, so the surface declares
      // `run` + `runProcedure` rather than the pre-§12.8 `llm` primitive.
      expect(plan.header.requires, isNot(contains('notImplemented')),
          reason: 'plan_v1 is the real planning loop, not a clear-error stub');
      expect(plan.header.requires.toSet(), <String>{
        'recall',
        'run',
        'runProcedure',
        'embed',
        'persist',
        'edge',
        'note',
      });
    });
  });
}
