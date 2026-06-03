// SubstrateBridge — the d4rt-bridged re-export of the brain's substrate
// primitive set (Plan step C.13;
// `tom_brain_procedure_prototype_specification.md` § 5.1).
//
// This is a **plain Dart class** (no annotation — `@D4rtBridged` does
// not exist in the d4rt ecosystem; see Q-C.3.1 / C.3 / C.11 in
// `prototype_implementation_details.md`). `tom_d4rt_generator` selects
// it for bridging because `build.yaml` (C.11) lists this file under the
// `all` module's `barrelFiles`. The generated bridge registers through
// `BrainBridges.register(d4rt)` (C.14 / C.16). The generator-output
// round-trip smoke lands at C.15; this step (C.13) authors only the
// source class and its native unit tests.
//
// ── Why primitive-typed signatures (Q-C.3.3 / Q-C.12.1) ─────────────
//
// Every method accepts and returns d4rt-native primitives — `String`,
// `num`/`int`/`double`, `bool`, `List`, `Map<String, Object?>`. The
// bridge translates those primitives into the substrate domain types
// (`LlmCall`, `Budget`, `WebSearchOptions`, `WebFetchOptions`, …) on
// the way in and back into plain maps/lists on the way out. Keeping the
// bridged surface primitive means the generator never has to bridge the
// entire `tom_brain_substrate` domain-type graph. The typed result
// wrappers the spec mentions in § 5.3 (`LlmResult`, `SearchResult`,
// `FetchResult`, …) are layered in `lib/api/` later (C.38–C.41) and
// wrap these primitive returns; they are deliberately *not* the bridged
// shape.
//
// ── Anchor invariant (PE-7) ─────────────────────────────────────────
//
// Every prompt the machinery issues carries the assistant-dedication
// anchor because `llm(...)` is the *only* completion path and it always
// routes through the substrate client. The bridge has no raw-completion
// escape hatch: it cannot supply a pre-assembled wire prompt — it can
// only name a `role` and supply `inputs`, and the substrate prepends
// the anchor at assembly time (substrate invariant 1, B.46). The bridge
// therefore preserves PE-7 structurally, without re-checking it.
//
// ── Why `llm` drains `completeStream` (Q-C.13.1) ────────────────────
//
// `TomBrainSubstrateClient.complete` returns an `LlmCallReport` only —
// the report carries provenance/metrics but **not the generated text**
// (the text lives on the stream's `LlmStreamChunk` events). The
// prototype's `answer_with_memory_v1` needs the answer text (§ 5.1
// step "answer"), so `llm` drains `completeStream`, concatenates the
// chunk text, and returns `{ 'text': …, 'report': … }`. A
// `LlmStreamFailed` terminal event is surfaced as a thrown
// [LlmCompletionFailure] carrying the typed failure class.
//
// ── Interface boundary (PE-10) ──────────────────────────────────────
//
// The bridge wraps a `TomBrainSubstrateClient` — the consumer-facing
// contract (B.40) — never the concrete `InProcessTomBrainSubstrate` and
// never `tom_brain_substrate/lib/src/` internals. The host injects
// whichever implementation the deployment topology chose; the bridge
// cannot tell the difference.

import 'package:tom_brain_shared/tom_brain_shared.dart' show Budget;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'bridge_call_recorder.dart';

/// Re-exposes the substrate primitive set to d4rt procedure scripts.
///
/// Mirrors the substrate rows of
/// `tom_brain_procedure_prototype_specification.md` § 5.1:
/// `llm(prompt, {role, budget})`, `embed(text)`,
/// `search(query, {provider, k})`, `fetch(url, {budget})`. Each method
/// delegates to the wrapped [TomBrainSubstrateClient] and converts
/// between d4rt primitives and the substrate domain types.
class SubstrateBridge {
  /// The interface-boundary substrate client every method delegates to
  /// (PE-10). Injected by the host (C.16).
  final TomBrainSubstrateClient client;

  /// Per-run recording hook (E.3.2). `null` on the shared template bridge
  /// the engine is constructed with; the engine binds a per-run instance to
  /// the active recorder so every effect call lands on that run's trail and
  /// folds into its effort tally. Not part of the d4rt-facing constructor
  /// surface — a procedure script only ever sees the injected instance.
  final BridgeCallRecorder? _onCall;

  /// Wraps [client]. The host constructs this natively and registers the
  /// instance with the d4rt runtime. [onCall], when supplied, records each
  /// completed primitive call against the issuing run (E.3.2).
  SubstrateBridge(this.client, {BridgeCallRecorder? onCall}) : _onCall = onCall;

  /// Delegates to [body], and — when [_onCall] is wired — records the call
  /// (name [primitive], argument map [input], the flattened [resultOf] of
  /// the value, and the measured wall-clock cost) before returning the
  /// value unchanged. With no hook wired the call is a straight delegate.
  /// A throwing [body] (e.g. [LlmCompletionFailure]) propagates without a
  /// recording — the engine records the crash on its own path.
  Future<T> _record<T>(
    String primitive,
    Map<String, Object?> input,
    Future<T> Function() body, {
    required Map<String, Object?> Function(T value) resultOf,
  }) async {
    final onCall = _onCall;
    if (onCall == null) return body();
    final watch = Stopwatch()..start();
    final value = await body();
    watch.stop();
    await onCall(
      primitive,
      input,
      resultOf(value),
      elapsedMs: watch.elapsedMilliseconds,
    );
    return value;
  }

  /// The role the prototype's user-facing answer step uses (§ 5.1
  /// step "answer"). The default for [llm] when the caller does not
  /// name a role.
  static const String defaultRole = 'assistant_to_user';

  /// The budget [llm] grants a call when the caller passes no `budget`
  /// map. Matches the procedure-header example in
  /// `tom_brain_procedure_prototype_specification.md` § 4 — generous
  /// enough that the single-shot prototype never trips it. The engine's
  /// procedure-level budget plumbing (C.19+) supersedes this; until
  /// then the bridge needs a concrete envelope to build an [LlmCall].
  /// (Q-C.13.2.)
  static Budget get defaultBudget => Budget(
        wallClockMs: 120000,
        tokenSpend: 40000,
        toolCalls: 30,
        memoryWrites: 6,
      );

  // ── llm ───────────────────────────────────────────────────────────

  /// Runs an LLM completion through the substrate and returns the
  /// generated text plus the call report.
  ///
  /// [prompt] is supplied to the role template as the `prompt` input
  /// (Q-C.13.3); the bridge never supplies a raw wire prompt, so the
  /// substrate's anchor injection (PE-7) cannot be bypassed. [role]
  /// names the role-registry key and defaults to [defaultRole]. [budget]
  /// is an optional primitive map (`wallClockMs`, `tokenSpend`,
  /// `toolCalls`, `memoryWrites`); when omitted, [defaultBudget]
  /// applies.
  ///
  /// Returns `{'text': <concatenated answer>, 'report': {...}}` where
  /// the report mirrors [LlmCallReport]. Throws [LlmCompletionFailure]
  /// when the stream terminates with [LlmStreamFailed].
  Future<Map<String, Object?>> llm(
    String prompt, {
    String role = defaultRole,
    Map<String, Object?>? budget,
  }) =>
      _record<Map<String, Object?>>(
        'llm',
        <String, Object?>{'prompt': prompt, 'role': role},
        () async {
          final call = LlmCall(
            roleId: role,
            inputs: <String, Object?>{'prompt': prompt},
            budget: _buildBudget(budget),
          );

          final buffer = StringBuffer();

          await for (final event in client.completeStream(call)) {
            switch (event) {
              case LlmStreamChunk(:final text):
                buffer.write(text);
              case LlmStreamCompleted(:final report):
                return <String, Object?>{
                  'text': buffer.toString(),
                  'report': _reportToMap(report),
                };
              case LlmStreamFailed(:final failure, report: final failReport):
                throw LlmCompletionFailure(
                  classCode: failure.classCode,
                  message: failure.message,
                  report: _reportToMap(failReport),
                );
              case LlmStreamStarted():
              case LlmStreamToolCallProposed():
                // Started carries no text; tool-call resolution is the
                // dispatcher's job (Phase D) and is not exercised by
                // `answer_with_memory_v1`. Both are ignored here.
                break;
            }
          }

          // A well-behaved substrate always terminates with Completed or
          // Failed. Reaching here means the stream closed without a terminal
          // event — a substrate contract violation, surfaced loudly.
          throw StateError(
            'completeStream closed without a terminal '
            'LlmStreamCompleted/LlmStreamFailed event.',
          );
        },
        resultOf: (value) => value,
      );

  // ── embed ─────────────────────────────────────────────────────────

  /// Embeds [text] and returns the vector plus the producing model's
  /// identity.
  ///
  /// Returns `{'vec': [<double>…], 'modelIdentity': {...}}`. The
  /// identity is memory's cosine-comparability commitment (§ 7.4); it
  /// rides into the persisted node so cross-model vectors are never
  /// mixed.
  Future<Map<String, Object?>> embed(String text) =>
      _record<Map<String, Object?>>(
        'embed',
        <String, Object?>{'text': text},
        () async {
          final result = await client.embed(text);
          return _embeddingToMap(result);
        },
        resultOf: (value) => value,
      );

  // ── search ────────────────────────────────────────────────────────

  /// Issues a web search and returns the hits.
  ///
  /// [provider] pins the search engine (`null` ⇒ substrate default);
  /// [k] caps the hit count (default 10, matching
  /// [WebSearchOptions.empty]). Returns
  /// `{'provider': …, 'query': …, 'hits': [{title, url, snippet, rank}]}`.
  Future<Map<String, Object?>> search(
    String query, {
    String? provider,
    int k = 10,
  }) =>
      _record<Map<String, Object?>>(
        'search',
        <String, Object?>{'query': query, 'provider': provider, 'k': k},
        () async {
          final result = await client.webSearch(
            query,
            options: WebSearchOptions(provider: provider, k: k),
          );
          return _searchToMap(result);
        },
        resultOf: (value) => value,
      );

  // ── fetch ─────────────────────────────────────────────────────────

  /// Fetches [url] with the configured budget + headers + UA.
  ///
  /// [budgetBytes] caps the read; a larger response returns with
  /// `truncated: true` rather than failing (§ 12). Returns
  /// `{'url', 'status', 'contentType', 'text'?, 'json'?, 'binaryMeta'?,
  /// 'truncated'}` — exactly one of `text` / `json` / `binaryMeta` is
  /// non-null per the resolved content type.
  Future<Map<String, Object?>> fetch(
    String url, {
    int? budgetBytes,
  }) =>
      _record<Map<String, Object?>>(
        'fetch',
        <String, Object?>{'url': url, 'budgetBytes': budgetBytes},
        () async {
          final result = await client.webFetch(
            Uri.parse(url),
            options: WebFetchOptions(budgetBytes: budgetBytes),
          );
          return _fetchToMap(result);
        },
        resultOf: (value) => value,
      );

  // ── primitive ⇄ domain conversions ────────────────────────────────

  static Budget _buildBudget(Map<String, Object?>? raw) {
    if (raw == null) return defaultBudget;
    final fallback = defaultBudget;
    return Budget(
      wallClockMs:
          (raw['wallClockMs'] as num?)?.toInt() ?? fallback.wallClockMs,
      tokenSpend: (raw['tokenSpend'] as num?)?.toInt() ?? fallback.tokenSpend,
      toolCalls: (raw['toolCalls'] as num?)?.toInt() ?? fallback.toolCalls,
      memoryWrites:
          (raw['memoryWrites'] as num?)?.toInt() ?? fallback.memoryWrites,
    );
  }

  static Map<String, Object?> _reportToMap(LlmCallReport report) =>
      <String, Object?>{
        'providerId': report.providerId,
        'modelId': report.modelId,
        'anchorHash': report.anchorHash,
        'promptHash': report.promptHash,
        'tokensIn': report.tokensIn,
        'tokensOut': report.tokensOut,
        'retries': report.retries,
        'wallClockMs': report.wallClockMs,
        if (report.cost != null) 'cost': report.cost,
        if (report.templateSha != null) 'templateSha': report.templateSha,
        'notes': List<String>.of(report.notes),
      };

  static Map<String, Object?> _embeddingToMap(EmbeddingResult result) =>
      <String, Object?>{
        'vec': result.vec.values.toList(),
        'modelIdentity': <String, Object?>{
          'providerId': result.modelIdentity.providerId,
          'modelId': result.modelIdentity.modelId,
          'dims': result.modelIdentity.dims,
          'normalized': result.modelIdentity.normalized,
        },
      };

  static Map<String, Object?> _searchToMap(WebSearchResult result) =>
      <String, Object?>{
        'provider': result.provider,
        'query': result.query,
        'hits': result.hits.map(_hitToMap).toList(),
      };

  static Map<String, Object?> _hitToMap(SearchHit hit) => <String, Object?>{
        'title': hit.title,
        'url': hit.url.toString(),
        'snippet': hit.snippet,
        'rank': hit.rank,
      };

  static Map<String, Object?> _fetchToMap(WebFetchResult result) =>
      <String, Object?>{
        'url': result.url.toString(),
        'status': result.status,
        'contentType': result.contentType,
        'truncated': result.truncated,
        if (result.text != null) 'text': result.text,
        if (result.json != null) 'json': result.json,
        if (result.binaryMeta != null)
          'binaryMeta': <String, Object?>{
            'contentType': result.binaryMeta!.contentType,
            if (result.binaryMeta!.contentLength != null)
              'contentLength': result.binaryMeta!.contentLength,
          },
      };
}

/// Thrown by [SubstrateBridge.llm] when the substrate stream terminates
/// with [LlmStreamFailed].
///
/// Carries the substrate failure taxonomy's [classCode] (kebab-case;
/// `rate_limit`, `timeout`, `auth`, `context_overflow`, …) so the
/// engine's fallback executor (C.46) can branch by class, plus the
/// best-effort [report] reflecting what was known at the point of
/// failure.
class LlmCompletionFailure implements Exception {
  /// Stable kebab-case discriminator from `substrate_specification.md`
  /// § 5.4.
  final String classCode;

  /// Human-readable diagnostic. For logging / trail entries, not
  /// end-user display.
  final String message;

  /// Flattened best-effort [LlmCallReport] at the point of failure.
  final Map<String, Object?> report;

  LlmCompletionFailure({
    required this.classCode,
    required this.message,
    required this.report,
  });

  @override
  String toString() =>
      'LlmCompletionFailure(classCode: $classCode, message: $message)';
}
