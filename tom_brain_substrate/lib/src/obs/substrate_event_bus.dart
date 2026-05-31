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

import 'dart:async';

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
/// Lifecycle: [emit] is legal up until [close]; after [close] [emit]
/// throws `StateError` and [events] subscribers receive a done-stream.
///
/// Shape mirror of `MemoryEventBus` (A.85). Two reasons: (i) zero
/// design risk — the memory pattern has shipped, is exercised by
/// every memory test that goes through an emitter, and is a documented
/// invariant in `memory_specification.md` § 16; (ii) zero divergence
/// cost — a future reader who has read one bus has read the other.
/// The only intentional divergence is the event-base type
/// (`SubstrateEvent` vs `MemoryEvent`).
final class SubstrateEventBus {
  /// The backing broadcast controller.
  ///
  /// `sync: false` is the default; we name it explicitly to make the
  /// design choice visible. Asynchronous emission keeps the producer
  /// call stack short and prevents a slow subscriber from stalling a
  /// per-call emit site (router rotation, streaming chunk fan-out,
  /// embedding batch fan-out).
  final StreamController<SubstrateEvent> _controller =
      StreamController<SubstrateEvent>.broadcast(sync: false);

  /// `true` once [close] has been called. After close, [emit] throws
  /// and the broadcast stream is in its done state.
  bool _closed = false;

  /// Whether this bus has been closed.
  bool get isClosed => _closed;

  /// Emits [event] to every current subscriber.
  ///
  /// Asynchronous: the call enqueues the event on the controller and
  /// returns. Subscribers see the event on a future microtask, not
  /// inside the producer's call stack.
  ///
  /// Throws `StateError` if the bus has been closed. Producers that
  /// race with shutdown should guard with [isClosed] — but the
  /// expected pattern is that the composition root closes the bus
  /// *after* every per-subsystem emitter is quiesced, so the race
  /// should not happen in practice.
  void emit(SubstrateEvent event) {
    if (_closed) {
      throw StateError(
        'SubstrateEventBus.emit called after close '
        '(event kind=${event.kind})',
      );
    }
    _controller.add(event);
  }

  /// Returns the typed event stream.
  ///
  /// Broadcast — multiple subscribers see every event. Subscriptions
  /// can come and go; missed events stay missed (this is an
  /// observability stream, not a durable queue).
  ///
  /// Each call returns the *same* underlying stream; subscribing
  /// multiple times produces multiple independent subscriptions, not
  /// duplicate views of the same one. This matches
  /// `StreamController.broadcast()` semantics.
  Stream<SubstrateEvent> events() => _controller.stream;

  /// Closes the bus.
  ///
  /// Subsequent [emit] calls throw `StateError`; live subscribers
  /// receive a done event and any `await for` loop over [events]
  /// terminates.
  ///
  /// Idempotent — calling `close` on an already-closed bus succeeds
  /// and returns immediately.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}
