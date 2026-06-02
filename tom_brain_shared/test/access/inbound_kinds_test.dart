// InboundKinds unit tests (added at the D.52 reuse-extraction pass when the
// type moved into `tom_brain_shared`).
//
// Covers the cross-phase vocabulary contract the Phase-E heuristic
// classifier (writes `InboundRequest.kindHint`) and the Phase-D dispatcher
// classifier (reads it) both rely on: the one well-known kind string carries
// its spec spelling, and it is reachable through the shared barrel without
// any dependency on the dispatcher package.

import 'package:test/test.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show InboundKinds, InboundRequest;

void main() {
  group('InboundKinds (D.52 extraction)', () {
    test('userPrompt carries the spec spelling', () {
      expect(InboundKinds.userPrompt, 'user_prompt');
    });

    test('the constant is usable as an InboundRequest.kindHint', () {
      // The whole point of the extraction: Phase E writes the shared
      // vocabulary into the shared envelope field without reaching into the
      // dispatcher package for the constant.
      final req = InboundRequest(text: 'hi', kindHint: InboundKinds.userPrompt);
      expect(req.kindHint, 'user_prompt');
    });
  });
}
