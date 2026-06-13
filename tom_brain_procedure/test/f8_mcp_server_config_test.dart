// Request (c) § 3.1 — the per-server `exposeToLlms` availability gate on
// `McpServerConfig` / `McpServersConfig.fromYamlString`
// (`agent_sdk_provider_and_mcp_liveness.md` § 3.1).
//
// A configured server is reachable by inspection tooling but is offered to
// procedures / LLMs only when `exposeToLlms: true`. The flag is data on the
// parsed config, defaulting to `false` (closed by default): a server that does
// not opt in is never auto-offered to a model.
//
// What this suite locks:
//
//   EX-1 — `exposeToLlms: true` parses to `true`.
//   EX-2 — `exposeToLlms: false` parses to `false`.
//   EX-3 — an absent `exposeToLlms` defaults to `false` (closed by default).
//   EX-4 — a non-bool `exposeToLlms` is a structural config error.
//   EX-5 — `exposeToLlms` participates in `==` / `hashCode`.

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show McpConfigInvalid, McpServerConfig, McpServersConfig, McpTransport;

void main() {
  group('f8 — McpServerConfig.exposeToLlms', () {
    McpServerConfig parseOne(String yaml) =>
        McpServersConfig.fromYamlString(yaml).servers.single;

    test('EX-1: exposeToLlms: true parses to true', () {
      final server = parseOne('''
mcpServers:
  - id: up
    transport: stdio
    command: serve
    exposeToLlms: true
''');
      expect(server.exposeToLlms, isTrue);
    });

    test('EX-2: exposeToLlms: false parses to false', () {
      final server = parseOne('''
mcpServers:
  - id: up
    transport: stdio
    command: serve
    exposeToLlms: false
''');
      expect(server.exposeToLlms, isFalse);
    });

    test('EX-3: absent exposeToLlms defaults to false (closed by default)', () {
      final server = parseOne('''
mcpServers:
  - id: up
    transport: stdio
    command: serve
''');
      expect(server.exposeToLlms, isFalse);
    });

    test('EX-4: a non-bool exposeToLlms is a structural config error', () {
      expect(
        () => McpServersConfig.fromYamlString('''
mcpServers:
  - id: up
    transport: stdio
    command: serve
    exposeToLlms: yes-please
'''),
        throwsA(isA<McpConfigInvalid>()),
      );
    });

    test('EX-5: exposeToLlms participates in == / hashCode', () {
      const exposed = McpServerConfig(
        id: 'up',
        transport: McpTransport.stdio,
        exposeToLlms: true,
      );
      const hidden = McpServerConfig(
        id: 'up',
        transport: McpTransport.stdio,
      );
      expect(exposed, isNot(equals(hidden)));
      expect(exposed.hashCode, isNot(equals(hidden.hashCode)));
      expect(hidden.exposeToLlms, isFalse);
    });
  });
}
