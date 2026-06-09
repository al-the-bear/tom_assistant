// A canned [TraceApiClient] for widget/model tests — no network, no live brain.
// `listTraces` returns the supplied rows; `traceFor` looks up a trace by turnId
// from the supplied map (PT-2.1 row→detail navigation); `llmCallDetail` looks
// up a dump by its `rawPath` link (PT-2.4 LLM-call detail).

import 'package:tom_brain_observatory_web/src/api/trace_api_client.dart';
import 'package:tom_brain_observatory_web/src/model/live_step.dart';
import 'package:tom_brain_observatory_web/src/model/llm_call_detail.dart';
import 'package:tom_brain_observatory_web/src/model/prompt_trace.dart';

class StubApiClient implements TraceApiClient {
  final List<PromptListRow> rows;
  final Map<String, PromptTrace> traces;

  /// Keyed by the run-tree `LlmCall`'s `rawPath` link (PT-2.4).
  final Map<String, LlmCallDetail> llmCalls;

  /// Keyed by procedureId — the verbatim d4rt source (PT-3.2).
  final Map<String, String> scripts;

  /// Canned SSE live-tail per turnId, keyed by turnId (PT-4.2).
  final Map<String, Stream<LiveStep>> turnStreams;

  /// The list-level change stream (PT-4.2); empty when not driven.
  final Stream<void>? changes;

  /// Re-fetch override: when set, [listTraces] returns these after [changes]
  /// fires, letting a test assert the list reloads on a tick.
  final List<PromptListRow>? rowsAfterChange;

  StubApiClient({
    this.rows = const <PromptListRow>[],
    this.traces = const <String, PromptTrace>{},
    this.llmCalls = const <String, LlmCallDetail>{},
    this.scripts = const <String, String>{},
    this.turnStreams = const <String, Stream<LiveStep>>{},
    this.changes,
    this.rowsAfterChange,
  });

  bool _reloaded = false;

  @override
  Future<List<PromptListRow>> listTraces({int? limit}) async {
    final source = _reloaded && rowsAfterChange != null ? rowsAfterChange! : rows;
    return limit == null ? source : source.take(limit).toList();
  }

  @override
  Future<PromptTrace?> traceFor(String turnId) async => traces[turnId];

  @override
  Future<LlmCallDetail?> llmCallDetail(String turnId, String rawPath) async =>
      llmCalls[rawPath];

  @override
  Future<String?> procedureScript(String procedureId) async =>
      scripts[procedureId];

  @override
  Stream<LiveStep> tailTurn(String turnId) =>
      turnStreams[turnId] ?? const Stream<LiveStep>.empty();

  @override
  Stream<void> listChanges() async* {
    await for (final _ in changes ?? const Stream<void>.empty()) {
      _reloaded = true;
      yield null;
    }
  }
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
