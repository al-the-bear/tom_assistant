# Tom Brain Workspace: Strategic Roadmap & Action Plan

**Document:** Phase 3 Deliverable (Primary Objective Definition + Task Breakdown)  
**Date:** 2026-06-14  
**Source:** Deep architecture audit (Phase 1-2) of Tom Agent Container

---

## Executive Summary

This document translates the comprehensive architecture analysis into a **strategic roadmap** for the Tom Brain workspace. The analysis reveals:

1. **A complete, production-ready cognitive system** (Tom Brain) at position 130 in the build order
2. **130 projects organized in 4 architectural layers** with clean dependency DAG
3. **43 active quests** covering development across all major subsystems
4. **Multiple integration opportunities** with VS Code, Telegram, and AI assistants
5. **Clear architectural discipline** with strict dependency inversion and observability

**Strategic Objectives:**
1. **Consolidate Tom Brain as production-ready system** (already built, needs testing + hardening)
2. **Complete Tom Assistant consumer layer** (thin wrapper, ready to implement)
3. **Expand integrations** (VS Code deeper integration, multi-modal inputs)
4. **Build applications on Tom Brain** (showcase use cases)
5. **Operationalize observability** (monitoring, tracing, metrics)

---

## Part 1: Current State Assessment

### What We Have (Complete & Working)

**Tom Brain Cognitive System:**
- ✅ tom_brain_memory: Complete self-organizing knowledge graph storage
- ✅ tom_brain_substrate: Complete LLM abstraction + embedding + web tools
- ✅ tom_brain_procedure: Complete D4rt engine + dispatcher + procedures
- ✅ tom_brain_access: Complete HTTP/SSE + Telegram inbound surface
- ✅ tom_brain_run: Complete production assembly layer
- ✅ tom_brain_shared: Complete vocabulary + interfaces
- ✅ Comprehensive event streams and observability infrastructure
- ✅ Strict architectural discipline with no circular dependencies

**Foundation Infrastructure:**
- ✅ tom_build_base: Complete CLI foundation (30+ tools depend on this)
- ✅ tom_core_kernel: Complete framework kernel
- ✅ tom_d4rt: Complete sandboxed interpreter ecosystem
- ✅ tom_basics: Complete foundational utilities

**Workspace Metadata & Documentation:**
- ✅ .tom_metadata/tom_master.yaml: Complete authoritative structure (314KB)
- ✅ 67 global guideline files in _agent_guidelines/
- ✅ 20+ project-specific guideline folders
- ✅ CLAUDE.md with comprehensive workspace instructions
- ✅ 43 active quests tracked in _ai/quests/

### What's In Progress or Deferred

**Tom Assistant Consumer Layer:**
- ⚠️ tom_assistant_core: Empty (v1.0.0) - awaiting implementation
- ⚠️ tom_assistant_messaging: Empty (v1.0.0) - protocol TBD
- ⚠️ tom_assistant_server: Empty (v1.0.0) - backend service pending
- ✅ tom_assistant_ui: Flutter UI exists but may need enhancement

**Test & Validation:**
- ⚠️ tom_brain_smoke_prototype: Exists as end-to-end test harness
- ⚠️ Integration tests: Need writing for complete flows
- ⚠️ Performance tests: Need baseline establishment

**Deployment & Operations:**
- ⚠️ Kubernetes deployment manifests: Not present
- ⚠️ Health check endpoints: Need definition
- ⚠️ Monitoring & alerting: Infrastructure TBD
- ⚠️ Multi-machine synchronization: Stub implementation

---

## Part 2: Strategic Objectives (Phase 3.1)

### Objective 1: Validate Tom Brain System (Validation Phase)

**Goal**: Establish that Tom Brain works end-to-end in real-world scenarios

**Scope:**
- Run tom_brain_smoke_prototype against real Ollama + OpenAI
- Verify knowledge graph persistence across restarts
- Test multi-turn conversation flows
- Validate retrieval quality (BM25 vs. semantic vs. graph walk)
- Confirm preemption + fallback mechanics work correctly

**Success Criteria:**
- Complete end-to-end flow in smoke test passes
- 100+ conversation turns without memory corruption
- Embedding consistency verified (same text → same vector)
- Retrieval diversity metrics (BM25 complement semantic)
- Fallback chain tested (primary + 2 fallback providers)

**Effort:** Medium (2-3 weeks)  
**Blocker:** None (system ready for testing)

---

### Objective 2: Complete Tom Assistant Consumer Layer (Implementation Phase)

**Goal**: Implement Tom Assistant as thin protocol wrapper around Tom Brain

**Scope:**

**tom_assistant_core:**
- Message history caching layer
- User session management
- Custom personas/avatars support
- Integration with Tom Brain's Access interface
- Event subscription for UI updates

**tom_assistant_messaging:**
- Define assistant-specific message types
- Extend/adapt Access protocol for assistant semantics
- Error code taxonomy (what can fail + how to recover)
- Rate limiting policies

**tom_assistant_server:**
- HTTP backend server (shelf-based, following tom_core_server pattern)
- User authentication/authorization
- Session endpoint (create, list, resume, delete)
- Message endpoint (send, stream, history)
- Settings endpoint (preferences, personas)
- Integration with tom_brain_access and tom_brain_run

**tom_assistant_ui:**
- Conversation UI component
- Settings panel
- Persona selector
- History browser
- Real-time message streaming

**Integration Points:**
- Both consume tom_brain_procedure.Dispatcher.accept(Access)
- Reuse tom_brain_substrate event streams
- Subscribe to tom_brain_memory observability
- Share configuration YAML structure

**Success Criteria:**
- tom_assistant_core: 500+ lines, complete history caching
- tom_assistant_messaging: Full protocol spec document
- tom_assistant_server: Full HTTP API, 10+ endpoints
- tom_assistant_ui: Production Flutter UI
- Integration tests passing (core → server → UI)

**Effort:** Medium-High (3-4 weeks)  
**Blocker:** Tom Brain validation must pass first

---

### Objective 3: Expand System Integrations (Extensibility Phase)

**Goal**: Deepen integration with VS Code, Telegram, and AI assistants

**Scope:**

**VS Code Extension Deepening:**
- Invoke Tom Brain procedures from editor context menu
- Code completion suggestions from knowledge graph
- Search knowledge graph from sidebar
- Procedure authoring UI (template, headers, validation)
- Tool output visualization

**Telegram Bot Enhancement:**
- Custom persona support (admin can set tone, style)
- Inline file/image upload handling
- Group chat mode (thread-aware conversations)
- Command palette (/ask, /search, /remember, /forget)
- Webhook delivery (fast responses, lower latency)

**Agent SDK Integration:**
- Claude Code integration (tom_brain_run exposes tools via Agent SDK)
- Tool invocation from Claude Code → Tom Brain procedures
- Result streaming back to Claude Code
- Shared memory between Claude Code and Tom Brain

**Slack/Discord Integration:**
- Adapter for Slack messaging
- Discord bot support
- Shared channel memory (organization-wide knowledge)
- Integration with tom_core_server webhooks

**Success Criteria:**
- VS Code: 5+ new features, 100+ test cases
- Telegram: Custom personas working, /command palette implemented
- Agent SDK: Tom Brain tools callable from Claude Code
- Slack/Discord: Full adapters working (may defer to later phase)

**Effort:** High (4-6 weeks)  
**Blocker:** Tom Assistant completion advised (not required)

---

### Objective 4: Demonstrate Applications on Tom Brain (Showcase Phase)

**Goal**: Build 2-3 reference applications showing Tom Brain capabilities

**Reference Application Ideas:**

**1. Code Research Assistant**
- Index codebase into Tom Brain memory
- Answer questions about code structure
- Suggest refactoring opportunities
- Track design decisions and rationale

**2. Personal Knowledge Manager**
- Progressive enhancement of personal notes
- Auto-tag and classify (dream_extract, dream_synthesise)
- Semantic search over lifetime notes
- Suggest connections between ideas

**3. Research Paper Digester**
- Index papers into knowledge graph
- Extract key concepts (dream_extract)
- Build relationship map between papers
- Answer questions across paper collection

**Success Criteria:**
- Each app: 10+ features working, demo video
- Knowledge graphs: 1000+ nodes each
- Demonstrable retrieval quality improvements
- Published examples + source code

**Effort:** High (5-8 weeks)  
**Blocker:** Tom Assistant completion recommended

---

### Objective 5: Operationalize Observability (Operations Phase)

**Goal**: Make Tom Brain production-ready with full monitoring

**Scope:**

**Observability Infrastructure:**
- Prometheus metrics export (token counts, latencies, provider calls)
- Distributed tracing (Jaeger or similar)
- Structured logging (JSON format, indexed)
- Custom dashboards for key metrics

**Health Checks:**
- Memory database integrity checks
- Embedding consistency verification
- Provider availability (OpenAI, Ollama, etc.)
- Preemption system health
- Budget enforcement audit

**Alerting Rules:**
- High error rates (provider failures exceeding threshold)
- Memory database growth warning
- Token spend tracking vs. budget
- Embedding service degradation
- Procedure fallback rate spikes

**Deployment:**
- Helm charts for Kubernetes
- Docker images (tom_brain_access, tom_brain_run, tom_brain_memory)
- Multi-region replication (tom_brain_memory sync)
- Graceful shutdown procedures
- Blue-green deployment patterns

**Success Criteria:**
- Prometheus metrics: 20+ key metrics exported
- Jaeger tracing: Every procedure execution traced
- Dashboards: 5+ operational dashboards
- Alerts: 10+ automated alerting rules
- Helm: Production-ready charts

**Effort:** High (4-6 weeks)  
**Blocker:** Can proceed in parallel with Objectives 2-4

---

## Part 3: Action Plan (Phase 3.2 - Task Breakdown)

### Phase 3A: Tom Brain Validation (Weeks 1-3)

#### Task 3A-1: Smoke Test Implementation
```yaml
content: "Execute tom_brain_smoke_prototype against real Ollama + OpenAI"
activeForm: "Running smoke tests with real providers"
description: |
  - Set up test environment (Ollama server, OpenAI API keys)
  - Run smoke_prototype with real substrate
  - Execute 100+ conversation turn validation
  - Measure retrieval metrics (latency, quality)
  - Document baseline performance
success_criteria: |
  - Smoke test passes with 0 errors
  - 100 turns completed without crash
  - Latency < 2s per turn (thinking + answer)
  - Memory size stable after 100 turns
```

#### Task 3A-2: Knowledge Graph Persistence
```yaml
content: "Validate knowledge graph persistence and recovery"
activeForm: "Testing persistence and recovery"
description: |
  - Create Tom Brain instance, add 50 nodes
  - Restart process, verify nodes still present
  - Test journal recovery (tom_brain_memory trails)
  - Verify classification centroid persistence
  - Test stack (inflight, recent_runs) recovery
success_criteria: |
  - 100% node recovery after restart
  - Centroid accuracy preserved
  - Stack state restored correctly
  - No data loss on crash recovery
```

#### Task 3A-3: Retrieval Quality Baseline
```yaml
content: "Establish retrieval quality metrics and baseline"
activeForm: "Measuring retrieval quality"
description: |
  - Create 500-node knowledge graph with diverse content
  - Run 50 recall queries across all modes (BM25, semantic, symbolic, graph)
  - Measure precision@10, recall@10 per mode
  - Compare fused results vs. individual modes
  - Document diversity metrics (MMR effectiveness)
success_criteria: |
  - Baseline metrics recorded
  - Semantic + BM25 > individual performance
  - MMR diversity > 0.7
  - Graph walk finds 50%+ relevant in 2 hops
```

#### Task 3A-4: Preemption & Fallback Testing
```yaml
content: "Validate preemption and fallback chain mechanics"
activeForm: "Testing preemption and fallback"
description: |
  - Test foreground/background scheduling
  - Trigger preemption and verify clean state
  - Cause provider failures (mock OpenAI timeout)
  - Verify fallback chain (primary → ollama → stub)
  - Confirm fallback_tried events emitted
success_criteria: |
  - Preemption/resume without state corruption
  - Fallback chain working 100%
  - FallbackTried events logged correctly
  - No hanging requests on failure
```

#### Task 3A-5: Anchor Enforcement Validation
```yaml
content: "Verify AssistantDedicationAnchor on all outbound prompts"
activeForm: "Validating anchor enforcement"
description: |
  - Hook LLM provider, inspect all prompts
  - Verify anchor prefix present
  - Verify SHA256 hash on LlmCallReport
  - Test anchor violation detection
  - Confirm AnchorViolation events fired
success_criteria: |
  - 100% of prompts carry anchor
  - Hash verification passing
  - Violations detected and logged
  - No prompts sent without anchor
```

---

### Phase 3B: Tom Assistant Implementation (Weeks 4-7)

#### Task 3B-1: tom_assistant_core
```yaml
content: "Implement tom_assistant_core with message caching + session management"
activeForm: "Building Tom Assistant core"
description: |
  - Message history in-memory cache (last 100 messages per session)
  - User session management (create, retrieve, delete)
  - Custom persona support (name, description, initial prompt)
  - Avatar/icon management
  - Subscribe to Tom Brain memory events for live updates
  - Implement session resume (reconnect with context)
success_criteria: |
  - 500+ lines of implementation
  - Message caching with eviction policy
  - Session create/resume/delete working
  - Personas configurable per user
  - Events streamed to UI subscribers
  - 50+ unit tests
```

#### Task 3B-2: tom_assistant_messaging
```yaml
content: "Define Tom Assistant message protocol"
activeForm: "Defining messaging protocol"
description: |
  - Extend Access protocol for assistant semantics
  - Define assistant_hello, assistant_ready, assistant_thinking messages
  - Define error taxonomy (AuthError, ProcessingError, ToolError, etc.)
  - Document backpressure and streaming semantics
  - Create protocol version versioning strategy
  - Publish protocol specification document
success_criteria: |
  - Protocol spec document (10+ pages)
  - 20+ message types defined
  - Error taxonomy with recovery strategies
  - Backward compatibility path
  - Example protocol flows
  - Implementers guide
```

#### Task 3B-3: tom_assistant_server
```yaml
content: "Implement Tom Assistant backend server"
activeForm: "Building Tom Assistant server"
description: |
  - Shelf-based HTTP server (port 8080)
  - User authentication (bearer token or OAuth)
  - /api/users endpoints (get, update, list preferences)
  - /api/sessions endpoints (create, list, resume, delete)
  - /api/messages endpoints (send, stream, history)
  - /api/personas endpoints (list, create, set current)
  - /api/settings endpoints (preferences, UI settings)
  - Integration with tom_brain_run provisioner
  - OpenAI-compatible /v1/ endpoints (if needed)
success_criteria: |
  - 15+ API endpoints implemented
  - OpenAPI/Swagger documentation
  - 100+ integration tests
  - Error handling complete
  - Database persistence (sqlite or similar)
  - Graceful shutdown
  - 99.9% uptime capability
```

#### Task 3B-4: tom_assistant_ui Enhancement
```yaml
content: "Enhance Tom Assistant Flutter UI"
activeForm: "Enhancing Flutter UI"
description: |
  - Message list with streaming display
  - Settings panel for preferences/personas
  - Session history browser
  - Real-time typing indicators
  - Persona selector with preview
  - Export conversation as markdown
  - Dark/light theme support
  - Mobile-optimized layout
  - Web version (Flutter web)
success_criteria: |
  - 10+ UI screens
  - 500+ lines of widget code
  - Real-time message streaming
  - Responsive design (mobile/tablet/web)
  - 50+ UI tests
  - Accessibility compliance (WCAG 2.1 AA)
  - Performance: <100ms interaction latency
```

#### Task 3B-5: Integration Tests
```yaml
content: "Write comprehensive integration tests"
activeForm: "Writing integration tests"
description: |
  - Test core → server → procedure flow
  - End-to-end conversation simulation (5 turns)
  - Session persistence across restarts
  - Error propagation (assistant → server → client)
  - Concurrent user sessions
  - Memory consistency checks
  - Performance under load (10 concurrent sessions)
success_criteria: |
  - 50+ integration tests
  - All major workflows covered
  - Performance benchmarks recorded
  - Load test passing (10 concurrent, 500 msgs/sec)
  - Failure scenarios tested
  - Recovery procedures validated
```

---

### Phase 3C: System Integrations (Weeks 5-10)

#### Task 3C-1: VS Code Extension Deepening
```yaml
content: "Add Tom Brain integration to VS Code extension"
activeForm: "Enhancing VS Code integration"
description: |
  - Context menu: "Ask Tom Brain" action
  - Sidebar: Search knowledge graph
  - Sidebar: Browse recent Tom Brain runs
  - Inline suggestion: Knowledge graph completions
  - Command: /search (search knowledge graph)
  - Command: /remember (explicit persist to memory)
  - Procedure explorer UI (list, edit, execute)
  - Output panel for procedure results
success_criteria: |
  - 5+ new VS Code features
  - Integration with Tom Brain HTTP API
  - 100+ test cases
  - Sidebar displays working
  - Command palette working
  - Performance: <500ms for search
```

#### Task 3C-2: Telegram Bot Enhancement
```yaml
content: "Enhance Telegram bot with custom personas and commands"
activeForm: "Enhancing Telegram bot"
description: |
  - Custom persona support (/set_persona)
  - Command palette (/ask, /search, /remember, /list_personas)
  - File upload handling (documents, images)
  - Group chat mode (thread awareness)
  - Inline query support (@tombrainbot search:...)
  - Reaction emoji support (like/dislike messages)
  - Webhook delivery (faster responses)
success_criteria: |
  - 8+ new commands
  - Custom persona working
  - Group chat support
  - File uploads working
  - Webhook latency <500ms
  - 100+ test cases
```

#### Task 3C-3: Agent SDK Integration
```yaml
content: "Integrate Tom Brain with Claude Code Agent SDK"
activeForm: "Integrating with Agent SDK"
description: |
  - Register Tom Brain tools in Agent SDK
  - Expose tom_brain_procedure.Dispatcher via tools
  - Call Tom Brain procedures from Claude Code context
  - Stream results back to Claude Code
  - Share knowledge between instances
  - Create test procedures (code_analysis, refactor_suggest)
success_criteria: |
  - Tom Brain tools registered and callable
  - 5+ test procedures implemented
  - Results streaming to Claude Code
  - Memory sharing working
  - 30+ tests
```

#### Task 3C-4: Slack Integration
```yaml
content: "Implement Slack bot adapter for Tom Brain"
activeForm: "Building Slack integration"
description: |
  - Slack app with slash commands
  - /ask, /search, /remember commands
  - Slack message threading support
  - Emoji reactions for feedback
  - File upload to knowledge graph
  - Org-wide memory sharing
  - Slack Events API integration
success_criteria: |
  - Slack app published to workspace
  - 5+ commands working
  - Threading support
  - 50+ tests
  - Performance <500ms
```

---

### Phase 3D: Reference Applications (Weeks 8-15)

#### Task 3D-1: Code Research Assistant
```yaml
content: "Build code indexing and research assistant on Tom Brain"
activeForm: "Building code research assistant"
description: |
  - Index codebase (scan, parse, extract entities)
  - Store in knowledge graph (files, classes, functions, types)
  - Implement search procedures (find_by_name, find_by_type, find_relations)
  - Answer questions ("What calls this function?" "Why exists?" etc.)
  - Suggest refactoring (classify, detect code smells)
  - Track design decisions (persist rationale)
success_criteria: |
  - 1000+ node knowledge graph (large codebase)
  - 10+ query types supported
  - Demo video showing workflows
  - Performance: <1s per query
  - 50+ tests
```

#### Task 3D-2: Personal Knowledge Manager
```yaml
content: "Build personal note aggregator on Tom Brain"
activeForm: "Building knowledge manager"
description: |
  - Note capture (CLI, API, web form)
  - Auto-tagging (via classification)
  - Auto-linking (related notes detection)
  - Concept extraction (dream_extract procedures)
  - Time-based review (spaced repetition)
  - Export to various formats (markdown, PDF, HTML)
success_criteria: |
  - Note capture working (5 input methods)
  - 1000+ notes indexed
  - Auto-tagging accuracy >80%
  - Related note detection working
  - Review workflow implemented
  - Demo with 6-month personal notes
```

#### Task 3D-3: Research Paper Digester
```yaml
content: "Build research paper analysis assistant on Tom Brain"
activeForm: "Building paper digester"
description: |
  - PDF upload + extraction
  - Concept extraction (abstract, methods, results)
  - Relationship mapping (cites, cited-by, related-to)
  - Cross-paper search (find papers discussing topic X)
  - Summary generation (per paper, across papers)
  - Suggest further reading
success_criteria: |
  - 100+ papers indexed
  - PDF extraction working
  - Concept extraction >85% accuracy
  - Cross-paper search working
  - Summary quality validated
  - Demo with real research papers
```

---

### Phase 3E: Observability Operationalization (Weeks 11-17)

#### Task 3E-1: Prometheus Metrics Export
```yaml
content: "Implement Prometheus metrics export from Tom Brain"
activeForm: "Adding metrics export"
description: |
  - Token count metrics (input, output, total)
  - Latency histograms (retrieval, LLM, procedure, total)
  - Provider metrics (calls, errors, fallback rates)
  - Memory metrics (node count, edge count, storage size)
  - Engine metrics (runs, preemptions, fallbacks)
  - Budget metrics (spend, remaining, allocation)
success_criteria: |
  - 20+ metrics exposed
  - Prometheus-compatible format
  - /metrics endpoint (port 8081 or similar)
  - 30+ tests
```

#### Task 3E-2: Jaeger Distributed Tracing
```yaml
content: "Integrate Jaeger distributed tracing"
activeForm: "Adding distributed tracing"
description: |
  - Instrument all major components (memory, substrate, procedure, access)
  - Trace spans: request → dispatcher → engine → deliver
  - Capture key spans: recall, llm_call, persist
  - Include metadata: user_id, persona, token_count, latency
  - Configure Jaeger endpoint
  - Create trace service
success_criteria: |
  - All procedures traced end-to-end
  - Traces visible in Jaeger UI
  - Span hierarchy correct
  - Performance impact <5%
  - 30+ tests
```

#### Task 3E-3: Structured Logging
```yaml
content: "Implement structured JSON logging"
activeForm: "Adding structured logging"
description: |
  - JSON log format (timestamp, level, component, message, tags)
  - Log levels (DEBUG, INFO, WARN, ERROR, FATAL)
  - Component tagging (memory, substrate, procedure, access)
  - Request tracing (correlation IDs through logs)
  - Index logs (ELK or similar compatible)
  - Create log dashboards
success_criteria: |
  - All logs in JSON format
  - Correlation IDs tracked
  - Logs indexed and searchable
  - Dashboard showing error rates
  - 30+ tests
```

#### Task 3E-4: Health Checks
```yaml
content: "Implement comprehensive health check endpoints"
activeForm: "Adding health checks"
description: |
  - /health (overall status)
  - /health/memory (database connectivity, size, integrity)
  - /health/substrate (provider connectivity, model availability)
  - /health/procedure (engine status, queue depth)
  - /health/access (adapters running, message throughput)
  - Database integrity verification
  - Embedding consistency checks
success_criteria: |
  - 5+ health endpoints
  - <1s response time
  - Detailed status information
  - CI/CD integration ready
  - 30+ tests
```

#### Task 3E-5: Alerting Rules & Dashboards
```yaml
content: "Create alerting rules and operational dashboards"
activeForm: "Setting up alerts and dashboards"
description: |
  - Alert: Error rate > 5% (1m average)
  - Alert: Memory database size growing >1GB/day
  - Alert: Token spend > budget (80% threshold)
  - Alert: Embedding service unavailable
  - Alert: Procedure fallback rate > 10%
  - Alert: Response latency p95 > 5s
  - Dashboard: System overview (uptime, error rate, latency)
  - Dashboard: Provider health (openai, ollama status)
  - Dashboard: Memory stats (node count, storage)
  - Dashboard: Token economics (spend, budget)
success_criteria: |
  - 10+ alerting rules
  - 5+ operational dashboards
  - Alert notifications working
  - Escalation procedures documented
  - 30+ tests
```

#### Task 3E-6: Kubernetes & Helm Charts
```yaml
content: "Create Kubernetes deployment manifests and Helm charts"
activeForm: "Creating K8s manifests"
description: |
  - Deployment manifests (tom_brain_access, tom_brain_run)
  - StatefulSet for tom_brain_memory (persistent storage)
  - ConfigMaps for configuration
  - Secrets management (API keys, tokens)
  - Service definitions (ClusterIP, LoadBalancer)
  - Ingress for external access
  - Helm values.yaml
  - Helm templates
  - Upgrade procedures
success_criteria: |
  - Deployable to K8s with 1 command
  - Helm repo ready
  - Multi-environment support (dev/staging/prod)
  - PersistentVolume for memory database
  - Health checks integrated
  - Rolling updates working
  - 50+ tests
```

---

## Part 4: Timeline & Dependencies

### Recommended Execution Order

```
Phase 3A (Weeks 1-3):    Tom Brain Validation
├─ Parallel: Task 3A-1, 3A-2, 3A-3
├─ Sequential: 3A-4, 3A-5 (after 3A-1 baseline)
└─ Gate: All tasks must PASS before Phase 3B

Phase 3B (Weeks 4-7):    Tom Assistant Implementation
├─ Parallel: Task 3B-1, 3B-2, 3B-3
├─ Sequential: 3B-4 (after server API finalized)
├─ Sequential: 3B-5 (after all components in place)
└─ Gate: Integration tests must PASS

Phase 3C (Weeks 5-10):   System Integrations (Parallel with 3B)
├─ Parallel: Task 3C-1, 3C-2, 3C-3, 3C-4
├─ Start: After 3B-3 (server API finalized)
└─ Can overlap with 3B work

Phase 3D (Weeks 8-15):   Reference Applications (After 3B)
├─ Parallel: Task 3D-1, 3D-2, 3D-3
├─ Start: After 3B-5 (integration tests passing)
└─ Showcase applications built on Tom Brain

Phase 3E (Weeks 11-17):  Observability (Parallel with 3C, 3D)
├─ Parallel: Task 3E-1, 3E-2, 3E-3
├─ Sequential: 3E-4, 3E-5, 3E-6
├─ Start: After 3B-1 (core metrics baseline)
└─ Gate: Production readiness
```

### Critical Path

```
3A-1 (validation) → PASS gate → 
3B-1, 3B-2, 3B-3 (core, messaging, server) → 
3B-4 (UI) → 
3B-5 (integration tests) → PASS gate →
3D-1, 3D-2, 3D-3 (showcase apps) + 
3E-1 through 3E-6 (observability)
```

**Total Timeline: 17 weeks (≈4 months)**

**Effort Estimate:**
- Phase 3A: 2-3 weeks, 1-2 people
- Phase 3B: 3-4 weeks, 2-3 people
- Phase 3C: 4-5 weeks, 2-3 people (parallel with 3B)
- Phase 3D: 6-8 weeks, 2-3 people (parallel with 3C)
- Phase 3E: 6-7 weeks, 1-2 people (parallel with all)

---

## Part 5: Success Metrics & Validation

### Phase 3A Success Metrics

- [ ] Smoke test passes with 100 conversation turns
- [ ] Memory persistence: 100% node recovery
- [ ] Retrieval quality baseline established
- [ ] Preemption/fallback mechanics verified
- [ ] Anchor enforcement validated (100%)
- [ ] Performance baseline: <2s per turn average

### Phase 3B Success Metrics

- [ ] tom_assistant_core: 500+ lines, 50+ tests
- [ ] tom_assistant_messaging: Full protocol spec
- [ ] tom_assistant_server: 15+ API endpoints, 100+ tests
- [ ] tom_assistant_ui: Production Flutter app, 50+ tests
- [ ] Integration tests: 50+ tests, all passing
- [ ] Performance: <500ms API response time (p95)

### Phase 3C Success Metrics

- [ ] VS Code: 5+ features, 100+ tests
- [ ] Telegram: 8+ commands, custom personas
- [ ] Agent SDK: Tom Brain tools callable, 30+ tests
- [ ] Slack: 5+ commands, 50+ tests

### Phase 3D Success Metrics

- [ ] Code Research: 1000+ node graph, 10+ queries, demo video
- [ ] Knowledge Manager: 1000+ notes, >80% tagging accuracy
- [ ] Paper Digester: 100+ papers, >85% extraction accuracy

### Phase 3E Success Metrics

- [ ] 20+ Prometheus metrics exported
- [ ] All procedures traced end-to-end in Jaeger
- [ ] All logs in JSON format, indexed
- [ ] 5+ health endpoints, <1s response
- [ ] 10+ alerting rules active
- [ ] 5+ operational dashboards
- [ ] K8s deployment with Helm, 1-command deploy
- [ ] Production readiness certification

---

## Part 6: Risks & Mitigation

### Technical Risks

**Risk:** Embedding consistency issues in distributed setup
- **Mitigation:** Embedding identity stamps, consistency tests, Ollama model pinning

**Risk:** SQLite scalability at 1M+ nodes
- **Mitigation:** Regular archival, index optimization, migration to PostgreSQL vec if needed

**Risk:** Preemption complexity (subtle state bugs)
- **Mitigation:** Extensive state machine testing, formal verification of critical sections

**Mitigation:** LLM provider instability
- **Mitigation:** Comprehensive fallback chains, rate limit detection, circuit breaker patterns

### Organizational Risks

**Risk:** Scope creep (43 active quests pulling attention)
- **Mitigation:** Focus on critical path (3A → 3B → 3D), defer integrations/observability

**Risk:** Integration complexity (many systems touch Tom Brain)
- **Mitigation:** Strict API contracts, integration tests, API versioning

**Risk:** Observability overhead (tracing/metrics impact)
- **Mitigation:** Measure before/after, use sampling for high-volume metrics

---

## Conclusion

The Tom Brain workspace audit reveals a **sophisticated, production-ready cognitive system** requiring validation and a thin **Tom Assistant consumer layer** ready for implementation.

**Strategic priorities:**
1. **Validate** Tom Brain (3A) — gate all other work
2. **Implement** Tom Assistant (3B) — thin protocol wrapper, showcase integration
3. **Integrate** with VS Code, Telegram, Agent SDK (3C) — expand reach
4. **Demonstrate** with reference apps (3D) — prove Tom Brain value
5. **Operationalize** observability (3E) — production readiness

**Success path:** 17-week execution with 4-6 people across phases yields a **production-grade AI assistant platform** (Tom Brain) with **full-stack integration** (Tom Assistant + extensions) and **operational visibility**.

The architecture is sound. Implementation is the path forward.
