// ProcedureEngine — the engine's consumer-facing entry point (Plan step
// C.38; `tom_brain_procedure_specification.md` § 10.1, § 3, § 8).
//
// ── What invoke does ────────────────────────────────────────────────
//
// `invoke(ProcedureInvocation)` is the single seam the Phase D dispatcher
// drives a run through. For each invocation the engine:
//
//   1. resolves the procedure id → a `LoadedProcedure` (source + header)
//      through the injected resolver (C.25);
//   2. opens a `RunRecorder` (C.31) over the memory client, wiring its
//      `onEntry` observation seam to a live `Stream<TrailEntry>`;
//   3. boots a fresh sandboxed `D4rtDcliHost` (C.16) with the two brain
//      bridges and the engine-native primitives bound to *this* run — the
//      `note` primitive writes to this recorder, `runProcedure` recurses
//      back through the engine under the hard depth cap (C.19), and
//      `yield_if_foreground_waiting` reads the shared `PreemptionState`
//      (C.34/C.35);
//   4. runs the procedure source under a hard per-step `StepDeadline`
//      (C.36) — a step that overruns is force-yielded, recorded with a
//      `step_truncated` note, and the run closes `preempted` (the mapping
//      C.37 prototyped in a test double, now production here);
//   5. closes the recorder and resolves the handle's outcome.
//
// invoke returns a `ProcedureRun` *synchronously*; the pipeline runs on the
// event queue so a caller can subscribe to `run.trail` before the first
// entry is emitted.
//
// ── Cancellation + external timeout (C.39) ──────────────────────────
//
// `invoke` builds a `RunCancellation` per run and races the run's guarded
// step against its signal. A caller drives it two ways: explicitly
// (`run.cancel()`) or by passing `invoke(..., timeout: …)` so an elapsed
// wall-clock budget fires the signal. Either way the engine stops waiting on
// the step (the abandoned d4rt work may still finish, its result dropped),
// records a `run_cancelled` / `run_timed_out` trail note, and closes the run
// `aborted`. This is the external counterpart to the internal `StepDeadline`
// (C.36, which closes `preempted`).
//
// ── What C.39 deliberately does NOT own ─────────────────────────────
//
// Cancelling a parent abandons its whole sub-tree by abandoning the parent's
// step future; a nested `runProcedure` is not threaded its own cancellation
// (Q-C.39.2). The sugar aliases (`think`, `plan`, …) are C.40.
//
// ── Sandbox gate (§ 7, PE-1) ────────────────────────────────────────
//
// Every resolved procedure clears the static `SandboxValidator` before the
// host is built (`_runInternal`, right after `resolver.resolve`). The
// validator allows an `import` only of the host-injected bridge / input /
// engine-native libraries and bans `export` and the SDK-gateway identifiers
// (E.3.5 reconciled the old blanket import ban with the host's
// import-to-reach-`mem`/`sub` convention, Q-D.37.1). A violation propagates
// like a resolution failure — surfaced as an outcome error, no run recorded.
// The strict `Future<ProcedureResult>` entry-point shape — including
// ProcedureResult bridging into d4rt — does not yet exist, so a procedure's
// entry-point return is still coerced (a `ProcedureResult` passes through; a
// `Map` becomes a succeeded result; see Q-C.38.2). C.38 owns the entry point,
// the run handle, and the outcome — the machinery that roundtrips a procedure.

import 'dart:async';

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show TomBrainMemoryClient, TrailEntry, TrailEntryKind, TrailOutcomeStatus;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show PreemptionState, TurnContext, defaultNowUtc;

import '../bridges/bridge_call_recorder.dart';
import '../bridges/llm_call_observation.dart' show LlmCallObservation;
import '../bridges/mcp_bridge.dart' show McpBridge;
import '../bridges/memory_bridge.dart';
import '../bridges/substrate_bridge.dart';
import '../budget/budget.dart';
import '../d4rt_host/d4rt_dcli_host.dart';
import '../d4rt_host/procedure_parse_exception.dart';
import '../preemption/step_deadline.dart';
import '../primitives_native/emit_primitive.dart';
import '../primitives_native/native_primitives_installer.dart';
import '../primitives_native/note_primitive.dart';
import '../primitives_native/run_procedure_primitive.dart';
import '../primitives_native/trail_note.dart';
import '../primitives_native/yield_primitive.dart';
import '../bridges/tool_bridge.dart' show ToolBridge;
import '../mcp/mcp_client.dart' show McpClient;
import '../mcp/mcp_client_tool_source.dart'
    show McpClientToolSource, McpOfferedGate;
import '../tools/basic_tools.dart' show registerBasicTools;
import '../tools/file_scope.dart' show FileScope;
import '../tools/mcp_tool_source.dart' show McpToolDefinition, McpToolSource;
import '../tools/mcp_tools.dart' show McpBrainTool;
import '../tools/substrate_tool_embed_surface.dart'
    show SubstrateToolEmbedSurface;
import '../tools/substrate_tool_web_surface.dart' show SubstrateToolWebSurface;
import '../tools/session_todo_stores.dart' show SessionTodoStores;
import '../tools/todo_store.dart' show TodoStore;
import '../tools/tool_context.dart' show ToolContext;
import '../tools/tool_dream_surface.dart' show ToolDreamSurface;
import '../tools/process_run_surface.dart' show ProcessRunToolSurface;
import '../tools/tool_process_surface.dart' show ToolProcessSurface;
import '../tools/tool_event.dart'
    show ToolDenied, ToolEvent, ToolFailed, ToolInvoked, ToolNoticeSink;
import '../tools/tool_policy_config.dart' show ToolPolicyConfig;
import '../tools/tool_registry.dart' show ToolRegistry;
import '../procedure_store/procedure_loader.dart';
import '../procedure_store/procedure_resolver.dart';
import '../procedure_store/procedure_resolver_handle.dart';
import '../procedure_store/procedure_store_interface.dart';
import '../recorder/llm_trail_record.dart';
import '../recorder/memory_access_record.dart';
import '../recorder/memory_recall_notice.dart'
    show MemoryNoticeSink, MemoryRecallNotice;
import '../recorder/procedure_tree_record.dart';
import '../recorder/tool_access_record.dart';
import '../recorder/run_records.dart';
import '../recorder/run_recorder.dart';
import '../validator/sandbox_validator.dart';
import 'engine_tool_surface.dart';
import 'live_run_registry.dart';
import 'procedure_inputs.dart';
import 'procedure_invocation.dart';
import 'procedure_outcome.dart';
import 'procedure_result.dart';
import 'procedure_run.dart';
import 'run_cancellation.dart';

/// The neutral file-scope sandbox the per-run [ToolContext] is built over when
/// a deployment configures none. A run that enables the `file.*` tools supplies
/// a real, configured scope through [ProcedureEngine.toolFileScope] (threaded
/// from `tools.readScope` / `tools.writeScope` in the run config); this single
/// placeholder keeps the tool-calling path well-formed for the many tests that
/// never touch a real filesystem.
final FileScope _defaultToolFileScope =
    FileScope(writeRoots: const <String>['/tom-brain-engine']);

/// The typed failure class a crashed run is recorded under (§ 10.4).
const String _runtimeCrashKind = 'procedure.runtime.crash';

/// The typed failure class a source-parse failure is recorded under (§ 10.4).
///
/// Distinct from [_runtimeCrashKind] because the two route differently for
/// version-chain fallback: a runtime crash steps the chain to an older
/// version, a parse failure does not (an older version cannot repair a
/// syntactically broken newer source). Collapsing them would trigger a wrong
/// fallback on a parse error (Q-C.46.1).
const String _parseFailedKind = 'procedure.parse.failed';

/// The typed failure class an uncaught budget refusal is recorded under
/// (PE-8, § 14). Distinct from a crash: a refused call is a deliberate stop,
/// so the run closes `budgetExceeded` (not `errored`) and the version chain is
/// never stepped (an older version would hit the same cap). A procedure that
/// *catches* `ProcedureBudgetExceeded` never reaches this path — it adapts and
/// resolves normally.
const String _budgetExceededKind = ProcedureBudgetExceeded.errorKind;

// `producedNodeIdsOutputKey` — the reserved produced-node-ids key the engine
// splits off a body's outputs — is owned by `recorder/run_records.dart` (the
// recorder writes the matching `ProcedureRun` field), and is in scope here
// through the `run_records.dart` import above.

/// The depth the top-level procedure of an `invoke` runs at (§ 5.1 / C.19).
const int _topLevelDepth = 1;

/// Resolves, runs, records, and hands back procedure runs.
///
/// One engine serves many invocations; it holds the shared, run-independent
/// collaborators (the resolver, the memory client, the two bridges, the
/// preemption state) and builds a fresh recorder + host per run so each run
/// owns its trail and its native-primitive bindings.
final class ProcedureEngine {
  /// Builds an engine over its shared collaborators.
  ///
  /// [resolver] resolves a procedure id to a loaded source (C.25).
  /// [memory] is the client the run recorder writes trails and run nodes
  /// to (C.31). [memoryBridge] / [substrateBridge] are the bridged effect
  /// surfaces a procedure script reaches (C.12/C.13). [preemptionState] is
  /// the shared cooperative-preemption state the dispatcher's coordinator
  /// drives (C.34); a fresh one is created when omitted. [stepDeadline] is
  /// the hard per-step wall-clock cap (C.36). [deadlineTimerFactory] is the
  /// injectable timer the deadline arms (tests drive it deterministically).
  /// [hardDepthCap] bounds the `runProcedure` chain (C.19).
  /// [cancellationTimerFactory] is the injectable timer the external-timeout
  /// path (C.39) arms (tests drive it deterministically). [now] / [newRunId]
  /// are injectable for deterministic tests.
  /// [memoryWriteLimits] is the process-wide, NON-FATAL per-run write backstop
  /// (spec § 5.4): a fresh `MemoryWriteGuard` over these caps is built per run
  /// and threaded into that run's memory bridge, so a runaway write loop is
  /// skipped-and-reported rather than allowed to bloat the store or fail the
  /// run. Defaults to [MemoryWriteLimits.standard].
  ProcedureEngine({
    required ProcedureResolver resolver,
    ProcedureStore? procedureReloadStore,
    required this.memory,
    required this.memoryBridge,
    required this.substrateBridge,
    this.validator = SandboxValidator.shared,
    this.toolDreamSurface,
    this.toolProcessSurface = const ProcessRunToolSurface(),
    this.mcpClient,
    this.mcpTools = const <McpToolDefinition>[],
    this.mcpOffered,
    FileScope? toolFileScope,
    PreemptionState? preemptionState,
    Duration stepDeadline = defaultStepDeadline,
    DeadlineTimerFactory? deadlineTimerFactory,
    CancellationTimerFactory? cancellationTimerFactory,
    int hardDepthCap = RunProcedurePrimitive.defaultHardDepthCap,
    DateTime Function()? now,
    String Function()? newRunId,
    LlmTrailSink? llmTrailSink,
    MemoryAccessSink? memoryAccessSink,
    ToolAccessSink? toolAccessSink,
    ProcedureTreeSink? procedureTreeSink,
    this.memoryWriteLimits = MemoryWriteLimits.standard,
    SessionTodoStores? sessionTodoStores,
  })  : _resolverHandle = procedureReloadStore == null
            ? ProcedureResolverHandle.fixed(resolver)
            : ProcedureResolverHandle.reloading(procedureReloadStore, resolver),
        toolFileScope = toolFileScope ?? _defaultToolFileScope,
        sessionTodoStores = sessionTodoStores ?? SessionTodoStores(),
        preemptionState = preemptionState ?? PreemptionState(),
        _stepDeadlineLimit = stepDeadline,
        _deadlineTimerFactory = deadlineTimerFactory,
        _cancellationTimerFactory = cancellationTimerFactory,
        _hardDepthCap = hardDepthCap,
        _now = now ?? defaultNowUtc,
        _newRunId = newRunId ?? _defaultRunIdGenerator(),
        _llmTrailSink = llmTrailSink,
        _memoryAccessSink = memoryAccessSink,
        _toolAccessSink = toolAccessSink,
        _procedureTreeSink = procedureTreeSink;

  /// The refreshable holder around the version resolver (C.25). Reloading
  /// when the engine was given a `procedureReloadStore`, fixed otherwise. The
  /// engine refreshes it once per top-level run (in [invoke]) so an edited
  /// script is picked up on the next run (`prompt_tracing.md` § 6.3, AUTH-5)
  /// while a turn always resolves against one fixed snapshot.
  final ProcedureResolverHandle _resolverHandle;

  /// Resolves a procedure id (and optional version) to a loaded source —
  /// the current snapshot held by [_resolverHandle].
  ProcedureResolver get resolver => _resolverHandle.current;

  /// The memory client the recorder writes every run to.
  final TomBrainMemoryClient memory;

  /// The process-lifetime per-session todo registry (§ 21.4). The engine binds
  /// each run's `ToolContext.todos` to the store of the run's
  /// [ProcedureInvocation.sessionId], so a session's working todo list survives
  /// from one prompt to the next within a conversation; a session-less run
  /// (turn-less / internal / dream, [ProcedureInvocation.sessionId] `null`) gets
  /// a fresh per-run store instead. Exposed so the access layer's inspector seam
  /// (`/todos_list` / `/todos_clear`) can read and reset a session's list off
  /// the booted engine.
  ///
  /// Injected so a production boot can pass a [SessionTodoStores.persistentAt]
  /// (a JSON-file-backed registry under the memory root) — making a session's
  /// working todo list survive a restart — while tests and a root-less boot get
  /// the in-memory default.
  final SessionTodoStores sessionTodoStores;

  /// The process-lifetime registry of in-flight runs (`/check_usage`). The
  /// engine opens a [LiveRun] when a run's recorder starts and closes it when
  /// the run finishes, so an out-of-band observer can read the live accumulating
  /// effort of the prompt currently being processed. Exposed so the access
  /// layer's inspector seam (`/check_usage`) can read the live budget off the
  /// booted engine.
  final LiveRunRegistry liveRunRegistry = LiveRunRegistry();

  /// The static sandbox gate every resolved procedure clears before it runs.
  ///
  /// PE-1's static half (§ 7): a procedure whose source imports a library
  /// outside the host-injected bridge / input / engine-native set, or names a
  /// disallowed SDK identifier, is rejected before any effect surface is built
  /// — the violation surfaces as an outcome error and no run is recorded, the
  /// same shape as an unresolvable id. The host's doc states the validator
  /// "gates source *before* it reaches here"; this is where that gate lives
  /// (Q-D.37.1). Defaults to [SandboxValidator.shared].
  final SandboxValidator validator;

  /// Template for the bridged memory surface a procedure script reaches as
  /// `mem`. Its `client` is rebound to a per-run recording bridge in
  /// `_runInternal` (E.3.2); the template instance itself is never
  /// dispatched through.
  final MemoryBridge memoryBridge;

  /// Template for the bridged substrate surface a procedure script reaches
  /// as `sub`. Its `client` is rebound to a per-run recording bridge in
  /// `_runInternal` (E.3.2); the template instance itself is never
  /// dispatched through.
  final SubstrateBridge substrateBridge;

  /// The shared cooperative-preemption state the engine yields against and
  /// the dispatcher's coordinator drives.
  final PreemptionState preemptionState;

  /// The process-wide NON-FATAL per-run memory-write caps (spec § 5.4). A fresh
  /// [MemoryWriteGuard] over these is built per run in `_runInternal` and
  /// threaded into the run's memory bridge: a write that would exceed a cap, or
  /// a duplicate edge within the run, is skipped (the side effect never runs),
  /// reported on the run trail as a `memory_write_skipped` note, and the run
  /// continues — an answer already produced is never silenced by a later write.
  final MemoryWriteLimits memoryWriteLimits;

  /// The configured two-tier file sandbox every per-run [ToolContext] is built
  /// over (§ 21.4). The file tools resolve and path-escape-check against it: a
  /// read tool against `readableRoots`, a write/delete tool against
  /// `writeableRoots`, so a `file.*` call may reach a configured directory but
  /// nothing outside its tier. The first writeable root is the primary
  /// (`file.write` target). A deployment threads its real scope here from
  /// `tools.readScope` / `tools.writeScope`; tests fall back to a placeholder.
  final FileScope toolFileScope;

  /// The optional dreaming-control surface every per-run [ToolContext] is built
  /// over (`memory_specification.md` § 9.7), or `null` when the cognition booted
  /// without a dreaming cadence. The run assembly (tom_brain_run) threads a
  /// late-bound surface here that it points at its `DreamController` once that
  /// controller is built post-boot; the `dream.control` tool routes through it,
  /// and a context without it raises `ToolSurfaceUnavailable`.
  final ToolDreamSurface? toolDreamSurface;

  /// The allow-listed process surface every per-run [ToolContext] is built over
  /// (`creation_specification.md` § 5.2–§ 5.4). The `analyze.*` / `test.*` tools
  /// name an executable (`dart` / `testkit` / `tom`) and hand it here; the
  /// surface — not the tool — runs it, refusing anything off its fixed allow-list
  /// with `ProcessExecutableNotAllowed` before a process is spawned, so the
  /// `create_v1` check phase has no general-shell capability. Defaults to the
  /// real [ProcessRunToolSurface]; tests inject a fake to avoid spawning.
  final ToolProcessSurface toolProcessSurface;

  /// The process-spanning external-MCP client every per-run [ToolContext] /
  /// [McpBridge] is built over (§ 21.3), or `null` when no MCP servers are
  /// configured. When present, the engine (1) registers the cached [mcpTools]
  /// as merged `mcp__*` `BrainTool`s in the run's tool registry — so the model
  /// is offered them in the same `tool.list` and calls them through the same
  /// tool-calling loop (request f, "external MCP servers as part of the tool
  /// loop") — (2) carries an [McpClientToolSource] on the run's
  /// `ToolContext.mcp` so a merged tool's call forwards to the right server, and
  /// (3) binds an [McpBridge] as the host's `mcp` global so a procedure may also
  /// call the `mcp.servers` / `mcp.list` / `mcp.call` primitives directly. A
  /// merged tool and a direct `mcp.call` are alternatives — neither
  /// double-charges the budget (PE-8).
  final McpClient? mcpClient;

  /// The external-MCP tool descriptors merged into every run's tool registry
  /// (request f), fetched once at boot (so the per-run hot path makes no network
  /// call to list). Empty when [mcpClient] is `null` or no server advertised a
  /// tool. A merged tool's call still reaches its server live through the
  /// [mcpClient] (carried on `ToolContext.mcp`).
  final List<McpToolDefinition> mcpTools;

  /// The dynamic `offered = exposeToLlms && isLive` gate threaded onto every
  /// per-run [McpClientToolSource] (request c, § 3.3). When bound, a merged
  /// `mcp__*` tool whose server is currently un-offered (statically closed or
  /// flipped dead by the liveness monitor) is skipped from enumeration and
  /// raises `ToolSurfaceUnavailable` on invoke, so a dead server drops out of
  /// the tool loop with no process restart. `null` leaves every configured
  /// server unconditionally offered (the pre-request-c behaviour).
  final McpOfferedGate? mcpOffered;

  final Duration _stepDeadlineLimit;
  final DeadlineTimerFactory? _deadlineTimerFactory;
  final CancellationTimerFactory? _cancellationTimerFactory;
  final int _hardDepthCap;
  final DateTime Function() _now;
  final String Function() _newRunId;

  /// The raw-LLM-trail sink (`tom_brain_logging.md` §5.2 / §10 step #4).
  /// `null` leaves the engine emitting no raw LLM trail; when bound, each
  /// run's substrate bridge fires one [LlmCallObservation] per completed `llm`
  /// call, which the engine wraps with run-correlation into an [LlmTrailRecord]
  /// and hands here (the host binds an `LlmTrailWriter`).
  final LlmTrailSink? _llmTrailSink;

  /// The per-profile memory-access sink (`tom_brain_logging.md` §5.6 / §10 step
  /// #8). `null` leaves the engine emitting no per-profile memory log; when
  /// bound, each run's memory bridge reports one bridged-memory call which the
  /// engine wraps with run-correlation + the request's memory profile into a
  /// [MemoryAccessRecord] and hands here (the host binds a
  /// `MemoryProfileLogWriter`).
  final MemoryAccessSink? _memoryAccessSink;

  /// The per-run tool-access sink (the trail half of "tool calls must be in
  /// the trails files, especially the live-trail"). `null` leaves the engine
  /// wiring no `onEvent` onto the run's tool bridge, so no tool record is
  /// emitted; when bound, each `tool.list` / `tool.invoke` the run issues fires
  /// a typed [ToolEvent] which the engine wraps with run-correlation (`runId`,
  /// the live `trailId`, the turn it serves) into a [ToolAccessRecord] and
  /// hands here (the host binds a live-trail writer).
  final ToolAccessSink? _toolAccessSink;

  /// The combined per-procedure tree sink (`tom_brain_logging.md` §5.7 / §10
  /// step #9). `null` leaves the engine emitting no per-procedure tree; when
  /// bound, each *top-level* (or turn-less dream) run assembles one
  /// [ProcedureTreeRecord] — the run's own trail entries as nodes, with each
  /// nested `runProcedure`'s sub-record spliced in at its call position — and
  /// hands it here (the host binds a `ProcedureTreeWriter`). A nested run
  /// bubbles its sub-record up to its parent instead of firing this sink.
  final ProcedureTreeSink? _procedureTreeSink;

  /// Runs the procedure named by [invocation] and returns its handle.
  ///
  /// The handle's [ProcedureRun.trail] streams trail entries live; its
  /// [ProcedureRun.outcome] resolves to the terminal [ProcedureOutcome], and
  /// [ProcedureRun.cancel] abandons the run (C.39). Returns synchronously —
  /// the run pipeline is scheduled on the event queue so a caller can
  /// subscribe to the trail before the run advances. An unresolvable
  /// procedure id surfaces as an error on the outcome future (there is no run
  /// to record).
  ///
  /// When [timeout] is supplied the run is closed `aborted` if it has not
  /// finished within that wall-clock budget — the external counterpart to the
  /// internal per-step deadline (C.36). [timeout] must be strictly positive.
  ///
  /// When [tokenSink] is supplied (the external/user request path, P1.3 #8)
  /// the engine binds it both to the per-run substrate bridge (every
  /// `sub.llm(...)` chunk is forwarded as it arrives) and to the `emit`
  /// primitive (text the body authors itself), so the run streams its answer
  /// increment-by-increment rather than only returning a whole-text result.
  /// Left `null` for an internal secondary / free-time run, where the
  /// substrate forwarding and `emit` both fall back to buffer-only no-ops.
  /// A [tokenSink] is bound only to the top-level run; nested `runProcedure`
  /// calls do not inherit it (the answer is streamed by the top-level body).
  ///
  /// When [noticeSink] is supplied (the external/user request path) the engine
  /// fires it for each tool [ToolEvent] this run's tool bridge emits, so the
  /// dispatch route can surface the call to the originating channel as an
  /// out-of-band notice (`OutboundChunk.notice`). Like [tokenSink], it is bound
  /// only to the top-level run; nested runs do not inherit it. Best-effort —
  /// the engine never awaits it and swallows its errors.
  ///
  /// When [thinkingSink] is supplied (the external/user request path, § 9.2
  /// Todo 6) the engine binds it to the per-run substrate bridge's thinking
  /// channel, so a tool-deciding turn's `call:NAME{…}` text (and any
  /// thinking-channel role's completion) reaches the originating channel as an
  /// out-of-band notice rather than folding into the streamed answer. Like
  /// [tokenSink] / [noticeSink] it is bound only to the top-level run.
  /// When [memoryNoticeSink] is supplied (the external/user request path, the
  /// `/trace_memory` toggle) the engine fires it for each `recall` /
  /// `recallMulti` call this turn issues, so the dispatch route can surface the
  /// retrieval steps to the originating channel as out-of-band notices. Unlike
  /// [tokenSink] / [noticeSink] / [thinkingSink], it is threaded to *every*
  /// nested run, not just the top-level one — memory recall happens inside
  /// nested runs (`retrieve_for_prompt_v1`, the `recall_*` strategies), never
  /// the top-level body. Best-effort — the engine never awaits it and swallows
  /// its errors.
  ProcedureRun invoke(
    ProcedureInvocation invocation, {
    Duration? timeout,
    OutboundDeltaSink? tokenSink,
    ToolNoticeSink? noticeSink,
    SubstrateThinkingSink? thinkingSink,
    MemoryNoticeSink? memoryNoticeSink,
  }) {
    final runId = invocation.runId ?? _newRunId();
    final trail = StreamController<TrailEntry>.broadcast();
    final outcome = Completer<ProcedureOutcome>();
    final cancellation = RunCancellation(
      timeout: timeout,
      timerFactory: _cancellationTimerFactory,
    );

    // One TurnContext per turn (logging-spec §3 / §9), built from the
    // access-edge-minted turnId and shared across every nested run of the turn
    // so the per-turn `callSeq` counter spans sub-procedures. A turn-less
    // invocation (internal / free-time / dream) leaves it `null`, so its
    // substrate calls stay unstamped. The invocation's `sessionId` (the live
    // tom_brain session this turn serves) rides along so the `SubstrateBridge`
    // can stamp it onto each call's `brainSessionId` (agent-SDK spec § 1.5).
    final turn = invocation.turnId == null
        ? null
        : TurnContext(invocation.turnId!, brainSessionId: invocation.sessionId);

    unawaited(
      Future<void>(() async {
        try {
          // Top-level-run entry: pick up any edited script before resolving
          // (`prompt_tracing.md` § 6.3, AUTH-5). Signature-gated, so an
          // unchanged script set costs only a stat sweep; a fixed handle is a
          // no-op. Done here (not per nested run) so the whole turn resolves
          // against one fixed snapshot — within-turn purity is preserved.
          await _resolverHandle.maybeRefresh();
          final result = await _runInternal(
            runId: runId,
            procedureId: invocation.procedureId,
            version: invocation.version,
            inputs: invocation.inputs,
            arguments: invocation.arguments,
            parentRunId: invocation.parentRunId,
            depth: _topLevelDepth,
            onEntry: trail.add,
            cancellation: cancellation,
            tokenSink: tokenSink,
            noticeSink: noticeSink,
            thinkingSink: thinkingSink,
            memoryNoticeSink: memoryNoticeSink,
            turn: turn,
            profile: invocation.memoryProfile,
            sessionId: invocation.sessionId,
          );
          outcome.complete(result);
        } catch (error, stack) {
          outcome.completeError(error, stack);
        } finally {
          // Disarm a pending timeout timer once the run has resolved, so it
          // cannot fire against an already-closed run.
          cancellation.dispose();
          await trail.close();
        }
      }),
    );

    return ProcedureRun(
      runId: runId,
      procedureId: invocation.procedureId,
      trail: trail.stream,
      outcome: outcome.future,
      cancellation: cancellation,
    );
  }

  /// Resolves, runs, records, and closes one run (top-level or nested).
  ///
  /// [onEntry] is the live-trail seam — `trail.add` for the top-level run,
  /// `null` for a nested run (a nested run owns its own trail and is not
  /// surfaced on the parent's stream). [cancellation] is the C.39 cancel +
  /// external-timeout control — present for the top-level run, `null` for a
  /// nested run (cancelling a parent abandons its sub-tree by abandoning the
  /// parent's step future; see Q-C.39.2). Resolution failure propagates (the
  /// caller turns it into an outcome error); a procedure crash is caught,
  /// classified (`procedure.parse.failed` for a source-parse failure,
  /// `procedure.runtime.crash` otherwise — Q-C.46.1), recorded as `errored`,
  /// and returned as an outcome carrying the error; a cancelled or timed-out
  /// run is closed `aborted`.
  ///
  /// [tokenSink] is the per-run outbound channel (P1.3 #8) — bound to the
  /// substrate bridge's `onToken` and the `emit` primitive's sink for the
  /// top-level external run, `null` for a nested run (the top-level body owns
  /// the answer stream; a nested `runProcedure` does not re-stream).
  ///
  /// [sessionId] is the conversation session the run serves (access spec
  /// § 21.10), threaded down so the run's `ToolContext.todos` binds to the
  /// session's persistent store (and every nested run of the session shares it)
  /// — so the working todo list survives across the runs of one conversation.
  /// `null` for a turn-less / internal / dream run, which gets a fresh per-run
  /// store instead.
  ///
  /// [onTree] is the combined-tree bubble seam (§5.7 / §10 step #9): `null` for
  /// the top-level run (which emits its assembled [ProcedureTreeRecord] to the
  /// engine's `_procedureTreeSink`), and the parent's "splice my sub-record in
  /// at this call position" callback for a nested run. Only set when a tree
  /// sink is bound; otherwise no tree is assembled at all.
  Future<ProcedureOutcome> _runInternal({
    required String runId,
    required String procedureId,
    required int? version,
    required ProcedureInputs inputs,
    required Map<String, Object?> arguments,
    required String? parentRunId,
    required int depth,
    void Function(TrailEntry entry)? onEntry,
    RunCancellation? cancellation,
    OutboundDeltaSink? tokenSink,
    ToolNoticeSink? noticeSink,
    SubstrateThinkingSink? thinkingSink,
    MemoryNoticeSink? memoryNoticeSink,
    TurnContext? turn,
    String? profile,
    String? sessionId,
    void Function(ProcedureTreeRecord tree)? onTree,
  }) async {
    final LoadedProcedure loaded = resolver.resolve(procedureId, version: version);

    // Static sandbox gate (§ 7, PE-1): a procedure that imports outside the
    // host-injected surface or names a disallowed identifier never reaches the
    // host. A violation propagates like a resolution failure — surfaced as an
    // outcome error, with no run recorded (the procedure never started).
    validator.validate(loaded);

    final recorder = RunRecorder(memory, now: _now, onEntry: onEntry);

    // Combined per-procedure tree seam (§5.7 / §10 step #9). The tree is built
    // only when a sink is bound — every run (top-level or nested) under a bound
    // sink assembles its own [ProcedureTreeRecord]; a top-level run emits it to
    // `_procedureTreeSink`, a nested run bubbles it up to its parent via
    // [onTree]. Two per-run captures feed the assembly: the run's `llm`
    // observations (zipped against its `llm` primitive-call entries for the
    // link facts) and the positioned sub-records of its nested `runProcedure`
    // calls (spliced in at the call position). Left empty (and unread) when no
    // tree is built.
    final treeSink = _procedureTreeSink;
    final buildTree = treeSink != null;
    final llmObservations = <LlmCallObservation>[];
    final childTrees = <_PositionedChildTree>[];
    // Positioned `tool.invoke`-family events (§5.7.1). A `tool.invoke` records
    // no trail entry — it rides only the bridge's `onEvent` seam — so the tree
    // would otherwise never see it. Each invoke/fail/deny event is captured
    // here paired with the parent-trail index it fired at (`recorder.entries
    // .length` at emission), so the assembly splices a `ProcedureToolNode` in
    // at that position the same way a nested run's subtree is. `tool.list`
    // (an enumeration, not an effect) is filtered out — it never reaches the
    // tree. Left empty (and unread) when no tree is built.
    final toolNodes = <_PositionedToolNode>[];

    // Bind the bridges to *this* run's recorder so every effect call lands on
    // the run's trail and folds into its effort tally (E.3.2). The engine's
    // `memoryBridge` / `substrateBridge` are shared templates; dispatching
    // through them directly would force one mutable observer across concurrent
    // runs, so a fresh recording instance over the same client is built per
    // run (the deferred composition-root wiring, Q-C.44.1).
    final recordCall = recorder.recordPrimitiveCall;

    // One budget ledger over this run's header budget, shared by both bridges
    // so token / tool-call / memory-write spend accumulates in a single place
    // across memory and substrate calls (PE-8). `null` when the budget
    // enforces no count/spend cap (a wall-clock-only budget — the deadline
    // owns that), so the bridges keep their zero-overhead fast path.
    final ledger = BudgetLedger(loaded.header.budget);
    final runBudget = ledger.enforces ? ledger : null;

    // The read-only budget view a procedure reaches as the `budget` global
    // (§ 5.4.2): the header limit and live remaining for the token / wall-clock
    // / tool-call dimensions. Built over *this* run's ledger (token / tool-call
    // remaining read its `consumed`, the same source the fatal gate reads) and
    // an elapsed clock armed now (wall-clock remaining, which the ledger does
    // not track). Bound on every run — uncapped dimensions report `null`, so a
    // wall-clock-only header (the answer budget) still exposes its time budget.
    final runStartedAt = _now();
    final budgetView = BudgetView(
      ledger: ledger,
      elapsed: () => _now().difference(runStartedAt),
    );

    // The per-run bridge preserves the template bridge's agent identity
    // (PE-10 / memory § 9): when the engine is wired for a cognitive-agent
    // run (a dream/maintenance procedure), `memoryBridge.agentName` names the
    // registered agent and every write this run issues carries it, so the
    // memory store's `AgentRegistry` confines the run to its declared scopes.
    // A user-facing run leaves it `null` and writes unscoped.
    //
    // Per-profile memory-log seam (§5.6 / §10 step #8): when a memory-access
    // sink is bound, compose it over the trail recorder so every bridged
    // memory call this run issues — recall / persist / edge / stackPush — is
    // both recorded on the run trail *and* wrapped (with this run's `runId`,
    // the live `trailId`, the turn it serves, and the request's memory
    // `profile`) into a [MemoryAccessRecord] for the per-profile writer. The
    // substrate bridge keeps the plain `recordCall` (below), so `llm` calls
    // fold into the run trail but never reach the memory sink. The wrapped
    // call awaits `recordCall` first (its trail/metrics effect is load-bearing)
    // then fires the sink best-effort: a throwing writer is swallowed so it
    // cannot break the run.
    // Two best-effort observers ride the one per-run memory seam: the process
    // [_memoryAccessSink] (the §5.6 per-profile memory log) and the per-run
    // [memoryNoticeSink] (the `/trace_memory` toggle — surfaces each recall to
    // the originating channel as out-of-band notices). With both unbound the
    // bridge keeps the plain `recordCall` fast path; either failing is swallowed
    // so neither logging nor a trace message can break the run.
    final memoryAccessSink = _memoryAccessSink;
    final BridgeCallRecorder recordMemoryCall =
        (memoryAccessSink == null && memoryNoticeSink == null)
            ? recordCall
            : (primitive, input, result, {int? elapsedMs}) async {
                await recordCall(primitive, input, result, elapsedMs: elapsedMs);
                if (memoryAccessSink != null) {
                  try {
                    memoryAccessSink(MemoryAccessRecord(
                      primitive: primitive,
                      input: input,
                      result: result,
                      elapsedMs: elapsedMs,
                      profile: profile,
                      runId: runId,
                      trailId: recorder.isOpen ? recorder.trailId.value : null,
                      turnId: turn?.turnId.value,
                      at: _now(),
                    ));
                  } catch (_) {
                    // Trail writing is non-essential; never break the run.
                  }
                }
                if (memoryNoticeSink != null) {
                  final notice =
                      MemoryRecallNotice.fromCall(primitive, result);
                  if (notice != null) {
                    try {
                      memoryNoticeSink(notice);
                    } catch (_) {
                      // A dropped trace must never break the run.
                    }
                  }
                }
              };
    // Per-run non-fatal write backstop (spec § 5.4). A fresh guard over the
    // process's caps bounds this run's writes and dedups its edges; a skipped
    // write fires a `memory_write_skipped` note on the run trail (the recorder
    // is open by the time any body runs) and the run continues. This is the
    // backstop for user-facing procedures, whose virtually-unlimited header
    // budget leaves the fatal `BudgetLedger` enforcing nothing.
    final writeGuard = MemoryWriteGuard(memoryWriteLimits);
    final runMemoryBridge = MemoryBridge(
      memoryBridge.client,
      onCall: recordMemoryCall,
      budget: runBudget,
      agentName: memoryBridge.agentName,
      writeGuard: writeGuard,
      onWriteSkipped: (skip) {
        if (!recorder.isOpen) return;
        recorder.noteSink(TrailNote(
          category: 'memory_write_skipped',
          recordedAt: _now(),
          payload: <String, Object?>{
            'primitive': skip.primitive,
            'outcome': skip.outcome.name,
            'detail': skip.detail,
          },
        ));
      },
    );
    // Bind the run's outbound channel (P1.3 #8) to both halves of the
    // streaming seam: the substrate bridge forwards each `sub.llm(...)` chunk
    // through `onToken`, and the `emit` primitive forwards text the body
    // authors itself — the same closure on both so they share one ordered
    // wire. `null` on a nested or internal run leaves both buffer-only.
    // Raw-LLM-trail seam (§5.2 / §10 step #4): when a sink is bound, wrap each
    // bridge observation with this run's correlation (`runId`, and the live
    // `trailId` once the recorder's trail is open) and hand it to the writer.
    // `trailId` is read lazily inside the closure because it fires during
    // `llm()`, after `recorder.start()` opened the trail. Best-effort: a
    // throwing sink is swallowed so it cannot break the completion.
    // The combined tree (§5.7) needs the same observation in lockstep with the
    // run's `llm` primitive-call entries, so the observer also captures it when
    // a tree is built — even if no raw-trail writer is bound.
    final llmTrailSink = _llmTrailSink;

    final runPrimitive = RunProcedurePrimitive(
      // Capture the parent's trail length *synchronously* at the call site so
      // the nested run's sub-record can later be spliced in at exactly this
      // position (§5.7): the assembly flushes any child whose `position`
      // equals the parent entry index it is about to process. `onTree` is the
      // nested run's "splice me here" bubble — wired only when a tree is built.
      executor: (call) {
        final position = recorder.entries.length;
        return _executeNested(
          call,
          parentRunId: runId,
          turn: turn,
          profile: profile,
          sessionId: sessionId,
          // Stream-sink inheritance (§9.2 + increment-6 migration). A nested
          // `runProcedure` does *not* re-stream by default — the answer is the
          // top-level body's to deliver. The one exception is the shared
          // `tool_loop_v1` the migrated answer path delegates its user-facing
          // completion to (via `sub.run`): the user-facing tokens now arise
          // *inside* that nested loop, so it must inherit this frame's outbound
          // sinks to stream the answer / thinking channels exactly as the
          // pre-migration inline loop did. Every other nested run (the recall
          // conductor, the `recall_*` strategies, a scripted sub-procedure)
          // stays sink-less.
          tokenSink: call.id == SubstrateBridge.toolLoopProcedureId
              ? tokenSink
              : null,
          thinkingSink: call.id == SubstrateBridge.toolLoopProcedureId
              ? thinkingSink
              : null,
          noticeSink: call.id == SubstrateBridge.toolLoopProcedureId
              ? noticeSink
              : null,
          // The memory-recall trace, unlike the streaming sinks, is threaded
          // to *every* nested run: recall happens inside nested runs, so a
          // tool_loop_v1-only gate would surface nothing.
          memoryNoticeSink: memoryNoticeSink,
          onTree: buildTree
              ? (childTree) =>
                  childTrees.add(_PositionedChildTree(position, childTree))
              : null,
        );
      },
      hardDepthCap: _hardDepthCap,
      startDepth: depth,
    );

    final runSubstrateBridge = SubstrateBridge(
      substrateBridge.client,
      onCall: recordCall,
      onToken: tokenSink,
      onThinking: thinkingSink,
      budget: runBudget,
      // Carry the §7.4 routing seam from the template bridge onto the per-run
      // bridge: without it every `sub.send` on a run would throw "no
      // RouteChainResolver bound" (it is the only seam `send` cannot default).
      routeChainOf: substrateBridge.routeChainOf,
      // Carry the §7.1/§7.4 prompt-resolution seam (`sub.run`) the same way: it
      // is config-backed and run-independent, so the template bridge's resolver
      // is the per-run resolver. Without it every `sub.run` would throw "no
      // PromptResolver bound".
      promptResolver: substrateBridge.promptResolver,
      // The `ProcedureRunner` `sub.run` delegates its tool-loop to is *this*
      // run's depth-capped `RunProcedurePrimitive` (not a seam copied from the
      // template bridge): the delegated `tool_loop_v1` run must inherit this
      // frame's depth bookkeeping and trail, exactly as a scripted nested
      // `runProcedure` does (substrate_bridge.dart `ProcedureRunner`).
      runProcedure: runPrimitive.runProcedure,
      turn: turn,
      onLlmTrail: (llmTrailSink == null && !buildTree)
          ? null
          : (observation) {
              if (buildTree) llmObservations.add(observation);
              if (llmTrailSink != null) {
                try {
                  llmTrailSink(LlmTrailRecord(
                    observation: observation,
                    runId: runId,
                    trailId: recorder.isOpen ? recorder.trailId.value : null,
                  ));
                } catch (_) {
                  // Trail writing is non-essential; never break the run.
                }
              }
            },
    );
    // Per-run tool surface (Extension F step 6; § 21.2): the `tool` global a
    // procedure reaches for the tool-calling loop (`answer_with_memory_v1`'s
    // `tool.list` / `tool.invoke`). Bound on *every* run so a script that
    // imports the tool library always finds the global — d4rt globals are
    // keyed by import, so a script that never imports it (a dream agent) never
    // sees it. Each run builds a fresh basic-tool registry under the all-allow
    // default policy, so a script that imports the tool library gets the
    // shipped 15 tools.
    // The context carries *this* run's ledger so a tool's effecting calls
    // charge the same header budget a scripted `persist` does (PE-8); the run's
    // memory client so memory tools route through the same surface the `mem`
    // bridge does; the configured file-scope roots so `file.*` reach the
    // deployment's directories (and nothing outside them); and a web surface
    // over the substrate **client** (never the budget-charging bridge — the one
    // `toolCalls` unit `tool.invoke` pre-charges *is* the web call) so
    // `web.search` / `web.fetch` work. The `engine` surface (Todo 4 / G-PR7)
    // is bound to *this* run's depth-capped `runPrimitive` and the engine's
    // resolver, so `procedure.list` / `procedure.run` and the four
    // `procedure.<verb>` aliases work; `script.run_d4rt` stays deferred (its
    // nested host is built after this context) and the surface raises
    // `ToolSurfaceUnavailable` for it, which the loop turns into `{ok: false}`.
    final toolRegistry = ToolRegistry();
    registerBasicTools(toolRegistry);
    // Merge the configured external MCP servers' tools into this run's registry
    // (request f / § 21.8): each cached [McpToolDefinition] becomes a merged
    // `mcp__*` `BrainTool`, indistinguishable to `tool.list` / `tool.invoke`
    // from a built-in, so the model calls it through the same tool-calling loop.
    // The descriptors were listed once at boot ([mcpTools]); the per-run merge
    // is a pure registration with no network call. The invoke path reaches the
    // server live through [McpClientToolSource] (carried on the context below).
    final runMcpClient = mcpClient;
    final McpToolSource? runMcpSource = runMcpClient == null
        ? null
        : McpClientToolSource(runMcpClient, offered: mcpOffered);
    if (runMcpClient != null) {
      for (final definition in mcpTools) {
        toolRegistry.register(McpBrainTool(definition));
      }
    }
    final toolPolicy = const ToolPolicyConfig().policyFor(null);
    // Per-run tool-access seam (the trail half of "tool calls must be in the
    // trails, especially the live-trail"): when a tool-access sink is bound,
    // wire the run's tool bridge with an `onEvent` that wraps each emitted
    // [ToolEvent] (with this run's `runId`, the live `trailId`, and the turn it
    // serves) into a [ToolAccessRecord] for the writer. `clock: _now` stamps
    // each event's `occurredAt` with the engine clock so trails are
    // deterministic. Best-effort: a throwing sink is swallowed so it cannot
    // break the run. `null` leaves the bridge a pure tool router.
    // Two best-effort consumers share the one tool-event seam: the process
    // [toolAccessSink] (records every call into the trails / live-trail with
    // run correlation) and the per-run [noticeSink] (surfaces the call to the
    // originating channel as an out-of-band notice, P2). The bridge emits each
    // event once; this closure fans it out to whichever sinks are bound.
    // Either failing is swallowed — neither trail writing nor a notification
    // may break the run. With both unbound the bridge stays a pure router.
    final toolAccessSink = _toolAccessSink;
    // Session-scoped todo list (§ 21.4): bind this run's `todo.*` store to the
    // conversation session's persistent store so the working list survives from
    // one prompt to the next within the session. A session-less run (turn-less /
    // internal / dream — `sessionId` `null`) keeps the old run-scoped behaviour:
    // a fresh, ephemeral store discarded at run end.
    final TodoStore runTodos = sessionId == null
        ? TodoStore()
        : sessionTodoStores.forSession(sessionId);
    // The run's tool surface — hoisted into a local so the [McpBridge] (the
    // host's `mcp` global) shares the *same* context the [ToolBridge] uses, so
    // a direct `mcp.call` charges the run's ledger exactly as a `tool.invoke`
    // does. `mcp` carries the external-MCP surface a merged `mcp__*` tool's
    // call forwards through (PE-1), or `null` when no servers are configured.
    final runToolContext = ToolContext(
      budget: ledger,
      memory: runMemoryBridge.client,
      fileScope: toolFileScope,
      todos: runTodos,
      web: SubstrateToolWebSurface(substrateBridge.client),
      // The `memory.write` tool embeds a policy-bearing node before persisting
      // it (memory never embeds lazily). Wraps the raw substrate client, not the
      // budget-charging bridge: the embedding is an internal step of the one
      // `memoryWrites` the write already charges (PE-8).
      embedder: SubstrateToolEmbedSurface(substrateBridge.client),
      engine: EngineToolSurface(
        resolver: resolver,
        runPrimitive: runPrimitive,
      ),
      process: toolProcessSurface,
      mcp: runMcpSource,
      dream: toolDreamSurface,
    );
    final runToolBridge = ToolBridge(
      toolRegistry,
      toolPolicy,
      runToolContext,
      clock: _now,
      onEvent: (toolAccessSink == null && noticeSink == null && !buildTree)
          ? null
          : (event) {
              // Splice the tool event into the combined tree (§5.7.1): capture
              // the invoke-family event at the parent-trail index it fired at
              // so the assembly can render it at that position. `tool.list`
              // (an enumeration) maps to `null` and is never captured.
              if (buildTree) {
                final node = _toolNodeOf(event);
                if (node != null) {
                  toolNodes.add(
                    _PositionedToolNode(recorder.entries.length, node),
                  );
                }
              }
              if (toolAccessSink != null) {
                try {
                  toolAccessSink(ToolAccessRecord(
                    event: event,
                    runId: runId,
                    trailId: recorder.isOpen ? recorder.trailId.value : null,
                    turnId: turn?.turnId.value,
                  ));
                } catch (_) {
                  // Trail writing is non-essential; never break the run.
                }
              }
              if (noticeSink != null) {
                try {
                  noticeSink(event);
                } catch (_) {
                  // A dropped notification must not break the run.
                }
              }
            },
    );
    final host = D4rtDcliHost(
      memoryBridge: runMemoryBridge,
      substrateBridge: runSubstrateBridge,
      toolBridge: runToolBridge,
      // The `mcp` global — bound only when MCP servers are configured (§ 21.3),
      // over the *same* run context the tool bridge uses so a direct `mcp.call`
      // charges the run's ledger. A script that never imports the mcp library
      // never sees the global (d4rt globals are keyed by import).
      mcpBridge: runMcpClient == null
          ? null
          : McpBridge(runMcpClient, runToolContext),
      budgetView: budgetView,
      installNativePrimitives: nativePrimitivesInstaller(
        runProcedurePrimitive: runPrimitive,
        notePrimitive: NotePrimitive(sink: recorder.noteSink, now: _now),
        yieldPrimitive: YieldPrimitive(state: preemptionState),
        emitPrimitive: EmitPrimitive(sink: tokenSink),
      ),
    );

    await recorder.start(
      RunStart(
        procedureId: loaded.header.id,
        version: loaded.header.version,
        runId: runId,
        parentRunId: parentRunId,
        arguments: arguments,
      ),
    );

    // Live-run seam (`/check_usage`): publish this run to the process-lifetime
    // registry the moment its recorder opens, so an out-of-band observer can
    // read the *live* accumulating effort of the prompt being processed right
    // now. The handle holds a `readEffort` closure over this recorder rather
    // than the recorder itself, so the registry never has to reach into engine
    // internals. It is closed in `finish()` — the single terminal funnel all
    // five exit paths pass through — so the run leaves the registry exactly
    // when it stops accumulating effort.
    liveRunRegistry.open(
      LiveRun(
        runId: runId,
        procedureId: loaded.header.id,
        parentRunId: parentRunId,
        turnId: turn?.turnId.value,
        startedAt: recorder.startedAt ?? _now(),
        readEffort: () => recorder.accumulatedEffort,
        // The `/stop_prompt` lever: a top-level run carries its
        // `RunCancellation.cancel`; a nested run has no handle (`null`) and is
        // abandoned with its parent (Q-C.39.2).
        cancel: cancellation?.cancel,
      ),
    );

    // Terminal seam (§5.7 / §10 step #9): every one of the run's five exit
    // paths funnels through here so the combined tree is assembled and emitted
    // exactly once, in lockstep with the outcome. When a tree is built, the
    // run's own trail entries become nodes (with the `llm` ones zipped against
    // the run's captured observations for their link facts) and each nested
    // run's sub-record is spliced in at its recorded call position. A top-level
    // run fires the engine's sink; a nested run bubbles the record up to its
    // parent through [onTree]. Best-effort (§9): a throwing top-level sink is
    // swallowed so it can never break the run.
    ProcedureOutcome finish({
      required ProcedureRunRecord record,
      ProcedureResult? result,
      Object? error,
    }) {
      // Leave the live-run registry first: the run stops accumulating effort
      // here, so no observer should still fold it into the live prompt usage.
      liveRunRegistry.close(runId);
      final entries = recorder.entries;
      if (buildTree) {
        final tree = _assembleProcedureTree(
          loaded: loaded,
          runId: runId,
          parentRunId: parentRunId,
          turn: turn,
          depth: depth,
          record: record,
          entries: entries,
          llmObservations: llmObservations,
          children: childTrees,
          tools: toolNodes,
        );
        if (onTree != null) {
          onTree(tree);
        } else {
          try {
            treeSink(tree);
          } catch (_) {
            // Trail writing is non-essential; never break the run.
          }
        }
      }
      return _outcomeOf(
        runId: runId,
        procedureId: loaded.header.id,
        record: record,
        entries: entries,
        result: result,
        error: error,
      );
    }

    final deadline = StepDeadline(
      limit: _stepDeadlineLimit,
      timerFactory: _deadlineTimerFactory,
    );

    // Race three outcomes: the deadline-guarded step settling (completed or
    // truncated), the step throwing (a crash), or the caller's cancellation /
    // timeout signal firing first (C.39).
    final _RunRace race;
    try {
      race = await _raceCancellable(
        deadline.guard<Object?>(
          host.run(loaded.source, inputs: <Object?>[inputs]),
        ),
        cancellation,
      );
    } on ProcedureBudgetExceeded catch (error) {
      // An *uncaught* budget refusal (PE-8): a bridged call exceeded an
      // applicable header-budget cap and the procedure did not catch it. This
      // is a deliberate stop, not a crash — the run closes `budgetExceeded`
      // (not `errored`), and the fallback executor surfaces the error without
      // stepping the version chain (an older version would hit the same cap).
      // A procedure that *catches* `ProcedureBudgetExceeded` adapts inside its
      // own body and never reaches here.
      await recorder.recordError(_budgetExceededKind, '$error');
      final aborted = await recorder.complete(
        RunCompletion(
          status: TrailOutcomeStatus.budgetExceeded,
          summary: 'procedure ${loaded.header.id} exceeded its '
              '${error.dimension.name} budget',
        ),
      );
      return finish(record: aborted, result: null, error: error);
    } catch (error) {
      // The step threw before the deadline. Classify it: a source-parse
      // failure (the procedure never ran — the host raises
      // `ProcedureSourceParseException`) is `procedure.parse.failed`; any other
      // uncaught error mid-execution is a `procedure.runtime.crash`. The two
      // route differently for version-chain fallback (§ 10.4) — only a runtime
      // crash steps the chain — so collapsing them would wrongly fall back on
      // a parse error (Q-C.46.1). Either way the run closes `errored` and the
      // outcome carries the error so the caller (and the Phase-D fallback
      // executor) sees the typed class.
      final isParseFailure = error is ProcedureSourceParseException;
      await recorder.recordError(
        isParseFailure ? _parseFailedKind : _runtimeCrashKind,
        '$error',
      );
      final crashed = await recorder.complete(
        RunCompletion(
          status: TrailOutcomeStatus.errored,
          summary: isParseFailure
              ? 'procedure ${loaded.header.id} failed to parse'
              : 'procedure ${loaded.header.id} crashed',
        ),
      );
      return finish(record: crashed, result: null, error: error);
    }

    if (race is _RaceCancelled) {
      // The caller cancelled or the run timed out before the step settled.
      // Disarm the (still-armed) deadline timer — its truncation no longer
      // matters — note the abandonment, and close the run `aborted`.
      deadline.cancel();
      final record = await _recordCancellation(
        recorder,
        cause: race.cause,
        timeout: cancellation?.timeout,
        procedureId: loaded.header.id,
      );
      return finish(record: record, result: null);
    }

    final StepOutcome<Object?> step = (race as _RaceStep).step;
    switch (step) {
      case StepCompleted<Object?>(:final value):
        final (:result, :producedNodeIds) = _coerceReturn(value);
        final status = result.isSuccess
            ? TrailOutcomeStatus.accepted
            : TrailOutcomeStatus.errored;
        final record = await recorder.complete(
          RunCompletion(
            status: status,
            summary: result.isSuccess
                ? 'ran ${loaded.header.id} to completion'
                : 'procedure ${loaded.header.id} reported failure',
            producedNodeIds: producedNodeIds,
          ),
        );
        return finish(record: record, result: result);

      case StepTruncated<Object?>(:final limit):
        recorder.note(
          TrailNote(
            category: stepTruncatedNoteCategory,
            recordedAt: _now(),
            payload: <String, Object?>{'limitMs': limit.inMilliseconds},
          ),
        );
        final record = await recorder.complete(
          RunCompletion(
            status: TrailOutcomeStatus.preempted,
            summary: 'step exceeded ${limit.inSeconds}s deadline',
          ),
        );
        return finish(record: record, result: null);
    }
  }

  /// Races the deadline-guarded [guarded] step against [cancellation].
  ///
  /// Returns a [_RaceStep] when the step settles first (completed or
  /// truncated), or a [_RaceCancelled] when the cancellation / timeout signal
  /// fires first. A step that throws propagates the error (the caller maps it
  /// to a crash). When [cancellation] is `null` (a nested run, Q-C.39.2) there
  /// is nothing to race — the guarded step is awaited directly.
  Future<_RunRace> _raceCancellable(
    Future<StepOutcome<Object?>> guarded,
    RunCancellation? cancellation,
  ) {
    if (cancellation == null) {
      return guarded.then<_RunRace>(_RaceStep.new);
    }
    final race = Completer<_RunRace>();
    unawaited(
      guarded.then(
        (StepOutcome<Object?> step) {
          if (!race.isCompleted) race.complete(_RaceStep(step));
        },
        onError: (Object error, StackTrace stack) {
          if (!race.isCompleted) race.completeError(error, stack);
        },
      ),
    );
    unawaited(
      cancellation.signal.then((RunCancelCause cause) {
        if (!race.isCompleted) race.complete(_RaceCancelled(cause));
      }),
    );
    return race.future;
  }

  /// Notes the abandonment and closes an aborted run through the recorder.
  ///
  /// An explicit cancel records a [runCancelledNoteCategory] note; a timeout
  /// records a [runTimedOutNoteCategory] note carrying the breached
  /// `timeoutMs`. Both close the run on [TrailOutcomeStatus.aborted]
  /// (Q-C.39.1).
  Future<ProcedureRunRecord> _recordCancellation(
    RunRecorder recorder, {
    required RunCancelCause cause,
    required Duration? timeout,
    required String procedureId,
  }) async {
    final timedOut = cause == RunCancelCause.timedOut;
    recorder.note(
      TrailNote(
        category:
            timedOut ? runTimedOutNoteCategory : runCancelledNoteCategory,
        recordedAt: _now(),
        payload: <String, Object?>{
          if (timedOut && timeout != null) 'timeoutMs': timeout.inMilliseconds,
        },
      ),
    );
    return recorder.complete(
      RunCompletion(
        status: TrailOutcomeStatus.aborted,
        summary: timedOut
            ? 'run $procedureId timed out'
            : 'run $procedureId cancelled by caller',
      ),
    );
  }

  /// The `runProcedure` executor: recurses back through the engine to run a
  /// depth-validated nested call and returns its typed result.
  ///
  /// The depth was already checked against the cap by [RunProcedurePrimitive]
  /// before this runs. A nested run that fails or crashes surfaces here as a
  /// [ProcedureResult.failed]; richer error propagation up the chain is a
  /// later concern (the fallback executor, Phase D).
  ///
  /// [turn] is the enclosing turn's [TurnContext] (logging-spec §3 / §9),
  /// threaded down so the nested run's substrate calls share the turn's id and
  /// advance the *same* per-turn `callSeq` counter — the counter spans the
  /// run boundary. `null` for a turn-less (internal / dream) parent run.
  Future<ProcedureResult> _executeNested(
    ProcedureCall call, {
    required String parentRunId,
    TurnContext? turn,
    String? profile,
    String? sessionId,
    OutboundDeltaSink? tokenSink,
    ToolNoticeSink? noticeSink,
    SubstrateThinkingSink? thinkingSink,
    MemoryNoticeSink? memoryNoticeSink,
    void Function(ProcedureTreeRecord tree)? onTree,
  }) async {
    final outcome = await _runInternal(
      runId: _newRunId(),
      procedureId: call.id,
      version: call.version,
      inputs: call.inputs,
      arguments: call.inputs.toMap(),
      parentRunId: parentRunId,
      depth: call.depth,
      // Non-null only for the `tool_loop_v1` delegation (the caller gates this);
      // every other nested run is sink-less, preserving "a nested run does not
      // re-stream the answer".
      tokenSink: tokenSink,
      noticeSink: noticeSink,
      thinkingSink: thinkingSink,
      memoryNoticeSink: memoryNoticeSink,
      turn: turn,
      profile: profile,
      sessionId: sessionId,
      onTree: onTree,
    );
    return outcome.result ?? ProcedureResult.failed();
  }

  /// Coerces a procedure entry point's raw return into a [ProcedureResult]
  /// and, in the same pass, extracts the reserved produced-node-ids channel.
  ///
  /// Coercion rules: a `ProcedureResult` passes through unchanged (it carries
  /// no produced-node-ids channel, so the list is empty). A `Map` becomes a
  /// succeeded result carrying its entries as outputs — except the reserved
  /// [producedNodeIdsOutputKey] (D.39), which is split off as the list of
  /// node ids the body produced and never surfaced as a declared output. Any
  /// other non-null value is wrapped under a single `value` output; `null` is
  /// an empty succeeded result.
  ///
  /// See Q-C.38.2: until ProcedureResult is bridged into d4rt, a script cannot
  /// construct one in-procedure, so the engine coerces; a procedure signals
  /// failure by throwing, not by returning a failed result. Returning both
  /// halves from one map walk keeps the produced-node-ids extraction
  /// (consumed for `produced_by` edges) and the output coercion in lockstep —
  /// they previously walked the same map twice (E.2.1).
  ({ProcedureResult result, List<String> producedNodeIds}) _coerceReturn(
    Object? raw,
  ) {
    if (raw is ProcedureResult) {
      return (result: raw, producedNodeIds: const <String>[]);
    }
    if (raw is Map) {
      final outputs = <String, Object?>{};
      var producedNodeIds = const <String>[];
      raw.forEach((Object? key, Object? value) {
        if ('$key' == producedNodeIdsOutputKey) {
          if (value is List) {
            producedNodeIds = value.whereType<String>().toList(growable: false);
          }
          return;
        }
        outputs['$key'] = value;
      });
      return (
        result: ProcedureResult.succeeded(outputs: outputs),
        producedNodeIds: producedNodeIds,
      );
    }
    if (raw == null) {
      return (
        result: ProcedureResult.succeeded(),
        producedNodeIds: const <String>[],
      );
    }
    return (
      result: ProcedureResult.succeeded(
        outputs: <String, Object?>{'value': raw},
      ),
      producedNodeIds: const <String>[],
    );
  }

  ProcedureOutcome _outcomeOf({
    required String runId,
    required String procedureId,
    required ProcedureRunRecord record,
    required List<TrailEntry> entries,
    required ProcedureResult? result,
    Object? error,
  }) =>
      ProcedureOutcome(
        runId: runId,
        procedureId: procedureId,
        status: record.status,
        record: record,
        entries: entries,
        result: result,
        error: error,
      );

  /// Assembles one run's combined structural tree (§5.7 / §10 step #9).
  ///
  /// Walks the run's trail [entries] in order, mapping each node-bearing entry
  /// to a [ProcedureTreeNode]: a `primitiveCall` becomes a
  /// [ProcedurePrimitiveNode] (an `llm` call additionally carries a
  /// [ProcedureTreeLlmRef] zipped positionally off [llmObservations] — the run
  /// fires one observation per completed `llm`, in the same order as the `llm`
  /// primitive entries); a `note` becomes a [ProcedureNoteNode]; an `error`
  /// becomes a [ProcedureErrorNode]. Each nested run's sub-record is spliced in
  /// at the parent entry index it was issued at (the captured `position`),
  /// *before* that entry is processed, so the subtree sits exactly where
  /// `runProcedure` was called. The structural-only entries — the `invocation`
  /// header, the synthetic `outcome` (the writer renders that from [record]),
  /// the bubbled `subProcedure` marker (the spliced sub-record carries the real
  /// shape), and the factory `persist` / `edge` / `stackPush` / `yield_` lines
  /// the prototype path never emits — carry no node.
  ProcedureTreeRecord _assembleProcedureTree({
    required LoadedProcedure loaded,
    required String runId,
    required String? parentRunId,
    required TurnContext? turn,
    required int depth,
    required ProcedureRunRecord record,
    required List<TrailEntry> entries,
    required List<LlmCallObservation> llmObservations,
    required List<_PositionedChildTree> children,
    required List<_PositionedToolNode> tools,
  }) {
    final nodes = <ProcedureTreeNode>[];
    var llmIndex = 0;

    void flushChildrenAt(int position) {
      for (final child in children) {
        if (child.position == position) {
          nodes.add(ProcedureSubtreeNode(tree: child.tree));
        }
      }
    }

    // A `tool.invoke` records no trail entry (§5.7.1), so — unlike a primitive
    // call — its node is spliced from the captured event list by position,
    // exactly as a nested subtree is. Tools captured at `position` render just
    // before the entry at that index (and after the last entry for `position ==
    // entries.length`).
    void flushToolsAt(int position) {
      for (final tool in tools) {
        if (tool.position == position) {
          nodes.add(tool.node);
        }
      }
    }

    for (var i = 0; i < entries.length; i++) {
      flushChildrenAt(i);
      flushToolsAt(i);
      final entry = entries[i];
      switch (entry.kind) {
        case TrailEntryKind.primitiveCall:
          final payload = entry.payload;
          final primitive = '${payload['primitive']}';
          ProcedureTreeLlmRef? llm;
          // Both `llm` and `send` are real substrate completions: each fires the
          // same `onLlmTrail` observation (substrate_bridge `_completeOnce`) and
          // writes a raw dump, so each must consume one observation here. The
          // `tool_loop_v1` path routes its model calls through `send` (route
          // selected by name, § 7.4); attaching the ref makes those calls render
          // as drill-into `llm <role> → tok → raw` lines instead of an inert
          // `send` line. Consuming for both also keeps `llmIndex` aligned with
          // the observation stream in a mixed `llm` + `send` run.
          if ((primitive == 'llm' || primitive == 'send') &&
              llmIndex < llmObservations.length) {
            final obs = llmObservations[llmIndex++];
            llm = ProcedureTreeLlmRef(
              callType: obs.callType,
              turnId: obs.turnId,
              callSeq: obs.callSeq,
              callId: obs.callId,
              runId: runId,
              tokensIn: obs.report.tokensIn,
              tokensOut: obs.report.tokensOut,
            );
          }
          nodes.add(ProcedurePrimitiveNode(
            primitive: primitive,
            input: _asStringMap(payload['input']),
            result: _asStringMap(payload['result']),
            llm: llm,
          ));
        case TrailEntryKind.note:
          nodes.add(ProcedureNoteNode(category: '${entry.payload['category']}'));
        case TrailEntryKind.error:
          nodes.add(ProcedureErrorNode(
            errorKind: '${entry.payload['errorKind']}',
            message: '${entry.payload['message']}',
          ));
        case TrailEntryKind.invocation:
        case TrailEntryKind.persist:
        case TrailEntryKind.edge:
        case TrailEntryKind.stackPush:
        case TrailEntryKind.subProcedure:
        case TrailEntryKind.yield_:
        case TrailEntryKind.outcome:
          break;
      }
    }
    // A nested call or tool invoke issued as the run's very last act lands at
    // `entries.length` (nothing was recorded after it but the synthetic
    // outcome): flush both too.
    flushChildrenAt(entries.length);
    flushToolsAt(entries.length);

    return ProcedureTreeRecord(
      procedureId: loaded.header.id,
      version: loaded.header.version,
      runId: runId,
      parentRunId: parentRunId,
      turnId: turn?.turnId.value,
      depth: depth,
      status: record.status,
      elapsedMs: record.effort.wallClockMs,
      entryCount: entries.length,
      nodes: nodes,
    );
  }

  /// Coerces a trail payload's `input` / `result` slot — a `Map` with possibly
  /// dynamic keys — into the `Map<String, Object?>` the tree nodes carry.
  /// A non-map (or absent) slot yields an empty map.
  static Map<String, Object?> _asStringMap(Object? value) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) {
      return value.map<String, Object?>(
        (Object? key, Object? v) => MapEntry<String, Object?>('$key', v),
      );
    }
    return const <String, Object?>{};
  }

  /// A monotonic, process-unique run-id generator: `run_<micros>_<seq>`.
  static String Function() _defaultRunIdGenerator() {
    var sequence = 0;
    return () => 'run_${DateTime.now().microsecondsSinceEpoch}_${sequence++}';
  }
}

/// Which side of the cancel race won, for the step run inside `_runInternal`.
///
/// A sealed pair so the run path must handle both: the deadline-guarded step
/// settled ([_RaceStep]) or the cancellation / timeout signal fired first
/// ([_RaceCancelled]). A step that throws is not modelled here — it propagates
/// as an error and is caught as a crash.
sealed class _RunRace {
  const _RunRace();
}

/// The deadline-guarded step settled first; [step] is its outcome
/// (completed or truncated).
final class _RaceStep extends _RunRace {
  const _RaceStep(this.step);

  /// The settled step outcome.
  final StepOutcome<Object?> step;
}

/// The cancellation / timeout signal fired before the step settled; [cause]
/// is why the run was abandoned.
final class _RaceCancelled extends _RunRace {
  const _RaceCancelled(this.cause);

  /// Why the run was abandoned (explicit cancel vs. elapsed timeout).
  final RunCancelCause cause;
}

/// A nested run's sub-record paired with the parent-trail index it was issued
/// at (§5.7 / §10 step #9). The parent captures `position` synchronously when
/// `runProcedure` fires (the parent's `recorder.entries.length` at that moment)
/// so the assembly can splice the subtree in at exactly that point.
final class _PositionedChildTree {
  const _PositionedChildTree(this.position, this.tree);

  /// The parent-trail entry index the nested call was issued before.
  final int position;

  /// The nested run's combined tree.
  final ProcedureTreeRecord tree;
}

/// A `tool.invoke`-family tree node paired with the parent-trail index the
/// invoke fired at (§5.7.1). A `tool.invoke` records no trail entry, so the
/// assembly cannot derive the node from an entry the way a primitive call is
/// derived; it captures the bridge event here (at `recorder.entries.length`)
/// and splices the node in at that position via `flushToolsAt`.
final class _PositionedToolNode {
  const _PositionedToolNode(this.position, this.node);

  /// The parent-trail entry index the invoke was issued before.
  final int position;

  /// The pre-built tool node (the event mapped through [_toolNodeOf]).
  final ProcedureToolNode node;
}

/// Maps an invoke-family [ToolEvent] to its [ProcedureToolNode], or `null` for
/// a `tool.list` enumeration (`ToolListed`) — which is not an effect and never
/// reaches the tree (§5.7.1). The bridge has already computed the one-line
/// `argSummary` and the result `resultSize` (a size, never the payload), so
/// this only re-shapes them into the tree node.
ProcedureToolNode? _toolNodeOf(ToolEvent event) => switch (event) {
      ToolInvoked(:final name, :final argSummary, :final resultSize) =>
        ProcedureToolNode(
          name: name,
          argSummary: argSummary,
          outcome: ProcedureToolOutcome.invoked,
          resultSize: resultSize,
        ),
      ToolFailed(:final name, :final argSummary, :final reason) =>
        ProcedureToolNode(
          name: name,
          argSummary: argSummary,
          outcome: ProcedureToolOutcome.failed,
          reason: reason,
        ),
      ToolDenied(:final name, :final argSummary, :final reason) =>
        ProcedureToolNode(
          name: name,
          argSummary: argSummary,
          outcome: ProcedureToolOutcome.denied,
          reason: reason,
        ),
      // `ToolListed` — an enumeration, not an effect; no tree node.
      _ => null,
    };
