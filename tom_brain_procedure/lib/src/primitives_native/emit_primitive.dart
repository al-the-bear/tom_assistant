// emit — the engine-native outbound-delta primitive (P1.3 #8;
// `tom_brain_procedure_specification.md` § 5.1, § 11 step 2).
//
// `emit(textDelta)` streams one increment of an answer back to the
// originating channel *while the procedure is still running*. It is the
// procedure-world expression of the spec's "stream tokens back via the
// `Access.deliver` callback": a body that produces text outside an
// `sub.llm(...)` call (a status line, a hand-assembled message) pushes it to
// the live caller through `emit` rather than only returning it at the end.
//
// ── Why `emit` and `sub.llm`'s token forwarding share one sink ───────
//
// `sub.llm(...)` already forwards each substrate `LlmStreamChunk` to the
// per-run [SubstrateTokenSink] the engine binds for an external request
// (P1.3 #7). `emit` is the *explicit* counterpart for text the body itself
// authors. Both write to the **same** per-run outbound channel (the engine
// binds one closure to both), so an answer streamed by `sub.llm` and a line
// emitted by the body arrive on the wire in the one order the body produced
// them. `answer_with_memory_v1` streams purely through the `sub.llm` seam and
// never calls `emit`; `emit` exists for procedures whose outbound text is not
// a single substrate completion.
//
// ── Why the sink is nullable (the internal / free-time path) ──────────
//
// Streaming is only required for an incoming external/user request; for an
// indirectly-triggered internal secondary prompt or a free-time run it is
// optional and would only add wiring (the USER decision behind P1.3). So the
// engine binds a real [OutboundDeltaSink] only on the top-level external run
// and leaves it `null` everywhere else. With no sink bound, `emit` is a
// no-op — a background body may call it unconditionally without caring
// whether anyone is listening, exactly as `sub.llm`'s token forwarding falls
// back to buffer-only when its sink is unbound.
//
// ── Why `emit` is awaited (backpressure) ─────────────────────────────
//
// Unlike `note` (fire-and-forget onto the trail), `emit` returns a
// `Future<void>` the script awaits, so the downstream channel's backpressure
// (an SSE client that cannot keep up, a Telegram rate limit) propagates back
// into the body's own pacing rather than piling unbounded work behind a dead
// wire. The sink the engine binds wraps `Access.deliver` and only resolves
// once the chunk is accepted.

/// Receives each outbound text delta a procedure streams to its caller.
///
/// The engine binds a per-run instance only for an **external/user** request
/// (the path the spec § 11 step 2 mandates streaming for); internal secondary
/// and free-time runs leave it unbound and [EmitPrimitive.emit] is a no-op.
/// [textDelta] is one increment of the answer, in the order the body produced
/// it. The future is awaited per delta so the downstream channel's
/// backpressure reaches the body. Structurally identical to the substrate's
/// `SubstrateTokenSink`: the engine binds the *same* closure to both so a
/// `sub.llm` token stream and an `emit` call share one ordered outbound
/// channel.
typedef OutboundDeltaSink = Future<void> Function(String textDelta);

/// The engine-native `emit` primitive.
///
/// Forwards each `emit(textDelta)` call to the injected [OutboundDeltaSink]
/// when one is bound (an external run), and drops it otherwise (an internal /
/// free-time run with no live caller). Stateless apart from its sink.
final class EmitPrimitive {
  /// Builds the primitive over an optional outbound [sink].
  ///
  /// [sink] is bound only on the top-level external/user run; an internal or
  /// free-time run constructs the primitive with no sink so [emit] is a no-op.
  EmitPrimitive({OutboundDeltaSink? sink}) : _sink = sink;

  final OutboundDeltaSink? _sink;

  /// Whether this primitive forwards to a live outbound channel.
  ///
  /// `true` on an external run (a sink is bound), `false` on an internal /
  /// free-time run (no sink). Exposed so callers / tests can assert the
  /// streaming vs buffered branch without emitting.
  bool get isBound => _sink != null;

  /// Streams one [textDelta] increment to the originating channel.
  ///
  /// Forwards to the bound [OutboundDeltaSink] and awaits its completion so
  /// the channel's backpressure reaches the caller. With no sink bound this is
  /// a no-op that completes immediately — an internal / free-time run has no
  /// live caller to stream to.
  Future<void> emit(String textDelta) async {
    final sink = _sink;
    if (sink == null) return;
    await sink(textDelta);
  }
}
