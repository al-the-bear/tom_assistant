// PT-1.1 — PromptTrace model + parser. Proves the assembler turns the fixture
// `incoming/` + `procedures/` + `llm/` + `sessions/` files for one `turnId` into
// a `PromptTrace` tree (§ 3.2) with Inbound, Configuration, Reply, and RunTree —
// each section degrading independently when its surface is absent (§ 4.1).

import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:test/test.dart';

const _fixtureHost = 'test/fixtures/trail/fixturehost';

void main() {
  final host = TrailHost.at(_fixtureHost);

  group('promptTraceFor — accepted turn (a0)', () {
    final trace = promptTraceFor(host, '260101-120000.000001')!;

    test('inbound projects the incoming record', () {
      final inbound = trace.inbound!;
      expect(inbound.channel, 'openai');
      expect(inbound.principalId, 'fixture-user');
      expect(inbound.sessionId, 'sess-fixture-0001');
      expect(inbound.persona, 'tom-assistant');
      expect(inbound.text, 'Fixture: what did we decide about the backup topology?');
      expect(inbound.receivedAt.toUtc().toIso8601String(),
          '2026-01-01T12:00:00.001Z');
    });

    test('configuration is what actually ran (distinct tuples)', () {
      final entries = trace.configuration.entries;
      expect(entries, hasLength(2));
      expect(
        entries,
        contains(const ConfigEntry(
            role: 'recall_planner', provider: 'local', model: 'fixture-model')),
      );
      expect(
        entries,
        contains(const ConfigEntry(
            role: 'assistant_to_user',
            provider: 'local',
            model: 'fixture-model')),
      );
    });

    test('reply joins the summary answer with the run outcome', () {
      final reply = trace.reply!;
      expect(
        reply.finalAnswer,
        startsWith('We settled on the tiered backup topology'),
      );
      expect(reply.outcomeStatus, 'accepted');
      expect(reply.wallClockMs, 2100);
    });

    test('run tree is present and recursive', () {
      expect(trace.runTree!.procedureId, 'answer_with_memory_v1');
      expect(trace.runTree!.nodes.first, isA<SubRunNode>());
    });

    test('toJson is the locked §3 shape', () {
      final json = trace.toJson();
      expect(json['turnId'], '260101-120000.000001');
      expect((json['inbound'] as Map)['channel'], 'openai');
      expect((json['configuration'] as Map)['entries'], hasLength(2));
      expect((json['reply'] as Map)['outcomeStatus'], 'accepted');
      expect((json['runTree'] as Map)['procedureId'], 'answer_with_memory_v1');
    });
  });

  group('promptTraceFor — errored turn (b0)', () {
    final trace = promptTraceFor(host, '260101-120100.000002')!;

    test('reply carries the verbatim no-answer placeholder + errored outcome', () {
      final reply = trace.reply!;
      expect(reply.finalAnswer, startsWith('_(no answer'));
      expect(reply.outcomeStatus, 'errored');
      expect(reply.wallClockMs, 8300);
    });
  });

  group('promptTraceFor — in-flight turn (c, incoming only)', () {
    final trace = promptTraceFor(host, '260101-120200.000003')!;

    test('inbound present but run-tree / reply absent', () {
      expect(trace.inbound, isNotNull);
      expect(trace.runTree, isNull);
      expect(trace.reply, isNull);
      expect(trace.configuration.entries, isEmpty);
    });
  });

  group('promptTraceFor — multi-run turn (analyzer + answer, d0)', () {
    // The turn dispatched the fast `prompt_analyzer_v1` classifier (1.6s) and
    // then the substantive `answer_with_memory_v1` run (1036.8s). Both logs
    // carry the same turn stem; the trace must report the *answer* run, not
    // whichever the filesystem lists first — otherwise a multi-minute prompt
    // mis-displays as the classifier's sub-second run with no flow.
    final trace = promptTraceFor(host, '260101-120300.000004')!;

    test('run tree is the substantive answer run, not the analyzer', () {
      expect(trace.runTree!.procedureId, 'answer_with_memory_v1');
    });

    test('wall-clock is the answer run duration, not the classifier 1.6s', () {
      expect(trace.reply!.wallClockMs, 1036800);
      expect(trace.reply!.outcomeStatus, 'accepted');
    });

    test('the full answer flow is present (retrieve + tool loops)', () {
      final subRuns = trace.runTree!.nodes.whereType<SubRunNode>().toList();
      expect(
        subRuns.map((s) => s.run.procedureId),
        containsAll(<String>['retrieve_for_prompt_v1', 'tool_loop_v1']),
      );
    });
  });

  group('promptTraceFor — unknown turn', () {
    test('returns null (turn unknown to host)', () {
      expect(promptTraceFor(host, '991231-235959.999999'), isNull);
    });
  });
}
