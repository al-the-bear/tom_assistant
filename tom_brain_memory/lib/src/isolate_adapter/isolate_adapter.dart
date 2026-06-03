// Barrel for the `isolate_adapter/` module.
//
// Owns the procedure-engine bridge described in
// `memory_specification.md` § 3.3 — the isolate-safe adapter that
// lets the procedure engine (Phase B+ in a separate isolate) call
// the in-process `TomBrainMemory` surface without sharing state
// across isolate boundaries.
//
// Scope:
//
//   - Request/response message envelopes (sendable across SendPort).
//   - Argument and result serialisation for each `TomBrainMemory`
//     method (the same surface defined under `api/`).
//   - Back-pressure and budget enforcement on the adapter side: the
//     procedure engine cannot bypass per-procedure write budgets by
//     spamming the adapter.
//   - Lifecycle: adapter spin-up/tear-down tied to procedure-engine
//     isolate lifecycle.
//
// Hard invariants honoured here:
//
//   - § 1.5 — embeddings are owned by substrate, so the adapter never
//     carries embedding-generation requests; it carries vectors that
//     substrate already produced.
//   - § 5 — stack mutations through the adapter are still transactional
//     against `memory.db`; the adapter does not buffer them.
//
// Wiring across Phase A steps:
//
//   - A.23 ✅ — folder scaffold (this barrel).
//   - A.79 ✅ — `TomBrainMemoryIsolateHost` + minimal envelope
//             skeleton: `IsolateRequest`/`IsolateResponse` base
//             classes, lifecycle envelopes (`Ping`, `OpenMemory`,
//             `CloseMemory`), and one dispatch-proof pair
//             (`MemoryStatsRequest`/`MemoryStatsResponse`) so the
//             boundary is exercised end-to-end.
//   - A.80 ✅ — `TomBrainMemoryIsolateClient`: the thin
//               `TomBrainMemoryClient` implementation that wraps
//               this host. Methods whose envelope is already in
//               A.79's skeleton (`open`, `close`, `stats`) round-
//               trip end-to-end; every other method throws an
//               `EnvelopeNotWiredError` that A.81 will lift.
//   - A.81 ✅ — streaming + cancellation protocol shape for all
//               five stream-returning methods, plus end-to-end
//               wiring for `readTrail` (backpressure) and `events`
//               (cancellation).
//   - A.82 ✅ — full envelope catalogue (one per remaining
//               `TomBrainMemoryClient` method) + every method
//               (including `stacks` / `migrations` and the
//               remaining three streams) round-trips through the
//               isolate boundary. `EnvelopeNotWiredError` retired.
//   - A.85    — multi-machine variant (RPC over the canonical-
//               authority transport described in § 10).

export 'isolate_cancellation_protocol.dart'
    show
        CancelRequest,
        CancelResponse,
        CancellationException,
        CancellationHandle,
        CancellationRegistry,
        CancellationToken,
        CancellationTokenAllocator;
export 'isolate_envelopes_full.dart'
    show
        AppendTrailRequest,
        AppendTrailResponse,
        BeginRunRequest,
        BeginRunResponse,
        CheckpointRequest,
        CheckpointResponse,
        ClassifyRequest,
        ClassifyResponse,
        CreateEdgeRequest,
        CreateEdgeResponse,
        DemoteRequest,
        DemoteResponse,
        EdgesOfRequest,
        EdgesOfResponse,
        EndRunRequest,
        EndRunResponse,
        FindUncertainRequest,
        FindUncertainResponse,
        ForgetRequest,
        ForgetResponse,
        GetManyRequest,
        GetManyResponse,
        GetNodeRequest,
        GetNodeResponse,
        GetNodeTypeRequest,
        GetNodeTypeResponse,
        ListNodeTypesRequest,
        ListNodeTypesResponse,
        MigrationsCursorRequest,
        MigrationsCursorResponse,
        MigrationsListInProgressRequest,
        MigrationsListInProgressResponse,
        MigrationsSaveCursorRequest,
        MigrationsSaveCursorResponse,
        MigrationsStartRequest,
        MigrationsStartResponse,
        MigrationsStatusRequest,
        MigrationsStatusResponse,
        OpenEventsStreamRequest,
        OpenReadTrailStreamRequest,
        OpenStacksArchivedStreamRequest,
        OpenStacksEventsStreamRequest,
        OpenStreamQueryRequest,
        OpenTrailRequest,
        OpenTrailResponse,
        PersistRequest,
        PersistResponse,
        RecallRequest,
        RecallResponse,
        RegisterNodeTypeRequest,
        RegisterNodeTypeResponse,
        RemainingBudgetRequest,
        RemainingBudgetResponse,
        StacksCreateRequest,
        StacksCreateResponse,
        StacksDeleteRequest,
        StacksDeleteResponse,
        StacksInfoRequest,
        StacksInfoResponse,
        StacksListRequest,
        StacksListResponse,
        StacksPeekRequest,
        StacksPeekResponse,
        StacksPopRequest,
        StacksPopResponse,
        StacksPushRequest,
        StacksPushResponse,
        StacksRemoveRequest,
        StacksRemoveResponse,
        StacksUpdatePolicyRequest,
        StacksUpdatePolicyResponse,
        StacksUpdateRequest,
        StacksUpdateResponse,
        StreamOpenedResponse,
        TrailCloseRequest,
        TrailCloseResponse,
        UpdateCentroidRequest,
        UpdateCentroidResponse;
export 'isolate_messages.dart'
    show
        CloseMemoryRequest,
        CloseMemoryResponse,
        IsolateBoundaryException,
        IsolateErrorResponse,
        IsolateRequest,
        IsolateResponse,
        MemoryStatsRequest,
        MemoryStatsResponse,
        OpenMemoryRequest,
        OpenMemoryResponse,
        PingRequest,
        PongResponse;
export 'isolate_stream_protocol.dart'
    show
        BackpressureTracker,
        StreamCancelledEnvelope,
        StreamChunkEnvelope,
        StreamCloseRequest,
        StreamCloseResponse,
        StreamCompleteEnvelope,
        StreamErrorEnvelope,
        StreamId,
        StreamIdAllocator,
        StreamPullRequest,
        StreamPullResponse,
        StreamSideChannelMessage;
export 'memory_factory.dart' show MemoryFactory;
export 'tom_brain_memory_isolate_client.dart'
    show TomBrainMemoryIsolateClient;
export 'tom_brain_memory_isolate_host.dart' show TomBrainMemoryIsolateHost;
// `isolate_executor.dart` and `isolate_boot.dart` are intentionally
// *not* exported. The executor and boot context are construction
// details owned by the host; consumers should not reference them.
