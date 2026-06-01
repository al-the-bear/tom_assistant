// C.17 — Sandbox configuration tests.
//
// Plan step C.17: "Sandbox configuration: enable Unix-style commands and
// VS Code integration only when the dispatcher explicitly opts in. For
// the prototype's `answer_with_memory_v1` script, both are disabled."
//
// Two things are proven here:
//
//   1. `SandboxConfig` value semantics — the two switches, their
//      defaults (both off), `locked()`, `copyWith`, equality, `isLocked`.
//   2. `D4rtDcliHost` opt-in behaviour:
//      - The default host runs under `SandboxConfig.locked`; neither
//        surface installer runs (the prototype's posture).
//      - Enabling a switch runs its installer against the *host's*
//        interpreter — and an enabled switch makes the surface the
//        installer registers reachable from a script.
//      - Enabling a switch without supplying its installer is refused
//        loudly at construction (StateError) rather than booting a
//        switch that is on but grants nothing.
//      - The two switches are independent.

import 'package:test/test.dart';
import 'package:tom_d4rt/d4rt.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

void main() {
  group('C.17 SandboxConfig value semantics', () {
    test('default constructor disables both surfaces', () {
      const cfg = SandboxConfig();
      expect(cfg.enableUnixCommands, isFalse);
      expect(cfg.enableVsCodeIntegration, isFalse);
      expect(cfg.isLocked, isTrue);
    });

    test('locked() is the all-off configuration', () {
      const locked = SandboxConfig.locked();
      expect(locked.enableUnixCommands, isFalse);
      expect(locked.enableVsCodeIntegration, isFalse);
      expect(locked.isLocked, isTrue);
      expect(locked, const SandboxConfig());
    });

    test('isLocked is false once any switch is on', () {
      expect(const SandboxConfig(enableUnixCommands: true).isLocked, isFalse);
      expect(
        const SandboxConfig(enableVsCodeIntegration: true).isLocked,
        isFalse,
      );
    });

    test('copyWith overrides only the named switch', () {
      const base = SandboxConfig.locked();
      final unix = base.copyWith(enableUnixCommands: true);
      expect(unix.enableUnixCommands, isTrue);
      expect(unix.enableVsCodeIntegration, isFalse);

      final both = unix.copyWith(enableVsCodeIntegration: true);
      expect(both.enableUnixCommands, isTrue);
      expect(both.enableVsCodeIntegration, isTrue);
    });

    test('equality + hashCode are value based', () {
      const a = SandboxConfig(enableUnixCommands: true);
      const b = SandboxConfig(enableUnixCommands: true);
      const c = SandboxConfig(enableVsCodeIntegration: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('toString names both switches', () {
      expect(
        const SandboxConfig(enableUnixCommands: true).toString(),
        contains('enableUnixCommands: true'),
      );
    });
  });

  group('C.17 host opt-in behaviour', () {
    late MemoryBridge memoryBridge;
    late SubstrateBridge substrateBridge;

    setUp(() {
      memoryBridge = MemoryBridge(_StubMemoryClient(_StubStackApi()));
      substrateBridge = SubstrateBridge(_StubSubstrateClient());
    });

    D4rtDcliHost makeHost({
      SandboxConfig sandbox = const SandboxConfig.locked(),
      SandboxSurfaceInstaller? installUnixCommands,
      SandboxSurfaceInstaller? installVsCodeIntegration,
    }) =>
        D4rtDcliHost(
          memoryBridge: memoryBridge,
          substrateBridge: substrateBridge,
          sandbox: sandbox,
          installUnixCommands: installUnixCommands,
          installVsCodeIntegration: installVsCodeIntegration,
        );

    test('default host is locked — neither installer runs', () {
      var unixRan = false;
      var vscodeRan = false;
      final host = makeHost(
        installUnixCommands: (_) => unixRan = true,
        installVsCodeIntegration: (_) => vscodeRan = true,
      );

      // The default config is locked, so the supplied installers stay
      // dormant — the prototype's `answer_with_memory_v1` posture.
      expect(host.sandbox, const SandboxConfig.locked());
      expect(unixRan, isFalse);
      expect(vscodeRan, isFalse);
    });

    test('enabling Unix commands runs that installer against the host '
        'interpreter', () {
      D4rt? seen;
      final host = makeHost(
        sandbox: const SandboxConfig(enableUnixCommands: true),
        installUnixCommands: (d4rt) => seen = d4rt,
      );
      expect(identical(seen, host.interpreter), isTrue);
    });

    test('enabling VS Code integration runs that installer against the host '
        'interpreter', () {
      D4rt? seen;
      final host = makeHost(
        sandbox: const SandboxConfig(enableVsCodeIntegration: true),
        installVsCodeIntegration: (d4rt) => seen = d4rt,
      );
      expect(identical(seen, host.interpreter), isTrue);
    });

    test('an enabled surface becomes reachable from a script', () async {
      // The installer registers a global under a synthetic library; a
      // script importing it can read the value — proving the opt-in
      // genuinely widens what a procedure can touch, not just a flag.
      const surfaceLibrary = 'package:zz_sandbox_surface/unix.dart';
      final host = makeHost(
        sandbox: const SandboxConfig(enableUnixCommands: true),
        installUnixCommands: (d4rt) =>
            d4rt.registerGlobalVariable('unixReach', 7, surfaceLibrary),
      );

      final result = await host.run('''
import '$surfaceLibrary';

int run() => unixReach;
''');
      expect(result, 7);
    });

    test('enabling Unix commands without its installer throws at '
        'construction', () {
      expect(
        () => makeHost(
          sandbox: const SandboxConfig(enableUnixCommands: true),
        ),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('enableUnixCommands'), contains('installUnixCommands')),
        )),
      );
    });

    test('enabling VS Code integration without its installer throws at '
        'construction', () {
      expect(
        () => makeHost(
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

    test('the two switches are independent — one installer can be absent '
        'when its switch is off', () {
      var unixRan = false;
      // VS Code off + no installer is fine; Unix on + installer present.
      final host = makeHost(
        sandbox: const SandboxConfig(enableUnixCommands: true),
        installUnixCommands: (_) => unixRan = true,
      );
      expect(unixRan, isTrue);
      expect(host.sandbox.enableVsCodeIntegration, isFalse);
    });

    test('both switches on run both installers', () {
      var unixRan = false;
      var vscodeRan = false;
      makeHost(
        sandbox: const SandboxConfig(
          enableUnixCommands: true,
          enableVsCodeIntegration: true,
        ),
        installUnixCommands: (_) => unixRan = true,
        installVsCodeIntegration: (_) => vscodeRan = true,
      );
      expect(unixRan, isTrue);
      expect(vscodeRan, isTrue);
    });
  });
}

/// Minimal `TomBrainMemoryClient` stub — the C.17 host scripts never
/// touch memory; the bridge only needs a non-null client to construct.
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
