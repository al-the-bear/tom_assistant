// SmokeSubstrate — a stub `TomBrainSubstrateClient` for the end-to-end smoke
// (E.46).
//
// The smoke harness boots a real `BrainProcessBoot`, which binds the engine's
// `sub` bridge against a `TomBrainSubstrateClient`. For the prototype smoke we
// do not want a real provider call, so this stub stands in: it emits a canned
// chunked answer stream (whose concatenation is the answer text) and a fixed
// one-dimensional embedding. It records its open/close lifecycle so a test can
// assert the boot opened and the shutdown closed it.
//
// Modelled on the procedure prototype's `_AnsweringSubstrate`
// (`d44_brain_process_boot_test.dart`) — kept here as a library symbol (not a
// test fixture) so the harness and every E.10 smoke step share one stub.
//
// The stub implements every member of `TomBrainSubstrateClient` explicitly —
// no `noSuchMethod` escape hatch — so the compiler enforces the interface and
// any future drift fails the build instead of throwing at runtime inside a
// smoke run. The surfaces the smoke never exercises (web tools, outbound MCP)
// throw [UnsupportedError]: an honest, compile-checked "this stub does not
// provide that" rather than a silent net.

import 'dart:typed_data';

import 'package:tom_brain_shared/tom_brain_shared.dart' show Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

/// A stub [TomBrainSubstrateClient] that answers with a canned chunked stream.
///
/// [answerChunks] is the ordered list of text fragments the next
/// [completeStream] emits; their concatenation is the answer. A test sets it
/// before driving a run (E.47+); for a pure stand-up smoke (E.46) the default
/// is enough. [openCount] / [closeCount] record the lifecycle the boot drives.
final class SmokeSubstrate implements TomBrainSubstrateClient {
  /// The ordered answer fragments the next [completeStream] emits. Must be
  /// non-empty (the default `['ok']` satisfies this) — [completeStream] throws
  /// a [StateError] when it is empty, since an empty stream yields an empty
  /// answer.
  List<String> answerChunks = <String>['ok'];

  /// Number of times [open] has been called (boot opens at most once, and only
  /// when a `SubstrateConfig` is supplied).
  int openCount = 0;

  /// Number of times [close] has been called (shutdown closes exactly once).
  int closeCount = 0;

  /// The `prompt` input of the most recent completion call, or `null` if none
  /// has been issued. Set by [completeStream] (and so also by [complete], which
  /// drains it), letting a test assert the substrate was actually reached and
  /// inspect the assembled prompt it carried.
  Object? lastPrompt;

  @override
  Future<void> open(SubstrateConfig config) async {
    openCount++;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    lastPrompt = call.inputs['prompt'];
    // A run expects at least one answer chunk: the procedure concatenates the
    // emitted [LlmStreamChunk] texts into the answer, and an empty stream would
    // yield an empty answer (and starve a consumer waiting on a first chunk).
    // The default `['ok']` satisfies this; guard against a caller clearing it.
    if (answerChunks.isEmpty) {
      throw StateError(
        'SmokeSubstrate.answerChunks is empty — completeStream needs at least '
        'one chunk to form a non-empty answer.',
      );
    }
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      for (final String chunk in answerChunks)
        LlmStreamChunk(callId: 'smoke', text: chunk),
      const LlmStreamCompleted(
        callId: 'smoke',
        report: LlmCallReport(
          providerId: 'smoke',
          modelId: 'smoke',
          anchorHash: 'a',
          promptHash: 'p',
          tokensIn: 1,
          tokensOut: 1,
          retries: 0,
          wallClockMs: 1,
        ),
      ),
    ]);
  }

  @override
  Future<LlmCallReport> complete(LlmCall call) async {
    // The contract's "complete == drain completeStream" equivalence (spec
    // § 3.1): buffer the canned stream and surface its terminal report.
    await for (final LlmStreamEvent event in completeStream(call)) {
      if (event is LlmStreamCompleted) return event.report;
    }
    throw StateError('completeStream produced no LlmStreamCompleted event.');
  }

  @override
  Future<EmbeddingResult> embed(String text) async => EmbeddingResult(
        vec: Vec(Float32List.fromList(<double>[0.0])),
        modelIdentity: const EmbeddingModelIdentity(
          providerId: 'smoke',
          modelId: 'smoke',
          dims: 1,
          normalized: true,
        ),
      );

  @override
  Future<List<EmbeddingResult>> embedBatch(List<String> texts) async =>
      <EmbeddingResult>[for (final String text in texts) await embed(text)];

  // ── Surfaces the smoke never exercises ──
  //
  // Web tools and outbound MCP are out of scope for the end-to-end smoke. They
  // throw rather than return a fake result, so a run that reaches them fails
  // loudly (and the compiler still enforces their presence on the interface).

  @override
  Future<WebSearchResult> webSearch(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) =>
      throw UnsupportedError('SmokeSubstrate does not provide web search.');

  @override
  Future<WebFetchResult> webFetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) =>
      throw UnsupportedError('SmokeSubstrate does not provide web fetch.');

  @override
  McpClient mcpClient(McpEndpoint endpoint) =>
      throw UnsupportedError('SmokeSubstrate does not provide outbound MCP.');

  @override
  Stream<SubstrateEvent> events() => const Stream<SubstrateEvent>.empty();

  @override
  SubstrateStats stats() => SubstrateStats.empty(DateTime.now());
}
