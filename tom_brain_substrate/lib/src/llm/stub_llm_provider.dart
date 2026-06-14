// B.16 — `StubLlmProvider`.
//
// Third concrete [LlmProvider] implementation (after B.14 `OllamaLlmProvider`
// and B.15 `OpenAiPassthroughProvider`). Deterministic, in-process, NO
// network. Mandatory per `memory_specification.md` § 1 invariant 2
// ("no LLM on hot path") so the LLM-free conformance test on memory has
// a substrate-compliant fake provider it can route through; reused by
// every downstream module's test suite (router B.18+, embedding service
// B.25+, dispatcher Phase D, access Phase E, memory Phase A's classifier
// conformance run, procedure engine Phase E).
//
// Three response-generation modes, in this precedence:
//
//   1. **Scripted responses** — `script: <List<String>>` is drained in
//      order on each `complete` / `completeStream` call. Exhaustion
//      semantics:
//        * `loopScript: true` — drained responses are pushed back to
//          the tail of the queue and the script cycles indefinitely.
//        * `loopScript: false` (the default), `responder` non-null —
//          once the queue is drained, subsequent calls fall through
//          to the responder (effectively "script for the first N
//          calls, then responder for the rest"). This is the
//          composable shape tests use when they want to script the
//          opening exchanges and let the responder cover the long
//          tail.
//        * `loopScript: false`, `responder` null — exhaustion throws
//          [StateError] with a precise message naming the provider
//          [id]. This guards script-only tests against accidentally
//          falling through to the default echo when the test author
//          under-counted the calls.
//      The script can be extended at runtime via [enqueueScripted].
//   2. **Custom responder** — `responder: <StubResponder>` is consulted
//      when the script is empty (or was never supplied), and is the
//      fall-through target once a non-looping script drains (above).
//      It is a synchronous `String Function(WirePrompt, LlmOptions)`
//      so tests can derive the response from the prompt body / role /
//      options (e.g. echo with a transform, lookup in a
//      `Map<String, String>`, raise to simulate failure). Synchronous
//      on purpose: a `Future` return would invite tests to do real
//      I/O inside the stub, and this provider's contract is "no I/O".
//   3. **Default echo** — `'STUB:' + prompt.combined`. Used when neither
//      script nor responder is configured. Documented at
//      [StubLlmProvider.defaultEcho].
//
// Determinism guarantees (the whole point of the stub):
//
//   - `wallClockMs: 0` on every emitted [LlmCallReport]. No `Stopwatch`
//     is started. Tests pin the value to `0` exactly.
//   - `tokensIn = prompt.combined.length`, `tokensOut = response.length`
//     (character counts). Documented as a proxy tokeniser — the
//     conformance tests downstream do not depend on real token counts.
//   - `retries: 0`, `cost: null` on every report.
//   - `callId` is derived from a monotonic per-provider counter (started
//     at `0`, incremented before each call) plus the prompt body hash.
//     Format: `stub-<id>-<n>-<bodyHashHex>`. Two calls with the same
//     prompt body return distinct call ids (counter increments) but
//     the counter is fully predictable for any deterministic call
//     sequence — tests can therefore assert exact call ids.
//   - `chunkSplitter` default returns the response as a single chunk
//     (`StubLlmProvider.singleChunk`). Tests that need multi-chunk
//     streams pass `chunkSplitter: StubLlmProvider.splitByWord` (whitespace
//     split, empty chunks suppressed) or a custom callback.
//
// No tool-call simulation at B.16. The stub does not emit
// [LlmStreamToolCallProposed]; routing through it must therefore not
// configure a tool catalogue that the procedure dispatcher would expect
// the provider to honour. A `notes` entry surfaces when a non-empty
// catalogue is supplied (matching B.14 / B.15's `tool_catalogue_present:
// not_yet_dispatched` convention), so the trail records the misuse.
//
// No failure simulation built into the constructor surface. Tests that
// need failure paths inject them through the [responder] callback (which
// can `throw` or return a sentinel) or — for streaming-side failures —
// use the dedicated [StubLlmProvider.alwaysFails] factory which emits
// a terminal [LlmStreamFailed] in place of [LlmStreamCompleted]. The
// failure factory mirrors B.14 / B.15's "router classifies later"
// posture: the emitted failure has `classCode: 'unknown'` so the B.18
// router's `LlmFailureClassifier` is the single source of taxonomy
// truth.
//
// What this file deliberately does NOT do:
//
//   - No HTTP seam. The stub is the entire surface — there is no
//     wire-shape to abstract behind a `StubHttpClient` (there is no
//     wire). Tests reach into the stub directly.
//   - No async delays / scheduled futures. `Future.delayed` would
//     introduce wall-clock variance into the test suite; the stub is
//     fully synchronous internally (the async surface is required by
//     the [LlmProvider] interface; the bodies await nothing).
//   - No anchor wrapping. The stub honours `prompt.anchorHash` on its
//     output but does not validate it — that is the B.46 conformance
//     test's job at the substrate level.

import 'dart:async';

import 'package:tom_core_agentic/tom_core_agentic.dart' show promptSha256;

import '../api/llm_call.dart';
import '../api/llm_stream_event.dart';
import 'llm_provider.dart';
import 'wire_prompt.dart';

/// Caller-supplied response generator.
///
/// Synchronous on purpose. Returning a `Future` would invite real I/O
/// inside the stub, which would defeat the determinism guarantee.
/// Tests that want to simulate a failure can `throw` from the callback;
/// the thrown object surfaces as the cause on a [LlmStreamFailed] event
/// on the streaming path and as a re-thrown exception on the
/// non-streaming path.
typedef StubResponder = String Function(
  WirePrompt prompt,
  LlmOptions options,
);

/// Caller-supplied chunk splitter for the streaming path.
///
/// Default: [StubLlmProvider.singleChunk] (one chunk per response).
/// Other shipped helpers: [StubLlmProvider.splitByWord] (whitespace
/// split, empty chunks suppressed). Callers can pass a custom callback
/// to simulate any provider-side chunking shape they need.
///
/// Empty strings in the returned list are suppressed by the stream
/// emitter (no `LlmStreamChunk` with empty `text`), matching the
/// "empty deltas do not emit a chunk" convention from the B.14 / B.15
/// providers.
typedef StubChunkSplitter = List<String> Function(String response);

/// Deterministic, in-process [LlmProvider] for tests.
///
/// See the file-level header for the design rationale. Constructed
/// freely from tests and from the LLM-free conformance run on memory.
///
/// Three response sources, in precedence: (1) `script` queue,
/// (2) `responder` callback, (3) `defaultEcho`. See class documentation
/// for the full semantics.
///
/// Determinism: `wallClockMs: 0`; `tokensIn` / `tokensOut` are
/// character counts; `retries: 0`; `cost: null`; `callId` derived from
/// a monotonic counter + prompt body hash. The provider does no I/O.
final class StubLlmProvider implements LlmProvider {
  @override
  final String id;

  /// Model id stamped onto every [LlmCallReport.modelId] when
  /// `LlmOptions.model` is null.
  final String defaultModel;

  /// Whether to cycle the script queue when exhausted. When `true`,
  /// each call moves the head response to the tail; when `false`
  /// (the default), the call throws [StateError] once the queue
  /// is drained.
  final bool loopScript;

  /// Optional custom response generator. Consulted when the script
  /// queue is empty.
  final StubResponder? responder;

  /// Stream-side chunk splitter. Defaults to [singleChunk].
  final StubChunkSplitter chunkSplitter;

  /// Internal queue. Initialised from the constructor `script:` list.
  /// Mutable so [enqueueScripted] can extend it at runtime and so
  /// non-looping drain works without copying.
  final List<String> _script;

  /// `true` if the constructor was given a non-empty `script:`. Used
  /// to decide whether exhaustion should throw (script-mode caller)
  /// or fall through to the responder / echo path (no script ever
  /// provided).
  final bool _scriptWasProvided;

  /// Monotonic per-provider call counter. Incremented at the start of
  /// every `complete` / `completeStream`. Forms part of the `callId`.
  int _callCounter = 0;

  StubLlmProvider({
    this.id = 'stub',
    this.defaultModel = 'stub-model',
    List<String>? script,
    this.loopScript = false,
    this.responder,
    StubChunkSplitter? chunkSplitter,
  })  : _script = script != null ? List<String>.of(script) : <String>[],
        _scriptWasProvided = script != null && script.isNotEmpty,
        chunkSplitter = chunkSplitter ?? singleChunk;

  /// Convenience factory: a stub whose streaming path always emits a
  /// terminal [LlmStreamFailed] and whose non-streaming path always
  /// re-throws [failure]'s `cause` (or a [StateError] derived from
  /// `failure.message` when `cause` is `null`).
  ///
  /// Used by tests that exercise the router's failure / retry / rotate
  /// path against the [LlmProvider] contract.
  factory StubLlmProvider.alwaysFails({
    String id = 'stub:fail',
    String defaultModel = 'stub-model',
    LlmFailure failure = const LlmFailure(
      classCode: 'unknown',
      message: 'StubLlmProvider.alwaysFails',
    ),
  }) {
    return _AlwaysFailsStubProvider(
      id: id,
      defaultModel: defaultModel,
      failure: failure,
    );
  }

  /// Number of scripted responses still in the queue. Useful for tests
  /// that want to assert "exactly N calls drained the script".
  int get scriptRemaining => _script.length;

  /// Current value of the monotonic call counter. Increments by 1 for
  /// every `complete` / `completeStream` invocation. Tests asserting
  /// call counts can read this directly.
  int get callCount => _callCounter;

  /// Adds [response] to the end of the script queue. Combines with
  /// loopScript: if loopScript is `true` and the queue currently
  /// cycles, the appended response joins the cycle.
  void enqueueScripted(String response) {
    _script.add(response);
  }

  /// Default response generator: `'STUB:' + prompt.combined`.
  ///
  /// Used when the stub is constructed without `script:` and without
  /// `responder:`. The `STUB:` prefix makes deterministic
  /// tests trivially distinguishable from real provider output if a
  /// configuration mistake ever pointed a production path at the
  /// stub.
  static String defaultEcho(WirePrompt prompt, LlmOptions options) {
    return 'STUB:${prompt.combined}';
  }

  /// Default chunk splitter: returns `[response]` if non-empty,
  /// else `const <String>[]`.
  ///
  /// Matches the "non-streaming provider emits one Chunk per
  /// completeStream" shape from spec § 4.3.
  static List<String> singleChunk(String response) {
    return response.isEmpty ? const <String>[] : <String>[response];
  }

  /// Whitespace-split chunk splitter. Splits on `\s+`, drops empty
  /// segments. Each non-empty segment becomes one `LlmStreamChunk`.
  ///
  /// Useful for tests that want to exercise multi-chunk reassembly
  /// downstream of the stream.
  static List<String> splitByWord(String response) {
    if (response.isEmpty) return const <String>[];
    return response
        .split(RegExp(r'\s+'))
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<LlmCallReport> complete(
    WirePrompt prompt,
    LlmOptions options,
  ) async {
    _callCounter++;
    final modelId = options.model ?? defaultModel;
    final response = _resolveResponse(prompt, options);
    return LlmCallReport(
      providerId: id,
      modelId: modelId,
      anchorHash: prompt.anchorHash,
      promptHash: promptSha256(prompt.combined),
      tokensIn: prompt.combined.length,
      tokensOut: response.length,
      retries: 0,
      wallClockMs: 0,
      templateSha: prompt.templateSha,
      notes: _notes(options),
    );
  }

  @override
  Stream<LlmStreamEvent> completeStream(
    WirePrompt prompt,
    LlmOptions options,
  ) async* {
    _callCounter++;
    final modelId = options.model ?? defaultModel;
    final callId = _callIdFor(prompt);

    yield LlmStreamStarted(
      callId: callId,
      providerId: id,
      modelId: modelId,
    );

    final String response;
    try {
      response = _resolveResponse(prompt, options);
    } catch (e) {
      yield LlmStreamFailed(
        callId: callId,
        failure: LlmFailure(
          // Unclassified at B.16; B.18 maps onto the spec § 5.4 taxonomy.
          classCode: 'unknown',
          message: e.toString(),
          cause: e,
        ),
        report: LlmCallReport(
          providerId: id,
          modelId: modelId,
          anchorHash: prompt.anchorHash,
          promptHash: promptSha256(prompt.combined),
          tokensIn: prompt.combined.length,
          tokensOut: 0,
          retries: 0,
          wallClockMs: 0,
          templateSha: prompt.templateSha,
          notes: _notes(options),
        ),
      );
      return;
    }

    final chunks = chunkSplitter(response);
    for (final chunk in chunks) {
      if (chunk.isEmpty) continue;
      yield LlmStreamChunk(callId: callId, text: chunk);
    }

    yield LlmStreamCompleted(
      callId: callId,
      report: LlmCallReport(
        providerId: id,
        modelId: modelId,
        anchorHash: prompt.anchorHash,
        promptHash: promptSha256(prompt.combined),
        tokensIn: prompt.combined.length,
        tokensOut: response.length,
        retries: 0,
        wallClockMs: 0,
        templateSha: prompt.templateSha,
        notes: _notes(options),
      ),
    );
  }

  // ─── Internals ──────────────────────────────────────────────────

  String _resolveResponse(WirePrompt prompt, LlmOptions options) {
    if (_script.isNotEmpty) {
      final next = _script.removeAt(0);
      if (loopScript) _script.add(next);
      return next;
    }
    if (_scriptWasProvided && !loopScript && responder == null) {
      throw StateError(
        'StubLlmProvider($id): scripted responses exhausted and no '
        'responder was configured. Pass loopScript: true to cycle, '
        'call enqueueScripted() to extend, pass a `responder:` callback '
        'to take over after exhaustion, or omit `script:` entirely.',
      );
    }
    final r = responder ?? defaultEcho;
    return r(prompt, options);
  }

  String _callIdFor(WirePrompt prompt) {
    final bodyTag = prompt.combined.hashCode.toUnsigned(32).toRadixString(16);
    return 'stub-$id-$_callCounter-$bodyTag';
  }

  List<String> _notes(LlmOptions options) {
    final notes = <String>['stub:deterministic'];
    if (options.toolCatalogue.isNotEmpty) {
      notes.add('tool_catalogue_present:not_yet_dispatched');
    }
    return notes;
  }
}

/// Internal variant returned by [StubLlmProvider.alwaysFails]. Always
/// emits a terminal [LlmStreamFailed] on `completeStream` and re-throws
/// from `complete`.
///
/// Implemented as a separate type rather than a flag on
/// [StubLlmProvider] so the failure path is opt-in by construction
/// and the happy path stays free of "is this a failing stub?" branches.
final class _AlwaysFailsStubProvider extends StubLlmProvider {
  final LlmFailure failure;

  _AlwaysFailsStubProvider({
    required super.id,
    required super.defaultModel,
    required this.failure,
  });

  @override
  Future<LlmCallReport> complete(
    WirePrompt prompt,
    LlmOptions options,
  ) {
    final cause = failure.cause;
    if (cause is Object) {
      return Future<LlmCallReport>.error(cause);
    }
    return Future<LlmCallReport>.error(StateError(failure.message));
  }

  @override
  Stream<LlmStreamEvent> completeStream(
    WirePrompt prompt,
    LlmOptions options,
  ) async* {
    _callCounter++;
    final modelId = options.model ?? defaultModel;
    final callId = _callIdFor(prompt);

    yield LlmStreamStarted(
      callId: callId,
      providerId: id,
      modelId: modelId,
    );

    yield LlmStreamFailed(
      callId: callId,
      failure: failure,
      report: LlmCallReport(
        providerId: id,
        modelId: modelId,
        anchorHash: prompt.anchorHash,
        promptHash: promptSha256(prompt.combined),
        tokensIn: prompt.combined.length,
        tokensOut: 0,
        retries: 0,
        wallClockMs: 0,
        templateSha: prompt.templateSha,
        notes: _notes(options),
      ),
    );
  }
}
