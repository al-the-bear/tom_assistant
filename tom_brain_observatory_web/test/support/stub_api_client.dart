// A canned [TraceApiClient] for widget/model tests — no network, no live brain.
// `listTraces` returns the supplied rows; `traceFor` looks up a trace by turnId
// from the supplied map (PT-2.1 row→detail navigation); `llmCallDetail` looks
// up a dump by its `rawPath` link (PT-2.4 LLM-call detail).

import 'package:tom_brain_observatory_web/src/api/trace_api_client.dart';
import 'package:tom_brain_observatory_web/src/model/llm_call_detail.dart';
import 'package:tom_brain_observatory_web/src/model/prompt_trace.dart';

class StubApiClient implements TraceApiClient {
  final List<PromptListRow> rows;
  final Map<String, PromptTrace> traces;

  /// Keyed by the run-tree `LlmCall`'s `rawPath` link (PT-2.4).
  final Map<String, LlmCallDetail> llmCalls;

  /// Keyed by procedureId — the verbatim d4rt source (PT-3.2).
  final Map<String, String> scripts;

  const StubApiClient({
    this.rows = const <PromptListRow>[],
    this.traces = const <String, PromptTrace>{},
    this.llmCalls = const <String, LlmCallDetail>{},
    this.scripts = const <String, String>{},
  });

  @override
  Future<List<PromptListRow>> listTraces({int? limit}) async =>
      limit == null ? rows : rows.take(limit).toList();

  @override
  Future<PromptTrace?> traceFor(String turnId) async => traces[turnId];

  @override
  Future<LlmCallDetail?> llmCallDetail(String turnId, String rawPath) async =>
      llmCalls[rawPath];

  @override
  Future<String?> procedureScript(String procedureId) async =>
      scripts[procedureId];
}

/// A §4.1 row with sensible defaults; override per test.
PromptListRow stubRow(
  String turnId, {
  String? channel = 'openai',
  String? principalId = 'fixture-user',
  String? persona = 'tom-assistant',
  String? preview = 'fixture preview',
  String? outcomeStatus = 'accepted',
  int? wallClockMs = 2100,
  int llmCallCount = 2,
  int memoryAccessCount = 5,
  DateTime? receivedAt,
}) =>
    PromptListRow(
      turnId: turnId,
      receivedAt: receivedAt,
      channel: channel,
      principalId: principalId,
      persona: persona,
      preview: preview,
      outcomeStatus: outcomeStatus,
      wallClockMs: wallClockMs,
      llmCallCount: llmCallCount,
      memoryAccessCount: memoryAccessCount,
    );
