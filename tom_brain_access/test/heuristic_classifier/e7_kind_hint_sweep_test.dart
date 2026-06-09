// E.35 — `## E.7` cheap kind-hint classifier test sweep.
//
// The formal sweep that closes `## E.7 — Cheap kind-hint classifier`
// (proto spec § 9.1 + § 9.2; AC-9). E.33 and E.34 each carry their own
// granular suites; this file is the named acceptance sweep the plan calls for
// and exercises the *integrated* § E.7 surface — the `HeuristicKindHintClassifier`
// (E.33) composed in front of the `EmbeddingCache` (E.34), exactly as boot
// (E.41+) wires them — to lock the three plan-named outcomes end-to-end:
//
//   1. Confident classification produces a kindHint.
//   2. Uncertain (and unknown) classification leaves the kindHint null.
//   3. A cache hit avoids the embed call (the repeat prompt short-circuits
//      the substrate embed) while still producing the same hint.

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';

/// A counting embedder seam: returns a distinct vector per call and records
/// how many times it ran, so the sweep can prove a cache hit *avoided* the
/// embed call (E.35 criterion 3) — distinguishing a hit by value, not just by
/// count.
final class _CountingEmbedder {
  int calls = 0;
  final List<String> seen = <String>[];

  Future<List<double>> call(String text) async {
    final int n = calls++;
    seen.add(text);
    return <double>[n.toDouble(), text.length.toDouble()];
  }
}

/// A fixed-decision classifier seam: always returns [result] and records the
/// embeddings it was handed, so the sweep can wire any decision band.
final class _FixedClassifier {
  _FixedClassifier(this.result);

  final KindHintClassification result;
  final List<List<double>> seen = <List<double>>[];

  Future<KindHintClassification> call(List<double> embedding) async {
    seen.add(embedding);
    return result;
  }
}

/// A controllable clock seam — the same shape the cache and edge-security
/// limiters use, so TTL boundaries are exercised deterministically.
final class _FakeClock {
  _FakeClock(this._now);
  DateTime _now;

  DateTime call() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

/// Builds the integrated § E.7 surface: the classifier (E.33) with its embed
/// seam bound to the cache (E.34), and the cache wrapping [embedder] — the
/// shape boot composes.
({
  HeuristicKindHintClassifier classifier,
  EmbeddingCache cache,
}) _section7({
  required _CountingEmbedder embedder,
  required KindHintClassification decision,
  required _FakeClock clock,
}) {
  final cache = EmbeddingCache(embedder: embedder.call, clock: clock.call);
  final classifier = HeuristicKindHintClassifier(
    embedder: cache.embed, // the cache IS the embed seam (E.34 in front of E.33)
    classifier: _FixedClassifier(decision).call,
  );
  return (classifier: classifier, cache: cache);
}

void main() {
  final DateTime t0 = DateTime.utc(2026, 6, 2, 12);

  group('E.35 § E.7 sweep — confident classification produces a kindHint', () {
    test('a confident decision attaches the matched procedure id', () async {
      final embedder = _CountingEmbedder();
      final section = _section7(
        embedder: embedder,
        decision: const KindHintClassification(
          decision: KindHintDecision.confident,
          procedureId: 'answer_with_memory_v1',
        ),
        clock: _FakeClock(t0),
      );

      final hint =
          await section.classifier.classifyKindHint('what is the capital?');

      expect(hint, 'answer_with_memory_v1');
      expect(embedder.calls, 1, reason: 'a fresh prompt embeds once');
    });
  });

  group('E.35 § E.7 sweep — non-confident classification leaves it null', () {
    test('an uncertain decision leaves the kindHint null', () async {
      final embedder = _CountingEmbedder();
      final section = _section7(
        embedder: embedder,
        decision: const KindHintClassification(
          // A procedureId is present but must be ignored: only a *confident*
          // band yields a hint (AC-9).
          decision: KindHintDecision.uncertain,
          procedureId: 'answer_with_memory_v1',
        ),
        clock: _FakeClock(t0),
      );

      expect(
        await section.classifier.classifyKindHint('a borderline prompt'),
        isNull,
      );
    });

    test('an unknown (cold-start) decision leaves the kindHint null', () async {
      final embedder = _CountingEmbedder();
      final section = _section7(
        embedder: embedder,
        decision: const KindHintClassification.unknown(),
        clock: _FakeClock(t0),
      );

      expect(
        await section.classifier.classifyKindHint('cold-start prompt'),
        isNull,
      );
    });
  });

  group('E.35 § E.7 sweep — a cache hit avoids the embed call', () {
    test('repeating the exact prompt within TTL skips the substrate embed',
        () async {
      final embedder = _CountingEmbedder();
      final clock = _FakeClock(t0);
      final section = _section7(
        embedder: embedder,
        decision: const KindHintClassification(
          decision: KindHintDecision.confident,
          procedureId: 'answer_with_memory_v1',
        ),
        clock: clock,
      );

      final first = await section.classifier.classifyKindHint('same prompt');
      clock.advance(const Duration(minutes: 2)); // within the 5-min TTL
      final second = await section.classifier.classifyKindHint('same prompt');

      expect(first, 'answer_with_memory_v1');
      expect(second, 'answer_with_memory_v1',
          reason: 'a cache hit still yields the same hint');
      expect(embedder.calls, 1,
          reason: 'the repeat prompt must short-circuit the embed call');
    });

    test('a repeat past the TTL re-embeds (the hit window is bounded)',
        () async {
      final embedder = _CountingEmbedder();
      final clock = _FakeClock(t0);
      final section = _section7(
        embedder: embedder,
        decision: const KindHintClassification(
          decision: KindHintDecision.confident,
          procedureId: 'answer_with_memory_v1',
        ),
        clock: clock,
      );

      await section.classifier.classifyKindHint('same prompt');
      clock.advance(const Duration(minutes: 6)); // past the 5-min TTL
      await section.classifier.classifyKindHint('same prompt');

      expect(embedder.calls, 2,
          reason: 'an expired entry is recomputed — the cache is not a leak');
    });

    test('a distinct prompt is a cache miss and embeds again', () async {
      final embedder = _CountingEmbedder();
      final section = _section7(
        embedder: embedder,
        decision: const KindHintClassification(
          decision: KindHintDecision.confident,
          procedureId: 'answer_with_memory_v1',
        ),
        clock: _FakeClock(t0),
      );

      await section.classifier.classifyKindHint('prompt one');
      await section.classifier.classifyKindHint('prompt two');

      expect(embedder.calls, 2, reason: 'distinct texts each miss the cache');
      expect(embedder.seen, <String>['prompt one', 'prompt two']);
    });
  });
}
