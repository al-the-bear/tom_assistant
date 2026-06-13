// r44 — `/cli_server_port <port>` (CliServerPortConfigWriter +
// TomBrainCliServerPortController). Proves the run-config persistence
// (comment-preserving, every `agent_sdk` provider's `options.bridgePort`
// rewritten) and the controller's validation / rebind / outcome rendering,
// without a live VS Code bridge.

import 'dart:io';

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';

/// A minimal run-config with two `agent_sdk` providers (on the old port) plus
/// one non-agent provider, with comments that must survive the rewrite.
const _config = '''
# brain_run config — head comment must survive.
substrate:
  providers:
    - id: omlx
      kind: openai
      models: [gemma]
    - id: claude:haiku:none
      kind: agent_sdk # provider comment
      models: [claude-haiku]
      options:
        bridgeHost: 127.0.0.1
        bridgePort: 19900
    - id: claude:sonnet:none
      kind: agent_sdk
      models: [claude-sonnet]
      options:
        bridgeHost: 127.0.0.1
        bridgePort: 19900
''';

/// An agent-SDK provider whose factory is never invoked (no completion is run),
/// so a rebind only flips the recorded port — no bridge dependency.
AgentSdkLlmProvider _provider(String id) => AgentSdkLlmProvider(
      id: id,
      defaultModel: 'm',
      bridgePort: 19900,
      clientFactory: (port) async =>
          throw StateError('factory should not be called in this test'),
    );

void main() {
  group('CliServerPortConfigWriter', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('cli_server_port_');
      file = File('${dir.path}/brain_run.yaml')..writeAsStringSync(_config);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('rewrites every agent_sdk provider bridgePort, preserving comments',
        () {
      final changed = CliServerPortConfigWriter(file).apply(20000);
      expect(changed, 2);

      final rewritten = file.readAsStringSync();
      expect(rewritten, contains('# brain_run config — head comment must survive.'));
      expect(rewritten, contains('# provider comment'));
      expect(rewritten, contains('bridgePort: 20000'));
      expect(rewritten, isNot(contains('bridgePort: 19900')));
      // The non-agent provider is untouched.
      expect(rewritten, contains('id: omlx'));
    });

    test('throws when the file is missing', () {
      final missing = File('${dir.path}/nope.yaml');
      expect(
        () => CliServerPortConfigWriter(missing).apply(20000),
        throwsA(isA<CliServerPortWriteException>()),
      );
    });

    test('throws when there is no agent_sdk provider to change', () {
      final f = File('${dir.path}/no_agent.yaml')
        ..writeAsStringSync('substrate:\n  providers:\n    - id: omlx\n'
            '      kind: openai\n      models: [gemma]\n');
      expect(
        () => CliServerPortConfigWriter(f).apply(20000),
        throwsA(isA<CliServerPortWriteException>()),
      );
    });
  });

  group('TomBrainCliServerPortController', () {
    test('rejects an out-of-range port without touching providers', () async {
      final p = _provider('claude:haiku:none');
      final controller = TomBrainCliServerPortController(providers: [p]);
      final out = await controller.setCliServerPort(port: 70000);
      expect(out, contains('out of range'));
      // Port unchanged — nothing was rebound.
      expect(p.bridgePort, 19900);
    });

    test('rebinds the live providers and reports the count (no writer)',
        () async {
      final a = _provider('claude:haiku:none');
      final b = _provider('claude:sonnet:none');
      final controller =
          TomBrainCliServerPortController(providers: [a, b]);

      final out = await controller.setCliServerPort(port: 20000);
      expect(a.bridgePort, 20000);
      expect(b.bridgePort, 20000);
      expect(out, contains('20000'));
      expect(out, contains('2 of 2'));
      expect(out, contains('not persisted'));
    });

    test('persists through the writer and reports it survives a restart',
        () async {
      final dir = Directory.systemTemp.createTempSync('cli_server_port_ctl_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/brain_run.yaml')
        ..writeAsStringSync(_config);

      final a = _provider('claude:haiku:none');
      final controller = TomBrainCliServerPortController(
        providers: [a],
        configWriter: CliServerPortConfigWriter(file),
      );

      final out = await controller.setCliServerPort(port: 21000);
      expect(a.bridgePort, 21000);
      expect(out, contains('persisted'));
      expect(out, contains('survives a restart'));
      expect(file.readAsStringSync(), contains('bridgePort: 21000'));
    });

    test('renders the no-providers case', () async {
      final controller =
          TomBrainCliServerPortController(providers: const []);
      final out = await controller.setCliServerPort(port: 20000);
      expect(out, contains('no live agent-SDK providers'));
    });
  });
}
