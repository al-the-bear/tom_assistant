// C.19 — engine-native `runProcedure` primitive (d4rt wiring).
//
// Companion to `run_procedure_primitive_test.dart` (which drives the Dart
// primitive directly). This file proves the *d4rt-facing* half: the
// installer registers `runProcedure` as a top-level function reachable
// from a procedure script through the host's `installNativePrimitives`
// seam (the C.16 compose-point), that a script can forward its own opaque
// `ProcedureInputs` to it, that the `version` / `depthDelta` named
// arguments marshal through, and that a `RecursionLimitExceeded` raised by
// the primitive propagates out of a script call.
//
// The scripts deliberately keep `ProcedureInputs` / `ProcedureResult` as
// *opaque* host objects: a procedure forwards the `inputs` it was handed
// and returns the result without introspecting either in-script (those
// types are not bridged at C.19, by design — the engine surface that
// constructs/inspects them lands at C.38–C.41). Assertions on the result
// happen on the Dart side.
//
// The memory / substrate bridges are constructed only to satisfy the
// host's constructor; the C.19 scripts call `runProcedure`, not `mem` /
// `sub`, so the bridge doubles fall through to `noSuchMethod`.

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

void main() {
  late MemoryBridge memoryBridge;
  late SubstrateBridge substrateBridge;

  setUp(() {
    memoryBridge = MemoryBridge(_StubMemoryClient(_StubStackApi()));
    substrateBridge = SubstrateBridge(_StubSubstrateClient());
  });

  // Boots a host whose native-primitive seam is filled by [primitive].
  D4rtDcliHost hostFor(RunProcedurePrimitive primitive) => D4rtDcliHost(
        memoryBridge: memoryBridge,
        substrateBridge: substrateBridge,
        installNativePrimitives: nativePrimitivesInstaller(primitive),
      );

  test('runProcedure is callable from a script and returns the executor '
      'result', () async {
    ProcedureCall? seen;
    final primitive = RunProcedurePrimitive(
      executor: (call) async {
        seen = call;
        return ProcedureResult.succeeded(
          outputs: <String, Object?>{'ran': call.id},
        );
      },
    );
    final host = hostFor(primitive);

    final result = await host.run(
      '''
import '$engineNativeLibrary';

run(inputs) async {
  return await runProcedure('think_v1', inputs);
}
''',
      inputs: <Object?>[ProcedureInputs.empty()],
    );

    expect(seen!.id, 'think_v1');
    expect(seen!.depth, 2);
    // The opaque ProcedureResult comes back to the Dart side intact.
    expect(result, isA<ProcedureResult>());
    expect((result! as ProcedureResult).output<String>('ran'), 'think_v1');
  });

  test('a script forwards its own opaque ProcedureInputs to runProcedure',
      () async {
    ProcedureCall? seen;
    final primitive = RunProcedurePrimitive(
      executor: (call) async {
        seen = call;
        return ProcedureResult.succeeded();
      },
    );
    final host = hostFor(primitive);

    final inputs = ProcedureInputs(<String, Object?>{'text': 'forward me'});
    await host.run(
      '''
import '$engineNativeLibrary';

run(inputs) async {
  await runProcedure('child_v1', inputs);
}
''',
      inputs: <Object?>[inputs],
    );

    // The very object the host passed in reached the executor untouched.
    expect(identical(seen!.inputs, inputs), isTrue);
    expect(seen!.inputs.get<String>('text'), 'forward me');
    expect(seen!.id, 'child_v1');
  });

  test('version and depthDelta named args marshal through to the primitive',
      () async {
    ProcedureCall? seen;
    final primitive = RunProcedurePrimitive(
      executor: (call) async {
        seen = call;
        return ProcedureResult.succeeded();
      },
    );
    final host = hostFor(primitive);

    await host.run(
      '''
import '$engineNativeLibrary';

run(inputs) async {
  await runProcedure('child_v1', inputs, version: 2, depthDelta: 3);
}
''',
      inputs: <Object?>[ProcedureInputs.empty()],
    );

    expect(seen!.version, 2);
    expect(seen!.depth, 4); // startDepth 1 + depthDelta 3
  });

  test('RecursionLimitExceeded propagates out of a script call', () async {
    // startDepth at the cap → the script's runProcedure is over the line.
    final primitive = RunProcedurePrimitive(
      executor: (call) async => ProcedureResult.succeeded(),
      startDepth: RunProcedurePrimitive.defaultHardDepthCap,
    );
    final host = hostFor(primitive);

    await expectLater(
      host.run(
        '''
import '$engineNativeLibrary';

run(inputs) async {
  await runProcedure('over_cap_v1', inputs);
}
''',
        inputs: <Object?>[ProcedureInputs.empty()],
      ),
      throwsA(isA<RecursionLimitExceeded>()),
    );
  });
}

// ── Bridge doubles (only to satisfy the host constructor) ────────────

class _StubMemoryClient implements TomBrainMemoryClient {
  _StubMemoryClient(this._stacks);
  final _StubStackApi _stacks;

  @override
  StackApi get stacks => _stacks;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _StubStackApi implements StackApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _StubSubstrateClient implements TomBrainSubstrateClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
