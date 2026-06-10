// ProcessRunToolSurface — the real, allow-listed process surface the engine
// binds over the `analyze.*` / `test.*` tools (completion-plan item 2;
// `creation_specification.md` § 5.2, § 5.3, § 5.4).
//
// What this suite locks:
//
//   PR-1  an allow-listed executable (`dart --version`) runs to completion and
//         the captured streams + exit code come back as a value.
//   PR-2  an executable off the fixed allow-list is refused with
//         `ProcessExecutableNotAllowed` *before* any process is spawned — the
//         "no general shell" guarantee (§ 5.4) is structural, not a convention.
//   PR-3  the allow-list is exactly the executables the shipped process tools
//         name (`dart`, `testkit`, `tom`).

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  group('PR-1 an allow-listed executable runs', () {
    test('dart --version returns a result with the version on a stream',
        () async {
      const surface = ProcessRunToolSurface();

      final result = await surface.run('dart', const <String>['--version']);

      expect(result.exitCode, 0);
      expect(result.ok, isTrue);
      // `dart --version` prints the banner to stderr on most SDKs and stdout on
      // others; assert the word lands on one of the captured streams.
      expect('${result.stdout}${result.stderr}'.toLowerCase(),
          contains('dart'));
    });
  });

  group('PR-2 an off-list executable is refused before spawning', () {
    test('a non-allow-listed executable raises ProcessExecutableNotAllowed',
        () async {
      const surface = ProcessRunToolSurface();

      await expectLater(
        surface.run('sh', const <String>['-c', 'echo nope']),
        throwsA(isA<ProcessExecutableNotAllowed>()
            .having((e) => e.executable, 'executable', 'sh')
            .having((e) => e.allowed, 'allowed',
                ProcessRunToolSurface.allowedExecutables)),
      );
    });
  });

  group('PR-3 the allow-list matches the shipped process tools', () {
    test('the allowed set is exactly {dart, testkit, tom}', () {
      expect(ProcessRunToolSurface.allowedExecutables,
          <String>{'dart', 'testkit', 'tom'});
    });
  });
}
