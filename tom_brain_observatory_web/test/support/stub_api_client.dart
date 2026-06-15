// A canned [TraceApiClient] for widget/model tests — no network, no live brain.
// `listTraces` returns the supplied rows; `traceFor` looks up a trace by turnId
// from the supplied map (PT-2.1 row→detail navigation); `llmCallDetail` looks
// up a dump by its `rawPath` link (PT-2.4 LLM-call detail).

import 'package:tom_brain_observatory_web/src/api/trace_api_client.dart';
import 'package:tom_brain_observatory_web/src/model/authoring.dart';
import 'package:tom_brain_observatory_web/src/model/catalogue.dart';
import 'package:tom_brain_observatory_web/src/model/live_step.dart';
import 'package:tom_brain_observatory_web/src/model/llm_call_detail.dart';
import 'package:tom_brain_observatory_web/src/model/prompt_trace.dart';

class StubApiClient implements TraceApiClient {
  final List<PromptListRow> rows;
  final Map<String, PromptTrace> traces;

  /// Keyed by the run-tree `LlmCall`'s `rawPath` link (PT-2.4).
  final Map<String, LlmCallDetail> llmCalls;

  /// Keyed by procedureId — the verbatim d4rt source (PT-3.2). A save through
  /// [writeProcedureScript] mutates this map, so a re-fetch sees the edit.
  final Map<String, String> scripts;

  /// Keyed by `<roleId>/<part>` — the externalized override prose (PT-4.x). A
  /// save through [writePromptFile] mutates this map. A missing key is the
  /// `404` "no override yet" the editor turns into a create-override start.
  final Map<String, String> prompts;

  /// When set, the next [writeProcedureScript] / [writePromptFile] /
  /// [writeConfigFile] returns this instead of saving, letting a test drive the
  /// `422`-findings path.
  final AuthoringResult? rejectWrites;

  /// The `GET /api/catalogue` body (§ 6.4); `null` models the host `503`
  /// "config unavailable".
  final CognitionCatalogue? catalogueData;

  /// Keyed by `<wireKind>/<name>` — the registered config file's verbatim text
  /// (§ 6.4). A save through [writeConfigFile] mutates this map. A missing key
  /// is the `404` "registered-but-absent" the editor opens as an empty buffer.
  final Map<String, String> configs;

  /// Canned SSE live-tail per turnId, keyed by turnId (PT-4.2).
  final Map<String, Stream<LiveStep>> turnStreams;

  /// The list-level change stream (PT-4.2); empty when not driven.
  final Stream<void>? changes;

  /// Re-fetch override: when set, [listTraces] returns these after [changes]
  /// fires, letting a test assert the list reloads on a tick.
  final List<PromptListRow>? rowsAfterChange;

  /// Records every save, in order, so a widget test can assert what the Save
  /// button marshalled.
  final List<(String, String)> procedureWrites = <(String, String)>[];
  final List<(String, String, String)> promptWrites =
      <(String, String, String)>[];
  final List<(String, String, String)> configWrites =
      <(String, String, String)>[];

  StubApiClient({
    this.rows = const <PromptListRow>[],
    this.traces = const <String, PromptTrace>{},
    this.llmCalls = const <String, LlmCallDetail>{},
    Map<String, String>? scripts,
    Map<String, String>? prompts,
    this.rejectWrites,
    this.catalogueData,
    Map<String, String>? configs,
    this.turnStreams = const <String, Stream<LiveStep>>{},
    this.changes,
    this.rowsAfterChange,
  })  : scripts = scripts ?? <String, String>{},
        prompts = prompts ?? <String, String>{},
        configs = configs ?? <String, String>{};

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
  Future<AuthoringResult> writeProcedureScript(
      String procedureId, String source) async {
    procedureWrites.add((procedureId, source));
    if (rejectWrites != null) return rejectWrites!;
    scripts[procedureId] = source;
    return AuthoringResult.saved;
  }

  @override
  Future<String?> readPromptFile(String roleId, String part) async =>
      prompts['$roleId/$part'];

  @override
  Future<AuthoringResult> writePromptFile(
      String roleId, String part, String prose) async {
    promptWrites.add((roleId, part, prose));
    if (rejectWrites != null) return rejectWrites!;
    prompts['$roleId/$part'] = prose;
    return AuthoringResult.saved;
  }

  @override
  Future<CognitionCatalogue?> catalogue() async => catalogueData;

  @override
  Future<String?> readConfigFile(String kind, String name) async =>
      configs['$kind/$name'];

  @override
  Future<AuthoringResult> writeConfigFile(
      String kind, String name, String content) async {
    configWrites.add((kind, name, content));
    if (rejectWrites != null) return rejectWrites!;
    configs['$kind/$name'] = content;
    return AuthoringResult.saved;
  }

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
