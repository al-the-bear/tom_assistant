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
// The contract has exactly two reachable procedures, reached through two doors:
//
//   - **Selection door** (the dispatcher route). Every inbound resolves to a
//     procedure id through the production `resolveProcedureId`. The only id it
//     ever yields is `answer_with_memory_v1`: a `user_prompt` kind, an absent /
//     blank hint (→ `classify_inbound_v1` → `user_prompt`), and a confident
//     `answer_with_memory_v1` procedure-id hint all land there. Every other
//     signal is rejected loudly (`UnknownProcedureHint` /
//     `UnsupportedProcedureKind`). This door needs no memory — it is pure
//     resolution.
//   - **Sugar-library door** (the `runProcedure` resolver). The sugar verbs map
//     `<verb>` → `<verb>_v1`; the shipped disk library contains exactly one of
//     those five targets — `think_v1`, the no-op stub (`requires: []`). The
//     other four (`plan_v1` / `create_v1` / `critique_v1` / `decide_v1`) are
//     absent, so the verbs surface `ProcedureNotFound` — the library-shape root
//     cause C.40 proves end-to-end through the engine.
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
        ProcedureNotFound,
        ProcedureResolver,
        ProcedureSelector,
        SystemProcedures,
        UnknownProcedureHint,
        UnsupportedProcedureKind,
        classifyInboundV1,
        procedureNotFoundCode,
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
  group('P2.25 selection door — every inbound resolves answer_with_memory_v1',
      () {
    // The selection table: each signal → the one routed procedure id. Null /
    // empty / blank hints are "no hint" (the route trims before testing), so
    // they fall to the classify_inbound_v1 stub → user_prompt → the procedure;
    // a confident (and a padded) procedure-id hint routes directly.
    const cases = <(String label, String? hint)>[
      ('no hint (null)', null),
      ('empty hint', ''),
      ('blank hint', '   '),
      ('confident procedure-id hint', SystemProcedures.answerWithMemoryV1),
      ('padded procedure-id hint', '  answer_with_memory_v1  '),
    ];

    for (final (label, hint) in cases) {
      test('$label → answer_with_memory_v1', () {
        expect(_resolve(hint), SystemProcedures.answerWithMemoryV1);
      });
    }

    // The plan's explicit Verify, called out as its own headline assertion.
    test('VERIFY: a prompt with no hint still resolves answer_with_memory_v1',
        () {
      expect(_resolve(null), 'answer_with_memory_v1',
          reason: 'an un-hinted prompt falls to classify_inbound_v1 → '
              'user_prompt → answer_with_memory_v1');
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
      expect(id, SystemProcedures.answerWithMemoryV1);
    });

    test('a confident hint bypasses the classifier entirely', () {
      var calls = 0;
      final id = _resolve(SystemProcedures.answerWithMemoryV1,
          fallback: (access) {
        calls++;
        return classifyInboundV1(access);
      });

      expect(calls, 0,
          reason: 'a procedure-id hint routes directly; the no-hint '
              'classifier is never consulted (Q-E.50.1)');
      expect(id, SystemProcedures.answerWithMemoryV1);
    });
  });

  group('P2.25 selection door — every other signal is rejected loudly', () {
    test('an unknown procedure-id hint raises UnknownProcedureHint', () {
      expect(
        () => _resolve('background_research'),
        throwsA(isA<UnknownProcedureHint>()
            .having((e) => e.procedureId, 'procedureId', 'background_research')
            .having((e) => e.knownProcedureIds, 'knownProcedureIds',
                <String>[SystemProcedures.answerWithMemoryV1])),
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

  group('P2.25 sugar-library door — only think_v1 is a reachable target', () {
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

    test('the routed procedure answer_with_memory_v1 is shipped', () {
      expect(library.knows(SystemProcedures.answerWithMemoryV1), isTrue,
          reason: 'the one procedure the selection door ever yields must be '
              'present in the reduced library');
    });

    // The library-shape table: the four request-handling sugar verbs map to
    // `<verb>_v1` targets the reduced library does not ship, so resolving them
    // raises an informative ProcedureNotFound — the root cause C.40 proves the
    // verbs surface end-to-end through the engine.
    for (final verb in const <String>['plan', 'create', 'critique', 'decide']) {
      test('$verb resolves to a missing ${verb}_v1 → ProcedureNotFound', () {
        final targetId = sugarAliasProcedureIds[verb]!;
        expect(targetId, '${verb}_v1');
        expect(library.knows(targetId), isFalse,
            reason: 'the reduced library does not ship $targetId');
        expect(
          () => library.resolve(targetId),
          throwsA(isA<ProcedureNotFound>()
              .having((e) => e.id, 'id', targetId)
              .having((e) => e.code, 'code', procedureNotFoundCode)),
        );
      });
    }
  });
}
