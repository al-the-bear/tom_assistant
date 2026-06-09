// E.34 — In-process embedding cache conformance tests.
//
// What this file locks (proto spec § 9.2; AC; def):
//
//   1. A repeat of the *exact* text within the TTL is a cache hit — the
//      wrapped embedder is NOT called again (the embed call is saved).
//   2. A cache hit returns the *stored* embedding (the value the first miss
//      computed).
//   3. The key is the *exact* text: a prompt differing by whitespace misses.
//   4. An entry past its TTL expires — a repeat after expiry re-embeds.
//   5. The TTL boundary is exclusive of "exactly ttl old" (an entry exactly
//      `ttl` old is expired) and live just before it.
//   6. A throwing embedder propagates and memoises nothing — the next call
//      retries the embedder rather than serving a cached failure.
//   7. `EmbeddingCache.embed` is a `KindHintEmbedder` and composes in front of
//      `HeuristicKindHintClassifier` — a hit there saves the classifier's
//      embed call too (§ 9.1 step 1 over § 9.2).
//   8. `size` reflects live entries (expired ones are swept) and `clear`
//      empties the cache.
//   9. The whole surface reaches through the package barrel — a consumer
//      never imports the `src/` file.

import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';

/// A counting embedder seam: returns a distinct vector per call and records
/// how many times it ran, so a test can prove a cache hit *avoided* the call.
final class _CountingEmbedder {
  int calls = 0;
  final List<String> seen = <String>[];

  Future<List<double>> call(String text) async {
    final int n = calls++;
    seen.add(text);
    // A per-call-distinct vector lets a test tell a fresh embed from a cache
    // hit by inspecting the returned value, not just the call count.
    return <double>[n.toDouble(), text.length.toDouble()];
  }
}

/// A controllable clock seam — the same shape the edge-security limiters use.
final class _FakeClock {
  _FakeClock(this._now);
  DateTime _now;

  DateTime call() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

void main() {
  final DateTime t0 = DateTime.utc(2026, 6, 2, 12);

  group('EmbeddingCache — hit / miss (§ 9.2)', () {
    test('repeat of the exact text within TTL is a hit — no second embed call',
        () async {
      final embedder = _CountingEmbedder();
      final clock = _FakeClock(t0);
      final cache = EmbeddingCache(embedder: embedder.call, clock: clock.call);

      final first = await cache.embed('summarise this');
      clock.advance(const Duration(minutes: 2));
      final second = await cache.embed('summarise this');

      expect(embedder.calls, 1, reason: 'the second call must hit the cache');
      expect(second, same(first),
          reason: 'a hit returns the stored embedding');
    });

    test('a hit returns the value the first miss computed', () async {
      final embedder = _CountingEmbedder();
      final clock = _FakeClock(t0);
      final cache = EmbeddingCache(embedder: embedder.call, clock: clock.call);

      final first = await cache.embed('abc');
      final second = await cache.embed('abc');

      // Vector encodes the call index; a re-embed would carry index 1.
      expect(first, <double>[0.0, 3.0]);
      expect(second, <double>[0.0, 3.0]);
    });

    test('distinct texts each miss and embed once', () async {
      final embedder = _CountingEmbedder();
      final cache = EmbeddingCache(embedder: embedder.call, clock: () => t0);

      await cache.embed('one');
      await cache.embed('two');

      expect(embedder.calls, 2);
      expect(embedder.seen, <String>['one', 'two']);
    });

    test('key is the EXACT text — a whitespace difference misses', () async {
      final embedder = _CountingEmbedder();
      final cache = EmbeddingCache(embedder: embedder.call, clock: () => t0);

      await cache.embed('hello');
      await cache.embed('hello '); // trailing space → different key

      expect(embedder.calls, 2,
          reason: '§ 9.2 keys by exact text; no trimming / normalisation');
    });
  });

  group('EmbeddingCache — TTL expiry', () {
    test('a repeat after the TTL re-embeds', () async {
      final embedder = _CountingEmbedder();
      final clock = _FakeClock(t0);
      final cache = EmbeddingCache(embedder: embedder.call, clock: clock.call);

      final first = await cache.embed('q');
      clock.advance(const Duration(minutes: 6)); // past 5-min default TTL
      final second = await cache.embed('q');

      expect(embedder.calls, 2, reason: 'expired entry must be recomputed');
      expect(second, isNot(same(first)));
      expect(second, <double>[1.0, 1.0], reason: 'second embed, call index 1');
    });

    test('entry exactly TTL old is expired (boundary is inclusive of expiry)',
        () async {
      final embedder = _CountingEmbedder();
      final clock = _FakeClock(t0);
      final cache = EmbeddingCache(
        embedder: embedder.call,
        ttl: const Duration(minutes: 5),
        clock: clock.call,
      );

      await cache.embed('x');
      clock.advance(const Duration(minutes: 5)); // age == ttl
      await cache.embed('x');

      expect(embedder.calls, 2, reason: 'age >= ttl counts as expired');
    });

    test('entry just under TTL is still live', () async {
      final embedder = _CountingEmbedder();
      final clock = _FakeClock(t0);
      final cache = EmbeddingCache(
        embedder: embedder.call,
        ttl: const Duration(minutes: 5),
        clock: clock.call,
      );

      await cache.embed('x');
      clock.advance(const Duration(minutes: 5) - const Duration(seconds: 1));
      await cache.embed('x');

      expect(embedder.calls, 1, reason: 'age < ttl is a live hit');
    });

    test('a non-positive TTL is rejected at construction', () {
      expect(
        () => EmbeddingCache(
          embedder: (_) async => const <double>[],
          ttl: Duration.zero,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('EmbeddingCache — failure handling', () {
    test('a throwing embedder propagates and memoises nothing', () async {
      var attempts = 0;
      Future<List<double>> flaky(String text) async {
        attempts++;
        if (attempts == 1) throw StateError('substrate down');
        return <double>[42.0];
      }

      final cache = EmbeddingCache(embedder: flaky, clock: () => t0);

      await expectLater(
          cache.embed('p'), throwsA(isA<StateError>()));
      // The failure was not cached: the retry reaches the embedder again.
      final retry = await cache.embed('p');

      expect(attempts, 2);
      expect(retry, <double>[42.0]);
    });
  });

  group('EmbeddingCache — composition with the classifier (§ 9.1 over § 9.2)',
      () {
    test('a cache hit saves the classifier\'s embed call', () async {
      final embedder = _CountingEmbedder();
      final clock = _FakeClock(t0);
      final cache = EmbeddingCache(embedder: embedder.call, clock: clock.call);

      // The classify seam ignores the vector and always answers confidently.
      Future<KindHintClassification> classify(List<double> embedding) async =>
          const KindHintClassification(
            decision: KindHintDecision.confident,
            procedureId: 'answer_with_memory_v1',
          );

      final classifier = HeuristicKindHintClassifier(
        embedder: cache.embed, // the cache IS the embedder seam
        classifier: classify,
      );

      final firstHint = await classifier.classifyKindHint('same prompt');
      clock.advance(const Duration(minutes: 1));
      final secondHint = await classifier.classifyKindHint('same prompt');

      expect(firstHint, 'answer_with_memory_v1');
      expect(secondHint, 'answer_with_memory_v1');
      expect(embedder.calls, 1,
          reason: 'the classifier embed call is short-circuited on repeat');
    });
  });

  group('EmbeddingCache — size / clear', () {
    test('size counts live entries and sweeps expired ones', () async {
      final embedder = _CountingEmbedder();
      final clock = _FakeClock(t0);
      final cache = EmbeddingCache(embedder: embedder.call, clock: clock.call);

      await cache.embed('a');
      await cache.embed('b');
      expect(cache.size, 2);

      clock.advance(const Duration(minutes: 6));
      expect(cache.size, 0, reason: 'expired entries are swept on access');
    });

    test('clear empties the cache', () async {
      final embedder = _CountingEmbedder();
      final cache = EmbeddingCache(embedder: embedder.call, clock: () => t0);

      await cache.embed('a');
      cache.clear();

      expect(cache.size, 0);
      await cache.embed('a');
      expect(embedder.calls, 2, reason: 'post-clear, the text re-embeds');
    });
  });
}
