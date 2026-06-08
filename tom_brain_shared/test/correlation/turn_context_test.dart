// Tests for TurnContext (logging-spec §3 — the per-turn correlation tuple).
//
// A TurnContext carries the `turnId` minted at the access edge plus the
// per-turn `callSeq` counter. `turnId` + `callSeq` together uniquely name any
// LLM call across the whole system (§3). One TurnContext is created per turn at
// `ProcedureEngine.invoke` and shared across every (possibly nested) run of that
// turn, so the counter spans sub-procedures.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('TurnContext', () {
    test('carries the turnId it was built with', () {
      final turnId = TurnId.generate();
      final ctx = TurnContext(turnId);
      expect(ctx.turnId, same(turnId));
    });

    test('nextCallSeq starts at 1 and increments monotonically', () {
      final ctx = TurnContext(TurnId.generate());
      expect(ctx.nextCallSeq(), equals(1));
      expect(ctx.nextCallSeq(), equals(2));
      expect(ctx.nextCallSeq(), equals(3));
    });

    test('two contexts count independently', () {
      final a = TurnContext(TurnId.generate());
      final b = TurnContext(TurnId.generate());
      expect(a.nextCallSeq(), equals(1));
      expect(a.nextCallSeq(), equals(2));
      // b is untouched by a's counter.
      expect(b.nextCallSeq(), equals(1));
    });
  });
}
