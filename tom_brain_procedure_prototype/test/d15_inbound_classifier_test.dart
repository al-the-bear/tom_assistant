// Inbound-classifier tests (Plan step D.15; spec § 10.2).
//
// D.15 delivers `InboundClassifier.classify(Access)` — stage two of the
// dispatcher's `accept → classify → select → schedule` pipeline. These
// tests pin the classifier's one decision in isolation:
//
//   1. Kind-hint pass-through: a non-blank `envelope.kindHint` is accepted
//      verbatim (trimmed), and the fallback is not consulted.
//   2. Fallback: an absent or whitespace-only hint routes to
//      `classify_inbound_v1`, which for the prototype returns `user_prompt`.
//   3. The classifier never reads the prompt body.

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show InboundClassifier, classifyInboundV1;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show Access, InboundKinds, InboundRequest, OutboundChunk, Persona,
        ResolvedIdentity, Session;

/// Builds a synthetic [Access]. The deliver callback is inert: the
/// classifier never touches it.
Access _accessWith({String text = 'what is the time?', String? kindHint}) =>
    Access(
      envelope: InboundRequest(text: text, kindHint: kindHint),
      identity: ResolvedIdentity(principalId: 'p1'),
      session: Session(sessionId: 's1'),
      persona: Persona.assistant(),
      deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
    );

void main() {
  group('D.15 classifier — kind-hint pass-through', () {
    test('accepts a pre-filled kind-hint verbatim', () {
      final classifier = InboundClassifier(
        fallback: (_) => fail('fallback must not run when a hint is present'),
      );

      expect(
        classifier.classify(_accessWith(kindHint: 'user_prompt')),
        'user_prompt',
      );
    });

    test('passes through an arbitrary (future) kind-hint unchanged', () {
      // The real classifier emits kinds the prototype does not anticipate;
      // the dispatcher must not narrow them to a closed set here.
      final classifier = InboundClassifier(
        fallback: (_) => fail('fallback must not run when a hint is present'),
      );

      expect(
        classifier.classify(_accessWith(kindHint: 'background_research')),
        'background_research',
      );
    });

    test('trims surrounding whitespace off a present hint', () {
      final classifier = InboundClassifier(fallback: (_) => 'should-not-run');

      expect(
        classifier.classify(_accessWith(kindHint: '  user_prompt\n')),
        'user_prompt',
      );
    });
  });

  group('D.15 classifier — fallback', () {
    test('falls back to classify_inbound_v1 when no hint is present', () {
      // Default fallback is the prototype stub → user_prompt.
      final classifier = InboundClassifier();

      expect(
        classifier.classify(_accessWith()),
        InboundKinds.userPrompt,
      );
    });

    test('treats a whitespace-only hint as absent (falls back)', () {
      var fallbackRan = false;
      final classifier = InboundClassifier(fallback: (_) {
        fallbackRan = true;
        return InboundKinds.userPrompt;
      });

      final kind = classifier.classify(_accessWith(kindHint: '   \t\n'));

      expect(fallbackRan, isTrue,
          reason: 'a blank hint carries no kind; the fallback decides');
      expect(kind, InboundKinds.userPrompt);
    });

    test('hands the access through to the injected fallback', () {
      Access? seen;
      final classifier = InboundClassifier(fallback: (access) {
        seen = access;
        return 'custom_kind';
      });
      final access = _accessWith();

      final kind = classifier.classify(access);

      expect(identical(seen, access), isTrue);
      expect(kind, 'custom_kind');
    });
  });

  group('D.15 classifier — body isolation', () {
    test('verdict does not depend on the prompt body', () {
      final classifier = InboundClassifier();

      final first = classifier.classify(_accessWith(text: 'tell me a joke'));
      final second =
          classifier.classify(_accessWith(text: 'translate this to French'));

      expect(first, second,
          reason: 'the prototype stub ignores the body; both are user_prompt');
      expect(first, InboundKinds.userPrompt);
    });
  });

  group('D.15 classify_inbound_v1 stub', () {
    test('returns user_prompt regardless of input', () {
      expect(classifyInboundV1(_accessWith(text: 'anything')),
          InboundKinds.userPrompt);
      expect(classifyInboundV1(_accessWith(kindHint: 'ignored-here')),
          InboundKinds.userPrompt);
    });

    test('InboundKinds.userPrompt is the spec spelling', () {
      expect(InboundKinds.userPrompt, 'user_prompt');
    });
  });
}
