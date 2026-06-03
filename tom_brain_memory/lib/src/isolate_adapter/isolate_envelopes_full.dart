// Full envelope catalogue for the isolate adapter (plan step A.82).
//
// A.79 shipped the lifecycle envelopes (`isolate_messages.dart`) plus
// one dispatch-proof pair (`MemoryStatsRequest` / `MemoryStatsResponse`).
//
// A.81 shipped the two stream-open proofs (`OpenReadTrailStreamRequest`,
// `OpenEventsStreamRequest`) plus the generic stream-opened response
// (`StreamOpenedResponse`), the cancellation protocol
// (`CancellationToken`, `CancelRequest`, `CancelResponse`) and the
// streaming control envelopes (`StreamPullRequest`, `StreamCloseRequest`,
// side-channel envelopes). Those three stream-open envelopes originally
// lived in a separate `isolate_envelopes.dart`; they were merged into
// this file (D.4.2) — see the "Stream-open envelopes" section at the
// bottom for their provenance.
//
// This file (A.82) adds one envelope pair per remaining
// `TomBrainMemoryClient` method so every public surface round-trips
// across the isolate boundary. The shape is mechanical:
//
//   * Each `Future<T> foo(...)` becomes `FooRequest` / `FooResponse`.
//     The response carries the typed return value; nullable returns
//     ride as nullable fields on the response.
//   * Each `Stream<T> bar(...)` becomes `OpenBarStreamRequest`. The
//     response is the generic `StreamOpenedResponse`. Chunks ride the
//     side channel.
//   * Methods on the `stacks` / `migrations` sub-APIs are flattened
//     into top-level envelopes whose names carry the sub-API prefix
//     (`StacksListRequest`, `MigrationsCursorRequest`). The proxy
//     classes on the client side multiplex them.
//
// Sendability:
//
//   Every field in every envelope here is composed of sendable shapes
//   (primitives, `Map`/`List` of sendable values, `Vec` whose backing
//   `Float32List` is sendable, value classes whose fields recursively
//   honour the rule). The `RecallQuery.reRank` closure is the one
//   un-sendable corner of the surface — the client rejects requests
//   that carry a non-null `reRank` with `ArgumentError.value` before
//   constructing the envelope (see `tom_brain_memory_isolate_client.dart`).

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show EdgeId, NodeId, StackEntryId, TrailId, Vec, WriteBudget;

import '../api/scope.dart';
import '../classification/classification_result.dart';
import '../edges/edge.dart';
import '../edges/edge_type.dart';
import '../migrations/migration_api.dart';
import '../nodes/node.dart';
import '../nodes/node_type_decl.dart';
import '../retrieval/recall_query.dart';
import '../retrieval/recall_result.dart';
import '../retrieval/stream_query.dart';
import '../stacks/stack_types.dart';
import '../trails/trail.dart';
import 'isolate_cancellation_protocol.dart';
import 'isolate_messages.dart';
import 'isolate_stream_protocol.dart';

// ─── Lifecycle (rest) ────────────────────────────────────────────────

/// Drive `memory.checkpoint()` inside the isolate. Forces a WAL
/// checkpoint and a JSONL fsync sweep.
final class CheckpointRequest extends IsolateRequest {
  const CheckpointRequest();
}

final class CheckpointResponse extends IsolateResponse {
  const CheckpointResponse();
}

// ─── WriteBudget enforcement ────────────────────────────────────────

final class BeginRunRequest extends IsolateRequest {
  final String runId;
  final WriteBudget budget;
  const BeginRunRequest({required this.runId, required this.budget});
}

final class BeginRunResponse extends IsolateResponse {
  const BeginRunResponse();
}

final class EndRunRequest extends IsolateRequest {
  final String runId;
  const EndRunRequest(this.runId);
}

final class EndRunResponse extends IsolateResponse {
  const EndRunResponse();
}

final class RemainingBudgetRequest extends IsolateRequest {
  final String runId;
  const RemainingBudgetRequest(this.runId);
}

/// Carries the remaining budget (or `null` when the run is not
/// registered). Nullable rather than absent so the host can
/// distinguish "registered with all zeros" from "not registered".
final class RemainingBudgetResponse extends IsolateResponse {
  final WriteBudget? budget;
  const RemainingBudgetResponse(this.budget);
}

// ─── Node CRUD ──────────────────────────────────────────────────────

final class PersistRequest extends IsolateRequest {
  final NodeDraft draft;
  final Scope scope;
  const PersistRequest({required this.draft, required this.scope});
}

final class PersistResponse extends IsolateResponse {
  final NodeId id;
  const PersistResponse(this.id);
}

final class GetNodeRequest extends IsolateRequest {
  final NodeId id;
  const GetNodeRequest(this.id);
}

final class GetNodeResponse extends IsolateResponse {
  final Node? node;
  const GetNodeResponse(this.node);
}

final class GetManyRequest extends IsolateRequest {
  final List<NodeId> ids;
  GetManyRequest(List<NodeId> ids) : ids = List<NodeId>.unmodifiable(ids);
}

final class GetManyResponse extends IsolateResponse {
  final List<Node> nodes;
  const GetManyResponse(this.nodes);
}

final class DemoteRequest extends IsolateRequest {
  final NodeId id;
  final DemotionReason reason;
  const DemoteRequest({required this.id, required this.reason});
}

final class DemoteResponse extends IsolateResponse {
  const DemoteResponse();
}

final class ForgetRequest extends IsolateRequest {
  final NodeId id;
  final ForgetReason reason;
  const ForgetRequest({required this.id, required this.reason});
}

final class ForgetResponse extends IsolateResponse {
  const ForgetResponse();
}

// ─── Edges ──────────────────────────────────────────────────────────

final class CreateEdgeRequest extends IsolateRequest {
  final NodeId from;
  final EdgeType type;
  final NodeId to;
  final Scope scope;
  final double weight;
  final Map<String, Object?>? attrs;
  CreateEdgeRequest({
    required this.from,
    required this.type,
    required this.to,
    required this.scope,
    this.weight = 1.0,
    Map<String, Object?>? attrs,
  }) : attrs =
            attrs == null ? null : Map<String, Object?>.unmodifiable(attrs);
}

final class CreateEdgeResponse extends IsolateResponse {
  final EdgeId id;
  const CreateEdgeResponse(this.id);
}

final class EdgesOfRequest extends IsolateRequest {
  final NodeId id;
  final EdgeDirection direction;
  final Set<EdgeType>? types;
  const EdgesOfRequest({
    required this.id,
    this.direction = EdgeDirection.both,
    this.types,
  });
}

final class EdgesOfResponse extends IsolateResponse {
  final List<Edge> edges;
  const EdgesOfResponse(this.edges);
}

// ─── Node-type registry ─────────────────────────────────────────────

final class RegisterNodeTypeRequest extends IsolateRequest {
  final NodeTypeDecl decl;
  const RegisterNodeTypeRequest(this.decl);
}

final class RegisterNodeTypeResponse extends IsolateResponse {
  const RegisterNodeTypeResponse();
}

final class ListNodeTypesRequest extends IsolateRequest {
  const ListNodeTypesRequest();
}

final class ListNodeTypesResponse extends IsolateResponse {
  final List<NodeTypeDecl> types;
  const ListNodeTypesResponse(this.types);
}

final class GetNodeTypeRequest extends IsolateRequest {
  final String typeName;
  const GetNodeTypeRequest(this.typeName);
}

final class GetNodeTypeResponse extends IsolateResponse {
  final NodeTypeDecl? decl;
  const GetNodeTypeResponse(this.decl);
}

// ─── Retrieval ──────────────────────────────────────────────────────

/// `recall` does not carry the `RecallQuery.reRank` closure — closures
/// are not sendable across isolate boundaries. The client rejects
/// requests with a non-null `reRank` before constructing this envelope
/// (Q-A.81.3 / Q-A.82.x). When LLM re-ranking is needed the consumer
/// must run the recall, then re-rank locally.
final class RecallRequest extends IsolateRequest {
  final RecallQuery query;
  const RecallRequest(this.query);
}

final class RecallResponse extends IsolateResponse {
  final RecallResult result;
  const RecallResponse(this.result);
}

/// Opens a `stream(StreamQuery)` cursor-backed scan. Backpressured —
/// per spec § 9.2 these scans can be huge.
final class OpenStreamQueryRequest extends IsolateRequest {
  final StreamId streamId;
  final StreamQuery query;
  final int initialCredits;
  final CancellationToken? cancellation;
  const OpenStreamQueryRequest({
    required this.streamId,
    required this.query,
    required this.initialCredits,
    this.cancellation,
  }) : assert(initialCredits > 0, 'initialCredits must be positive');
}

// ─── Classification ─────────────────────────────────────────────────

final class ClassifyRequest extends IsolateRequest {
  final Vec embedding;
  final ClassificationTarget target;
  const ClassifyRequest({
    required this.embedding,
    this.target = ClassificationTarget.nodeType,
  });
}

final class ClassifyResponse extends IsolateResponse {
  final ClassificationResult result;
  const ClassifyResponse(this.result);
}

final class UpdateCentroidRequest extends IsolateRequest {
  final String forKey;
  final Vec centroid;
  const UpdateCentroidRequest({required this.forKey, required this.centroid});
}

final class UpdateCentroidResponse extends IsolateResponse {
  const UpdateCentroidResponse();
}

final class FindUncertainRequest extends IsolateRequest {
  final String forKey;
  final double low;
  final double high;
  final int limit;
  const FindUncertainRequest({
    required this.forKey,
    required this.low,
    required this.high,
    this.limit = 200,
  });
}

final class FindUncertainResponse extends IsolateResponse {
  final List<NodeId> ids;
  const FindUncertainResponse(this.ids);
}

// ─── Stacks ─────────────────────────────────────────────────────────

final class StacksListRequest extends IsolateRequest {
  const StacksListRequest();
}

final class StacksListResponse extends IsolateResponse {
  final List<StackSummary> summaries;
  const StacksListResponse(this.summaries);
}

final class StacksInfoRequest extends IsolateRequest {
  final String name;
  const StacksInfoRequest(this.name);
}

final class StacksInfoResponse extends IsolateResponse {
  final StackInfo? info;
  const StacksInfoResponse(this.info);
}

final class StacksCreateRequest extends IsolateRequest {
  final StackDecl decl;
  const StacksCreateRequest(this.decl);
}

final class StacksCreateResponse extends IsolateResponse {
  const StacksCreateResponse();
}

final class StacksUpdatePolicyRequest extends IsolateRequest {
  final String name;
  final StackPolicy policy;
  const StacksUpdatePolicyRequest({required this.name, required this.policy});
}

final class StacksUpdatePolicyResponse extends IsolateResponse {
  const StacksUpdatePolicyResponse();
}

final class StacksDeleteRequest extends IsolateRequest {
  final String name;
  const StacksDeleteRequest(this.name);
}

final class StacksDeleteResponse extends IsolateResponse {
  const StacksDeleteResponse();
}

final class StacksPushRequest extends IsolateRequest {
  final String name;
  final NodeId entry;
  final double priority;
  final Map<String, Object?>? attrs;
  final Scope? scope;
  StacksPushRequest({
    required this.name,
    required this.entry,
    this.priority = 0.0,
    Map<String, Object?>? attrs,
    this.scope,
  }) : attrs =
            attrs == null ? null : Map<String, Object?>.unmodifiable(attrs);
}

final class StacksPushResponse extends IsolateResponse {
  final StackEntryId id;
  const StacksPushResponse(this.id);
}

final class StacksPeekRequest extends IsolateRequest {
  /// Default entry count when the caller does not specify `k`. The
  /// wire-contract owner of this default; the client's `peek(k:)`
  /// references it so the two cannot drift.
  static const int defaultK = 16;

  final String name;
  final int k;
  const StacksPeekRequest({required this.name, this.k = defaultK});
}

final class StacksPeekResponse extends IsolateResponse {
  final List<StackEntry> entries;
  const StacksPeekResponse(this.entries);
}

final class StacksPopRequest extends IsolateRequest {
  final String name;
  const StacksPopRequest(this.name);
}

final class StacksPopResponse extends IsolateResponse {
  final StackEntry? entry;
  const StacksPopResponse(this.entry);
}

final class StacksUpdateRequest extends IsolateRequest {
  final String name;
  final NodeId entry;
  final double? priority;
  final StackEntryStatus? status;
  final Map<String, Object?>? attrs;
  const StacksUpdateRequest({
    required this.name,
    required this.entry,
    this.priority,
    this.status,
    this.attrs,
  });
}

final class StacksUpdateResponse extends IsolateResponse {
  const StacksUpdateResponse();
}

final class StacksRemoveRequest extends IsolateRequest {
  final String name;
  final NodeId entry;
  const StacksRemoveRequest({required this.name, required this.entry});
}

final class StacksRemoveResponse extends IsolateResponse {
  const StacksRemoveResponse();
}

/// Opens `stacks.streamArchived(name, limit)`. Backpressured — the
/// archive can be huge for long-lived stacks.
final class OpenStacksArchivedStreamRequest extends IsolateRequest {
  final StreamId streamId;
  final String name;
  final int? limit;
  final int initialCredits;
  final CancellationToken? cancellation;
  const OpenStacksArchivedStreamRequest({
    required this.streamId,
    required this.name,
    required this.initialCredits,
    this.limit,
    this.cancellation,
  }) : assert(initialCredits > 0, 'initialCredits must be positive');
}

/// Opens `stacks.events(name)`. Unbounded — like `events()`. Required
/// cancellation token (only way to stop the stream from the client
/// side besides `StreamCloseRequest`).
final class OpenStacksEventsStreamRequest extends IsolateRequest {
  final StreamId streamId;
  final String name;
  final CancellationToken cancellation;
  const OpenStacksEventsStreamRequest({
    required this.streamId,
    required this.name,
    required this.cancellation,
  });
}

// ─── Trails ─────────────────────────────────────────────────────────

final class OpenTrailRequest extends IsolateRequest {
  final ProcedureRunRef run;
  const OpenTrailRequest(this.run);
}

final class OpenTrailResponse extends IsolateResponse {
  final TrailId id;
  const OpenTrailResponse(this.id);
}

final class AppendTrailRequest extends IsolateRequest {
  final TrailId id;
  final TrailEntry entry;
  const AppendTrailRequest({required this.id, required this.entry});
}

final class AppendTrailResponse extends IsolateResponse {
  const AppendTrailResponse();
}

/// Name `TrailCloseRequest` rather than `CloseTrailRequest` to avoid
/// visual collision with the streaming-control `StreamCloseRequest`
/// (different domain, different semantics).
final class TrailCloseRequest extends IsolateRequest {
  final TrailId id;
  final TrailOutcome outcome;
  const TrailCloseRequest({required this.id, required this.outcome});
}

final class TrailCloseResponse extends IsolateResponse {
  const TrailCloseResponse();
}

// ─── Migrations ─────────────────────────────────────────────────────

final class MigrationsStartRequest extends IsolateRequest {
  final MigrationDecl decl;
  const MigrationsStartRequest(this.decl);
}

final class MigrationsStartResponse extends IsolateResponse {
  const MigrationsStartResponse();
}

final class MigrationsCursorRequest extends IsolateRequest {
  final String migrationId;
  const MigrationsCursorRequest(this.migrationId);
}

final class MigrationsCursorResponse extends IsolateResponse {
  final MigrationCursor? cursor;
  const MigrationsCursorResponse(this.cursor);
}

final class MigrationsSaveCursorRequest extends IsolateRequest {
  final String migrationId;
  final Map<String, Object?> position;
  MigrationsSaveCursorRequest({
    required this.migrationId,
    required Map<String, Object?> position,
  }) : position = Map<String, Object?>.unmodifiable(position);
}

final class MigrationsSaveCursorResponse extends IsolateResponse {
  const MigrationsSaveCursorResponse();
}

final class MigrationsStatusRequest extends IsolateRequest {
  final String migrationId;
  const MigrationsStatusRequest(this.migrationId);
}

final class MigrationsStatusResponse extends IsolateResponse {
  final MigrationStatus? status;
  const MigrationsStatusResponse(this.status);
}

final class MigrationsListInProgressRequest extends IsolateRequest {
  const MigrationsListInProgressRequest();
}

final class MigrationsListInProgressResponse extends IsolateResponse {
  final List<MigrationStatus> statuses;
  const MigrationsListInProgressResponse(this.statuses);
}

// ════════════════════════════════════════════════════════════════════
// Stream-open envelopes (originally A.81's `isolate_envelopes.dart`).
//
// These three types shipped in plan step A.81 — the two stream-open
// proofs (`OpenReadTrailStreamRequest` for backpressure,
// `OpenEventsStreamRequest` for cancellation) plus the generic
// `StreamOpenedResponse` every stream-opening request replies with.
// They lived in a separate `isolate_envelopes.dart` only as an
// A.81/A.82 historical split; both files were always imported together
// (`isolate_executor.dart`, `tom_brain_memory_isolate_client.dart`),
// so they are merged here under one section comment preserving the
// provenance (D.4.2).
//
// Naming convention:
//
//   `OpenXStreamRequest` opens a stream — the response is a
//   `StreamOpenedResponse` carrying the freshly-allocated `StreamId`.
//   Subsequent chunk delivery rides the isolate-to-host side channel
//   (`sendToCreator(StreamChunkEnvelope)`). Closing the stream uses the
//   generic `StreamCloseRequest` from `isolate_stream_protocol.dart`;
//   pulling backpressure credits uses the generic `StreamPullRequest`;
//   cancelling uses the generic `CancelRequest`.
// ════════════════════════════════════════════════════════════════════

/// Reply to every `OpenXStreamRequest`. Carries the [streamId] the
/// host will use for routing chunks back through the side channel.
///
/// One response shape for every stream-opening envelope so the host
/// only needs one `host.send<StreamOpenedResponse>(...)` codepath
/// for opening any kind of stream.
final class StreamOpenedResponse extends IsolateResponse {
  /// The id assigned by the host (the client-side
  /// [StreamIdAllocator]). The executor echoes it back so the host
  /// can confirm the registration round-tripped.
  final StreamId streamId;

  const StreamOpenedResponse(this.streamId);
}

/// Opens a `readTrail(TrailId)` stream.
///
/// `readTrail` is the A.81 **backpressure proof**: chunks are paced
/// by a credit budget. The client primes the budget with
/// [initialCredits]; the executor pushes chunks while credits are
/// positive and pauses when they hit zero, resuming on
/// [StreamPullRequest] credit tops-ups.
///
/// Cancellation is supported via the same [cancellation] token
/// mechanism as every other cancellable request — the executor checks
/// the token's flag between every chunk push.
final class OpenReadTrailStreamRequest extends IsolateRequest {
  /// The client-allocated stream id. The host registers it in the
  /// stream router before sending the open envelope.
  final StreamId streamId;

  /// The trail to read.
  final TrailId trailId;

  /// Initial credit allowance on the per-stream
  /// [BackpressureTracker]. Must be positive.
  final int initialCredits;

  /// Optional cancellation token. When the host wants to abort an
  /// in-flight trail read, it sends a [CancelRequest] for this token
  /// and the executor honours it at the next chunk-boundary
  /// checkpoint.
  final CancellationToken? cancellation;

  const OpenReadTrailStreamRequest({
    required this.streamId,
    required this.trailId,
    required this.initialCredits,
    this.cancellation,
  }) : assert(initialCredits > 0, 'initialCredits must be positive');
}

/// Opens an `events()` stream.
///
/// `events()` is the A.81 **cancellation proof**: the stream is
/// unbounded (no backpressure — events are produced rarely and
/// consumers drive the rate), and the only way to stop it is the
/// cancellation token mechanism or a [StreamCloseRequest].
final class OpenEventsStreamRequest extends IsolateRequest {
  /// The client-allocated stream id.
  final StreamId streamId;

  /// Cancellation token. Required (not optional) because the only
  /// way to stop an unbounded stream from the client is the cancel
  /// path; making the token mandatory makes that intent visible at
  /// the type level.
  final CancellationToken cancellation;

  const OpenEventsStreamRequest({
    required this.streamId,
    required this.cancellation,
  });
}
