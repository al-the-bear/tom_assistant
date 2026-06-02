// E.33 — Cheap kind-hint classifier conformance tests.
//
// What this file locks (proto spec § 9.1; AC-9; def § 1.5):
//
//   1. A `confident` decision attaches the returned procedure id as the hint.
//   2. The hint is trimmed of surrounding whitespace.
//   3. An `uncertain` decision leaves the hint null (the cheap path is silent).
//   4. An `unknown` decision leaves the hint null.
//   5. A `confident` decision whose procedure id is null degrades to null —
//      a hint must name a procedure.
//   6. A `confident` decision whose procedure id is blank degrades to null.
//   7. The three steps run in order: embed the *exact* text → classify the
//      *embedder's* vector → branch on the decision.
//   8. Seam failures (embedder / classifier throwing) propagate — the
//      graceful-degradation path is boot's (E.41+), not the classifier's.
//   9. `KindHintClassification` value equality + the `unknown` convenience.
//  10. The whole surface reaches through the package barrel — a consumer
//      never imports the `src/` file.

import 'package:test/test.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';

/// A recording embedder seam: returns a fixed vector and remembers every
/// text it was asked to embed, so a test can prove the embed call ran (and
/// on what input).
final class _RecordingEmbedder {
  _RecordingEmbedder(this.vector);

  final List<double> vector;
  final List<String> seen = <String>[];

  Future<List<double>> call(String text) async {
    seen.add(text);
    return vector;
  }
}

/// A recording classifier seam: returns a fixed [KindHintClassification] and
/// remembers every embedding it was handed, so a test can prove the classify
/// call ran on the embedder's vector.
final class _RecordingClassifier {
  _RecordingClassifier(this.result);

  final KindHintClassification result;
  final List<List<double>> seen = <List<double>>[];

  Future<KindHintClassification> call(List<double> embedding) async {
    seen.add(embedding);
    return result;
  }
}

HeuristicKindHintClassifier _classifierWith({
  required List<double> vector,
  required KindHintClassification result,
  _RecordingEmbedder? embedder,
  _RecordingClassifier? classifier,
}) {
  final emb = embedder ?? _RecordingEmbedder(vector);
  final cls = classifier ?? _RecordingClassifier(result);
  return HeuristicKindHintClassifier(
    embedder: emb.call,
    classifier: cls.call,
  );
}

void main() {
  group('E.33 confident-only hint', () {
    test('a confident decision attaches the procedure id as the hint', () async {
      final sut = _classifierWith(
        vector: const [0.1, 0.2, 0.3],
        result: const KindHintClassification(
          decision: KindHintDecision.confident,
          procedureId: 'answer_with_memory_v1',
        ),
      );

      expect(
        await sut.classifyKindHint('what is the capital of France?'),
        equals('answer_with_memory_v1'),
      );
    });

    test('the attached hint is trimmed of surrounding whitespace', () async {
      final sut = _classifierWith(
        vector: const [0.0],
        result: const KindHintClassification(
          decision: KindHintDecision.confident,
          procedureId: '  research_v1\n',
        ),
      );

      expect(await sut.classifyKindHint('dig into the topic'),
          equals('research_v1'));
    });
  });

  group('E.33 silence on non-confident decisions', () {
    test('an uncertain decision leaves the hint null', () async {
      final sut = _classifierWith(
        vector: const [0.0],
        result: const KindHintClassification(
          decision: KindHintDecision.uncertain,
          procedureId: 'research_v1',
        ),
      );

      expect(await sut.classifyKindHint('a borderline prompt'), isNull);
    });

    test('an unknown decision leaves the hint null', () async {
      final sut = _classifierWith(
        vector: const [0.0],
        result: const KindHintClassification.unknown(),
      );

      expect(await sut.classifyKindHint('cold-start prompt'), isNull);
    });
  });

  group('E.33 confident-but-unroutable degrades to null', () {
    test('a confident decision with a null procedure id returns null',
        () async {
      final sut = _classifierWith(
        vector: const [0.0],
        result: const KindHintClassification(
          decision: KindHintDecision.confident,
        ),
      );

      expect(await sut.classifyKindHint('prompt'), isNull);
    });

    test('a confident decision with a blank procedure id returns null',
        () async {
      final sut = _classifierWith(
        vector: const [0.0],
        result: const KindHintClassification(
          decision: KindHintDecision.confident,
          procedureId: '   ',
        ),
      );

      expect(await sut.classifyKindHint('prompt'), isNull);
    });
  });

  group('E.33 step ordering and wiring', () {
    test('embeds the exact text, then classifies the embedder vector',
        () async {
      final embedder = _RecordingEmbedder(const [9.0, 8.0, 7.0]);
      final classifier = _RecordingClassifier(
        const KindHintClassification(
          decision: KindHintDecision.confident,
          procedureId: 'answer_with_memory_v1',
        ),
      );
      final sut = HeuristicKindHintClassifier(
        embedder: embedder.call,
        classifier: classifier.call,
      );

      await sut.classifyKindHint('exact prompt text');

      // Step 1: the embedder saw the exact, untouched prompt text.
      expect(embedder.seen, equals(['exact prompt text']));
      // Step 2: the classifier saw the vector the embedder produced.
      expect(classifier.seen, equals([
        const [9.0, 8.0, 7.0]
      ]));
    });
  });

  group('E.33 seam-failure propagation', () {
    test('an embedder failure propagates (no graceful catch here)', () async {
      final sut = HeuristicKindHintClassifier(
        embedder: (_) async => throw StateError('substrate down'),
        classifier: (_) async =>
            const KindHintClassification.unknown(),
      );

      expect(
        () => sut.classifyKindHint('prompt'),
        throwsA(isA<StateError>()),
      );
    });

    test('a classifier failure propagates (no graceful catch here)', () async {
      final sut = HeuristicKindHintClassifier(
        embedder: (_) async => const [0.0],
        classifier: (_) async => throw StateError('memory down'),
      );

      expect(
        () => sut.classifyKindHint('prompt'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('E.33 KindHintClassification value type', () {
    test('value equality over decision + procedureId', () {
      const a = KindHintClassification(
        decision: KindHintDecision.confident,
        procedureId: 'answer_with_memory_v1',
      );
      const b = KindHintClassification(
        decision: KindHintDecision.confident,
        procedureId: 'answer_with_memory_v1',
      );
      const c = KindHintClassification(
        decision: KindHintDecision.uncertain,
        procedureId: 'answer_with_memory_v1',
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('the unknown convenience is decision=unknown, procedureId=null', () {
      const u = KindHintClassification.unknown();
      expect(u.decision, equals(KindHintDecision.unknown));
      expect(u.procedureId, isNull);
    });
  });
}
