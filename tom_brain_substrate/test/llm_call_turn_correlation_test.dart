// Tests for the optional turn-correlation fields on LlmCall (logging-spec §3 /
// §9; substrate_specification.md § 3.1).
//
// `turnId` + `callSeq` uniquely name any LLM call across the whole system
// (§3). They are stamped by the procedure engine's per-run SubstrateBridge as
// the call is built (§9 — the "→ substrate" end of the turnId thread-through),
// so `LlmCall` carries them as two additive optional fields. Every pre-existing
// construction site leaves them `null` — the internal / free-time / dream paths
// that do not run inside a user turn never stamp them.

import 'package:tom_brain_shared/tom_brain_shared.dart' show Budget, TurnId;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

void main() {
  Budget budget() => Budget(
        wallClockMs: 1000,
        tokenSpend: 100,
        toolCalls: 1,
        memoryWrites: 0,
      );

  group('LlmCall turn correlation', () {
    test('turnId and callSeq default to null', () {
      final call = LlmCall(
        roleId: 'assistant_to_user',
        inputs: const <String, Object?>{'prompt': 'hi'},
        budget: budget(),
      );
      expect(call.turnId, isNull);
      expect(call.callSeq, isNull);
    });

    test('carries the turn correlation tuple when stamped', () {
      final turnId = TurnId.generate();
      final call = LlmCall(
        roleId: 'assistant_to_user',
        inputs: const <String, Object?>{'prompt': 'hi'},
        budget: budget(),
        turnId: turnId,
        callSeq: 3,
      );
      expect(call.turnId, same(turnId));
      expect(call.callSeq, equals(3));
    });
  });
}
