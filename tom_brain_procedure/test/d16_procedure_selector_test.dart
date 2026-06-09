// Procedure-selection tests (Plan step D.16; spec § 10.2).
//
// D.16 delivers `ProcedureSelector` — stage three of the dispatcher's
// `accept → classify → select → schedule` pipeline. After Q-E.50.1 the
// selector owns *two* doors into one closed procedure set. These tests pin
// both in isolation:
//
//   1. The no-hint door (`select(kind)`): `user_prompt` →
//      `prompt_analyzer_v1`; any other kind raises
//      `UnsupportedProcedureKind`, naming the offender + the supported set.
//   2. The confident-hint door (`resolveHintedProcedure(id)`): a procedure-id
//      hint that names a shipped procedure routes directly (trimmed); an
//      unknown id raises `UnknownProcedureHint`. The kind → procedure map is
//      not consulted.
//   3. The routing table is injectable + defensively copied.
//
// Route-flip (Todo 6 / § 4.0.1). `user_prompt` now routes to the entry
// router `prompt_analyzer_v1`, not directly to an answer branch. The answer
// branches (`answer_with_memory_v1`, `answer_with_thinking_v1`) are
// reachable *only* through the router's two-phase dispatch — they are never
// a routing target the selector returns. So the selector's one routed
// procedure id is `prompt_analyzer_v1`.

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        ProcedureSelector,
        SystemProcedures,
        UnknownProcedureHint,
        UnsupportedProcedureKind,
        defaultProcedureRouting;
import 'package:tom_brain_shared/tom_brain_shared.dart' show InboundKinds;

void main() {
  group('D.16 selection — accept and route', () {
    test('user_prompt routes to the entry router prompt_analyzer_v1', () {
      final selector = ProcedureSelector();

      expect(
        selector.select(InboundKinds.userPrompt),
        SystemProcedures.promptAnalyzerV1,
      );
    });

    test('SystemProcedures spellings match the spec', () {
      expect(SystemProcedures.promptAnalyzerV1, 'prompt_analyzer_v1');
      expect(SystemProcedures.answerWithMemoryV1, 'answer_with_memory_v1');
      expect(SystemProcedures.answerWithThinkingV1, 'answer_with_thinking_v1');
    });

    test('the default routing is the single router entry', () {
      expect(defaultProcedureRouting, <String, String>{
        'user_prompt': 'prompt_analyzer_v1',
      });
    });

    test('supportedKinds reports the one routed kind', () {
      expect(ProcedureSelector().supportedKinds, <String>['user_prompt']);
    });
  });

  group('D.16 selection — confident-hint door (Q-E.50.1)', () {
    test('a procedure-id hint that names a shipped procedure routes directly',
        () {
      final selector = ProcedureSelector();

      // The hint IS the procedure id (the centroid bestMatch), not a kind —
      // it routes without ever touching the kind → procedure map. The one
      // routable procedure is the entry router.
      expect(
        selector.resolveHintedProcedure(SystemProcedures.promptAnalyzerV1),
        SystemProcedures.promptAnalyzerV1,
      );
    });

    test('the hint is trimmed before it is matched', () {
      expect(
        ProcedureSelector().resolveHintedProcedure('  prompt_analyzer_v1\n'),
        SystemProcedures.promptAnalyzerV1,
      );
    });

    test('knownProcedureIds reports the shipped procedure set', () {
      expect(ProcedureSelector().knownProcedureIds,
          <String>[SystemProcedures.promptAnalyzerV1]);
    });

    test('an answer branch is not a routable hint — it is rejected', () {
      // The answer branches are reachable only via the router's two-phase
      // dispatch (§ 4.0.1); a centroid hint that names one is therefore not a
      // routing target and is rejected loudly.
      final selector = ProcedureSelector();

      expect(
        () => selector
            .resolveHintedProcedure(SystemProcedures.answerWithMemoryV1),
        throwsA(isA<UnknownProcedureHint>()),
      );
    });

    test('an inbound *kind* is not a procedure id — it is rejected', () {
      // `user_prompt` is the kind the no-hint door routes; as a procedure-id
      // hint it names no shipped procedure. This is exactly the conflation
      // Q-E.50.1 removes: the two namespaces no longer overlap.
      final selector = ProcedureSelector();

      expect(
        () => selector.resolveHintedProcedure(InboundKinds.userPrompt),
        throwsA(isA<UnknownProcedureHint>()),
      );
    });

    test('an unknown procedure-id hint raises UnknownProcedureHint naming '
        'the offender + the known set', () {
      final selector = ProcedureSelector();

      try {
        selector.resolveHintedProcedure('research_v1');
        fail('expected UnknownProcedureHint');
      } on UnknownProcedureHint catch (e) {
        expect(e.procedureId, 'research_v1');
        expect(e.knownProcedureIds,
            <String>[SystemProcedures.promptAnalyzerV1]);
        expect(e.code, 'procedure.hint.unknown');
        expect(e.message, contains('research_v1'));
        expect(e.message, contains('prompt_analyzer_v1'));
        expect(e.toString(), startsWith('UnknownProcedureHint:'));
      }
    });

    test('a custom routing exposes its de-duplicated procedure ids', () {
      // Two kinds routing to the same procedure collapse to one known id.
      final selector = ProcedureSelector(routing: const <String, String>{
        'user_prompt': 'prompt_analyzer_v1',
        'background_research': 'research_v1',
        'follow_up': 'prompt_analyzer_v1',
      });

      expect(selector.knownProcedureIds,
          <String>['prompt_analyzer_v1', 'research_v1']);
      expect(selector.resolveHintedProcedure('research_v1'), 'research_v1');
    });
  });

  group('D.16 selection — reject unknown kinds loudly', () {
    test('an unknown kind raises UnsupportedProcedureKind', () {
      final selector = ProcedureSelector();

      expect(
        () => selector.select('background_research'),
        throwsA(isA<UnsupportedProcedureKind>()),
      );
    });

    test('the error names the offending kind and the supported set', () {
      final selector = ProcedureSelector();

      try {
        selector.select('weather_query');
        fail('expected UnsupportedProcedureKind');
      } on UnsupportedProcedureKind catch (e) {
        expect(e.kind, 'weather_query');
        expect(e.supportedKinds, <String>['user_prompt']);
        expect(e.message, contains('weather_query'));
        expect(e.message, contains('user_prompt'));
        expect(e.toString(), startsWith('UnsupportedProcedureKind:'));
      }
    });

    test('an empty kind is rejected (never silently dropped)', () {
      expect(
        () => ProcedureSelector().select(''),
        throwsA(isA<UnsupportedProcedureKind>()),
      );
    });

    test('a kind differing only by whitespace is not routed', () {
      // The classifier (D.15) trims before producing a verdict; the selector
      // does not re-normalise, so an untrimmed kind is genuinely a different
      // (unsupported) kind here.
      expect(
        () => ProcedureSelector().select(' user_prompt'),
        throwsA(isA<UnsupportedProcedureKind>()),
      );
    });
  });

  group('D.16 selection — injectable routing', () {
    test('a custom routing table routes its own kinds', () {
      final selector = ProcedureSelector(routing: const <String, String>{
        'background_research': 'research_v1',
        'user_prompt': 'prompt_analyzer_v1',
      });

      expect(selector.select('background_research'), 'research_v1');
      expect(selector.select('user_prompt'), 'prompt_analyzer_v1');
      expect(selector.supportedKinds,
          <String>['background_research', 'user_prompt']);
    });

    test('the routing is copied defensively (later mutation is inert)', () {
      final routing = <String, String>{'user_prompt': 'prompt_analyzer_v1'};
      final selector = ProcedureSelector(routing: routing);

      routing['user_prompt'] = 'hijacked_v1';
      routing['injected'] = 'evil_v1';

      expect(selector.select('user_prompt'), 'prompt_analyzer_v1');
      expect(
        () => selector.select('injected'),
        throwsA(isA<UnsupportedProcedureKind>()),
      );
    });
  });
}
