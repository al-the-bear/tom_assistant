// Inbound-classifier tests (Plan step D.15; spec § 10.2; Q-E.50.1).
//
// D.15 delivers `InboundClassifier.classify(Access)` — the *no-hint* branch
// of stage two of the dispatcher's `accept → classify → select → schedule`
// pipeline. After Q-E.50.1 the confident-hint branch is no longer this
// classifier's concern: the route (`resolveProcedureId`) routes a procedure-id
// hint directly. So the classifier owns exactly one decision — run the
// injected fallback (`classify_inbound_v1` by default). These tests pin that:
//
//   1. `classify` always delegates to the fallback (it never inspects the
//      hint — a present hint does not short-circuit the fallback here).
//   2. The fallback receives the access unchanged; its verdict is returned.
//   3. The classifier never reads the prompt body.

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
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
  group('D.15 classifier — always runs the no-hint fallback', () {
    test('delegates to the fallback when no hint is present', () {
      // Default fallback is the prototype stub → user_prompt.
      final classifier = InboundClassifier();

      expect(classifier.classify(_accessWith()), InboundKinds.userPrompt);
    });

    test('still delegates to the fallback even if a hint is present', () {
      // After Q-E.50.1 the route handles the confident-hint branch; this
      // classifier never short-circuits on the hint. The route only reaches
      // here on the no-hint path, so a present hint must not change the
      // classifier's behaviour.
      var fallbackRan = false;
      final classifier = InboundClassifier(fallback: (_) {
        fallbackRan = true;
        return InboundKinds.userPrompt;
      });

      final kind =
          classifier.classify(_accessWith(kindHint: 'answer_with_memory_v1'));

      expect(fallbackRan, isTrue,
          reason: 'the classifier no longer reads the hint; the fallback '
              'decides unconditionally');
      expect(kind, InboundKinds.userPrompt);
    });

    test('returns the injected fallback verdict verbatim', () {
      final classifier =
          InboundClassifier(fallback: (_) => 'custom_kind');

      expect(classifier.classify(_accessWith()), 'custom_kind');
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
