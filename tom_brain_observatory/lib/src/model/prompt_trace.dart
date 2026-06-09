// The PromptTrace projection — one processed prompt, re-assembled from the trail
// files the brain already wrote (`prompt_tracing.md` § 3.1–3.8).
//
// This introduces no new persisted model: a [PromptTrace] is a *view* keyed by
// `turnId`, projecting the `incoming/` request, the `llm/` calls' configuration,
// the `sessions/` + `summary/` reply, and the `procedures/` run-tree into one
// object. Field names mirror the shipped record types so the spec cannot drift
// from the writers.

import 'run_tree.dart';

/// One traced prompt (`prompt_tracing.md` § 3.2), keyed by [turnId]. Every
/// section is independently nullable so the projection degrades gracefully when
/// a surface is absent (unconfigured-mode trail, an in-flight turn with no
/// completed run-tree yet, …) — absence is never an error (§ 4.1).
final class PromptTrace {
  /// The turn correlation id (`YYMMDD-HHMMSS.ssssss`).
  final String turnId;

  /// The inbound request (§ 3.3), or `null` when no `incoming/` record exists.
  final Inbound? inbound;

  /// The configuration that actually ran (§ 3.4) — always present (empty when
  /// no LLM call was trailed).
  final Configuration configuration;

  /// The streamed reply + outcome (§ 3.5), or `null` when neither a summary nor
  /// a completed run-tree is present.
  final Reply? reply;

  /// The top-level procedure run (§ 3.6), or `null` in unconfigured mode / when
  /// the run-tree file is absent.
  final ProcedureRun? runTree;

  const PromptTrace({
    required this.turnId,
    required this.configuration,
    this.inbound,
    this.reply,
    this.runTree,
  });

  /// The locked § 3 JSON contract for `GET /api/traces/{turnId}`.
  Map<String, Object?> toJson() => <String, Object?>{
        'turnId': turnId,
        'inbound': inbound?.toJson(),
        'configuration': configuration.toJson(),
        'reply': reply?.toJson(),
        'runTree': runTree?.toJson(),
      };
}

/// The inbound request envelope (`prompt_tracing.md` § 3.3 / `IncomingTrailRecord`).
final class Inbound {
  /// The channel the request arrived on (`openai` / `telegram` / `ollama` / `anthropic`).
  final String channel;

  /// The resolved principal id — never a bearer/bot credential (§ 7.2).
  final String principalId;

  /// The session this turn answered under.
  final String sessionId;

  /// The conversation id from the envelope, when present.
  final String? conversationId;

  /// The memory profile pinned on the session, or `null` for the process default.
  final String? profile;

  /// The resolved persona id (the OpenAI `model` string, mapped).
  final String persona;

  /// The admission instant (UTC).
  final DateTime receivedAt;

  /// The full prompt text (raw tier).
  final String text;

  /// The inbound attachments (empty until attachments land).
  final List<Object?> attachments;

  /// The channel-specific raw envelope, secret-redacted by the writer.
  final Map<String, Object?> rawEnvelope;

  Inbound({
    required this.channel,
    required this.principalId,
    required this.sessionId,
    required this.persona,
    required this.receivedAt,
    required this.text,
    this.conversationId,
    this.profile,
    List<Object?> attachments = const <Object?>[],
    Map<String, Object?> rawEnvelope = const <String, Object?>{},
  })  : attachments = List<Object?>.unmodifiable(attachments),
        rawEnvelope = Map<String, Object?>.unmodifiable(rawEnvelope);

  Map<String, Object?> toJson() => <String, Object?>{
        'channel': channel,
        'principalId': principalId,
        'sessionId': sessionId,
        if (conversationId != null) 'conversationId': conversationId,
        if (profile != null) 'profile': profile,
        'persona': persona,
        'receivedAt': receivedAt.toIso8601String(),
        'text': text,
        'attachments': attachments,
        'rawEnvelope': rawEnvelope,
      };
}

/// The configuration that actually ran for a turn (`prompt_tracing.md` § 3.4) —
/// reconstructed from the LLM-call trail, *what ran*, not what the YAML says.
final class Configuration {
  /// The distinct (role, provider, model, profile) tuples that ran in the turn.
  final List<ConfigEntry> entries;

  /// The memory profile the turn ran under, or `null` for the process default.
  final String? memoryProfile;

  Configuration({
    List<ConfigEntry> entries = const <ConfigEntry>[],
    this.memoryProfile,
  }) : entries = List<ConfigEntry>.unmodifiable(entries);

  Map<String, Object?> toJson() => <String, Object?>{
        'entries': <Object?>[for (final entry in entries) entry.toJson()],
        if (memoryProfile != null) 'memoryProfile': memoryProfile,
      };
}

/// One distinct (role, provider, model, profile) tuple that ran in a turn
/// (`prompt_tracing.md` § 3.4 / § 4.3).
final class ConfigEntry {
  /// The role / callType the call was assembled for.
  final String role;

  /// The provider that answered the call.
  final String provider;

  /// The model that answered the call.
  final String model;

  /// The memory profile the call ran under, when the raw dump carried one.
  final String? profile;

  const ConfigEntry({
    required this.role,
    required this.provider,
    required this.model,
    this.profile,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'role': role,
        'provider': provider,
        'model': model,
        if (profile != null) 'profile': profile,
      };

  @override
  bool operator ==(Object other) =>
      other is ConfigEntry &&
      other.role == role &&
      other.provider == provider &&
      other.model == model &&
      other.profile == profile;

  @override
  int get hashCode => Object.hash(role, provider, model, profile);
}

/// The streamed reply + terminal outcome of a turn (`prompt_tracing.md` § 3.5).
/// The step-by-step streaming replay is a later phase (PT-4); v0 carries the
/// final answer and the outcome the run-tree / summary already record.
final class Reply {
  /// The final answer text, or `null` when the turn did not complete with one.
  final String? finalAnswer;

  /// The terminal outcome status name (`accepted`, `errored`, …), or `null`
  /// when no completed run-tree is present.
  final String? outcomeStatus;

  /// The top-level run's wall-clock elapsed in milliseconds, or `null`.
  final int? wallClockMs;

  const Reply({this.finalAnswer, this.outcomeStatus, this.wallClockMs});

  Map<String, Object?> toJson() => <String, Object?>{
        if (finalAnswer != null) 'finalAnswer': finalAnswer,
        if (outcomeStatus != null) 'outcomeStatus': outcomeStatus,
        if (wallClockMs != null) 'wallClockMs': wallClockMs,
      };
}

/// One row of the prompt list (`prompt_tracing.md` § 4.1) — the entry view's
/// per-turn summary, correlated across `incoming/` + `procedures/` by `turnId`.
final class PromptListRow {
  /// The turn correlation id.
  final String turnId;

  /// The admission instant (UTC) — the list's newest-first sort key.
  final DateTime? receivedAt;

  /// The channel badge.
  final String? channel;

  /// The resolved principal.
  final String? principalId;

  /// The resolved persona.
  final String? persona;

  /// A one-line prompt preview.
  final String? preview;

  /// The terminal outcome status (`accepted` / `errored` / …), or `null` for an
  /// in-flight turn with no completed run-tree.
  final String? outcomeStatus;

  /// The top-level run's wall-clock in milliseconds, or `null`.
  final int? wallClockMs;

  /// The count of LLM calls across the whole turn's run-tree.
  final int llmCallCount;

  /// The count of memory/primitive accesses (non-`llm` primitive calls) across
  /// the whole turn's run-tree.
  final int memoryAccessCount;

  const PromptListRow({
    required this.turnId,
    required this.llmCallCount,
    required this.memoryAccessCount,
    this.receivedAt,
    this.channel,
    this.principalId,
    this.persona,
    this.preview,
    this.outcomeStatus,
    this.wallClockMs,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'turnId': turnId,
        if (receivedAt != null) 'receivedAt': receivedAt!.toIso8601String(),
        if (channel != null) 'channel': channel,
        if (principalId != null) 'principalId': principalId,
        if (persona != null) 'persona': persona,
        if (preview != null) 'preview': preview,
        if (outcomeStatus != null) 'outcomeStatus': outcomeStatus,
        if (wallClockMs != null) 'wallClockMs': wallClockMs,
        'llmCallCount': llmCallCount,
        'memoryAccessCount': memoryAccessCount,
      };
}
