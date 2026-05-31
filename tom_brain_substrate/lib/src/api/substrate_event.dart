// B.9 — `SubstrateEvent` sealed sum.
//
// substrate_specification.md § 10.2 names twelve variants. They are
// what consumers (the dispatcher trail, Tom Forge brain inspector,
// metrics scraper) subscribe to via
// `TomBrainSubstrateClient.events()`.
//
// Sealed for the same reason `LlmStreamEvent` and `McpClientException`
// are sealed: a new variant is a substrate contract change, not a
// silent extension. Adding one bumps the substrate spec § 10.2 list
// and the consumer-side switches must compile-error until they handle
// the new case.
//
// Why these inherit `BrainEvent` (from `tom_brain_shared`):
//
//   - `BrainEvent` is the universal observability base — it carries
//     `occurredAt` (UTC) + `runId` + `causedBy`, defines the
//     `payloadJson()` contract for serialisation, and the kebab-case
//     `kind` discriminator (`component.event-name`). All Tom Brain
//     components emit events through that base so trail consumers
//     do not branch on Dart runtime types.
//   - The substrate-specific carrier is `SubstrateEvent`; each
//     variant carries its substrate-side payload plus the inherited
//     base. Trail consumers can switch on the substrate variant or
//     on the `kind` string — both are stable.

import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainEvent;

import 'embedding_result.dart' show EmbeddingModelIdentity;
import 'llm_call.dart' show LlmCallReport;
import 'llm_stream_event.dart' show LlmFailure;

/// Marker / base for every typed substrate observability event.
///
/// A consumer subscribed to `TomBrainSubstrateClient.events()` sees
/// only subtypes of this class. Exhaustive `switch` over the closed
/// taxonomy is the recommended branch surface.
sealed class SubstrateEvent extends BrainEvent {
  SubstrateEvent({required super.occurredAt, super.runId, super.causedBy});
}

/// An LLM call was submitted (after role assembly + anchor injection,
/// before the wire request fires).
final class LlmCallStarted extends SubstrateEvent {
  /// Substrate-assigned call id. Matches the `callId` on
  /// [LlmStreamStarted] etc.
  final String callId;
  final String roleId;
  final String providerId;
  final String modelId;

  LlmCallStarted({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.callId,
    required this.roleId,
    required this.providerId,
    required this.modelId,
  });

  @override
  String get kind => 'substrate.llm-call-started';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'callId': callId,
        'roleId': roleId,
        'providerId': providerId,
        'modelId': modelId,
      };
}

/// Sampled progress event for a streaming call. Emitted per-chunk
/// (the substrate may sample to bound observer load); carries only
/// the count of characters in the chunk, not the chunk text itself.
final class LlmCallChunk extends SubstrateEvent {
  final String callId;
  final int charCount;

  LlmCallChunk({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.callId,
    required this.charCount,
  });

  @override
  String get kind => 'substrate.llm-call-chunk';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'callId': callId,
        'charCount': charCount,
      };
}

/// Successful completion. Carries the final [LlmCallReport]; trail
/// consumers persist the report verbatim.
final class LlmCallCompleted extends SubstrateEvent {
  final String callId;
  final LlmCallReport report;

  LlmCallCompleted({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.callId,
    required this.report,
  });

  @override
  String get kind => 'substrate.llm-call-completed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'callId': callId,
        'providerId': report.providerId,
        'modelId': report.modelId,
        'anchorHash': report.anchorHash,
        'promptHash': report.promptHash,
        'tokensIn': report.tokensIn,
        'tokensOut': report.tokensOut,
        'retries': report.retries,
        'wallClockMs': report.wallClockMs,
        if (report.cost != null) 'cost': report.cost,
        if (report.templateSha != null) 'templateSha': report.templateSha,
        if (report.notes.isNotEmpty) 'notes': report.notes,
      };
}

/// Failure event. Carries the [failure] taxonomy + the partial
/// [report] (whatever was known at the failure point).
final class LlmCallFailed extends SubstrateEvent {
  final String callId;
  final LlmFailure failure;
  final String providerId;
  final String modelId;
  final int retryCount;

  LlmCallFailed({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.callId,
    required this.failure,
    required this.providerId,
    required this.modelId,
    required this.retryCount,
  });

  @override
  String get kind => 'substrate.llm-call-failed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'callId': callId,
        'errorClass': failure.classCode,
        'message': failure.message,
        'providerId': providerId,
        'modelId': modelId,
        'retryCount': retryCount,
      };
}

/// The router moved the call to a different provider after a
/// failure on the first-choice provider. Emits exactly once per
/// rotation; `reason` is the failure class that triggered the
/// rotation (`rate_limit`, `billing`, …).
final class ProviderFailover extends SubstrateEvent {
  final String fromProviderId;
  final String toProviderId;
  final String reason;

  ProviderFailover({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.fromProviderId,
    required this.toProviderId,
    required this.reason,
  });

  @override
  String get kind => 'substrate.provider-failover';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'fromProviderId': fromProviderId,
        'toProviderId': toProviderId,
        'reason': reason,
      };
}

/// A credential was placed on cooldown by the router.
///
/// `credentialFingerprint` is a stable short hash of the credential
/// material — **never** the credential itself. The substrate
/// guarantees no event payload ever carries a raw token / API key.
final class CredentialCooldownStarted extends SubstrateEvent {
  final String profileId;
  final String credentialFingerprint;
  final String errorClass;

  /// Wall-clock at which the cooldown lifts (UTC ms since epoch).
  final int untilMs;

  CredentialCooldownStarted({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.profileId,
    required this.credentialFingerprint,
    required this.errorClass,
    required this.untilMs,
  });

  @override
  String get kind => 'substrate.credential-cooldown-started';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'profileId': profileId,
        'credentialFingerprint': credentialFingerprint,
        'errorClass': errorClass,
        'untilMs': untilMs,
      };
}

/// One embedding (or batch) completed.
final class EmbeddingComputed extends SubstrateEvent {
  final String providerId;
  final String modelId;
  final int dims;
  final int batchSize;

  EmbeddingComputed({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.providerId,
    required this.modelId,
    required this.dims,
    required this.batchSize,
  });

  @override
  String get kind => 'substrate.embedding-computed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'providerId': providerId,
        'modelId': modelId,
        'dims': dims,
        'batchSize': batchSize,
      };
}

/// The embedding-model identity changed (configuration reload,
/// provider failover for embeddings, etc.). Memory must stamp the
/// new identity on subsequent vectors; old vectors keep their old
/// identity.
final class EmbeddingIdentityChanged extends SubstrateEvent {
  final EmbeddingModelIdentity fromIdentity;
  final EmbeddingModelIdentity toIdentity;

  EmbeddingIdentityChanged({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.fromIdentity,
    required this.toIdentity,
  });

  @override
  String get kind => 'substrate.embedding-identity-changed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'fromIdentity': <String, Object?>{
          'providerId': fromIdentity.providerId,
          'modelId': fromIdentity.modelId,
          'dims': fromIdentity.dims,
          'normalized': fromIdentity.normalized,
        },
        'toIdentity': <String, Object?>{
          'providerId': toIdentity.providerId,
          'modelId': toIdentity.modelId,
          'dims': toIdentity.dims,
          'normalized': toIdentity.normalized,
        },
      };
}

/// A web search returned (or yielded zero results — still emitted).
final class WebSearchCompleted extends SubstrateEvent {
  final String provider;
  final String query;
  final int k;
  final int hits;

  WebSearchCompleted({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.provider,
    required this.query,
    required this.k,
    required this.hits,
  });

  @override
  String get kind => 'substrate.web-search-completed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'provider': provider,
        'query': query,
        'k': k,
        'hits': hits,
      };
}

/// A web fetch returned. `truncated` reflects whether the response
/// hit the per-call budget.
final class WebFetchCompleted extends SubstrateEvent {
  final String url;
  final int status;
  final int bytes;
  final bool truncated;

  WebFetchCompleted({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.url,
    required this.status,
    required this.bytes,
    required this.truncated,
  });

  @override
  String get kind => 'substrate.web-fetch-completed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'url': url,
        'status': status,
        'bytes': bytes,
        'truncated': truncated,
      };
}

/// An outbound MCP handshake completed and the tool catalogue was
/// fetched.
final class McpHandshakeCompleted extends SubstrateEvent {
  final String endpointId;
  final List<String> tools;

  McpHandshakeCompleted({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.endpointId,
    required this.tools,
  });

  @override
  String get kind => 'substrate.mcp-handshake-completed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'endpointId': endpointId,
        'tools': tools,
      };
}

/// One outbound MCP `callTool` round-trip completed.
final class McpCallCompleted extends SubstrateEvent {
  final String endpointId;
  final String tool;
  final int wallClockMs;
  final bool ok;

  McpCallCompleted({
    required super.occurredAt,
    super.runId,
    super.causedBy,
    required this.endpointId,
    required this.tool,
    required this.wallClockMs,
    required this.ok,
  });

  @override
  String get kind => 'substrate.mcp-call-completed';

  @override
  Map<String, Object?> payloadJson() => <String, Object?>{
        'endpointId': endpointId,
        'tool': tool,
        'wallClockMs': wallClockMs,
        'ok': ok,
      };
}
