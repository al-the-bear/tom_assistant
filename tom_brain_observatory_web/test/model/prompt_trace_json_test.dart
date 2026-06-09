// PT-2.1 (model) — the client DTOs decode the locked §3.9 JSON contract. These
// are the web-side counterpart to the server's parser tests: they pin that the
// frontend reads exactly what `prompt_tracing.md` § 3.9 documents, including the
// run-node `kind` discrimination and the sub-run recursion, and that
// omitted-when-absent optional keys decode to `null` (never throw).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/prompt_trace.dart';

void main() {
  group('PromptListRow.fromJson (§4.1 array element)', () {
    test('decodes a completed row', () {
      final row = PromptListRow.fromJson(jsonDecode('''
        {
          "turnId": "260101-120000.000001",
          "receivedAt": "2026-01-01T12:00:00.001Z",
          "channel": "openai",
          "principalId": "fixture-user",
          "persona": "tom-assistant",
          "preview": "what did we decide about backup?",
          "outcomeStatus": "accepted",
          "wallClockMs": 2100,
          "llmCallCount": 2,
          "memoryAccessCount": 5
        }
      ''') as Map<String, dynamic>);

      expect(row.turnId, '260101-120000.000001');
      expect(row.receivedAt, DateTime.parse('2026-01-01T12:00:00.001Z'));
      expect(row.outcomeStatus, 'accepted');
      expect(row.llmCallCount, 2);
      expect(row.memoryAccessCount, 5);
    });

    test('an in-flight row omits outcome + wall-clock → null, counts default 0', () {
      final row = PromptListRow.fromJson(jsonDecode('''
        {"turnId": "260101-120300.000004", "channel": "openai"}
      ''') as Map<String, dynamic>);

      expect(row.outcomeStatus, isNull);
      expect(row.wallClockMs, isNull);
      expect(row.receivedAt, isNull);
      expect(row.llmCallCount, 0);
      expect(row.memoryAccessCount, 0);
    });
  });

  group('PromptTrace.fromJson (§3.9 full body)', () {
    late PromptTrace trace;

    setUp(() {
      trace = PromptTrace.fromJson(jsonDecode('''
        {
          "turnId": "260101-120000.000001",
          "inbound": {
            "channel": "openai",
            "principalId": "fixture-user",
            "sessionId": "sess-fixture-0001",
            "persona": "tom-assistant",
            "receivedAt": "2026-01-01T12:00:00.001Z",
            "text": "what did we decide?",
            "attachments": [],
            "rawEnvelope": {}
          },
          "configuration": {
            "entries": [
              {"role": "recall_planner", "provider": "local", "model": "fixture-model"},
              {"role": "assistant_to_user", "provider": "local", "model": "fixture-model"}
            ],
            "memoryProfile": "default"
          },
          "reply": {
            "finalAnswer": "We settled on the tiered backup topology.",
            "outcomeStatus": "accepted",
            "wallClockMs": 2100
          },
          "runTree": {
            "procedureId": "answer_with_memory_v1",
            "runId": "run-fixture-a0",
            "turnId": "260101-120000.000001",
            "status": "accepted",
            "elapsedMs": 2100,
            "entryCount": 6,
            "nodes": [
              {
                "kind": "subRun",
                "run": {
                  "procedureId": "retrieve_for_prompt_v1",
                  "runId": "run-fixture-a1",
                  "status": "accepted",
                  "nodes": [
                    {
                      "kind": "primitive",
                      "primitive": "recall",
                      "recall": {"modes": "bm25+vector", "k": 8, "returned": 5}
                    }
                  ]
                }
              },
              {"kind": "llm", "callType": "assistant_to_user", "tokensIn": 88, "tokensOut": 40, "rawPath": "../../llm/assistant_to_user/x.raw.json"},
              {"kind": "note", "category": "selfCritique"},
              {"kind": "error", "errorKind": "substrateTimeout", "message": "timed out"},
              {"kind": "primitive", "primitive": "persist", "resultId": "n_fixtureA1"}
            ]
          }
        }
      ''') as Map<String, dynamic>);
    });

    test('top-level + inbound + configuration + reply', () {
      expect(trace.turnId, '260101-120000.000001');
      expect(trace.inbound!.sessionId, 'sess-fixture-0001');
      expect(trace.inbound!.conversationId, isNull); // omitted → null
      expect(trace.configuration.entries, hasLength(2));
      expect(trace.configuration.entries.first.role, 'recall_planner');
      expect(trace.configuration.memoryProfile, 'default');
      expect(trace.reply!.outcomeStatus, 'accepted');
    });

    test('run-tree nodes discriminate by kind, sub-run recurses', () {
      final run = trace.runTree!;
      expect(run.procedureId, 'answer_with_memory_v1');
      expect(run.nodes, hasLength(5));

      final sub = run.nodes[0] as SubRunNode;
      expect(sub.run.procedureId, 'retrieve_for_prompt_v1');
      final recall = sub.run.nodes.single as PrimitiveCallNode;
      expect(recall.primitive, 'recall');
      expect(recall.recall!.returned, 5);

      final llm = run.nodes[1] as LlmCallNode;
      expect(llm.callType, 'assistant_to_user');
      expect(llm.tokensIn, 88);
      expect(llm.tokensOut, 40);

      expect((run.nodes[2] as NoteNode).category, 'selfCritique');
      expect((run.nodes[3] as ErrorNode).errorKind, 'substrateTimeout');
      expect((run.nodes[4] as PrimitiveCallNode).resultId, 'n_fixtureA1');
    });

    test('an unknown run-node kind is a hard format error', () {
      expect(
        () => RunNode.fromJson(<String, dynamic>{'kind': 'wat'}),
        throwsFormatException,
      );
    });
  });
}
