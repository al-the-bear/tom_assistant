// B.36 — `SubstrateConfigLoader` test suite.
//
// Covers:
//
//   * Happy-path YAML → typed `SubstrateConfig` round-trip for a
//     spec § 9 example that exercises every section.
//   * Per-section parser invariants (missing required keys, type
//     mismatches, empty lists, duplicate ids, kind-shape coupling).
//   * Cross-section validation (roleRoutes → providers refs,
//     embedding → providers refs, priceTable → providers refs,
//     webSearch.defaultProvider must be one of the providers).
//   * `${ENV}` substitution (success, missing var, empty token,
//     unterminated brace).
//   * MCP transport / auth coupling (stdio + bearer is rejected at
//     load time per the B.34 `McpAuthResolver` invariant; stdio +
//     `url:` rejected; http + `command:` rejected).
//   * `SubstrateConfig.buildRouterPolicy()` produces the expected
//     `RouterPolicy` shape (declaration order preserved; conditions
//     plumbed through).
//   * `SubstrateConfig.validateRoleRegistry` against the bootstrap
//     registry: every routed role is registered (happy path);
//     unregistered routed role is rejected (failure path).
//
// What this test does NOT cover:
//
//   * Loading from disk via `loadFromFile`. The file I/O wrapper
//     is trivially testable but adds disk dependence; the file
//     reader is exercised once in the round-trip block.
//   * Secret resolution. `secretRef:` strings are carried through
//     verbatim; the facade (B.40) reads them via the resolver layer.
//   * Construction of runtime providers / embedding services / web
//     tools. The loader produces typed values; runtime construction
//     is the facade's job.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.36 SubstrateConfigLoader.parse — happy path', () {
    test('parses a fully populated spec § 9 example', () {
      final cfg = SubstrateConfigLoader.parse(_fullYaml);

      // Providers: two entries in declaration order.
      expect(cfg.providers, hasLength(2));
      expect(cfg.providers[0].id, equals('local-ollama'));
      expect(cfg.providers[0].kind, equals(ProviderKind.ollama));
      expect(
        cfg.providers[0].baseUrl,
        equals(Uri.parse('http://localhost:11434')),
      );
      expect(cfg.providers[0].auth.isNone, isTrue);
      expect(cfg.providers[0].models, equals(['gemma3:27b', 'nomic-embed-text']));

      expect(cfg.providers[1].id, equals('openrouter'));
      expect(cfg.providers[1].kind, equals(ProviderKind.openai));
      expect(cfg.providers[1].auth.isApiKey, isTrue);
      expect(
        cfg.providers[1].auth.apiKeySecretRef,
        equals('_ai/secrets/openrouter.token'),
      );
      expect(cfg.providers[1].models, equals(['gpt-4o-mini']));

      // Routes: declaration order preserved per role.
      expect(cfg.roleRoutes.keys.toList(), equals(['analyser']));
      final analyser = cfg.roleRoutes['analyser']!;
      expect(analyser, hasLength(2));
      expect(analyser[0].providerId, equals('local-ollama'));
      expect(analyser[0].model, equals('gemma3:27b'));
      expect(analyser[0].conditions, isNull);
      expect(analyser[1].providerId, equals('openrouter'));
      expect(analyser[1].model, equals('gpt-4o-mini'));
      expect(analyser[1].conditions?.maxInputTokens, equals(8192));

      // Embedding.
      expect(cfg.embedding.providerId, equals('local-ollama'));
      expect(cfg.embedding.model, equals('nomic-embed-text'));
      expect(cfg.embedding.dims, equals(768));
      expect(cfg.embedding.normalize, isTrue);

      // Web search.
      expect(cfg.webSearch.defaultProvider, equals('duckduckgo'));
      expect(cfg.webSearch.providers.keys, contains('duckduckgo'));
      expect(
        cfg.webSearch.providers['duckduckgo']!.kind,
        equals('ddg_html'),
      );

      // Web fetch.
      expect(cfg.webFetch.defaultBudgetBytes, equals(524288));
      expect(cfg.webFetch.userAgent, contains('TomBrain/'));

      // MCP client.
      expect(cfg.mcpClient.endpoints.keys, equals(['memory']));
      final memEp = cfg.mcpClient.endpoints['memory']!;
      expect(memEp.transport, equals(McpTransportKind.http));
      expect(memEp.url, equals(Uri.parse('http://localhost:8731')));

      // Price table: lookup by helper.
      final price = cfg.lookupPrice('openrouter', 'gpt-4o-mini');
      expect(price, isNotNull);
      expect(price!.inputPerMTokens, equals(0.15));
      expect(price.outputPerMTokens, equals(0.6));
      expect(cfg.lookupPrice('missing', 'model'), isNull);

      // Helper: lookupProvider.
      expect(cfg.lookupProvider('local-ollama'), isNotNull);
      expect(cfg.lookupProvider('not-there'), isNull);
    });

    test('omits optional sections, defaults to spec § 9 defaults', () {
      final cfg = SubstrateConfigLoader.parse(_minimalYaml);
      // webSearch omitted → default DuckDuckGo block.
      expect(cfg.webSearch.defaultProvider, equals('duckduckgo'));
      expect(cfg.webSearch.providers, hasLength(1));
      // webFetch omitted → default budget + UA.
      expect(cfg.webFetch.defaultBudgetBytes, equals(262144));
      expect(cfg.webFetch.userAgent, contains('TomBrain/'));
      // mcpClient omitted → empty endpoint map.
      expect(cfg.mcpClient.endpoints, isEmpty);
      // priceTable omitted → empty.
      expect(cfg.priceTable, isEmpty);
      // embedding.normalize omitted → true by default.
      expect(cfg.embedding.normalize, isTrue);
    });

    test('loadFromFile reads + parses a YAML on disk', () async {
      final tmp = await _writeTempYaml(_minimalYaml);
      try {
        final cfg = SubstrateConfigLoader.loadFromFile(tmp.path);
        expect(cfg.providers, hasLength(1));
        expect(cfg.roleRoutes.keys, equals(['analyser']));
      } finally {
        await tmp.delete();
      }
    });

    test('loadFromFile rejects a missing path', () {
      expect(
        () => SubstrateConfigLoader.loadFromFile('/nope/nope/nope.yaml'),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('not found'),
          ),
        ),
      );
    });
  });

  group('B.36 SubstrateConfigLoader.parse — structural failures', () {
    test('non-map root', () {
      expect(
        () => SubstrateConfigLoader.parse('- not a map'),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('non-map document'),
          ),
        ),
      );
    });

    test('missing substrate: root', () {
      expect(
        () => SubstrateConfigLoader.parse('other:\n  k: v'),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('substrate'),
          ),
        ),
      );
    });

    test('YAML parse error wraps into SubstrateConfigException', () {
      expect(
        () => SubstrateConfigLoader.parse('substrate: {a: [unclosed'),
        throwsA(isA<SubstrateConfigException>()),
      );
    });

    test('providers list cannot be empty', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers: []
  roleRoutes:
    a:
      - {providerId: x, model: y}
  embedding:
    providerId: x
    model: y
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('at least one provider'),
          ),
        ),
      );
    });

    test('duplicate provider ids are rejected', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: dup
      kind: stub
    - id: dup
      kind: stub
  roleRoutes:
    a:
      - {providerId: dup, model: x}
  embedding:
    providerId: dup
    model: e
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('duplicate'),
          ),
        ),
      );
    });

    test('unknown provider kind is rejected', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: x
      kind: martian
  roleRoutes:
    a:
      - {providerId: x, model: y}
  embedding:
    providerId: x
    model: y
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('one of `ollama`, `openai`, `stub`'),
          ),
        ),
      );
    });

    test('non-stub provider must declare baseUrl', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: o
      kind: ollama
      models: [m1]
  roleRoutes:
    a:
      - {providerId: o, model: m1}
  embedding:
    providerId: o
    model: m1
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('requires `baseUrl`'),
          ),
        ),
      );
    });

    test('non-stub provider must declare at least one model', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: o
      kind: ollama
      baseUrl: http://localhost:11434
  roleRoutes:
    a:
      - {providerId: o, model: m}
  embedding:
    providerId: o
    model: m
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('at least one `models:` entry'),
          ),
        ),
      );
    });

    test('stub provider must not declare non-none auth', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
      auth:
        method: api_key
        token: t
  roleRoutes:
    a:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('kind=stub'),
          ),
        ),
      );
    });

    test('api_key auth without token or secretRef is rejected', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: o
      kind: openai
      baseUrl: http://api.example.com
      models: [m]
      auth:
        method: api_key
  roleRoutes:
    a:
      - {providerId: o, model: m}
  embedding:
    providerId: o
    model: m
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('exactly one'),
          ),
        ),
      );
    });

    test('api_key auth with both token and secretRef is rejected', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: o
      kind: openai
      baseUrl: http://api.example.com
      models: [m]
      auth:
        method: api_key
        token: inline
        secretRef: /path/to/file
  roleRoutes:
    a:
      - {providerId: o, model: m}
  embedding:
    providerId: o
    model: m
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('exactly one'),
          ),
        ),
      );
    });

    test('roleRoutes empty chain is rejected', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
  roleRoutes:
    a: []
  embedding:
    providerId: s
    model: x
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('at least one route entry'),
          ),
        ),
      );
    });

    test('roleRoutes empty map is rejected', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
  roleRoutes: {}
  embedding:
    providerId: s
    model: x
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('at least one role'),
          ),
        ),
      );
    });

    test('embedding.dims must be > 0', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
  roleRoutes:
    a:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 0
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('dims must be > 0'),
          ),
        ),
      );
    });
  });

  group('B.36 SubstrateConfigLoader.parse — cross-section validation', () {
    test('roleRoutes references unknown provider', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: known
      kind: stub
  roleRoutes:
    a:
      - {providerId: unknown, model: x}
  embedding:
    providerId: known
    model: x
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('not a configured provider'),
          ),
        ),
      );
    });

    test('roleRoutes references unknown model on a non-stub provider', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: o
      kind: ollama
      baseUrl: http://localhost:11434
      models: [actual]
  roleRoutes:
    a:
      - {providerId: o, model: not-there}
  embedding:
    providerId: o
    model: actual
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('not advertised by provider'),
          ),
        ),
      );
    });

    test('embedding.providerId must be a configured provider', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
  roleRoutes:
    a:
      - {providerId: s, model: x}
  embedding:
    providerId: missing
    model: x
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('embedding.providerId'),
          ),
        ),
      );
    });

    test('embedding.model must be advertised by a non-stub provider', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: o
      kind: ollama
      baseUrl: http://localhost:11434
      models: [other]
  roleRoutes:
    a:
      - {providerId: o, model: other}
  embedding:
    providerId: o
    model: ghost
    dims: 1
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('embedding.model'),
          ),
        ),
      );
    });

    test('priceTable references unknown provider', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
  roleRoutes:
    a:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 1
  priceTable:
    ghost/x:
      inputPerMTokens: 1.0
      outputPerMTokens: 2.0
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('references provider "ghost"'),
          ),
        ),
      );
    });

    test('priceTable key without `/` is rejected', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
  roleRoutes:
    a:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 1
  priceTable:
    badkey:
      inputPerMTokens: 1.0
      outputPerMTokens: 2.0
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('providerId/modelId'),
          ),
        ),
      );
    });

    test('webSearch.defaultProvider must match a registered provider', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
  roleRoutes:
    a:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 1
  webSearch:
    defaultProvider: not-there
    providers:
      duckduckgo:
        kind: ddg_html
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('not one of the configured providers'),
          ),
        ),
      );
    });
  });

  group('B.36 SubstrateConfigLoader.parse — env substitution', () {
    test('expands \${TOKEN} in provider baseUrl', () {
      final cfg = SubstrateConfigLoader.parse(
        '''
substrate:
  providers:
    - id: o
      kind: ollama
      baseUrl: \${OLLAMA_URL}
      models: [m]
  roleRoutes:
    a:
      - {providerId: o, model: m}
  embedding:
    providerId: o
    model: m
    dims: 1
''',
        envVars: const {'OLLAMA_URL': 'http://gpu-host:11434'},
      );
      expect(
        cfg.providers[0].baseUrl,
        equals(Uri.parse('http://gpu-host:11434')),
      );
    });

    test('expands \${TOKEN} in api_key.token and secretRef', () {
      final cfg = SubstrateConfigLoader.parse(
        '''
substrate:
  providers:
    - id: o
      kind: openai
      baseUrl: http://api.example.com
      models: [m]
      auth:
        method: api_key
        token: \${INLINE}
    - id: o2
      kind: openai
      baseUrl: http://api.example.com
      models: [m]
      auth:
        method: api_key
        secretRef: \${REF}
  roleRoutes:
    a:
      - {providerId: o, model: m}
  embedding:
    providerId: o
    model: m
    dims: 1
''',
        envVars: const {'INLINE': 'sk-INLINE', 'REF': '/secrets/file'},
      );
      expect(cfg.providers[0].auth.apiKeyInlineToken, equals('sk-INLINE'));
      expect(cfg.providers[1].auth.apiKeySecretRef, equals('/secrets/file'));
    });

    test('missing env var raises SubstrateConfigException', () {
      expect(
        () => SubstrateConfigLoader.parse(
          '''
substrate:
  providers:
    - id: o
      kind: ollama
      baseUrl: \${MISSING}
      models: [m]
  roleRoutes:
    a:
      - {providerId: o, model: m}
  embedding:
    providerId: o
    model: m
    dims: 1
''',
        ),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('undefined env var'),
          ),
        ),
      );
    });

    test('unterminated \${ raises SubstrateConfigException', () {
      expect(
        () => SubstrateConfigLoader.parse(
          '''
substrate:
  providers:
    - id: o
      kind: ollama
      baseUrl: "\${UNCLOSED"
      models: [m]
  roleRoutes:
    a:
      - {providerId: o, model: m}
  embedding:
    providerId: o
    model: m
    dims: 1
''',
          envVars: const {'UNCLOSED': 'x'},
        ),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('unterminated'),
          ),
        ),
      );
    });

    test('empty \${} raises SubstrateConfigException', () {
      expect(
        () => SubstrateConfigLoader.parse(
          '''
substrate:
  providers:
    - id: o
      kind: ollama
      baseUrl: "\${}"
      models: [m]
  roleRoutes:
    a:
      - {providerId: o, model: m}
  embedding:
    providerId: o
    model: m
    dims: 1
''',
        ),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('empty'),
          ),
        ),
      );
    });
  });

  group('B.36 SubstrateConfigLoader.parse — MCP transport coupling', () {
    test('stdio endpoint with bearer auth is rejected at load time', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
  roleRoutes:
    a:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 1
  mcpClient:
    endpoints:
      memory:
        transport: stdio
        command: dart run mcp_memory
        auth:
          mode: bearer
          token: sekret
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('transport=stdio'),
          ),
        ),
      );
    });

    test('stdio endpoint accepts explicit `mode: none` auth', () {
      final cfg = SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
  roleRoutes:
    a:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 1
  mcpClient:
    endpoints:
      memory:
        transport: stdio
        command: dart run mcp_memory
        auth:
          mode: none
''');
      expect(cfg.mcpClient.endpoints['memory']!.transport,
          equals(McpTransportKind.stdio));
    });

    test('stdio + `url:` is rejected', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
  roleRoutes:
    a:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 1
  mcpClient:
    endpoints:
      memory:
        transport: stdio
        command: dart run mcp_memory
        url: http://localhost:8731
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('must not declare `url:`'),
          ),
        ),
      );
    });

    test('http + `command:` is rejected', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
  roleRoutes:
    a:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 1
  mcpClient:
    endpoints:
      memory:
        transport: http
        url: http://localhost:8731
        command: should-not-be-here
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('must not declare `command:`'),
          ),
        ),
      );
    });

    test('unknown MCP transport kind is rejected', () {
      expect(
        () => SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
  roleRoutes:
    a:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 1
  mcpClient:
    endpoints:
      memory:
        transport: martian
        url: http://x
'''),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('one of `stdio`, `http`'),
          ),
        ),
      );
    });
  });

  group('B.36 SubstrateConfig.buildRouterPolicy', () {
    test('preserves declaration order and plumbs conditions', () {
      final cfg = SubstrateConfigLoader.parse(_fullYaml);
      final policy = cfg.buildRouterPolicy();
      expect(policy.roleRoutes.keys.toList(), equals(['analyser']));
      final chain = policy.roleRoutes['analyser']!;
      expect(chain, hasLength(2));
      expect(chain[0].providerId, equals('local-ollama'));
      expect(chain[0].model, equals('gemma3:27b'));
      // Empty conditions on the first entry.
      expect(chain[0].conditions.maxInputTokens, isNull);
      expect(chain[1].providerId, equals('openrouter'));
      expect(chain[1].conditions.maxInputTokens, equals(8192));
    });
  });

  group('B.36 SubstrateConfig.validateRoleRegistry', () {
    test('accepts when every routed role is registered', () {
      // Bootstrap registry has `assistant_to_user`, `analyser`,
      // `sub_thinker`, `recaller`, `evaluator`. The fixture routes
      // only `analyser`, which is a member.
      final cfg = SubstrateConfigLoader.parse(_fullYaml);
      // Does not throw.
      cfg.validateRoleRegistry(bootstrapRoleRegistry());
    });

    test('rejects when a routed role is not in the registry', () {
      final cfg = SubstrateConfigLoader.parse('''
substrate:
  providers:
    - id: s
      kind: stub
  roleRoutes:
    not_a_real_role:
      - {providerId: s, model: x}
  embedding:
    providerId: s
    model: x
    dims: 1
''');
      expect(
        () => cfg.validateRoleRegistry(bootstrapRoleRegistry()),
        throwsA(
          isA<SubstrateConfigException>().having(
            (e) => e.message,
            'message',
            contains('not_a_real_role'),
          ),
        ),
      );
    });

    test(
      'asymmetric: registered roles without routes are NOT rejected',
      () {
        // Only `analyser` is routed; the other four bootstrap roles
        // (`assistant_to_user`, `sub_thinker`, `recaller`,
        // `evaluator`) have no entry. The spec calls this asymmetry
        // out explicitly — tests / future procedures may use
        // templates without dispatching through the router.
        final cfg = SubstrateConfigLoader.parse(_fullYaml);
        cfg.validateRoleRegistry(bootstrapRoleRegistry()); // No throw.
      },
    );
  });
}

// ─── Fixtures ────────────────────────────────────────────────────

const String _fullYaml = '''
substrate:
  providers:
    - id: local-ollama
      kind: ollama
      baseUrl: http://localhost:11434
      models:
        - gemma3:27b
        - nomic-embed-text
    - id: openrouter
      kind: openai
      baseUrl: https://openrouter.ai/api/v1
      auth:
        method: api_key
        secretRef: _ai/secrets/openrouter.token
      models:
        - gpt-4o-mini
  roleRoutes:
    analyser:
      - providerId: local-ollama
        model: gemma3:27b
      - providerId: openrouter
        model: gpt-4o-mini
        conditions:
          maxInputTokens: 8192
  embedding:
    providerId: local-ollama
    model: nomic-embed-text
    dims: 768
    normalize: true
  webSearch:
    defaultProvider: duckduckgo
    providers:
      duckduckgo:
        kind: ddg_html
  webFetch:
    defaultBudgetBytes: 524288
    userAgent: 'TomBrain/0.2 (+https://tom-brain.local)'
  mcpClient:
    endpoints:
      memory:
        transport: http
        url: http://localhost:8731
        auth:
          mode: bearer
          secretRef: _ai/secrets/memory.token
  priceTable:
    openrouter/gpt-4o-mini:
      inputPerMTokens: 0.15
      outputPerMTokens: 0.6
''';

const String _minimalYaml = '''
substrate:
  providers:
    - id: stub-provider
      kind: stub
  roleRoutes:
    analyser:
      - providerId: stub-provider
        model: any
  embedding:
    providerId: stub-provider
    model: any
    dims: 1
''';

Future<File> _writeTempYaml(String content) async {
  final dir = await Directory.systemTemp.createTemp('substrate_cfg_test_');
  final file = File('${dir.path}/substrate.yaml');
  await file.writeAsString(content);
  return file;
}
