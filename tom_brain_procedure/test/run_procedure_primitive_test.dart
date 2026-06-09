// C.19 — engine-native `runProcedure` primitive (unit).
//
// Plan step C.19 (verbatim): "Implement `runProcedure(id, inputs,
// {version, depthDelta})`. Hard depth cap = 10 (per definition § 7.3). No
// `request_depth_extension` in v1."
//
// These tests drive `RunProcedurePrimitive` directly (the Dart side of the
// primitive) plus the `ProcedureInputs` / `ProcedureResult` contract it
// consumes and returns. The d4rt-facing wiring (the `runProcedure` global)
// is covered by `native_primitives_installer_test.dart`. The headline
// PE-3 fact — the 11th level errors with `RecursionLimitExceeded` — is
// proven here against the real cap of 10 and against a small cap for
// chain-shape clarity.

import 'package:test/test.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  group('ProcedureInputs', () {
    test('get<T> returns a typed value', () {
      final inputs = ProcedureInputs(<String, Object?>{'text': 'hello', 'k': 8});
      expect(inputs.get<String>('text'), 'hello');
      expect(inputs.get<int>('k'), 8);
      expect(inputs.has('text'), isTrue);
      expect(inputs.has('absent'), isFalse);
    });

    test('get<T> throws ArgumentError on a missing input', () {
      final inputs = ProcedureInputs.empty();
      expect(() => inputs.get<String>('text'), throwsArgumentError);
    });

    test('get<T> throws StateError on a type mismatch', () {
      final inputs = ProcedureInputs(<String, Object?>{'k': 'not-an-int'});
      expect(() => inputs.get<int>('k'), throwsStateError);
    });

    test('getOrNull<T> returns null for absent / null, value for present',
        () {
      final inputs = ProcedureInputs(<String, Object?>{'a': 1, 'b': null});
      expect(inputs.getOrNull<int>('a'), 1);
      expect(inputs.getOrNull<int>('b'), isNull);
      expect(inputs.getOrNull<int>('missing'), isNull);
    });

    test('is immutable — mutating the source map does not leak in', () {
      final source = <String, Object?>{'a': 1};
      final inputs = ProcedureInputs(source);
      source['a'] = 999;
      expect(inputs.get<int>('a'), 1);
    });
  });

  group('ProcedureResult', () {
    test('succeeded / failed factories carry status + outputs', () {
      final ok = ProcedureResult.succeeded(outputs: <String, Object?>{'a': 1});
      expect(ok.status, ProcedureStatus.succeeded);
      expect(ok.isSuccess, isTrue);
      expect(ok.output<int>('a'), 1);

      final bad = ProcedureResult.failed();
      expect(bad.status, ProcedureStatus.failed);
      expect(bad.isSuccess, isFalse);
    });

    test('output<T> is lenient — null on absent or wrong type', () {
      final r = ProcedureResult.succeeded(outputs: <String, Object?>{'a': 'x'});
      expect(r.output<int>('a'), isNull);
      expect(r.output<String>('missing'), isNull);
    });
  });

  group('RunProcedurePrimitive — delegation', () {
    test('forwards id / inputs / version to the executor and returns its '
        'result', () async {
      ProcedureCall? seen;
      final primitive = RunProcedurePrimitive(
        executor: (call) async {
          seen = call;
          return ProcedureResult.succeeded(
            outputs: <String, Object?>{'echoed': call.id},
          );
        },
      );

      final inputs = ProcedureInputs(<String, Object?>{'text': 'hi'});
      final result =
          await primitive.runProcedure('think_v1', inputs, version: 1);

      expect(seen!.id, 'think_v1');
      expect(seen!.version, 1);
      expect(identical(seen!.inputs, inputs), isTrue);
      expect(seen!.depth, 2); // startDepth(1) + depthDelta(1)
      expect(result.output<String>('echoed'), 'think_v1');
    });

    test('default startDepth is 1; a single call targets depth 2', () async {
      late int childDepth;
      final primitive = RunProcedurePrimitive(
        executor: (call) async {
          childDepth = call.depth;
          return ProcedureResult.succeeded();
        },
      );
      expect(primitive.currentDepth, 1);
      await primitive.runProcedure('p_v1', ProcedureInputs.empty());
      expect(childDepth, 2);
      // Depth is restored after the call returns.
      expect(primitive.currentDepth, 1);
    });

    test('currentDepth reflects the child frame during execution and is '
        'restored after, even on executor failure', () async {
      final primitive = RunProcedurePrimitive(
        executor: (call) async {
          throw StateError('boom');
        },
      );
      await expectLater(
        primitive.runProcedure('p_v1', ProcedureInputs.empty()),
        throwsStateError,
      );
      expect(primitive.currentDepth, 1);
    });
  });

  group('RunProcedurePrimitive — depthDelta', () {
    test('depthDelta advances the child depth by more than one', () async {
      late int childDepth;
      final primitive = RunProcedurePrimitive(
        executor: (call) async {
          childDepth = call.depth;
          return ProcedureResult.succeeded();
        },
      );
      await primitive.runProcedure(
        'p_v1',
        ProcedureInputs.empty(),
        depthDelta: 3,
      );
      expect(childDepth, 4); // 1 + 3
    });

    test('depthDelta < 1 is rejected — a call must advance the chain', () {
      final primitive = RunProcedurePrimitive(
        executor: (call) async => ProcedureResult.succeeded(),
      );
      expect(
        () => primitive.runProcedure(
          'p_v1',
          ProcedureInputs.empty(),
          depthDelta: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('RunProcedurePrimitive — hard recursion cap (PE-3)', () {
    test('a chain that re-enters reaches depth 10 then the 11th level errors',
        () async {
      // The executor models a procedure that re-enters itself, so the
      // chain deepens by one each time. With the real cap of 10 and
      // startDepth 1, depths 2..10 are allowed (9 nested calls); the call
      // that would run at depth 11 throws.
      late RunProcedurePrimitive primitive;
      var deepestReached = 0;
      primitive = RunProcedurePrimitive(
        executor: (call) async {
          deepestReached = call.depth;
          // Re-enter until the cap stops us.
          return primitive.runProcedure(call.id, call.inputs);
        },
      );

      await expectLater(
        primitive.runProcedure('recurse_v1', ProcedureInputs.empty()),
        throwsA(isA<RecursionLimitExceeded>()),
      );
      // The deepest frame that actually executed is the cap itself.
      expect(deepestReached, RunProcedurePrimitive.defaultHardDepthCap);
    });

    test('the rejected invocation carries the attempted depth and target',
        () async {
      // startDepth at the cap means the very next call is over the line.
      final primitive = RunProcedurePrimitive(
        executor: (call) async => ProcedureResult.succeeded(),
        startDepth: RunProcedurePrimitive.defaultHardDepthCap,
      );

      try {
        await primitive.runProcedure('think_v1', ProcedureInputs.empty(),
            version: 2);
        fail('expected RecursionLimitExceeded');
      } on RecursionLimitExceeded catch (e) {
        expect(e.attemptedDepth, 11);
        expect(e.hardDepthCap, 10);
        expect(e.procedureId, 'think_v1');
        expect(e.version, 2);
        expect(e.toString(), contains('think_v1'));
      }
    });

    test('the executor is NOT invoked when the cap is breached', () async {
      var executorCalls = 0;
      final primitive = RunProcedurePrimitive(
        executor: (call) async {
          executorCalls++;
          return ProcedureResult.succeeded();
        },
        startDepth: RunProcedurePrimitive.defaultHardDepthCap,
      );
      await expectLater(
        primitive.runProcedure('p_v1', ProcedureInputs.empty()),
        throwsA(isA<RecursionLimitExceeded>()),
      );
      expect(executorCalls, 0);
    });

    test('depthDelta can breach the cap in a single jump', () async {
      final primitive = RunProcedurePrimitive(
        executor: (call) async => ProcedureResult.succeeded(),
      );
      // startDepth 1 + depthDelta 10 = 11 > 10.
      await expectLater(
        primitive.runProcedure('p_v1', ProcedureInputs.empty(), depthDelta: 10),
        throwsA(isA<RecursionLimitExceeded>()),
      );
    });

    test('a smaller cap makes the chain shape explicit', () async {
      // cap = 3, startDepth = 1: depth 2 and 3 allowed, depth 4 errors.
      late RunProcedurePrimitive primitive;
      final depths = <int>[];
      primitive = RunProcedurePrimitive(
        executor: (call) async {
          depths.add(call.depth);
          return primitive.runProcedure(call.id, call.inputs);
        },
        hardDepthCap: 3,
      );
      await expectLater(
        primitive.runProcedure('p_v1', ProcedureInputs.empty()),
        throwsA(isA<RecursionLimitExceeded>()),
      );
      expect(depths, <int>[2, 3]);
    });
  });

  group('RunProcedurePrimitive — construction guards', () {
    test('hardDepthCap < 1 is rejected', () {
      expect(
        () => RunProcedurePrimitive(
          executor: (call) async => ProcedureResult.succeeded(),
          hardDepthCap: 0,
        ),
        throwsArgumentError,
      );
    });

    test('startDepth out of 1..hardDepthCap is rejected', () {
      expect(
        () => RunProcedurePrimitive(
          executor: (call) async => ProcedureResult.succeeded(),
          startDepth: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => RunProcedurePrimitive(
          executor: (call) async => ProcedureResult.succeeded(),
          hardDepthCap: 5,
          startDepth: 6,
        ),
        throwsArgumentError,
      );
    });
  });
}
