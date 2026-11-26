# Tom Brain and Tom Assistant Systems: Deep-Dive Technical Analysis

**Analysis Date:** 2026-06-14  
**Scope:** Complete Tom Brain cognitive system + Tom Assistant consumer layer  
**Methodology:** Source code inspection, architecture documentation review, data flow analysis

---

## Executive Summary

The **Tom Brain** is a sophisticated, layered cognitive system with strict architectural discipline across 6 core components:

- **tom_brain_shared**: Cross-component vocabulary (IDs, budgets, embeddings, events)
- **tom_brain_memory**: Self-organizing property-graph knowledge storage with multi-mode retrieval
- **tom_brain_substrate**: LLM abstraction, embedding, web tools, and role management
- **tom_brain_procedure**: D4rt-hosted script engine with dispatcher and sandboxing
- **tom_brain_access**: HTTP/SSE and Telegram inbound surface
- **tom_brain_run**: Production assembly layer with real provisioning

**Key Architecture Principles:**
1. Strict dependency inversion with client contracts
2. Substitutable implementations (real, stub, isolate-adapted)
3. Comprehensive observability via event streams
4. Cooperative preemption and budget enforcement
5. Structural anchor on every outbound prompt

The **Tom Assistant** is a thin protocol wrapper around Tom Brain—implementation deferred but integration point clear.

---

## Part 1: Component Responsibilities and Architecture

### 1. Tom Brain Shared (v0.5.0)

**Responsibility**: Cross-component vocabulary and pure types

**Key Abstractions:**
- **IDs**: NodeId, EdgeId, TrailId, TurnId, ProcedureId, StackEntryId (all ULIDs with prefixes)
- **Budget Tracking**: WriteBudget, BudgetDelta, TokenSpend
- **Embedding**: Vec, Embedding vector types
- **Memory Interface**: TomBrainMemoryClient (abstract)
- **Events**: MemoryEvent, BrainEvent, BrainEventBus
- **Access Protocol**: Access, InboundRequest, OutboundChunk, ResolvedIdentity, Session, Persona
- **Procedures**: Procedure, ProcedureStatus, CapabilitySet
- **Cognitive Agents**: AgentRegistration with scope-based budgets
- **Symbolic Operations**: SymbolicOp, SymbolicFilter, AttrClause for graph querying
- **Classification**: ClassificationResult (confidence, margin)
- **Time**: BrainTime, Clock for coordinated timing
- **Anchor**: AssistantDedicationAnchor (structural prompt framing)

**Design Discipline:**
- No I/O, no networking, no side effects
- Pure value objects (immutable)
- Barrel pattern for module re-exports
- Dependency inversion throughout
- Anchor enforcement at type level

**Dependencies:**
- tom_basics (exception tracking, logging)
- tom_core_agentic (generic building blocks)
- yaml (config reading)

---

### 2. Tom Brain Memory (v0.0.1) — Storage & Retrieval

**Responsibility**: Self-organizing property-graph knowledge storage with multi-mode retrieval pipeline

**Storage Substrate:**
- SQLite backend (two-DB coordination: memory.db + vectors.db)
- vec0 extension for semantic search (SIMD-accelerated cosine)
- JSONL trails with fsync durability
- 21 bootstrap node types from YAML manifest

**Core Data Structures:**

**Nodes:**
- Types, creation timestamps, attributes, edges (both directions)
- Lifecycle states: demote (marked stale), forget (permanent deletion)
- Classification tracking for knowledge refinement

**Edges:**
- Directional, typed, weighted relationships
- Permission matrix per edge type
- Audit trail (created_by, discovered_by, etc.)

**Stacks:**
- First-class ordered collections (inflight, recent_runs, custom stacks)
- FIFO, LIFO, windowed priority policies
- SQLite-backed persistence for durability

**Trails:**
- Per-run JSONL logs with fsync guarantees
- Corruption-tolerant streaming reads
- Outcome recording at run completion

**Retrieval Pipeline** (§ 6):

Four retrieval modes, intelligently fused:

1. **BM25 (Full-Text Lexical Search)**
   - SQLite FTS5 full-text index
   - Term frequency-inverse document frequency ranking
   - Returns ranked node candidates

2. **Semantic (Vector Search)**
   - Embeddings routed to vec0 (cosine similarity)
   - On-demand embedding via Ollama if needed
   - Efficient SIMD computation over large scale

3. **Symbolic (Attribute Filters)**
   - Graph constraint satisfaction (at/attr clauses)
   - Filter nodes matching predicates
   - Compose multiple constraints

4. **Graph Walk (Traversal-Based)**
   - BFS from seed node via edges
   - Hop-limited exploration (default 2 hops)
   - Weight-biased walk via edge weights

**Fusion & Diversification:**

1. **RRF (Reciprocal Rank Fusion)**: Combine ranked lists from all modes
2. **MMR (Maximal Marginal Relevance)**: Diversify results (avoid redundancy)
3. **Optional LLM Re-Rank**: Caller supplies re-ranking function (memory doesn't call LLM)

**Classification** (§ 7):
- Centroid-based (LLM-independent machine learning)
- Cold-start detection (insufficient data → skip)
- Confidence + margin thresholds
- Centroid auto-updates for continuous learning

**MCP Server** (§ A.75):
- Seven read-only tools (no HTTP client needed)
- Bearer token authentication
- Streamable responses for large recalls

**Cognitive Agents** (§ A.80+):
- Per-scope agent registry
- Shaking events for sleep/wake cycles
- Agent-specific budget constraints
- Managed identities for cognitive workflows

**Observability:**
- MemoryEventBus with typed events (CRUD, retrieval, migrations)
- MemoryStatsCollector for metrics
- MemoryLog for debugging

**Design Patterns:**
- Repository Pattern: Storage abstraction via TomBrainMemoryClient
- Isolate Adapter: Cross-isolate marshaling via SendPort
- Observer: Event streaming for observability
- Builder: Query construction with fluent interface

---

### 3. Tom Brain Substrate (v0.0.1) — LLM Abstraction & Outbound Surface

**Responsibility**: Outbound edge for LLM providers, embeddings, web tools, and MCP client integration

**LLM Providers (Pluggable Strategy):**
- `OpenAiPassthroughProvider` — OpenAI API relay
- `OllamaLlmProvider` — Ollama local inference
- `AnthropicLlmProvider` — Anthropic API
- `StubLlmProvider` — Testing
- `AgentSdkLlmProvider` — Claude Code integration

**LLM Routing & Resilience:**
- `LlmRouter` (policy-based provider selection)
- RouteEntry with constraints, fallback chains
- `LlmFailureClassifier` (closed taxonomy: ContextOverflow, RateLimit, InvalidRequest, NetworkError, etc.)
- StrictFormatAdapter (output validation)
- Retry + circuit breaker patterns

**Role System** (§ 2):
- Persona templates: Analyst, Sub-thinker, Recaller, Researcher, Evaluator, Procedure-Author, Creator, Assistant
- Deployment roles: Retrieval, Creation, Procedure, Planning, Dream
- Per-role capability sets (`allowedAction` constraint)
- Per-role budget defaults
- File-backed role loader for composition

**Embedding Service:**
- `OllamaEmbeddingService` for local embeddings
- `EmbeddingProbeResult` for model identity verification
- Same-text → same-vector guarantee (identity stamped)

**Web Tools (§ 3):**
- `WebSearch` interface with `DuckDuckGoSearchProvider`
- `WebFetch` with robots.txt compliance
- HTML → readable text extraction
- RetryingWebHttpClient with exponential backoff

**MCP Outbound** (§ A.6+):
- `McpClient` consumer-facing interface
- Transports: StdioTransport (external servers), ChannelTransport (Dart isolate), HttpTransport
- Session persistence (one session per endpoint, reused)
- Server list caching

**Anchor Enforcement** (§ B.46):
- Every prompt carries `AssistantDedicationAnchor` structurally
- SHA256 hash stored on every `LlmCallReport`
- Anchor violation → `AnchorViolation` event (fatal substrate event)

**Observability:**
- SubstrateEventBus: LLM calls, embedding, MCP, web
- SubstrateStats: Event-based counters
- SubstrateLog: Categorized logging

**Isolate Adapter:**
- `InProcessTomBrainSubstrate` (main-isolate facade)
- `TomBrainSubstrateIsolateHost` (host-side management)
- `IsolateTomBrainSubstrateAdapter` (client-side stub)
- Message marshaling via `SubstrateStreamProtocol`

**Design Patterns:**
- Strategy: Pluggable providers, transports, roles
- Chain of Responsibility: Provider fallback routing
- Adapter: Isolate cross-call marshaling
- Facade: Unified surface via InProcessTomBrainSubstrate

**Critical Invariants:**
- Anchor on every outbound prompt (structural + hash verification)
- Role templates always include anchor prefix
- Embedding identity stamps enable consistency checking
- Uniform retry + circuit breaker across all HTTP clients

---

### 4. Tom Brain Procedure (v0.0.1) — Engine & Dispatcher

**Responsibility**: Glue layer binding memory + substrate to sandboxed D4rt execution

**Engine Components** (Phases C):

**D4rt Host:**
- `D4rtHost` — sandboxed script executor
- Memory bridge: `MemoryBridge` wrapping `TomBrainMemoryClient` → `memory.*` primitives
- Substrate bridge: `SubstrateBridge` wrapping `TomBrainSubstrateClient` → `llm.*`, `embed.*`, `web.*`, `mcp.*` primitives
- Call recording for tracing + budget ledger

**Procedure Store & Loading:**
- `DiskProcedureStore` (scripts/system/, scripts/user/)
- `MemoryProcedureStore` (in-memory cache)
- `CompositeProcedureStore` (layered: memory → disk)
- `ProcedureLoader` (parses YAML headers)
- `ProcedureResolver` (fallback chain resolution)

**System Procedures (Core D4rt Scripts):**
| Procedure | Purpose |
|-----------|---------|
| answer_with_memory_v1 | Main user-facing recall→answer→persist loop |
| think_v1 | Planning + analysis |
| tool_loop_v1 | Inner LLM tool-calling cycle |
| recall_semantic_v1 | Vector search primitive |
| recall_lexical_v1 | BM25 primitive |
| recall_symbolic_v1 | Attribute filter primitive |
| create_v1 | Workspace/item creation |
| dream_extract_v1 | Knowledge distillation |
| dream_prune_v1 | Demote stale nodes |
| dream_recentroid_v1 | Retrain classification centroids |
| dream_synthesise_v1 | Merge related nodes |
| dream_procedure_metrics_v1 | Update statistics |

**Dispatcher Components** (Phases D):

**Entry Point:**
- `Dispatcher.accept(Access)` — single entry point
- `DispatcherEntry` — classification → selection → scheduling

**Classification & Selection:**
- `InboundClassifier` — no-hint branch (classify_inbound_v1 stub)
- `ProcedureSelector` — maps request kind → procedure id
- `ProcedureRouting` — hinted vs. no-hint decision

**Run Coordination:**
- `RunCoordinator` — ≤1 foreground + ≤1 background slot
- FIFO foreground queue (configurable depth, default 4)
- Cooperative preemption at engine checkpoints (never mid-step)
- Hard step deadline (backstop to engine deadline)

**Preemption System:**
- `PreemptionState` (shared coordinator ↔ engine state)
- `PreemptionController` (observe-only supervisor)
- `PreemptionEvent` (RunSlotEntered, RunSlotExited, ForegroundPreemptionRequested, BackgroundResumeSignalled)
- Idempotent state transitions

**Fallback Execution** (PE-6):
- `FallbackExecutor` walks version chains on typed failures
- Triggers: contract violation, critique rejected, deadline exceeded, runtime crash
- `FallbackTried` event per attempt
- `AutomationIdea` push on sustained fallback

**Recording & Audit:**
- `RunRecorder` persists `ProcedureRun` nodes to memory
- `BridgeCallRecorder` tracks memory + substrate access
- `RunRecords` per-run trail snapshots
- Trail recording → inflight + recent_runs stacks

**Tool System:**
- `ToolRegistry` registered tools (brain tools + VS Code tools)
- `ToolInputSchema` (JSON schema with examples)
- `ToolGroup` (file, grep, process, dream, vscode)
- Sandbox enforcement (file-scope containment)
- VS Code tool source (direct Agent SDK integration)

**MCP Client** (Extension F.8):
- `DartMcpConnection` persistent session management
- `mcp.servers` / `mcp.list` / `mcp.call` primitives
- Transports via substrate

**Validator:**
- `ProcedureValidationChain` contract enforcement
- `HeaderValidator` YAML metadata
- `ContractValidator` requires/provides matching
- Sandbox violation detection

**Configuration:**
- `EngineConfig` (script paths, defaults)
- `DispatcherConfig` (routing, queue depth)
- `SandboxConfig` (file scope, memory limits)
- YAML loaders with environment variable expansion

**Observability:**
- EngineEventBus, DispatcherEventBus, ToolEventBus, McpEventBus
- EngineLog, DispatcherLog (category logging)
- Trail event types: Memory access, LLM calls, tool invocations

**Design Patterns:**
- Sandboxing: File containment, budget ledger
- State Machine: Procedure lifecycle
- Observer: Event buses
- Chain of Responsibility: Fallback version walking
- Template Method: Procedure headers + implementation

**Critical Logic:**
- **Procedure Resolution**: Hinted → direct; unhinted → classify → select
- **Cooperative Preemption**: No preemption mid-step; foreground highest priority
- **Budget Enforcement**: Per-run WriteBudget tracked at engine boundary
- **Answer Streaming**: Tokens routed per-turn (thinking vs. answer channel)

---

### 5. Tom Brain Access (v0.0.1) — Inbound Edge

**Responsibility**: HTTP/SSE and Telegram inbound surface for Tom Brain cognition

**Channel Adapters:**

**HTTP/SSE Adapter** (§ E.11+):
- OpenAI `/v1/` endpoint compatible wire protocol
- SSE framing for streaming responses
- Custom JSON shapes (non-standard OpenAI variant)

**Telegram Adapter** (§ E.19+):
- ChatApi consumer (TelegramChatConfig)
- Long-polling transport
- Message normalization

**Identity & Session Management:**
- `ResolvedIdentity` (opaque principal handle)
- Bearer token validation
- Scope threadability (per-session conversation context)
- History retrieval linkage to runs

**Persona Resolution:**
- User-dedicated assistant persona
- Substrate role mapping

**Edge Security** (§ E.28+):
- Bearer token authentication
- Rate limiting (token bucket)
- Request validation

**Delivery:**
- `DeliverCallback` (outbound streaming)
- Backpressure signaling
- Channel-specific error handling

**Configuration:**
- `AccessConfigLoader` (YAML parsing)
- Per-adapter settings
- Edge security policies

**Entry Point:**
- `tom_build_base` v2 CLI framework
- `bin/tom_brain_access.dart` executable

**Design Patterns:**
- Adapter: Channel-specific adapters (OpenAI, Telegram)
- Factory: Access object construction
- Observer: Delivery callbacks

---

### 6. Tom Brain Run (v0.0.1) — Production Assembly

**Responsibility**: Boot-time provisioning and assembly of complete Tom Brain system

**Higher Assembly:**
- `BrainProvisioner` seam (returns already-booted cognition)
- `BrainProcessBoot` — full stack initialization
- Real `SqliteTomBrainMemory` (on-disk storage)
- Real substrate with real LLM providers

**Real Provisioning Wiring:**
- `InProcessTomBrainSubstrate` with real routers
- `OpenAiPassthroughProvider` + `OllamaLlmProvider`
- `OllamaEmbeddingService`
- MCP client factory for external servers

**Entry Point:**
- `bin/brain_serve.dart` — production server
- `startBrainAccessProcess` — access layer startup
- `QueueSnapshot` — run coordinator state queries

**Configuration Assembly:**
- `MemoryConfig`, `SubstrateConfig`, `AccessConfig` composition
- Whole-process YAML loading from config files
- Environment variable interpolation

**MCP Channel Factory:**
- Stdio transport (for external MCP servers)
- HTTP transport (for http: endpoints)
- `VSCodeBridgeAgentSdkTransport` (VS Code integration)

**Provider Management:**
- Model switching via `/switch_model` endpoint
- Port discovery via `/cli_server_port`
- Agent SDK provider (`AgentSdkLlmProvider`)

**Design Patterns:**
- Composition: Layers composed at boot time
- Factory: Provisioner seam
- Dependency Injection: Config-driven wiring

---

## Part 2: Critical Data Flows

### End-to-End Request → Response Flow

```
1. INBOUND EDGE (tom_brain_access)
   Adapter (OpenAI HTTP/SSE | Telegram)
   → IdentityResolver (bearer token → ResolvedIdentity)
   → SessionManager (retrieve context)
   → PersonaResolver (persona → substrate role)
   → Construct Access {
       envelope: InboundRequest,
       identity, session, persona, deliver, history, turnId
     }

2. DISPATCHER (tom_brain_procedure)
   Dispatcher.accept(Access)
   → Classify Inbound (no-hint branch → classify_inbound_v1)
   → Select Procedure (kind=user_prompt → answer_with_memory_v1)
   → Resolve Procedure ID
   → RunCoordinator (foreground/background scheduling)
   → Start Engine with Access

3. ENGINE (D4rt script host)
   answer_with_memory_v1 procedure LOOP:
   
   A. RECALL
      memory.recall(RecallQuery)
      ├─ BM25 (full-text)
      ├─ Vector (embeddings → cosine)
      ├─ Symbolic (attribute filters)
      └─ Graph Walk
      Result → fused + MMR-diversified nodes
   
   B. ASSEMBLE PROMPT
      ${recall} + ${history} + ${text} → wire prompt
      Anchor-wrap (AssistantDedicationAnchor.ensurePrefix)
   
   C. ANSWER (via tool_loop_v1)
      llm.completeStream(role=persona.substrateRole)
      ├─ Router selects provider (OpenAI | Ollama | …)
      ├─ Failure classifier (closed taxonomy)
      └─ Retry + circuit breaker
      Tokens streamed → Access.deliver(OutboundChunk)
      Tool calls accumulated for next pass
   
   D. PERSIST (event + conclusion + edges)
      memory.persist(Event, Conclusion)
      memory.edge(answer → run, "produced_by")
      stack.push(recent_runs, run)

4. OUTBOUND DELIVERY
   OutboundChunk streamed to channel adapter
   Adapter frames (SSE | Telegram message | …)
   Back-pressure signal on channel stall
```

### Memory Retrieval Pipeline

```
RecallQuery
├─ text (seed)
├─ embedding (precomputed)
├─ symbolic filters
└─ reRank (optional LLM hook)

FOUR-MODE RETRIEVAL:
├─ BM25 (FTS5) → ranked nodes
├─ SEMANTIC (Vec) → cosine-ranked nodes
├─ SYMBOLIC (filters) → matching nodes
└─ GRAPH WALK (BFS) → nearby nodes

FUSION & DIVERSIFICATION:
├─ RRF (Reciprocal Rank Fusion)
├─ MMR (Maximal Marginal Relevance)
└─ Optional reRank (LLM)

RecallResult
├─ nodes (fused, diversified)
├─ provenance (which mode + weight)
└─ scores + distances
```

### LLM Call Flow

```
llm.completeStream(LlmCall)
├─ prompt (wire format)
├─ role (substrate role)
├─ model (routing key)
└─ tools (optional schema)

ANCHOR ENFORCEMENT:
AssistantDedicationAnchor.ensurePrefix(prompt)
→ anchored prompt + sha256 hash

ROLE ASSEMBLY:
RoleTemplate.assemble()
├─ System message (anchor + objective)
├─ Per-role constraints
└─ Output schema

ROUTING:
LlmRouter.route(call)
├─ Match model → providers
├─ Try first provider
├─ On typed failure → fallback chain
└─ Classify (ContextOverflow, RateLimit, etc.)

PROVIDER CALL:
LlmProvider.stream()
├─ HTTP client
├─ Retry + circuit breaker
├─ Stream events as chunks
└─ Tool-call accumulation

STREAM EVENTS:
LlmStreamStarted
LlmStreamChunk (text token)
LlmStreamToolCallProposed
LlmStreamCompleted | Failed
```

---

## Part 3: Tom Assistant System

**Current Status:**
- `tom_assistant_core` (empty, v1.0.0)
- `tom_assistant_messaging` (empty, v1.0.0)
- `tom_assistant_server` (empty, v1.0.0)
- `tom_assistant_ui` (Flutter UI package, v0.0.1)

**Integration Point:**
Tom Assistant consumes `tom_brain_procedure.Dispatcher.accept(Access)` as its primary API. The system is designed to be a thin protocol wrapper and UI around the complete Tom Brain cognition system.

**Future Extensibility:**
- tom_assistant_core: Custom messaging protocol, caching layer
- tom_assistant_server: Dedicated backend, user management
- tom_assistant_ui: Custom Flutter UI, native integrations

---

## Part 4: Architecture Patterns & Design Decisions

### Core Architectural Principles

1. **Strict Layering**:
   - Each layer has single responsibility
   - Clear interface boundaries
   - No cross-layer backdoors

2. **Dependency Inversion**:
   - All components target interfaces (TomBrainMemoryClient, TomBrainSubstrateClient)
   - No direct cross-layer imports
   - Substitutable implementations (real, stub, isolate-adapted)

3. **Client Contracts**:
   - Every component receives a "client" contract
   - Enables unit testing with mocks
   - Enables multi-isolate deployment without code changes

4. **Isolate Isolation**:
   - Memory can run in separate isolate (cross-isolate client marshaling)
   - Substrate typically in-process (shared HTTP clients)
   - Procedure engine runs in caller's isolate
   - Access is entry isolate

### Key Design Patterns

| Pattern | Components | Benefit |
|---------|-----------|---------|
| **Barrel Modules** | All lib/src re-exports | Single import, encapsulation |
| **Observer (Event Buses)** | Memory/Substrate/Procedure | Observability without coupling |
| **Strategy (Pluggable)** | LLM providers, roles, web | Multi-provider, testability |
| **Adapter (Isolate)** | SendPort marshaling | Transparent multi-isolate |
| **Chain of Responsibility** | Fallback version walking | Graceful degradation |
| **Template Method** | Procedure YAML headers | Declarative metadata |
| **Factory (Config-Driven)** | BrainProcessBoot wiring | All layers config-depend only |
| **Decorator (Budget)** | WriteBudgetTracker | Cross-layer enforcement |

### Critical Invariants

1. **Anchor Guarantee**: Every outbound prompt has `AssistantDedicationAnchor` (structural)
2. **Budget Enforcement**: WriteBudget per run, uncharged writes opted-in
3. **Idempotent Writes**: Non-null idempotencyKey → no-op on re-call
4. **Audit Trail**: All writes attributed (produced_by edges)
5. **Cooperative Preemption**: No preemption mid-engine-step
6. **Embedding Consistency**: Same text → same vector (identity stamped)

### Configuration Model

Every layer reads YAML configuration:
- **Memory**: memory.yaml (sqlite paths, embedding model, retention policies)
- **Substrate**: substrate.yaml (LLM providers, role routes, web options)
- **Procedure**: engine.yaml + dispatcher.yaml (script paths, routing)
- **Access**: access.yaml (HTTP/Telegram adapters, security)

YAML loaders normalize `${ENV}` expansion and type coercion.

---

## Part 5: Observability Architecture

### Event Streams

- **MemoryEvent**: node CRUD, retrieval, migrations, stacks, trails
- **SubstrateEvent**: LLM calls, embeddings, web, MCP
- **DispatcherEvent**: run lifecycle, preemption, fallback, route
- **PreemptionEvent**: slot entry/exit, requests, resume
- **ToolEvent**: tool calls, results, denials
- **McpEvent**: server connect, tool list, call results

### Trail Recording

- Per-run JSONL trail (TrailId)
- Appends recorded atomically (fsync per write)
- Memory access records, LLM call reports, tool invocations
- Outcome recorded at run completion

### Metrics

- Token counts (input, output, total)
- Latency per retrieval mode
- Classification confidence scores
- Provider call counts + failures
- Tool invocation counts

---

## Summary Table: Component Responsibilities

| Component | Owns | Consumes | Exports |
|-----------|------|----------|---------|
| **tom_brain_shared** | IDs, budgets, embeddings, events, types | tom_basics, tom_core_agentic | TomBrainMemoryClient, TomBrainSubstrateClient (interfaces) |
| **tom_brain_memory** | SQLite storage, retrieval, stacks, trails | shared, sqlite3, dart_mcp | TomBrainMemory (impl), MCP server |
| **tom_brain_substrate** | LLM providers, embedding, web, MCP client | shared, tom_core_*, http, dart_mcp | TomBrainSubstrate (impl), role templates |
| **tom_brain_procedure** | Engine, dispatcher, procedures, tools | shared, memory, substrate, tom_d4rt | Dispatcher, Engine, procedures |
| **tom_brain_access** | HTTP/SSE, Telegram adapters, identity, delivery | shared, procedure, tom_core_* | Access objects, bin/tom_brain_access |
| **tom_brain_run** | Assembly + provisioning | all above, tom_vscode_scripting_api | BrainProvisioner, bin/brain_serve |

---

## Conclusion

The **Tom Brain system** is an exemplary implementation of layered architecture with strict dependency inversion. Its defining characteristics:

1. **Architectural Purity**: Each layer has single, clear responsibility
2. **Testability**: Every layer has stub implementation
3. **Configurability**: Boot-time YAML assembly, no hardcoding
4. **Observability**: Comprehensive event streams + trail recording
5. **Resilience**: Retry + fallback chains at all levels
6. **Identity Framing**: Structural anchor on every outbound prompt
7. **Isolation-Ready**: Cross-isolate marshaling transparent to consumers

The **Tom Assistant** consumes Tom Brain via `Dispatcher.accept(Access)` interface—a thin protocol translator and UI wrapper around a complete, production-ready cognitive system.
