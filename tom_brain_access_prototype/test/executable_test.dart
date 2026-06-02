// E.9 executable contract test.
//
// Drives the access-prototype entry point black-box: the `ToolDefinition`
// shape, the executor map, and the end-to-end `ToolRunner` dispatch for
// `--version`, `--help`, the default `serve` command (bare invocation),
// and `--config` plumbing. The same surface `bin/tom_brain_access_prototype
// .dart` wires is exercised here — `main` is a three-line shim over these
// symbols, so testing them is testing the executable.
//
// At E.9 the `serve` command is a not-yet-wired stub (boot lands at
// E.41–E.45). The contract this test locks is therefore: the entry point
// parses correctly, reports version/help, routes a bare invocation to the
// `serve` stub, and threads `--config` through to the executor — nothing
// is actually served yet.

import 'dart:async';

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_build_base/tom_build_base_v2.dart';
import 'package:test/test.dart';

/// Outcome of driving the tool through a `ToolRunner`.
class _RunOutcome {
  final ToolResult result;

  /// What the framework wrote to its injected output sink
  /// (`--version`, `--help`, error messages).
  final String frameworkOutput;

  /// What the `serve` executor wrote via `print` (the status banner).
  final String printedOutput;

  _RunOutcome(this.result, this.frameworkOutput, this.printedOutput);
}

/// Run the access-prototype tool with [args], capturing both the framework
/// output sink and any `print` output from the executor.
Future<_RunOutcome> _run(List<String> args) async {
  final frameworkBuffer = StringBuffer();
  final printBuffer = StringBuffer();

  final runner = ToolRunner(
    tool: accessPrototypeTool,
    executors: createAccessPrototypeExecutors(),
    verbose: false,
    output: frameworkBuffer,
  );

  final result = await runZoned(
    () => runner.run(args),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => printBuffer.writeln(line),
    ),
  );

  return _RunOutcome(result, frameworkBuffer.toString(), printBuffer.toString());
}

void main() {
  group('E.9 tool definition shape', () {
    test('identity, version, and mode', () {
      expect(accessPrototypeTool.name, 'tom_brain_access_prototype');
      expect(accessPrototypeTool.version, accessPrototypeVersion);
      expect(accessPrototypeTool.versionString, accessPrototypeVersionString);
      expect(accessPrototypeVersionString, contains(accessPrototypeVersion));
      expect(accessPrototypeTool.mode, ToolMode.multiCommand);
    });

    test('serve is the default, non-traversal command', () {
      expect(accessPrototypeTool.defaultCommand, accessServeCommandName);

      final serve = accessPrototypeTool.findCommand(accessServeCommandName);
      expect(serve, isNotNull);
      // The load-bearing flag: a server runs once, it does not traverse
      // projects. requiresTraversal=false is what routes the runner to
      // executeWithoutTraversal.
      expect(serve!.requiresTraversal, isFalse);
      expect(serve.supportsProjectTraversal, isFalse);
    });

    test('--config global option is declared', () {
      final config = accessPrototypeTool.globalOptions
          .where((o) => o.name == accessConfigOptionName)
          .toList();
      expect(config, hasLength(1));
      expect(config.single.type, OptionType.option);
      expect(config.single.abbr, 'c');
    });
  });

  group('E.9 executor map', () {
    test('exposes a single serve executor', () {
      final executors = createAccessPrototypeExecutors();
      expect(executors.keys, equals({accessServeCommandName}));
      expect(executors[accessServeCommandName], isA<AccessServeExecutor>());
    });

    test('serve executor is non-traversal (runs once, returns success)', () {
      final executor = AccessServeExecutor();
      // A non-traversal executor's contract entry point is
      // executeWithoutTraversal; it must return success for the stub.
      expect(
        runZoned(
          () => executor.executeWithoutTraversal(_emptyCliArgs()),
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, _) {}, // swallow banner
          ),
        ),
        completion(
          isA<ToolResult>()
              .having((r) => r.success, 'success', isTrue)
              .having((r) => r.processedCount, 'processedCount', 1),
        ),
      );
    });
  });

  group('E.9 end-to-end dispatch', () {
    test('--version prints the banner and succeeds', () async {
      final outcome = await _run(['--version']);
      expect(outcome.result.success, isTrue);
      expect(outcome.frameworkOutput, contains(accessPrototypeVersionString));
    });

    test('--help lists the serve command and the running-process footer',
        () async {
      final outcome = await _run(['--help']);
      expect(outcome.result.success, isTrue);
      expect(outcome.frameworkOutput, contains('serve'));
      expect(outcome.frameworkOutput, contains('Running the process'));
    });

    test('bare invocation routes to the serve stub', () async {
      final outcome = await _run(const []);
      expect(outcome.result.success, isTrue);
      expect(outcome.printedOutput, contains('entry-point scaffold'));
      // No --config supplied → defaults branch.
      expect(outcome.printedOutput, contains('none supplied'));
      // The stub must make clear nothing is actually served at E.9.
      expect(outcome.printedOutput, contains('not yet wired'));
    });

    test('--config is threaded through to the serve executor', () async {
      final outcome = await _run(['--config=access.yaml']);
      expect(outcome.result.success, isTrue);
      expect(outcome.printedOutput, contains('access.yaml'));
    });

    test('an unknown command fails loudly', () async {
      final outcome = await _run([':bogus']);
      expect(outcome.result.success, isFalse);
    });
  });
}

/// A minimal parsed-args object for direct executor calls.
CliArgs _emptyCliArgs() =>
    CliArgParser(toolDefinition: accessPrototypeTool).parse(const []);
