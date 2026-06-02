// E.58 — process-level latency bench (inbound-prompt → first-SSE-chunk).
//
// Plan step E.58 (verbatim): "Process-level bench: measure inbound-prompt →
// first-SSE-chunk latency p50/p95 with the stub substrate (isolate-hosted
// memory). Target: p95 ≤ 250 ms."
//
// Two layers, matching how the bench is built:
//
//   1. PURE LOGIC — the percentile maths ([percentileDuration]), the
//      [LatencySummary] aggregation, and the [renderLatencyReport] Markdown
//      rendering are deterministic and are asserted in isolation, with no
//      process, no socket, no timing dependence. This is where the bench's
//      correctness lives.
//   2. END-TO-END — the bench is run for real against a stood-up smoke process
//      (stub substrate + isolate-hosted memory), and the measured p95 is
//      asserted against the plan's 250 ms target. With the stub substrate the
//      framework overhead dominates and the target is met with wide margin.

import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart';
import 'package:test/test.dart';

void main() {
  group('E.58 percentileDuration (pure nearest-rank)', () {
    // Ten samples, 10 ms … 100 ms, already ascending.
    final List<Duration> tenAscending = <Duration>[
      for (int ms = 10; ms <= 100; ms += 10) Duration(milliseconds: ms),
    ];

    test('p50 of 10 ascending samples is the 5th (nearest-rank)', () {
      // rank = ceil(0.50 · 10) = 5 ⇒ index 4 ⇒ 50 ms.
      expect(percentileDuration(tenAscending, 0.50),
          const Duration(milliseconds: 50));
    });

    test('p95 of 10 ascending samples is the 10th (nearest-rank)', () {
      // rank = ceil(0.95 · 10) = 10 ⇒ index 9 ⇒ 100 ms.
      expect(percentileDuration(tenAscending, 0.95),
          const Duration(milliseconds: 100));
    });

    test('p0 clamps to the smallest, p100 to the largest', () {
      expect(percentileDuration(tenAscending, 0.0),
          const Duration(milliseconds: 10));
      expect(percentileDuration(tenAscending, 1.0),
          const Duration(milliseconds: 100));
    });

    test('a single-sample list returns that sample for any quantile', () {
      final List<Duration> one = <Duration>[const Duration(milliseconds: 7)];
      expect(percentileDuration(one, 0.0), const Duration(milliseconds: 7));
      expect(percentileDuration(one, 0.5), const Duration(milliseconds: 7));
      expect(percentileDuration(one, 0.95), const Duration(milliseconds: 7));
    });

    test('an empty list is a programming error', () {
      expect(() => percentileDuration(<Duration>[], 0.5),
          throwsA(isA<ArgumentError>()));
    });

    test('a quantile outside [0, 1] is rejected', () {
      expect(() => percentileDuration(tenAscending, 1.5),
          throwsA(isA<ArgumentError>()));
      expect(() => percentileDuration(tenAscending, -0.1),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('E.58 LatencySummary.fromSamples', () {
    test('computes count/min/max/p50/p95 and leaves the caller list unsorted',
        () {
      // Deliberately unsorted on input.
      final List<Duration> samples = <Duration>[
        const Duration(milliseconds: 30),
        const Duration(milliseconds: 10),
        const Duration(milliseconds: 50),
        const Duration(milliseconds: 20),
        const Duration(milliseconds: 40),
      ];
      final List<Duration> original = List<Duration>.of(samples);

      final LatencySummary summary = LatencySummary.fromSamples(samples);

      expect(summary.sampleCount, 5);
      expect(summary.min, const Duration(milliseconds: 10));
      expect(summary.max, const Duration(milliseconds: 50));
      // rank = ceil(0.50 · 5) = 3 ⇒ index 2 ⇒ 30 ms (sorted).
      expect(summary.p50, const Duration(milliseconds: 30));
      // rank = ceil(0.95 · 5) = 5 ⇒ index 4 ⇒ 50 ms.
      expect(summary.p95, const Duration(milliseconds: 50));
      // The caller's list is untouched (a copy was sorted).
      expect(samples, original);
    });

    test('an empty sample set is rejected', () {
      expect(() => LatencySummary.fromSamples(<Duration>[]),
          throwsA(isA<ArgumentError>()));
    });

    test('meetsTarget gates on p95 against the default 250 ms target', () {
      const LatencySummary within = LatencySummary(
        sampleCount: 3,
        min: Duration(milliseconds: 5),
        max: Duration(milliseconds: 200),
        p50: Duration(milliseconds: 50),
        p95: Duration(milliseconds: 200),
      );
      const LatencySummary over = LatencySummary(
        sampleCount: 3,
        min: Duration(milliseconds: 5),
        max: Duration(milliseconds: 300),
        p50: Duration(milliseconds: 50),
        p95: Duration(milliseconds: 300),
      );
      expect(within.meetsTarget(), isTrue);
      expect(over.meetsTarget(), isFalse);
      // The default target is the plan's 250 ms figure.
      expect(processBenchP95Target, const Duration(milliseconds: 250));
      // A custom target is honoured.
      expect(within.meetsTarget(const Duration(milliseconds: 100)), isFalse);
    });
  });

  group('E.58 renderLatencyReport (pure Markdown)', () {
    const LatencySummary summary = LatencySummary(
      sampleCount: 60,
      min: Duration(milliseconds: 3),
      max: Duration(milliseconds: 41),
      p50: Duration(milliseconds: 8),
      p95: Duration(milliseconds: 22),
    );

    test('a passing summary renders the metrics and a PASS verdict', () {
      final String report = renderLatencyReport(
        summary,
        warmupSamples: 5,
        generatedAt: DateTime.utc(2026, 6, 2, 19, 45),
      );
      expect(report, contains('Process-level latency bench (E.58)'));
      expect(report, contains('inbound-prompt → first-SSE-chunk'));
      expect(report, contains('| samples | 60 |'));
      expect(report, contains('| p50 | 8.00 ms |'));
      expect(report, contains('| p95 | 22.00 ms |'));
      expect(report, contains('| target (p95 ≤) | 250.00 ms |'));
      expect(report, contains('**PASS**'));
      expect(report, contains('2026-06-02T19:45:00.000Z'));
    });

    test('a failing summary renders a FAIL verdict', () {
      const LatencySummary slow = LatencySummary(
        sampleCount: 60,
        min: Duration(milliseconds: 3),
        max: Duration(milliseconds: 900),
        p50: Duration(milliseconds: 300),
        p95: Duration(milliseconds: 700),
      );
      final String report = renderLatencyReport(slow);
      expect(report, contains('**FAIL**'));
      expect(report, contains('exceeds'));
    });
  });

  group('E.58 end-to-end process bench', () {
    late SmokeProcess smoke;

    setUp(() async {
      smoke = await standUpSmokeProcess();
    });

    tearDown(() async {
      await smoke.stop();
    });

    test(
      'first-SSE-chunk p95 is within the 250 ms target with the stub substrate',
      () async {
        final LatencySummary summary = await runProcessLatencyBench(
          smoke,
          sampleCount: 40,
          warmupSamples: 5,
        );

        // Real measured numbers — print them so a CI log carries the figures.
        // ignore: avoid_print
        print('E.58 bench: ${renderLatencyReport(summary)}');

        expect(summary.sampleCount, 40);
        // Sanity: the percentiles are ordered within the observed range.
        expect(summary.min <= summary.p50, isTrue);
        expect(summary.p50 <= summary.p95, isTrue);
        expect(summary.p95 <= summary.max, isTrue);
        // The plan's pass condition.
        expect(
          summary.meetsTarget(),
          isTrue,
          reason: 'p95=${summary.p95.inMilliseconds} ms must be ≤ '
              '${processBenchP95Target.inMilliseconds} ms',
        );
      },
      // Standing the cognition up + 45 round-trips needs more than the default.
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
