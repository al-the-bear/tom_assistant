// EffortMetrics — the closed effort-metric set a `ProcedureRun` carries
// and the dispatcher's harvester later reads
// (`tom_brain_procedure_prototype_specification.md` § 8;
// `tom_brain_definition.md` § 7.4).
//
// ── Origin: the C.48 reuse-extraction pass ──────────────────────────
//
// First cut in `tom_brain_procedure_prototype` (Plan step C.31), where
// the run recorder owns the *shape* and C.32's accountant owns the
// *accumulation*. Moved here at the Phase C review (C.48): the recorder
// produces this shape, and the Phase D dispatcher's harvester reads the
// same shape off the `recent_runs` stack — two distinct components share
// the metric vocabulary. It is a pure value type (no I/O), so it fits the
// A.9 dependency-discipline contract for `tom_brain_shared`.

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

  /// Const, unvalidated raw constructor. Private — the only const path, used
  /// by [zero] (the all-zero sentinel is trivially valid). All public
  /// construction goes through the validating factory below.
  const EffortMetrics._({
    this.wallClockMs = 0,
    this.llmCalls = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.toolCalls = 0,
    this.memoryReads = 0,
    this.memoryWrites = 0,
  });

  /// Builds a metric bundle. Every field defaults to zero.
  ///
  /// All fields must be non-negative. The check throws (rather than
  /// `assert`s) so a negative counter — always a programming error in the
  /// accountant — fails in release builds too: this record rides on every
  /// `ProcedureRun`, so a corrupt one must not propagate silently. Because a
  /// validating factory cannot be `const`, the all-zero [zero] sentinel is
  /// built via the const private constructor and remains usable in const
  /// contexts (e.g. default parameter values).
  factory EffortMetrics({
    int wallClockMs = 0,
    int llmCalls = 0,
    int inputTokens = 0,
    int outputTokens = 0,
    int toolCalls = 0,
    int memoryReads = 0,
    int memoryWrites = 0,
  }) {
    _requireNonNegative(wallClockMs, 'wallClockMs');
    _requireNonNegative(llmCalls, 'llmCalls');
    _requireNonNegative(inputTokens, 'inputTokens');
    _requireNonNegative(outputTokens, 'outputTokens');
    _requireNonNegative(toolCalls, 'toolCalls');
    _requireNonNegative(memoryReads, 'memoryReads');
    _requireNonNegative(memoryWrites, 'memoryWrites');
    return EffortMetrics._(
      wallClockMs: wallClockMs,
      llmCalls: llmCalls,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      toolCalls: toolCalls,
      memoryReads: memoryReads,
      memoryWrites: memoryWrites,
    );
  }

  static void _requireNonNegative(int value, String name) {
    if (value < 0) {
      throw ArgumentError.value(value, name, 'must be >= 0');
    }
  }

  /// The all-zero record — the starting point C.32 accumulates onto. Const so
  /// it stays usable as a default parameter value.
  static const EffortMetrics zero = EffortMetrics._();

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
