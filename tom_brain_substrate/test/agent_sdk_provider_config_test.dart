// Agent-SDK provider config surface (agent-SDK design spec § 1.2 / § 1.3 /
// § 1.5). Phase 1: the substrate-level config additions that make the run-layer
// `AgentSdkLlmProvider` configurable —
//
//   * `ProviderKind.agentSdk` + the loader's `agent_sdk` string;
//   * `ProviderProfile.options` (a generic passthrough bag) + the loader's
//     deep-converting `options:` parse;
//   * the agent-SDK provider's exemption from `baseUrl` (bridge host/port live
//     in `options`) and its rejection of substrate-side `auth` (the bridge owns
//     the Anthropic credential);
//   * `LlmOptions.sessionId`, the per-call seam that carries the live
//     tom_brain session id to the provider for `sessionMode: brain`.

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('agent_sdk provider config — loader', () {
    test('parses kind agent_sdk with no baseUrl and an options bag', () {
      final cfg = SubstrateConfigLoader.parse(_agentSdkYaml);

      final provider = cfg.providers.first;
      expect(provider.id, equals('claude-sonnet-quest'));
      expect(provider.kind, equals(ProviderKind.agentSdk));
      // The bridge host/port ride in options, never in baseUrl.
      expect(provider.baseUrl, isNull);
      expect(provider.auth.isNone, isTrue);
      expect(provider.models, equals(<String>['claude-sonnet-4-6']));
    });

    test('options is a deep-converted plain-Dart passthrough', () {
      final cfg = SubstrateConfigLoader.parse(_agentSdkYaml);
      final options = cfg.providers.first.options;

      expect(options['bridgeHost'], equals('127.0.0.1'));
      expect(options['bridgePort'], equals(19900));
      expect(options['sessionMode'], equals('quest'));
      expect(options['maxTurns'], equals(24));
      expect(options['questId'], equals('tom_brain'));

      // Nested list survives as a plain List<Object?>.
      final mcpServers = options['mcpServers'];
      expect(mcpServers, isA<List<Object?>>());
      expect(mcpServers, equals(<Object?>['vscode_ext']));
    });

    test('absent options defaults to the empty map', () {
      final cfg = SubstrateConfigLoader.parse(_agentSdkNoOptionsYaml);
      expect(cfg.providers.first.options, isEmpty);
    });

    test('agent_sdk with declared auth is rejected', () {
      expect(
        () => SubstrateConfigLoader.parse(_agentSdkWithAuthYaml),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('agentSdk'),
          ),
        ),
      );
    });

    test('agent_sdk still requires at least one model', () {
      expect(
        () => SubstrateConfigLoader.parse(_agentSdkNoModelsYaml),
        throwsA(isA<SubstrateConfigException>()),
      );
    });
  });

  group('LlmOptions.sessionId', () {
    test('defaults to null', () {
      expect(const LlmOptions().sessionId, isNull);
      expect(LlmOptions.empty.sessionId, isNull);
    });

    test('copyWith sets, preserves, and clears it', () {
      const base = LlmOptions(sessionId: 'sess-1');
      expect(base.sessionId, equals('sess-1'));

      // Omitting the parameter preserves the existing value.
      expect(base.copyWith(temperature: 0.5).sessionId, equals('sess-1'));

      // Passing a new value replaces it.
      expect(base.copyWith(sessionId: 'sess-2').sessionId, equals('sess-2'));

      // Passing null explicitly clears it.
      expect(base.copyWith(sessionId: null).sessionId, isNull);
    });
  });
}

const String _agentSdkYaml = '''
substrate:
  providers:
    - id: claude-sonnet-quest
      kind: agent_sdk
      models:
        - claude-sonnet-4-6
      options:
        bridgeHost: 127.0.0.1
        bridgePort: 19900
        sessionMode: quest
        maxTurns: 24
        questId: tom_brain
        mcpServers:
          - vscode_ext
    - id: emb
      kind: ollama
      baseUrl: http://localhost:11434
      models:
        - nomic-embed-text
  roleRoutes:
    assistant_to_user:
      - providerId: claude-sonnet-quest
        model: claude-sonnet-4-6
  embedding:
    providerId: emb
    model: nomic-embed-text
    dims: 768
    normalize: true
''';

const String _agentSdkNoOptionsYaml = '''
substrate:
  providers:
    - id: claude-sonnet
      kind: agent_sdk
      models:
        - claude-sonnet-4-6
    - id: emb
      kind: ollama
      baseUrl: http://localhost:11434
      models:
        - nomic-embed-text
  roleRoutes:
    assistant_to_user:
      - providerId: claude-sonnet
        model: claude-sonnet-4-6
  embedding:
    providerId: emb
    model: nomic-embed-text
    dims: 768
    normalize: true
''';

const String _agentSdkWithAuthYaml = '''
substrate:
  providers:
    - id: claude-sonnet
      kind: agent_sdk
      models:
        - claude-sonnet-4-6
      auth:
        method: api_key
        token: should-not-be-here
    - id: emb
      kind: ollama
      baseUrl: http://localhost:11434
      models:
        - nomic-embed-text
  roleRoutes:
    assistant_to_user:
      - providerId: claude-sonnet
        model: claude-sonnet-4-6
  embedding:
    providerId: emb
    model: nomic-embed-text
    dims: 768
    normalize: true
''';

const String _agentSdkNoModelsYaml = '''
substrate:
  providers:
    - id: claude-sonnet
      kind: agent_sdk
    - id: emb
      kind: ollama
      baseUrl: http://localhost:11434
      models:
        - nomic-embed-text
  roleRoutes:
    assistant_to_user:
      - providerId: emb
        model: nomic-embed-text
  embedding:
    providerId: emb
    model: nomic-embed-text
    dims: 768
    normalize: true
''';
