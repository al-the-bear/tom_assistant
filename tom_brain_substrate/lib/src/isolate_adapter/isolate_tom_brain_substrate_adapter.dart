// IsolateTomBrainSubstrateAdapter — the isolate-backed implementation
// of [TomBrainSubstrateClient] (Tom Brain completion-plan item #12).
//
// This is the *second* implementation of the substrate client surface;
// the in-process facade (`InProcessTomBrainSubstrate`) is the first. The
// adapter hosts a real `TomBrainSubstrateClient` inside a worker isolate
// (via [TomBrainSubstrateIsolateHost]) and marshals every surface method
// across the boundary. It exists so a procedure engine running in its
// own isolate (or, later, on its own machine) can drive the substrate
// without sharing mutable state across the boundary.
//
// Two behaviours are load-bearing:
//
//   * **Anchor re-check at the proxy.** `complete` and `completeStream`
//     independently re-verify every surfaced report's `anchorHash`
//     against the proxy's own `AnchorRegistry.currentHash`, throwing
//     `AnchorViolation` *locally* before the report ever reaches a
//     consumer. The worker enforces the anchor too — but a worker that
//     fails to (a tampered or buggy build) cannot leak an unanchored
//     report past this proxy. This mirrors the facade's
//     `_enforceAnchorOrThrow` exactly, so the adapter "behaves
//     identically to the in-process facade".
//
//   * **Synchronous `stats()` from a piggybacked cache.** The client
//     surface returns `SubstrateStats` synchronously, so the proxy
//     cannot await a round trip. Every unary reply carries a fresh
//     stats snapshot, which the proxy caches; `stats()` returns the
//     cache. Streamed completions do not refresh the cache (no unary
//     reply rides back with them) — `stats()` is therefore
//     eventually-consistent with respect to streamed calls. A consumer
//     that needs streamed-call counters reads them after the next unary
//     call, or via the worker's own MCP / observability surface.

import '../api/embedding_result.dart';
import '../api/llm_call.dart';
import 'package:tom_core_llm/tom_core_llm.dart';
import '../api/mcp_endpoint.dart';
import '../api/substrate_event.dart';
import '../api/substrate_stats.dart';
import '../api/tom_brain_substrate_client.dart';
import '../api/web_results.dart';
import '../config/substrate_config.dart';
import '../llm/anchor_registry.dart';
import '../mcp_client/mcp_client_barrel.dart';
import 'substrate_isolate_messages.dart';
import 'substrate_stream_protocol.dart';
import 'tom_brain_substrate_isolate_host.dart';

/// Isolate-backed [TomBrainSubstrateClient]. Construct over a
/// [TomBrainSubstrateIsolateHost] that has already been `spawn()`ed.
final class IsolateTomBrainSubstrateAdapter implements TomBrainSubstrateClient {
  final TomBrainSubstrateIsolateHost host;

  /// The last stats snapshot piggybacked on a unary reply. Seeded empty
  /// so `stats()` is answerable before any call has round-tripped.
  SubstrateStats _cachedStats = SubstrateStats.empty(DateTime.now().toUtc());

  IsolateTomBrainSubstrateAdapter({required this.host});

  @override
  Future<void> open(SubstrateConfig config) async {
    final resp = await host.send<OpenSubstrateResponse>(
      OpenSubstrateRequest(config),
    );
    _cachedStats = resp.stats;
  }

  @override
  Future<void> close() async {
    final resp = await host.send<CloseSubstrateResponse>(
      const CloseSubstrateRequest(),
    );
    _cachedStats = resp.stats;
  }

  @override
  Future<LlmCallReport> complete(LlmCall call) async {
    final resp = await host.send<CompleteResponse>(
      CompleteRequest(_stripForWire(call)),
    );
    _cachedStats = resp.stats;
    _enforceAnchorOrThrow(report: resp.report, roleId: call.roleId);
    return resp.report;
  }

  @override
  Stream<LlmEvent> completeStream(LlmCall call) async* {
    final streamId = host.streamIdAllocator.next();
    final stream = host.openStream<LlmEvent>(
      OpenCompleteStreamRequest(streamId: streamId, call: _stripForWire(call)),
      streamId: streamId,
    );
    await for (final event in stream) {
      if (event is LlmRunCompleted) {
        // Re-check before surfacing: never yield an unanchored report.
        _enforceAnchorOrThrow(report: event.report, roleId: call.roleId);
      }
      yield event;
    }
  }

  @override
  Future<EmbeddingResult> embed(String text) async {
    final resp = await host.send<EmbedResponse>(EmbedRequest(text));
    _cachedStats = resp.stats;
    return resp.result;
  }

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) async {
    final resp = await host.send<EmbedBatchResponse>(EmbedBatchRequest(texts));
    _cachedStats = resp.stats;
    return resp.results;
  }

  @override
  Future<WebSearchResult> webSearch(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async {
    final resp = await host.send<WebSearchResponse>(
      WebSearchRequest(query: query, options: options),
    );
    _cachedStats = resp.stats;
    return resp.result;
  }

  @override
  Future<WebFetchResult> webFetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async {
    final resp = await host.send<WebFetchResponse>(
      WebFetchRequest(url: url, options: options),
    );
    _cachedStats = resp.stats;
    return resp.result;
  }

  @override
  McpClient mcpClient(McpEndpoint endpoint) {
    // An MCP client is a live, stateful connection holding sockets and
    // controllers — none of which can cross an isolate boundary. A
    // consumer that needs MCP runs it on the isolate that owns the
    // worker (the in-process facade), not through this proxy.
    throw UnsupportedError(
      'IsolateTomBrainSubstrateAdapter.mcpClient is not supported across '
      'the isolate boundary: an McpClient holds non-sendable connection '
      'state. Use the in-process facade for outbound MCP.',
    );
  }

  @override
  Stream<SubstrateEvent> events() {
    final streamId = host.streamIdAllocator.next();
    return host.openStream<SubstrateEvent>(
      OpenEventsStreamRequest(streamId),
      streamId: streamId,
    );
  }

  @override
  SubstrateStats stats() => _cachedStats;

  // ─── Internal helpers ────────────────────────────────────────

  /// Replicates `InProcessTomBrainSubstrate._enforceAnchorOrThrow`: a
  /// report whose anchor is not current never reaches a consumer.
  void _enforceAnchorOrThrow({
    required LlmCallReport report,
    required String roleId,
  }) {
    if (AnchorRegistry.isCurrent(report.anchorHash)) return;
    throw AnchorViolation(
      expected: AnchorRegistry.currentHash,
      actual: report.anchorHash,
      providerId: report.providerId,
      modelId: report.modelId,
      roleId: roleId,
    );
  }

  /// Rebuilds [call] without its `cancellationToken`. A live token may
  /// capture a `Completer` / `StreamController` and is not sendable; the
  /// rebuilt call carries `CancellationToken.none` (a const, field-free,
  /// sendable singleton). Cancellation across the boundary is not
  /// supported — substrate streams self-terminate and are torn down via
  /// the host's `closeStream`.
  LlmCall _stripForWire(LlmCall call) => LlmCall(
    roleId: call.roleId,
    inputs: call.inputs,
    options: call.options,
    budget: call.budget,
    turnId: call.turnId,
    callSeq: call.callSeq,
  );
}
