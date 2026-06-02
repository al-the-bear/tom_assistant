/// End-to-end smoke harness for the Tom Brain prototype.
///
/// The higher assembly that boots a whole cognition (a stub substrate + an
/// in-isolate memory) and stands the access process up on a local port — the
/// one package that may legally wire `tom_brain_substrate`, `tom_brain_memory`,
/// `tom_brain_procedure_prototype`, and `tom_brain_access_prototype` together.
/// It fulfils the access package's `BrainProvisioner` seam, whose default
/// refuses because the access package cannot boot a brain on its own. See
/// Phase E.10 (steps E.46–E.50) of `prototype_implementation_plan.md`.
///
/// - E.46 ✅ — Stand-up smoke: [standUpSmokeProcess] boots the cognition with
///   [SmokeSubstrate] + in-isolate [SmokeMemory] and binds the OpenAI +
///   `/healthz` socket on a local port, returning a [SmokeProcess] handle.
/// - E.47 ✅ — Chat-completion roundtrip: a real `POST /v1/chat/completions`
///   (`stream=false`) runs `answer_with_memory_v1` to completion; the OpenAI
///   body carries the answer and the in-isolate memory holds the persisted
///   `Event` + `Conclusion` + edges (read back through [SmokeProcess.memory]).
/// - E.48 ✅ — Streaming roundtrip: a real `POST /v1/chat/completions`
///   (`stream=true`) returns a `text/event-stream` body whose `data:` frames
///   are `chat.completion.chunk` objects in order, terminated by a final
///   `data: [DONE]` line.
/// - E.49 ✅ — Telegram roundtrip: [standUpSmokeProcess] also stands up the
///   Telegram edge over an injected loopback `ChatApi`. A whitelisted sender's
///   message runs the full cognition and the answer is delivered back as a
///   Telegram message; a non-whitelisted sender is gated at the edge (the
///   graceful decline, no `Access`, nothing written to memory).
/// - E.50 ✅ — Classifier short-circuit: [standUpSmokeProcess] also wires the
///   cheap kind-hint classifier (a counting embedder + a confident centroid
///   classifier) and a spy dispatcher fallback. Driving a second prompt with
///   *identical* text proves the E.34 embedding cache saves the embed call (the
///   embedder is called once across both prompts) and that the confident
///   centroid classification attaches a kind-hint the dispatcher accepts
///   verbatim — so its `classify_inbound_v1` fallback (the LLM-classifier
///   stand-in) is never called.
/// - E.55 ✅ — End-to-end conformance, inspected via the MCP server:
///   [standUpSmokeProcess] accepts an `inProcessMemory` ([InspectableSmokeMemory])
///   that switches the cognition onto the in-process memory transport so the run
///   and the memory MCP server share one store in the host isolate. A scripted
///   OpenAI scenario (and, repeated, a Telegram scenario) drives the channel to
///   an answer, then stands `TomBrainMemoryMcpServer` up over the shared store
///   and asserts the post-run graph *purely through the MCP read tools*:
///   `memory.recall` surfaces the run's `Event` (summary == prompt) and
///   `Conclusion` (statement == answer); `memory.stack.list` shows the cold-path
///   `interests` stack with one entry; `memory.stack.peek` + `memory.get`
///   resolve it to an `InterestItem` whose `topic` is the prompt.
/// - E.58 ✅ — Process-level latency bench: [runProcessLatencyBench] drives N
///   streaming `POST /v1/chat/completions` requests against a stood-up
///   [SmokeProcess] and measures inbound-prompt → first-SSE-chunk latency,
///   summarising p50/p95 ([LatencySummary]) against the plan's
///   [processBenchP95Target] (p95 ≤ 250 ms) with the stub substrate +
///   isolate-hosted memory. The pure percentile maths
///   ([percentileDuration]) and report rendering ([renderLatencyReport]) are
///   unit-tested; `bin/e58_process_bench.dart` is the runnable entry point.
library;

export 'src/inspectable_smoke_memory.dart' show InspectableSmokeMemory;
export 'src/latency_bench.dart'
    show
        LatencySummary,
        defaultBenchPrompt,
        measureTimeToFirstSseFrame,
        percentileDuration,
        processBenchP95Target,
        renderLatencyReport,
        runProcessLatencyBench;
export 'src/smoke_brain.dart'
    show SmokeProcess, smokeBearerToken, standUpSmokeProcess;
export 'src/smoke_memory.dart' show SmokeMemory, spawnSmokeMemory;
export 'src/smoke_substrate.dart' show SmokeSubstrate;
