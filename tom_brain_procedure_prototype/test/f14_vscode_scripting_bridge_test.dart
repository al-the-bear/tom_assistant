// Extension F step 14 — the VS Code Scripting API as a bridged primitive
// (`tom_brain_procedure_prototype_specification.md` § 21.9, § 6, § 21.10;
// `prototype_tools_mcp_extension_plan.md` step 14).
//
// `VsCodeScriptingBridge` is a plain Dart class bridged exactly like
// `MemoryBridge` / `SubstrateBridge` / `ToolBridge` / `McpBridge`: `build.yaml`
// lists its source file under the `all` module's `barrelFiles`,
// `tom_d4rt_generator` emits the bridge, and `BrainBridges.register` registers
// it under [BrainBridges.vscodeScriptingLibrary]. It exposes one d4rt-facing
// method — `vscode.call(api, method, args)` — over a narrow
// [VsCodeScriptingSurface] port (the prototype stays decoupled from
// `tom_vscode_scripting_api`, PE-10; the concrete socket adapter is built at
// colocation wiring) and the run's [BudgetLedger].
//
// Distinct from § 21.8's *tools* path (which merges the extension's *tools*
// into the `ToolRegistry`): this exposes the *scripting API surface itself* as
// a bridged primitive a procedure calls directly.
//
// The bridge reaches a script only when the host's `enableVsCodeIntegration`
// switch is on and the matching `installVsCodeIntegration` installer is
// supplied (the two-switch installer-seam model, § 6). Absent colocation the
// switch stays off and the bridge is absent; an on-switch with no installer is
// refused loudly at construction.
//
// What this suite locks:
//
//   F.14-1  — the catalog knows `vscode.call`, with the dotted→camel call
//             tokens, so a colocated procedure may declare it in `requires`.
//   F.14-2  — the effort accountant scores `vscode.call` as one toolCall (so
//             the budget gate can pre-charge it, PE-8).
//   F.14-3  — call happy path: {ok: true, result}; the surface received
//             (api, method, args); one toolCall charged.
//   F.14-4  — a surface failure returns {ok: false, error} and still charges
//             the call (counts the call — PE-6 environmental, not a fallback).
//   F.14-5  — budget pre-charge refuses a call over the toolCalls cap with
//             ProcedureBudgetExceeded, before the surface is touched.
//   F.14-6  — a d4rt script calls vscode.call through the interpreter (the
//             generator-output round-trip).
//   F.14-7  — switch on + the real `installVsCodeIntegration` installer: a
//             script reaches the `vscode` global and calls one scripting-API
//             method (the Test-clause "switch on + installer" path).
//   F.14-8  — switch on + no installer → loud StateError at construction (the
//             installer-seam refusal test, § 6).
//   F.14-9  — switch off (locked) → the bridge is absent: a script referencing
//             `vscode` fails because the global was never injected.
//   F.14-10 — the generated `AllBridge` exposes `VsCodeScriptingBridge` with
//             its canonical source URI and its `call` method.

import 'package:test/test.dart';
import 'package:tom_d4rt/d4rt.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart' show EffortMetrics;
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show StackApi, TomBrainMemoryClient;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show TomBrainSubstrateClient;

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:tom_brain_procedure_prototype/src/bridges/brain_bridges.b.dart';

void main() {
  group('F.14-1 catalog membership', () {
    test('vscode.call is a recognised bridged primitive', () {
      expect(BridgedPrimitiveCatalog.isKnown('vscode.call'), isTrue);
      expect(BridgedPrimitiveCatalog.all, contains('vscode.call'));
    });

    test('the dotted call token carries its camelCase spelling', () {
      expect(
        BridgedPrimitiveCatalog.callTokensFor('vscode.call'),
        <String>{'vscode.call', 'vscodeCall'},
      );
    });
  });

  group('F.14-2 effort accounting', () {
    const accountant = EffortAccountant();

    test('vscode.call scores one toolCall (dotted and camel spelling)', () {
      expect(accountant.classify('vscode.call').toolCalls, 1);
      expect(accountant.classify('vscodeCall').toolCalls, 1);
    });
  });

  group('F.14-3 call — happy path', () {
    test('a call returns {ok: true, result}, forwards args, charges 1',
        () async {
      final ledger = _ledger(toolCalls: 1);
      final surface = _StubScriptingSurface(result: 'shown');
      final bridge = VsCodeScriptingBridge(surface, ledger);

      final result = await bridge.call(
        'window',
        'showInformationMessage',
        const <Object?>['hi'],
      );

      expect(result['ok'], isTrue);
      expect(result['result'], 'shown');
      expect(surface.lastApi, 'window');
      expect(surface.lastMethod, 'showInformationMessage');
      expect(surface.lastArgs, const <Object?>['hi']);
      expect(ledger.consumed.toolCalls, 1,
          reason: 'a scripting-API call charges one toolCall (PE-8)');
    });
  });

  group('F.14-4 call — surface failure (PE-6)', () {
    test('a surface failure returns {ok: false, error} and charges the call',
        () async {
      final ledger = _ledger(toolCalls: 2);
      final surface = _StubScriptingSurface(
        failure: const VsCodeScriptingFailure('the extension is not reachable'),
      );
      final bridge = VsCodeScriptingBridge(surface, ledger);

      final result =
          await bridge.call('window', 'showInformationMessage', const <Object?>[]);

      expect(result['ok'], isFalse);
      expect(result['error'], isA<String>());
      expect((result['error'] as String), contains('not reachable'));
      expect(ledger.consumed.toolCalls, 1,
          reason: 'an attempted-but-failed call still counts (§ 21.10)');
    });
  });

  group('F.14-5 call — budget pre-charge (PE-8)', () {
    test('a call over the toolCalls cap is refused before the surface is hit',
        () async {
      final ledger = _ledger(toolCalls: 1);
      final surface = _StubScriptingSurface(result: 'ok');
      final bridge = VsCodeScriptingBridge(surface, ledger);

      final first = await bridge.call('commands', 'executeCommand',
          const <Object?>['tom.first']);
      expect(first['ok'], isTrue);
      expect(ledger.consumed.toolCalls, 1);

      final before = surface.callCount;
      await expectLater(
        bridge.call('commands', 'executeCommand', const <Object?>['tom.second']),
        throwsA(isA<ProcedureBudgetExceeded>()),
      );
      expect(surface.callCount, before,
          reason: 'the refused call never reaches the surface (pre-charge gate)');
    });
  });

  group('F.14-6 d4rt round-trip through the interpreter', () {
    test('a script calls vscode.call on the natively-constructed bridge',
        () async {
      final surface = _StubScriptingSurface(result: 'streamed');
      final bridge = VsCodeScriptingBridge(surface, _ledger());
      final interpreter = D4rt();
      BrainBridges.register(interpreter);

      final result = await interpreter.execute(
        source: '''
import '${BrainBridges.vscodeScriptingLibrary}';

Future<Map<String, Object?>> main(VsCodeScriptingBridge vscode) async {
  return await vscode.call('window', 'showInformationMessage', ['from script']);
}
''',
        positionalArgs: <Object?>[bridge],
      );

      final out = (result as Map).cast<String, Object?>();
      expect(out['ok'], isTrue);
      expect(out['result'], 'streamed');
      expect(surface.lastArgs, const <Object?>['from script']);
    });
  });

  group('F.14-7 host installer — switch on + installVsCodeIntegration', () {
    test('the installer injects the `vscode` global and a script reaches it',
        () async {
      final surface = _StubScriptingSurface(result: 'wired');
      final bridge = VsCodeScriptingBridge(surface, _ledger());
      final host = D4rtDcliHost(
        memoryBridge: MemoryBridge(_StubMemoryClient(_StubStackApi())),
        substrateBridge: SubstrateBridge(_StubSubstrateClient()),
        sandbox: const SandboxConfig(enableVsCodeIntegration: true),
        installVsCodeIntegration: vsCodeScriptingInstaller(bridge),
      );

      final result = await host.run(
        '''
import '${BrainBridges.vscodeScriptingLibrary}';

Future<Object?> run(Object? inputs) async {
  final r = await vscode.call('window', 'showInformationMessage', ['hello']);
  return r['result'];
}
''',
        inputs: const <Object?>[null],
      );

      expect(result, 'wired');
      expect(surface.lastApi, 'window');
    });
  });

  group('F.14-8 installer-seam refusal — switch on + no installer', () {
    test('enabling VS Code integration without its installer throws at '
        'construction', () {
      expect(
        () => D4rtDcliHost(
          memoryBridge: MemoryBridge(_StubMemoryClient(_StubStackApi())),
          substrateBridge: SubstrateBridge(_StubSubstrateClient()),
          sandbox: const SandboxConfig(enableVsCodeIntegration: true),
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('enableVsCodeIntegration'),
            contains('installVsCodeIntegration'),
          ),
        )),
      );
    });
  });

  group('F.14-9 switch off — the bridge is absent', () {
    test('a locked host never injects `vscode`; a script referencing it fails',
        () async {
      final host = D4rtDcliHost(
        memoryBridge: MemoryBridge(_StubMemoryClient(_StubStackApi())),
        substrateBridge: SubstrateBridge(_StubSubstrateClient()),
        // SandboxConfig.locked default — VS Code integration off.
      );

      await expectLater(
        host.run(
          '''
import '${BrainBridges.vscodeScriptingLibrary}';

Future<Object?> run(Object? inputs) async {
  return await vscode.call('window', 'showInformationMessage', []);
}
''',
          inputs: const <Object?>[null],
        ),
        throwsA(anything),
        reason: 'the `vscode` global is only injected by the installer, which '
            'a locked host never runs',
      );
    });
  });

  group('F.14-10 generated bridge structure', () {
    test('AllBridge exposes VsCodeScriptingBridge with its source URI + method',
        () {
      final names = AllBridge.bridgeClasses().map((b) => b.name).toSet();
      expect(names, contains('VsCodeScriptingBridge'));

      expect(
        AllBridge.classSourceUris()['VsCodeScriptingBridge'],
        'package:tom_brain_procedure_prototype/src/bridges/'
            'vscode_scripting_bridge.dart',
      );

      final bridge = AllBridge.bridgeClasses()
          .firstWhere((b) => b.name == 'VsCodeScriptingBridge');
      expect(bridge.methods.keys, contains('call'));
    });
  });
}

// ── helpers ──────────────────────────────────────────────────────────

/// A ledger over a budget that caps [toolCalls] (or no cap when omitted).
BudgetLedger _ledger({int? toolCalls}) =>
    BudgetLedger(ProcedureBudget(<String, int>{'toolCalls': ?toolCalls}));

/// A stub [VsCodeScriptingSurface]: records the last invocation and returns a
/// canned result, or raises a [VsCodeScriptingFailure] to simulate an
/// unreachable extension.
final class _StubScriptingSurface implements VsCodeScriptingSurface {
  _StubScriptingSurface({this.result, this.failure});

  final Object? result;
  final VsCodeScriptingFailure? failure;

  int callCount = 0;
  String? lastApi;
  String? lastMethod;
  List<Object?>? lastArgs;

  @override
  Future<Object?> invoke(String api, String method, List<Object?> args) async {
    callCount++;
    lastApi = api;
    lastMethod = method;
    lastArgs = args;
    final f = failure;
    if (f != null) throw f;
    return result;
  }
}

/// Minimal `TomBrainMemoryClient` — the host scripts never touch memory; the
/// bridge only needs a non-null client to construct.
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

// EffortMetrics is referenced indirectly via the accountant tests above; the
// import keeps the symbol available for readers extending this suite.
// ignore: unused_element
EffortMetrics get _zero => EffortMetrics.zero;
