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
library;

export 'src/smoke_brain.dart'
    show SmokeProcess, smokeBearerToken, standUpSmokeProcess;
export 'src/smoke_memory.dart' show SmokeMemory, spawnSmokeMemory;
export 'src/smoke_substrate.dart' show SmokeSubstrate;
