// B.9 — `TomBrainSubstrateClient`.
//
// The *consumer-facing* contract every brain component (the
// dispatcher in Phase D, the procedure engine in Phase E, the
// access layer, tests) binds against. The substrate facade
// `TomBrainSubstrate` (see `tom_brain_substrate.dart`)
// implements this. A future isolate or remote adapter implements
// the same interface without any code change in consumers.
//
// Mirrors `substrate_specification.md` § 3.1. The method-level
// docs describe the *consumer-observable* contract — what every
// implementation must honour. Implementation-level mechanics
// (provider routing, retry, anchor injection, role assembly, MCP
// session caching) belong in the implementation classes and are
// **not** part of this contract.
//
// B.9 status: interface only. No implementation lands here; the
// in-process facade arrives in incremental steps (B.11+ for the
// LLM half, B.21+ for roles, B.25+ for embedding, B.29+ for web
// tools, B.40+ for the in-process facade itself).
//
// B.40 status: the engine-bridge contract is locked. The procedure
// engine binds against [TomBrainSubstrateClient] only. There is no
// engine-side reference to `TomBrainSubstrate` (the in-process
// marker), nor to the upcoming `InProcessTomBrainSubstrate` (B.41).
// Surface drift on this contract breaks the structural test at
// `test/b40_engine_bridge_contract_test.dart` before any
// behavioural test runs. See the file header there for the three
// load-bearing invariants the test pins.

import '../mcp_client/mcp_client_barrel.dart';

import 'embedding_result.dart';
import 'llm_call.dart';
import 'package:tom_core_llm/tom_core_llm.dart';
import '../config/substrate_config.dart';
import 'mcp_endpoint.dart';
import 'substrate_event.dart';
import 'substrate_stats.dart';
import 'web_results.dart';

/// Consumer-facing contract for the Tom Brain substrate.
///
/// Six surfaces, in spec § 3.1 order:
///
///   1. Lifecycle — [open], [close].
///   2. LLM      — [complete], [completeStream].
///   3. Embedding — [embed], [embedBatch].
///   4. Web tools — [webSearch], [webFetch].
///   5. MCP outbound — [mcpClient].
///   6. Observability — [events], [stats].
///
/// **Anchor guarantee.** Every call path that produces an
/// `LlmCallReport` (i.e. [complete] and [completeStream]) carries
/// the assistant-dedication anchor on the assembled wire prompt and
/// stamps the anchor's content hash on the report's `anchorHash`
/// field. A report whose `anchorHash` is not the current registry
/// hash is `AnchorViolation` (spec § 12) — a fatal substrate event,
/// not a recoverable error. Consumers do not need to enforce this;
/// the substrate enforces it for them and the conformance test at
/// plan step B.46 proves the surface cannot bypass it.
abstract class TomBrainSubstrateClient {
  // ─── Lifecycle ───────────────────────────────────────────────

  /// Opens the substrate against [config].
  ///
  /// Validates the provider set, materialises the route chains,
  /// connects to (or lazily prepares) MCP endpoints, registers the
  /// embedding-model identity. Idempotent — calling on an already-
  /// open substrate returns immediately.
  ///
  /// Fails with:
  ///   - `RoleNotFound` when a configured `roleRoutes` key references
  ///     a role template that does not exist.
  ///   - `AuthMethodUnsupported` when a provider's `auth.method` is
  ///     not in the prototype's supported set (`api_key`, `none`).
  ///   - `ConfigInvalid` for any structural defect in [config].
  Future<void> open(SubstrateConfig config);

  /// Closes the substrate: aborts in-flight calls, fsyncs any
  /// pending observability writes, closes MCP sessions and HTTP
  /// connections. Idempotent.
  Future<void> close();

  // ─── LLM ─────────────────────────────────────────────────────

  /// Runs an LLM call to completion and returns the report.
  ///
  /// Buffers the underlying stream and returns a single
  /// [LlmCallReport]. Equivalent to draining
  /// [completeStream] and returning the [LlmRunCompleted]'s
  /// report.
  ///
  /// Failure shape:
  ///   - The router and provider classify failures into the closed
  ///     taxonomy (spec § 5.4). A failure that the router has no
  ///     route to recover from surfaces as an exception whose runtime
  ///     class matches the failure (e.g. `NoRouteAvailable`,
  ///     `ContextOverflow`, `AnchorViolation`). The closed exception
  ///     set is part of the substrate version contract.
  Future<LlmCallReport> complete(LlmCall call);

  /// Streams the LLM call.
  ///
  /// The returned stream emits exactly one [LlmRunStarted], zero
  /// or more [LlmTextDelta] / [LlmToolCall] events,
  /// then exactly one of [LlmRunCompleted] / [LlmRunFailed].
  ///
  /// Cancellation: completing [LlmCall.cancellationToken] aborts the
  /// underlying provider connection and surfaces
  /// `LlmRunFailed(LlmFailure(classCode: 'cancelled_by_consumer',
  /// ...))`.
  ///
  /// Non-streaming providers (those whose underlying API does not
  /// support streaming): the substrate buffers the response, emits
  /// one [LlmTextDelta] with the full text, then
  /// [LlmRunCompleted]. Consumers cannot distinguish a
  /// non-streaming provider from one that simply chose to emit one
  /// large chunk.
  Stream<LlmEvent> completeStream(LlmCall call);

  // ─── Embedding ───────────────────────────────────────────────

  /// Embeds [text] and returns the vector + identity of the model
  /// that produced it.
  ///
  /// The identity is the substrate's commitment to the cosine
  /// invariant: two [EmbeddingResult]s with `==` identities are
  /// comparable under cosine. Memory stamps the identity on the
  /// per-vector marker row (`memory_specification.md` § 7.4).
  Future<EmbeddingResult> embed(String text);

  /// Batched embedding. Returns one [EmbeddingResult] per input,
  /// in input order.
  ///
  /// Batching is the implementation's choice — the surface
  /// promises the same identity on every result and the same
  /// vectors-from-the-same-text invariant as [embed]. Concurrency
  /// caps and per-batch token limits are policy in [SubstrateConfig]
  /// and live below this surface.
  Future<List<EmbeddingResult>> embedBatch(List<String> texts);

  // ─── Web tools ───────────────────────────────────────────────

  /// Issues a web search.
  ///
  /// Uses [WebSearchOptions.provider] when set; otherwise the
  /// substrate's configured default. Returns the engine-supplied
  /// hits in engine-supplied order.
  Future<WebSearchResult> webSearch(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  });

  /// Fetches [url] with the configured budget + headers + UA.
  ///
  /// A response larger than the budget returns with
  /// `truncated: true` rather than failing. Unsupported content
  /// types surface as `WebFetchUnsupportedType` (spec § 12). Other
  /// transport failures surface as the typed `WebFetch*` errors
  /// declared in the implementation layer.
  Future<WebFetchResult> webFetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  });

  // ─── MCP outbound ────────────────────────────────────────────

  /// Returns an outbound MCP client bound to [endpoint].
  ///
  /// The substrate caches one persistent MCP session per
  /// `McpEndpoint` (`substrate_specification.md` § 3.2); successive
  /// calls with the same [endpoint] return the same underlying
  /// session. On disconnect the next tool call triggers a re-
  /// handshake with exponential backoff.
  ///
  /// The returned [McpClient] is owned by the substrate — consumers
  /// must not call `close()` on it. Closing it would invalidate the
  /// substrate's cache for other consumers.
  McpClient mcpClient(McpEndpoint endpoint);

  // ─── Observability ───────────────────────────────────────────

  /// Typed event stream. Consumers (dispatcher trail, Tom Forge
  /// inspector, metrics scraper) subscribe to this for the firehose.
  ///
  /// The stream is broadcast — late subscribers do not see past
  /// events. Per-run replay belongs to the trail layer (memory),
  /// not to substrate.
  ///
  /// **Buffered-vs-streaming failure asymmetry.** A failed
  /// [completeStream] call emits a terminal `LlmCallFailed` event here,
  /// because the router surfaces it as an `LlmRunFailed` carrier that
  /// names the provider/model triple. A failed [complete] call does
  /// **not** emit `LlmCallFailed`: the router surfaces buffered failures
  /// as typed router-layer exceptions (`NoRouteAvailable`,
  /// `ContextOverflowError`, …) that are the chain's terminal verdict and
  /// carry no single-provider triple. Consumers that need a structural
  /// "the buffered call ended in failure" signal must observe the thrown
  /// exception at the call site, not this stream.
  Stream<SubstrateEvent> events();

  /// Point-in-time counters snapshot. Cheap; safe to poll.
  SubstrateStats stats();
}
