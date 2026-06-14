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

    test('configuration carries the generation knobs from the raw dump', () {
      final planner = trace.configuration.entries
          .firstWhere((e) => e.role == 'recall_planner');
      expect(planner.temperature, 0.2);
      expect(planner.maxOutputTokens, 256);
      expect(planner.stopSequences, <String>['STOP']);
      // The assistant_to_user dump pins no knobs → defaults (null / empty).
      final answerer = trace.configuration.entries
          .firstWhere((e) => e.role == 'assistant_to_user');
      expect(answerer.temperature, isNull);
      expect(answerer.maxOutputTokens, isNull);
      expect(answerer.stopSequences, isEmpty);
    });

    test('toJson emits present knobs and omits absent ones', () {
      final entries =
          (trace.toJson()['configuration'] as Map)['entries'] as List;
      final planner = entries
          .firstWhere((e) => (e as Map)['role'] == 'recall_planner') as Map;
      expect(planner['temperature'], 0.2);
      expect(planner['maxOutputTokens'], 256);
      expect(planner['stopSequences'], <String>['STOP']);
      final answerer = entries
          .firstWhere((e) => (e as Map)['role'] == 'assistant_to_user') as Map;
      expect(answerer.containsKey('temperature'), isFalse);
      expect(answerer.containsKey('maxOutputTokens'), isFalse);
      expect(answerer.containsKey('stopSequences'), isFalse);
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

    test('run trees are present and recursive', () {
      expect(trace.runTrees, hasLength(1));
      expect(trace.runTrees.single.procedureId, 'answer_with_memory_v1');
      expect(trace.runTrees.single.nodes.first, isA<SubRunNode>());
    });

    test('toJson is the locked §3 shape', () {
      final json = trace.toJson();
      expect(json['turnId'], '260101-120000.000001');
      expect((json['inbound'] as Map)['channel'], 'openai');
      expect((json['configuration'] as Map)['entries'], hasLength(2));
      expect((json['reply'] as Map)['outcomeStatus'], 'accepted');
      final runTrees = json['runTrees'] as List;
      expect(runTrees, hasLength(1));
      expect((runTrees.single as Map)['procedureId'], 'answer_with_memory_v1');
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

    test('inbound present but run-trees / reply absent', () {
      expect(trace.inbound, isNotNull);
      expect(trace.runTrees, isEmpty);
      expect(trace.reply, isNull);
      expect(trace.configuration.entries, isEmpty);
    });
  });

  group('promptTraceFor — multi-run turn (analyzer + answer, d0)', () {
    // The turn dispatched the fast `prompt_analyzer_v1` classifier (1.6s) and
    // then the substantive `answer_with_memory_v1` run (1036.8s). Both logs
    // carry the same turn stem; the trace must surface BOTH top-level runs in
    // start order (classifier first, answer last) — otherwise whole procedures
    // and their secondary LLM/memory calls stay hidden (§ 3.2).
    final trace = promptTraceFor(host, '260101-120300.000004')!;

    test('both top-level runs surface, classifier first then answer', () {
      expect(
        trace.runTrees.map((r) => r.procedureId),
        <String>['prompt_analyzer_v1', 'answer_with_memory_v1'],
      );
    });

    test('wall-clock is the substantive answer run, not the classifier 1.6s', () {
      expect(trace.reply!.wallClockMs, 1036800);
      expect(trace.reply!.outcomeStatus, 'accepted');
    });

    test('the full answer flow is present (retrieve + tool loops)', () {
      final answer = trace.runTrees.last;
      final subRuns = answer.nodes.whereType<SubRunNode>().toList();
      expect(
        subRuns.map((s) => s.run.procedureId),
        containsAll(<String>['retrieve_for_prompt_v1', 'tool_loop_v1']),
      );
    });

    test('toJson surfaces every top-level run in start order', () {
      final runTrees = trace.toJson()['runTrees'] as List;
      expect(
        runTrees.map((r) => (r as Map)['procedureId']),
        <String>['prompt_analyzer_v1', 'answer_with_memory_v1'],
      );
    });
  });

  group('promptTraceFor — unknown turn', () {
    test('returns null (turn unknown to host)', () {
      expect(promptTraceFor(host, '991231-235959.999999'), isNull);
    });
  });
}
