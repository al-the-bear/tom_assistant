// f8b — directory-sourced external MCP servers (`mcpServersDir`, CLI plan
// step #3). The `mcpServers:` block may be sourced from a directory of
// `*.yaml` / `*.yml` files instead of inline, mirroring the substrate
// `providersDir` / profiles `profilesDir` aspects: the files' `mcpServers:`
// lists are unioned in filename order with cross-file duplicate-id detection,
// declaring both inline + directory is a config error, a relative dir resolves
// against the config file's directory, and `${env:NAME}` tokens expand in the
// server coordinates.
//
// What this suite locks:
//
//   DIR-1 — inline `mcpServers:` still parses (no regression).
//   DIR-2 — `mcpServersDir:` unions the files' servers in filename order.
//   DIR-3 — inline + directory together is a config error.
//   DIR-4 — `${env:NAME}` expands in url / headers / command / args.
//   DIR-5 — a duplicate id across two files is a config error.
//   DIR-6 — a relative `mcpServersDir` with no basePath is a config error.
//   DIR-7 — a missing `mcpServersDir` directory is a config error.
//   DIR-8 — an absent block (no inline, no dir) yields an empty registry.

import 'dart:io';

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show McpConfigInvalid, McpServersConfig, McpTransport;

void main() {
  group('f8b — McpServersConfig.mcpServersDir', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('f8b_mcp_dir_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    File write(String name, String content) {
      final f = File('${tmp.path}/$name')..writeAsStringSync(content);
      return f;
    }

    test('DIR-1: inline mcpServers still parses', () {
      final cfg = McpServersConfig.fromYamlString('''
mcpServers:
  - id: memory
    transport: http
    url: http://localhost:9000
''');
      expect(cfg.servers.single.id, 'memory');
      expect(cfg.servers.single.transport, McpTransport.http);
    });

    test('DIR-2: mcpServersDir unions files in filename order', () {
      write('a_first.yaml', '''
mcpServers:
  - id: alpha
    transport: stdio
    command: serve-alpha
''');
      write('b_second.yml', '''
mcpServers:
  - id: beta
    transport: http
    url: http://localhost:9100
''');
      final cfg = McpServersConfig.fromYamlString(
        'mcpServersDir: ${tmp.path}\n',
      );
      expect(cfg.servers.map((s) => s.id).toList(), <String>['alpha', 'beta']);
    });

    test('DIR-3: inline + directory together is a config error', () {
      expect(
        () => McpServersConfig.fromYamlString('''
mcpServersDir: ${tmp.path}
mcpServers:
  - id: inline
    transport: stdio
    command: x
'''),
        throwsA(isA<McpConfigInvalid>()),
      );
    });

    test('DIR-4: \${env:NAME} expands in url / headers / command / args', () {
      write('servers.yaml', r'''
mcpServers:
  - id: secured
    transport: http
    url: ${env:MCP_URL}
    headers:
      Authorization: Bearer ${env:MCP_TOKEN}
  - id: child
    transport: stdio
    command: ${env:MCP_CMD}
    args:
      - --port=${env:MCP_PORT}
''');
      final cfg = McpServersConfig.fromYamlString(
        'mcpServersDir: ${tmp.path}\n',
        envVars: const <String, String>{
          'MCP_URL': 'http://10.8.0.9:9200',
          'MCP_TOKEN': 'sekret',
          'MCP_CMD': '/usr/bin/serve',
          'MCP_PORT': '4242',
        },
      );
      final secured = cfg.byId('secured')!;
      expect(secured.url, 'http://10.8.0.9:9200');
      expect(secured.headers['Authorization'], 'Bearer sekret');
      final child = cfg.byId('child')!;
      expect(child.command, '/usr/bin/serve');
      expect(child.args, <String>['--port=4242']);
    });

    test('DIR-5: a duplicate id across two files is a config error', () {
      write('a.yaml', '''
mcpServers:
  - id: dup
    transport: stdio
    command: x
''');
      write('b.yaml', '''
mcpServers:
  - id: dup
    transport: http
    url: http://localhost:9300
''');
      expect(
        () => McpServersConfig.fromYamlString('mcpServersDir: ${tmp.path}\n'),
        throwsA(isA<McpConfigInvalid>()),
      );
    });

    test('DIR-6: relative mcpServersDir with no basePath is a config error', () {
      expect(
        () => McpServersConfig.fromYamlString('mcpServersDir: mcp\n'),
        throwsA(isA<McpConfigInvalid>()),
      );
    });

    test('DIR-6b: relative mcpServersDir resolves against basePath', () {
      Directory('${tmp.path}/mcp').createSync();
      File('${tmp.path}/mcp/s.yaml').writeAsStringSync('''
mcpServers:
  - id: rel
    transport: stdio
    command: x
''');
      final cfg = McpServersConfig.fromYamlString(
        'mcpServersDir: mcp\n',
        basePath: tmp.path,
      );
      expect(cfg.servers.single.id, 'rel');
    });

    test('DIR-7: a missing mcpServersDir directory is a config error', () {
      expect(
        () => McpServersConfig.fromYamlString(
          'mcpServersDir: ${tmp.path}/does-not-exist\n',
        ),
        throwsA(isA<McpConfigInvalid>()),
      );
    });

    test('DIR-8: an absent block yields an empty registry', () {
      final cfg = McpServersConfig.fromYamlString('substrate: {}\n');
      expect(cfg.servers, isEmpty);
    });
  });
}
