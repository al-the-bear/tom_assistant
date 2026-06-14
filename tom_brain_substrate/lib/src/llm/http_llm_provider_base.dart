// B.2.2 — `HttpLlmProviderBase`.
//
// The two HTTP-backed providers — `OllamaLlmProvider` (B.14) and
// `OpenAiPassthroughProvider` (B.15) — are structural twins. Before
// this extraction each owned its own verbatim copy of:
//
//   * the `LlmCallReport` construction block (provenance + anchor
//     stamp + `promptSha256` body hash + `retries: 0` + template sha),
//     repeated five times across the two files;
//   * the per-call id formula (`<prefix>-<id>-<micros>-<bodyhash>`);
//   * the owns-the-client / `close()` lifecycle pair.
//
// This base owns those invariant pieces; each subclass keeps only its
// wire-shape translation (option mapping, the typed HTTP client, the
// per-frame accumulation, and the backend-specific terminal semantics
// — Ollama's `done: true` frame versus OpenAI's SSE `[DONE]` end).
//
// What this base deliberately does NOT own:
//
//   * The streaming control flow. The two backends terminate
//     differently (Ollama carries a terminal `done` frame mid-stream
//     and treats a missing one as a `format` failure; OpenAI completes
//     when the SSE stream ends), accumulate different counter fields,
//     and compute different terminal-report notes. Forcing both into
//     one template would need a normalised-fragment seam whose
//     complexity exceeds the duplication it removes — so the loop
//     stays per-subclass, calling [buildReport] for the report.
//   * The typed HTTP client. `OllamaHttpClient` and `OpenAiHttpClient`
//     have disjoint surfaces; the base holds only the ownership flag
//     and delegates teardown to [disposeHttpClient].
//   * Failure classification. Per `LlmProvider` (B.11) providers do
//     not classify; the router (B.18+) maps raw exceptions onto the
//     spec § 5.4 taxonomy.

import '../api/llm_call.dart' show LlmCallReport;
import 'llm_provider.dart';
import 'wire_prompt.dart';

import 'package:tom_core_agentic/tom_core_agentic.dart' show promptSha256;

/// Shared base for the HTTP-backed [LlmProvider]s (Ollama, OpenAI
/// passthrough).
///
/// Subclasses `extend` this base and supply [callIdPrefix],
/// [disposeHttpClient], and the two interface methods ([complete] /
/// [completeStream]); the report-construction, body-hashing, call-id,
/// and `close()` plumbing live here.
///
/// `base` (not `interface` / `sealed`): subclasses must be able to
/// `extend` it (cross-file within the package) but nothing should
/// `implement` it and re-supply the invariant plumbing by hand — that
/// is exactly the duplication this class removes.
abstract base class HttpLlmProviderBase implements LlmProvider {
  @override
  final String id;

  /// Base URL the backend listens on. Subclasses compose endpoint
  /// paths off it.
  final Uri baseUri;

  /// Model id used when `LlmOptions.model` is null (spec § 9 sources
  /// it from `providers[*].defaults.model`).
  final String defaultModel;

  /// Per-call wall-clock cap on the non-streaming path. `null` ⇒ no
  /// cap.
  final Duration? requestTimeout;

  /// Whether this provider owns its HTTP client (and should dispose it
  /// on [close]) or whether the caller manages its lifetime. Set by
  /// each subclass from `httpClient == null` at construction.
  final bool ownsHttpClient;

  HttpLlmProviderBase({
    required this.id,
    required this.baseUri,
    required this.defaultModel,
    required this.requestTimeout,
    required this.ownsHttpClient,
  });

  /// Stable prefix for [newCallId] — `ollama` / `openai`.
  String get callIdPrefix;

  /// Builds an [LlmCallReport] with the provider-invariant fields
  /// already filled: provenance (`providerId` = [id]), the anchor
  /// stamp (`anchorHash` = the prompt's), the body hash
  /// (`promptHash` = `promptSha256(prompt.combined)`), `retries: 0`, and
  /// the prompt's `templateSha`. Callers supply only the per-call
  /// counters and notes.
  ///
  /// `cost` is left null — both HTTP providers report it at the router
  /// layer (B.32+), not here.
  LlmCallReport buildReport({
    required WirePrompt prompt,
    required String modelId,
    required int tokensIn,
    required int tokensOut,
    required int wallClockMs,
    List<String> notes = const <String>[],
  }) {
    return LlmCallReport(
      providerId: id,
      modelId: modelId,
      anchorHash: prompt.anchorHash,
      promptHash: promptSha256(prompt.combined),
      tokensIn: tokensIn,
      tokensOut: tokensOut,
      retries: 0,
      wallClockMs: wallClockMs,
      templateSha: prompt.templateSha,
      notes: notes,
    );
  }

  /// A per-call id unique enough for trail correlation:
  /// `<callIdPrefix>-<id>-<micros>-<32-bit body hash>`.
  String newCallId(WirePrompt prompt) {
    final now = DateTime.now().microsecondsSinceEpoch;
    return '$callIdPrefix-$id-$now-${prompt.combined.hashCode.toUnsigned(32)}';
  }

  /// Releases owned HTTP resources. No-op if the HTTP client was
  /// injected by the caller.
  void close() {
    if (ownsHttpClient) disposeHttpClient();
  }

  /// Disposes the subclass's typed HTTP client. Invoked by [close]
  /// only when [ownsHttpClient] is true.
  void disposeHttpClient();
}
