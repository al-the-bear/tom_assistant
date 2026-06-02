// Procedure-selection tests (Plan step D.16; spec § 10.2).
//
// D.16 delivers `ProcedureSelector.select(kind)` — stage three of the
// dispatcher's `accept → classify → select → schedule` pipeline. These
// tests pin the selector's one decision in isolation:
//
//   1. Accept-and-route: `user_prompt` → `answer_with_memory_v1`.
//   2. Reject loudly: any other kind raises `UnsupportedProcedureKind`,
//      and the error names the offender + the supported set.
//   3. The routing table is injectable + defensively copied.

import 'package:test/test.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show
        InboundKinds,
        ProcedureSelector,
        SystemProcedures,
        UnsupportedProcedureKind,
        defaultProcedureRouting;

void main() {
  group('D.16 selection — accept and route', () {
    test('user_prompt routes to answer_with_memory_v1', () {
      final selector = ProcedureSelector();

      expect(
        selector.select(InboundKinds.userPrompt),
        SystemProcedures.answerWithMemoryV1,
      );
    });

    test('SystemProcedures.answerWithMemoryV1 is the spec spelling', () {
      expect(SystemProcedures.answerWithMemoryV1, 'answer_with_memory_v1');
    });

    test('the default routing is the single prototype entry', () {
      expect(defaultProcedureRouting, <String, String>{
        'user_prompt': 'answer_with_memory_v1',
      });
    });

    test('supportedKinds reports the one routed kind', () {
      expect(ProcedureSelector().supportedKinds, <String>['user_prompt']);
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
        'user_prompt': 'answer_with_memory_v1',
      });

      expect(selector.select('background_research'), 'research_v1');
      expect(selector.select('user_prompt'), 'answer_with_memory_v1');
      expect(selector.supportedKinds,
          <String>['background_research', 'user_prompt']);
    });

    test('the routing is copied defensively (later mutation is inert)', () {
      final routing = <String, String>{'user_prompt': 'answer_with_memory_v1'};
      final selector = ProcedureSelector(routing: routing);

      routing['user_prompt'] = 'hijacked_v1';
      routing['injected'] = 'evil_v1';

      expect(selector.select('user_prompt'), 'answer_with_memory_v1');
      expect(
        () => selector.select('injected'),
        throwsA(isA<UnsupportedProcedureKind>()),
      );
    });
  });
}
