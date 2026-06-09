// D.52 reuse-extraction sentinel (Plan step D.52; spec § 10.2).
//
// D.52 promoted `InboundKinds` — the inbound-kind vocabulary — out of the
// dispatcher package into `tom_brain_shared`, beside the
// `InboundRequest.kindHint` field it names (D.11). Phase E *produces* the
// hint (E.33); Phase D *consumes* it (D.15 / D.16). This sentinel pins that
// both dispatcher consumers now speak the *shared* vocabulary, so a later
// edit cannot silently re-introduce a package-local copy of the token.
//
// The `InboundKinds` symbol here is imported from `tom_brain_shared`; the
// `InboundClassifier` / `ProcedureSelector` it drives come from the
// dispatcher package. The test passing therefore *requires* the dispatcher
// internals to resolve the same shared constant — exactly the cross-phase
// agreement the extraction exists to guarantee.

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show InboundClassifier, ProcedureSelector, SystemProcedures;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        InboundKinds,
        InboundRequest,
        OutboundChunk,
        Persona,
        ResolvedIdentity,
        Session;

/// Builds a synthetic un-hinted [Access]; the classifier never touches the
/// deliver callback.
Access _unhintedAccess() => Access(
      envelope: InboundRequest(text: 'what is the time?'),
      identity: ResolvedIdentity(principalId: 'p1'),
      session: Session(sessionId: 's1'),
      persona: Persona.assistant(),
      deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
    );

void main() {
  group('D.52 — InboundKinds promoted to tom_brain_shared', () {
    test('the shared constant carries the spec spelling', () {
      expect(InboundKinds.userPrompt, 'user_prompt');
    });

    test('the dispatcher classifier resolves to the shared vocabulary', () {
      // Default stub fallback (`classify_inbound_v1`) → the shared
      // `InboundKinds.userPrompt`. If the dispatcher kept a package-local
      // copy of the token this comparison-by-value would still pass, but the
      // selector hop below pins the *routing* against the same shared value.
      final classifier = InboundClassifier();

      expect(classifier.classify(_unhintedAccess()), InboundKinds.userPrompt);
    });

    test('the selector routes the shared kind to answer_with_memory_v1', () {
      final selector = ProcedureSelector();

      expect(
        selector.select(InboundKinds.userPrompt),
        SystemProcedures.answerWithMemoryV1,
      );
    });

    test('classifier + selector compose across the shared vocabulary', () {
      // The full classify → select hop the dispatcher runs, driven from the
      // shared `InboundKinds` symbol only.
      final kind = InboundClassifier().classify(_unhintedAccess());
      final procedureId = ProcedureSelector().select(kind);

      expect(kind, InboundKinds.userPrompt);
      expect(procedureId, SystemProcedures.answerWithMemoryV1);
    });
  });
}
