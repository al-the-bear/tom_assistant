// SubstrateEventBus — central fan-in for `SubstrateEvent`s emitted
// across the substrate subsystem (Plan step B.38; spec § 3.1
// `TomBrainSubstrateClient.events()`, spec § 10.2 observability
// surface).
//
// What this file owns:
//
//   - A `StreamController<SubstrateEvent>.broadcast()` that fans every
//     emission out to every subscriber.
//   - The `void Function(SubstrateEvent)` sink that the per-subsystem
//     emitters (router, providers, embedding service, web tools, MCP
//     client) take as their `eventSink` constructor argument. The
//     composition root (`InProcessTomBrainSubstrate`, lands at plan
//     step B.40+) hands `bus.emit` to every component so every event
//     lands on the same controller.
//   - The `Stream<SubstrateEvent>` returned from
//     `TomBrainSubstrateClient.events()`.
//
// What this file does NOT own:
//
//   - The events themselves. `SubstrateEvent` and its leaves live in
//     `lib/src/api/substrate_event.dart` (B.9 sealed sum: twelve
//     variants — `LlmCallStarted`, `LlmCallChunk`, `LlmCallCompleted`,
//     `LlmCallFailed`, `ProviderFailover`, `CredentialCooldownStarted`,
//     `EmbeddingComputed`, `EmbeddingIdentityChanged`,
//     `WebSearchCompleted`, `WebFetchCompleted`,
//     `McpHandshakeCompleted`, `McpCallCompleted`). Adding a new leaf
//     is a `substrate_event.dart` edit; the bus stays generic in
//     `SubstrateEvent`.
//
//   - Filtering. Subscribers filter with
//     `bus.events().where((e) => e is LlmCallCompleted)`. Pushing
//     typed filters into the bus would tie it to the event taxonomy
//     and turn every new leaf into an interface edit.
//
//   - Persistence. Events are observed live; the trail subsystem
//     (over in `tom_brain_memory`) persists the entries that matter
//     for replay. The substrate is observability-only — it does not
//     hold history.
//
//   - Stats. `SubstrateStats` is a separate cheap-counters surface
//     (`substrate_stats.dart`); the bus and the stats collector are
//     fed in parallel by the same per-subsystem emit sites.
//
// Design choices (direct mirror of memory's `MemoryEventBus` at plan
// step A.85 — same "consumers vary, producers don't" framing):
//
//   - **Broadcast**, not single-subscription. Multiple observers can
//     subscribe simultaneously — the dispatcher feeds its trail from
//     `LlmCallCompleted` + `WebFetchCompleted`; the Forge brain
//     inspector reads everything for the operator UI; tests subscribe
//     for assertions; the cooldown-watchdog reads
//     `CredentialCooldownStarted`. A single-subscription controller
//     would let any one of those starve the others.
//
//   - **Asynchronous** (`sync: false`). Emission is a constant-time
//     enqueue, not an O(observers) fan-out under the producer's
//     lock. This matters because some producers (the LLM router,
//     `OllamaEmbeddingService.embedBatch`, the streaming completion
//     loop) emit inside tight inner loops; a slow subscriber must
//     never block the call path.
//
//   - **Closed after `close()`**. Subsequent `emit` calls throw
//     `StateError`; subsequent `events()` subscribers get a
//     done-stream. The composition root closes the bus during
//     `TomBrainSubstrate.close()` so the dispatcher's `await for`
//     loops terminate cleanly.
//
//   - **No back-pressure across the bus**. Broadcast streams in
//     `dart:async` do not implement back-pressure; a slow subscriber
//     drops nothing but does fall behind. The agreed posture is
//     "events are an observability stream, not a queue" — if a
//     subscriber needs durability it reads trails on the memory
//     side. This matches the posture documented on `BrainEvent`
//     and on `MemoryEventBus`.
//
// Spec-vs-plan divergence (locked in tests, not behaviour):
//
//   Plan step B.38 names five subtypes (`LlmCallStarted`,
//   `LlmCallCompleted`, `ProviderFailover`, `EmbeddingComputed`,
//   `WebFetchCompleted`). Spec § 10.2 names twelve (the same five
//   plus seven more — see the sealed sum in
//   `api/substrate_event.dart`). The bus is typed on the abstract
//   base, so the same controller fans every variant out without any
//   per-variant code; the divergence is captured in the test
//   assertions, not in this file. Mirrors the B.37 logger pattern.
//   See Q-B.38.1 in `prototype_implementation_questions.md`.

import 'package:tom_brain_shared/tom_brain_shared.dart';

import '../api/substrate_event.dart';

/// Central fan-in for `SubstrateEvent`s emitted across the substrate
/// subsystem.
///
/// One bus per open `InProcessTomBrainSubstrate` (the in-process
/// facade that lands at B.40+). The composition root constructs the
/// bus, hands `bus.emit` to every per-subsystem emitter's `eventSink`
/// parameter, and exposes `bus.events()` as the
/// `TomBrainSubstrateClient.events()` return.
///
/// Lifecycle, broadcast/async semantics, and the closed-after-close
/// guard all live in the shared [BrainEventBus] (B.2.1) — this is the
/// element-bound subclass for `SubstrateEvent`. The five Tom Brain
/// buses were verbatim shape-mirrors; the only per-component values are
/// the element type and the bus label in the emit-after-close message.
final class SubstrateEventBus extends BrainEventBus<SubstrateEvent> {
  SubstrateEventBus() : super(busLabel: 'SubstrateEventBus');
}
