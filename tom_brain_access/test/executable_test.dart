// E.45 executable contract test.
//
// Drives the access-prototype entry point black-box: the `ToolDefinition`
// shape, the executor map, and the end-to-end `ToolRunner` dispatch for
// `--version`, `--help`, the default `serve` command (bare invocation), and
// `--config` plumbing. The same surface `bin/tom_brain_access.dart`
// wires is exercised here — `main` is a three-line shim over these symbols, so
// testing them is testing the executable.
//
// The standalone binary uses the default `unsupportedBrainProvisioner` (it may
// not import substrate / memory — `dependency_surface_test.dart`), so a bare
// `serve` cannot boot a cognition: it reports the boundary honestly and exits
// with a failure, without crashing the tool framework (Q-E.45.1). The contract
// this test locks is therefore: the entry point parses correctly, reports
// version/help, routes a bare invocation to the honest refusal, and threads
// `--config` through to the provisioner (proven with a capturing provisioner
// that records the loaded `AccessConfig` then refuses). The full serve path —
// the live socket, the channel edges, graceful shutdown — is proven in
// `boot/brain_access_process_test.dart` with injected seams.

import 'dart:async';
import 'dart:io';

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_build_base/tom_build_base_v2.dart';
import 'package:test/test.dart';

/// The minimum viable whole-process YAML (only the required `access:` keys),
/// with a distinctive port so config threading can be asserted.
const String _minimalConfig = '''
access:
  openai:
    port: 9090
  rateLimit:
    capacity: 10
    refillTokens: 5
    refillPeriodSeconds: 30
  quota:
    dailyCap: 100
''';

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

CliArgs _cliArgs(List<String> args) =>
    CliArgParser(toolDefinition: accessPrototypeTool).parse(args);

void main() {
  group('E.45 tool definition shape', () {
    test('identity, version, and mode', () {
      expect(accessPrototypeTool.name, 'tom_brain_access');
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

  group('E.45 executor map', () {
    test('exposes a single serve executor', () {
      final executors = createAccessPrototypeExecutors();
      expect(executors.keys, equals({accessServeCommandName}));
      expect(executors[accessServeCommandName], isA<AccessServeExecutor>());
    });

    test('the default (standalone) serve executor refuses: no brain is wired',
        () async {
      final executor = AccessServeExecutor();
      // A non-traversal executor's contract entry point is
      // executeWithoutTraversal. With the default unsupported provisioner it
      // returns failure (it cannot boot substrate + memory), not a throw.
      final printBuffer = StringBuffer();
      final result = await runZoned(
        () => executor.executeWithoutTraversal(_cliArgs(const [])),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printBuffer.writeln(line),
        ),
      );

      expect(result.success, isFalse);
      expect(printBuffer.toString(), contains('no brain is wired'));
    });
  });

  group('E.45 end-to-end dispatch', () {
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

    test('bare invocation routes to the honest refusal (no brain wired)',
        () async {
      final outcome = await _run(const []);
      // The standalone binary cannot serve: the run reports failure.
      expect(outcome.result.success, isFalse);
      expect(outcome.printedOutput, contains('no brain is wired'));
    });

    test('an unknown command fails loudly', () async {
      final outcome = await _run([':bogus']);
      expect(outcome.result.success, isFalse);
    });
  });

  group('E.45 --config threading', () {
    test('a --config file is loaded and threaded to the provisioner',
        () async {
      final tempDir = Directory.systemTemp.createTempSync('e45_config_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final configFile = File('${tempDir.path}/access.yaml')
        ..writeAsStringSync(_minimalConfig);

      // A capturing provisioner records the loaded config, then refuses — so
      // the executor returns a clean failure while we observe the threading.
      AccessConfig? seen;
      Future<ProvisionedBrain> capturing(AccessConfig config) async {
        seen = config;
        throw const BrainProvisioningException('captured; refusing to serve');
      }

      final executor = AccessServeExecutor(provisioner: capturing);
      final result = await runZoned(
        () => executor.executeWithoutTraversal(
          _cliArgs(['--config=${configFile.path}']),
        ),
        zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}),
      );

      expect(result.success, isFalse);
      // The YAML's required access section roundtripped into the config the
      // provisioner received.
      expect(seen, isNotNull);
      expect(seen!.openAiPort, 9090);
    });
  });
}
