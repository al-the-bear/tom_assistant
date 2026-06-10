// The client-side DTOs for the locked §3.9 JSON contract
// (`prompt_tracing.md` § 3.9). These deliberately mirror the server's
// `tom_brain_observatory/lib/src/model/` shapes but are a *separate* decoding
// surface: the web app consumes the JSON contract, it does not import the
// server's parser package (which pulls in `dart:io`/shelf and would not survive
// `flutter build web`'s dart2js graph). Frontend↔API coupling is the JSON, not
// the Dart types.
//
// Optional fields are nullable and decode to `null` when the key is absent —
// the contract omits keys the trail did not carry (§ 3.1), never fabricates
// them. Decoding is total: a missing optional is `null`, never a throw.

/// One turn's full projection — the body of `GET /api/traces/{turnId}`.
class PromptTrace {
  final String turnId;
  final Inbound? inbound;
  final Configuration configuration;
  final Reply? reply;
  final ProcedureRun? runTree;

  const PromptTrace({
    required this.turnId,
    required this.inbound,
    required this.configuration,
    required this.reply,
    required this.runTree,
  });

  factory PromptTrace.fromJson(Map<String, dynamic> json) => PromptTrace(
        turnId: json['turnId'] as String,
        inbound: _maybe(json['inbound'], Inbound.fromJson),
        configuration: json['configuration'] == null
            ? const Configuration(entries: <ConfigEntry>[], memoryProfile: null)
            : Configuration.fromJson(json['configuration'] as Map<String, dynamic>),
        reply: _maybe(json['reply'], Reply.fromJson),
        runTree: _maybe(json['runTree'], ProcedureRun.fromJson),
      );
}

/// The request envelope (§ 3.3).
class Inbound {
  final String channel;
  final String principalId;
  final String sessionId;
  final String? conversationId;
  final String? profile;
  final String persona;
  final DateTime receivedAt;
  final String text;
  final List<dynamic> attachments;
  final Map<String, dynamic> rawEnvelope;

  const Inbound({
    required this.channel,
    required this.principalId,
    required this.sessionId,
    required this.conversationId,
    required this.profile,
    required this.persona,
    required this.receivedAt,
    required this.text,
    required this.attachments,
    required this.rawEnvelope,
  });

  factory Inbound.fromJson(Map<String, dynamic> json) => Inbound(
        channel: json['channel'] as String,
        principalId: json['principalId'] as String,
        sessionId: json['sessionId'] as String,
        conversationId: json['conversationId'] as String?,
        profile: json['profile'] as String?,
        persona: json['persona'] as String,
        receivedAt: DateTime.parse(json['receivedAt'] as String),
        text: json['text'] as String? ?? '',
        attachments: (json['attachments'] as List<dynamic>?) ?? const <dynamic>[],
        rawEnvelope:
            (json['rawEnvelope'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
      );
}

/// What actually ran (§ 3.4): the distinct (provider, model, profile, role)
/// tuples reconstructed from the turn's `llm/` dumps.
class Configuration {
  final List<ConfigEntry> entries;
  final String? memoryProfile;

  const Configuration({required this.entries, required this.memoryProfile});

  factory Configuration.fromJson(Map<String, dynamic> json) => Configuration(
        entries: <ConfigEntry>[
          for (final e in (json['entries'] as List<dynamic>? ?? const <dynamic>[]))
            ConfigEntry.fromJson(e as Map<String, dynamic>),
        ],
        memoryProfile: json['memoryProfile'] as String?,
      );
}

/// One distinct configuration tuple that ran in the turn.
class ConfigEntry {
  final String role;
  final String provider;
  final String model;
  final String? profile;

  const ConfigEntry({
    required this.role,
    required this.provider,
    required this.model,
    required this.profile,
  });

  factory ConfigEntry.fromJson(Map<String, dynamic> json) => ConfigEntry(
        role: json['role'] as String,
        provider: json['provider'] as String,
        model: json['model'] as String,
        profile: json['profile'] as String?,
      );
}

/// The reply surface (§ 3.5) — present only when some surface carries it.
class Reply {
  final String? finalAnswer;
  final String? outcomeStatus;
  final int? wallClockMs;

  const Reply({
    required this.finalAnswer,
    required this.outcomeStatus,
    required this.wallClockMs,
  });

  factory Reply.fromJson(Map<String, dynamic> json) => Reply(
        finalAnswer: json['finalAnswer'] as String?,
        outcomeStatus: json['outcomeStatus'] as String?,
        wallClockMs: json['wallClockMs'] as int?,
      );
}

/// A procedure run (§ 3.6) — the `runTree` and every nested `subRun`.
class ProcedureRun {
  final String procedureId;
  final String runId;
  final String? turnId;
  final String status;
  final int? elapsedMs;
  final int? entryCount;
  final List<RunNode> nodes;

  const ProcedureRun({
    required this.procedureId,
    required this.runId,
    required this.turnId,
    required this.status,
    required this.elapsedMs,
    required this.entryCount,
    required this.nodes,
  });

  factory ProcedureRun.fromJson(Map<String, dynamic> json) => ProcedureRun(
        procedureId: json['procedureId'] as String,
        runId: json['runId'] as String,
        turnId: json['turnId'] as String?,
        status: json['status'] as String,
        elapsedMs: json['elapsedMs'] as int?,
        entryCount: json['entryCount'] as int?,
        nodes: <RunNode>[
          for (final n in (json['nodes'] as List<dynamic>? ?? const <dynamic>[]))
            RunNode.fromJson(n as Map<String, dynamic>),
        ],
      );
}

/// A structural node in a run, discriminated by `kind` (§ 3.9). The UI's render
/// selector is a `switch` over the sealed subtypes.
sealed class RunNode {
  const RunNode();

  factory RunNode.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String;
    return switch (kind) {
      'primitive' => PrimitiveCallNode.fromJson(json),
      'llm' => LlmCallNode.fromJson(json),
      'note' => NoteNode.fromJson(json),
      'error' => ErrorNode.fromJson(json),
      'subRun' => SubRunNode.fromJson(json),
      _ => throw FormatException('unknown run-node kind: $kind'),
    };
  }
}

/// `kind: primitive` — a memory/primitive act (§ 3.8).
class PrimitiveCallNode extends RunNode {
  final String primitive;
  final String? resultId;
  final RecallDescriptor? recall;

  const PrimitiveCallNode({
    required this.primitive,
    required this.resultId,
    required this.recall,
  });

  factory PrimitiveCallNode.fromJson(Map<String, dynamic> json) => PrimitiveCallNode(
        primitive: json['primitive'] as String,
        resultId: json['resultId'] as String?,
        recall: _maybe(json['recall'], RecallDescriptor.fromJson),
      );
}

/// The recall shape carried by a `recall` primitive. `modes` is the list the
/// §3.9 contract serialises (`["bm25","vector"]`); `returnedIds` are the fused
/// result ids the §4.7 deep-links walk into Module 2 (absent when empty).
class RecallDescriptor {
  final List<String> modes;
  final int? k;
  final int returned;
  final List<String> returnedIds;

  const RecallDescriptor({
    required this.modes,
    required this.k,
    required this.returned,
    this.returnedIds = const <String>[],
  });

  factory RecallDescriptor.fromJson(Map<String, dynamic> json) => RecallDescriptor(
        modes: (json['modes'] as List<dynamic>).cast<String>(),
        k: json['k'] as int?,
        returned: json['returned'] as int,
        returnedIds:
            (json['returnedIds'] as List<dynamic>?)?.cast<String>() ??
                const <String>[],
      );
}

/// `kind: llm` — a substrate call. The full §3.7/§4.5 detail (hashes, wire
/// body, answer) is fetched separately from [rawPath] (PT-2.4).
class LlmCallNode extends RunNode {
  final String callType;
  final int tokensIn;
  final int tokensOut;
  final String rawPath;

  const LlmCallNode({
    required this.callType,
    required this.tokensIn,
    required this.tokensOut,
    required this.rawPath,
  });

  factory LlmCallNode.fromJson(Map<String, dynamic> json) => LlmCallNode(
        callType: json['callType'] as String,
        tokensIn: json['tokensIn'] as int? ?? 0,
        tokensOut: json['tokensOut'] as int? ?? 0,
        rawPath: json['rawPath'] as String,
      );
}

/// `kind: note` — a cognitive-step note.
class NoteNode extends RunNode {
  final String category;
  const NoteNode({required this.category});

  factory NoteNode.fromJson(Map<String, dynamic> json) =>
      NoteNode(category: json['category'] as String);
}

/// `kind: error` — a typed error raised within the run.
class ErrorNode extends RunNode {
  final String errorKind;
  final String message;
  const ErrorNode({required this.errorKind, required this.message});

  factory ErrorNode.fromJson(Map<String, dynamic> json) => ErrorNode(
        errorKind: json['errorKind'] as String,
        message: json['message'] as String,
      );
}

/// `kind: subRun` — a nested [ProcedureRun]. This is the recursion (§ 6).
class SubRunNode extends RunNode {
  final ProcedureRun run;
  const SubRunNode({required this.run});

  factory SubRunNode.fromJson(Map<String, dynamic> json) =>
      SubRunNode(run: ProcedureRun.fromJson(json['run'] as Map<String, dynamic>));
}

/// One row of `GET /api/traces` — the prompt list (§ 4.1). `outcomeStatus` and
/// `wallClockMs` are absent for an in-flight turn (no completed run-tree).
class PromptListRow {
  final String turnId;
  final DateTime? receivedAt;
  final String? channel;
  final String? principalId;
  final String? persona;
  final String? preview;
  final String? outcomeStatus;
  final int? wallClockMs;
  final int llmCallCount;
  final int memoryAccessCount;

  const PromptListRow({
    required this.turnId,
    required this.receivedAt,
    required this.channel,
    required this.principalId,
    required this.persona,
    required this.preview,
    required this.outcomeStatus,
    required this.wallClockMs,
    required this.llmCallCount,
    required this.memoryAccessCount,
  });

  factory PromptListRow.fromJson(Map<String, dynamic> json) => PromptListRow(
        turnId: json['turnId'] as String,
        receivedAt: _maybe(json['receivedAt'], (String v) => DateTime.parse(v)),
        channel: json['channel'] as String?,
        principalId: json['principalId'] as String?,
        persona: json['persona'] as String?,
        preview: json['preview'] as String?,
        outcomeStatus: json['outcomeStatus'] as String?,
        wallClockMs: json['wallClockMs'] as int?,
        llmCallCount: json['llmCallCount'] as int? ?? 0,
        memoryAccessCount: json['memoryAccessCount'] as int? ?? 0,
      );
}

/// Decode [value] with [fromJson] when present, else `null`. [S] is the decoder
/// input (`Map<String, dynamic>` for object decoders, `String` for
/// `DateTime.parse`) and is inferred from the call site.
T? _maybe<S, T>(Object? value, T Function(S) fromJson) =>
    value == null ? null : fromJson(value as S);
