// EffortMetrics — the closed effort-metric set a `ProcedureRun` carries
// (`tom_brain_procedure_prototype_specification.md` § 8;
// `tom_brain_definition.md` § 7.4).
//
// ── What C.31 owns vs. C.32 defers ──────────────────────────────────
//
// C.31 (the run recorder) owns the *shape* of the effort record and
// persists it onto the `ProcedureRun` node at completion. C.32 owns the
// *accumulation* — incrementing the counters as each bridged primitive
// runs (an `llm` call bumps `llmCalls` + `inputTokens` + `outputTokens`,
// a `recall` bumps `memoryReads`, a `persist`/`edge` bumps
// `memoryWrites`, etc.). C.31 therefore defines this value as an
// immutable, zero-defaulted bundle the recorder records verbatim, and
// gives it the combinators (`plus`, `withWallClockMs`) C.32 needs to
// build a final total from per-call deltas without re-deriving the
// shape. Keeping the type here (not in C.32) means the recorder's
// `complete` signature is stable from the moment the recorder exists.

import 'dart:collection';

/// The seven-field effort record stamped onto every `ProcedureRun`.
///
/// All fields default to zero so a run that did nothing measurable still
/// produces a well-formed record. Immutable: combine with [plus] or the
/// `with*` copies rather than mutating.
///
/// The primary estimation metric is [estimatedTokens]
/// (`inputTokens + outputTokens`), per spec § 8.
final class EffortMetrics {
  /// Wall-clock duration of the run, in milliseconds.
  final int wallClockMs;

  /// Number of substrate `llm(...)` calls the run made.
  final int llmCalls;

  /// Prompt tokens sent to the substrate across all `llm` calls.
  final int inputTokens;

  /// Completion tokens received from the substrate.
  final int outputTokens;

  /// Bridged tool calls other than `llm` (e.g. `search`, `fetch`).
  final int toolCalls;

  /// Memory reads (`recall`, `stack.peek`, `stack.list`).
  final int memoryReads;

  /// Memory writes (`persist`, `edge`, `stack.push`/`update`/`remove`).
  final int memoryWrites;

  /// Builds a metric bundle. Every field defaults to zero.
  const EffortMetrics({
    this.wallClockMs = 0,
    this.llmCalls = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.toolCalls = 0,
    this.memoryReads = 0,
    this.memoryWrites = 0,
  })  : assert(wallClockMs >= 0, 'wallClockMs must be >= 0'),
        assert(llmCalls >= 0, 'llmCalls must be >= 0'),
        assert(inputTokens >= 0, 'inputTokens must be >= 0'),
        assert(outputTokens >= 0, 'outputTokens must be >= 0'),
        assert(toolCalls >= 0, 'toolCalls must be >= 0'),
        assert(memoryReads >= 0, 'memoryReads must be >= 0'),
        assert(memoryWrites >= 0, 'memoryWrites must be >= 0');

  /// The all-zero record — the starting point C.32 accumulates onto.
  static const EffortMetrics zero = EffortMetrics();

  /// The primary estimation metric: `inputTokens + outputTokens`
  /// (spec § 8).
  int get estimatedTokens => inputTokens + outputTokens;

  /// Field-wise sum of `this` and [other]. The combinator C.32 uses to
  /// fold per-primitive deltas into the run total.
  EffortMetrics plus(EffortMetrics other) => EffortMetrics(
        wallClockMs: wallClockMs + other.wallClockMs,
        llmCalls: llmCalls + other.llmCalls,
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
        toolCalls: toolCalls + other.toolCalls,
        memoryReads: memoryReads + other.memoryReads,
        memoryWrites: memoryWrites + other.memoryWrites,
      );

  /// A copy with [wallClockMs] replaced — the recorder stamps the
  /// run's measured elapsed time at completion without disturbing the
  /// counters C.32 accumulated.
  EffortMetrics withWallClockMs(int value) => EffortMetrics(
        wallClockMs: value,
        llmCalls: llmCalls,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        toolCalls: toolCalls,
        memoryReads: memoryReads,
        memoryWrites: memoryWrites,
      );

  /// The metric set as a JSON-encodable map, ready to be stored in a
  /// `ProcedureRun` node's `values` and in trail-outcome details.
  /// [estimatedTokens] is included so a reader does not have to re-derive
  /// the primary metric.
  Map<String, Object?> toJson() => UnmodifiableMapView<String, Object?>(
        <String, Object?>{
          'wallClockMs': wallClockMs,
          'llmCalls': llmCalls,
          'inputTokens': inputTokens,
          'outputTokens': outputTokens,
          'toolCalls': toolCalls,
          'memoryReads': memoryReads,
          'memoryWrites': memoryWrites,
          'estimatedTokens': estimatedTokens,
        },
      );

  @override
  bool operator ==(Object other) =>
      other is EffortMetrics &&
      other.wallClockMs == wallClockMs &&
      other.llmCalls == llmCalls &&
      other.inputTokens == inputTokens &&
      other.outputTokens == outputTokens &&
      other.toolCalls == toolCalls &&
      other.memoryReads == memoryReads &&
      other.memoryWrites == memoryWrites;

  @override
  int get hashCode => Object.hash(
        wallClockMs,
        llmCalls,
        inputTokens,
        outputTokens,
        toolCalls,
        memoryReads,
        memoryWrites,
      );

  @override
  String toString() => 'EffortMetrics(wallClockMs: $wallClockMs, '
      'llmCalls: $llmCalls, inputTokens: $inputTokens, '
      'outputTokens: $outputTokens, toolCalls: $toolCalls, '
      'memoryReads: $memoryReads, memoryWrites: $memoryWrites)';
}
