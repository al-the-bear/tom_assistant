// Tests for `MemoryConfigLoader` (Plan step A.83).
//
// Covers:
//   - The full canonical YAML from `memory_specification.md` § 14
//     parses round-trip into the expected typed values.
//   - Optional sections default to the typed-record defaults when
//     omitted.
//   - `${NAME}` env-var substitution works for string fields and
//     raises on unknown / malformed tokens.
//   - Every required field, type-mismatch, range-violation, and
//     topology-violation produces a `MemoryConfigException` whose
//     message names the offending key path.
//   - `loadFromFile` reads a real on-disk file and returns the same
//     value as `parse` on the same content.
//
// Drives the public API only — no peeking at private helpers.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

void main() {
  group('MemoryConfigLoader.parse — happy paths', () {
    test('parses the canonical § 14 example with env substitution', () {
      final yaml = '''
memory:
  root: /var/lib/tom_brain/memory
  sqliteVec:
    extensionPath: \${TOM_BINARIES}/sqlite_vec/\${PLATFORM}/vec0.so
  retrieval:
    rrf:
      k: 60
    mmr:
      lambda: 0.7
  trails:
    fsyncEveryAppend: true
    compressAfterDays: 7
    coldStorageAfterDays: 90
  classification:
    minConfidence: 0.55
    minMargin: 0.05
  budgets:
    defaultWriteBudget:
      maxNodes: 5000
      maxEdges: 20000
      maxStackEntries: 1000
  mcpServer:
    enabled: true
    bind: 127.0.0.1:8841
    bearerAuthRealm: tom-brain-memory
  replication:
    role: authority
    writeLogDir: /var/lib/tom_brain/write-log
''';

      final cfg = MemoryConfigLoader.parse(
        yaml,
        envVars: {
          'TOM_BINARIES': '/opt/tom/binaries',
          'PLATFORM': 'linux-x64',
        },
      );

      expect(cfg.root, '/var/lib/tom_brain/memory');
      expect(
        cfg.sqliteVec.extensionPath,
        '/opt/tom/binaries/sqlite_vec/linux-x64/vec0.so',
      );
      expect(cfg.retrieval.rrfK, 60);
      expect(cfg.retrieval.mmrLambda, 0.7);
      expect(cfg.trails.fsyncEveryAppend, true);
      expect(cfg.trails.compressAfter, const Duration(days: 7));
      expect(cfg.trails.coldStorageAfter, const Duration(days: 90));
      expect(cfg.classification.minConfidence, 0.55);
      expect(cfg.classification.minMargin, 0.05);
      expect(cfg.budgets.defaultWriteBudget.maxNodes, 5000);
      expect(cfg.budgets.defaultWriteBudget.maxEdges, 20000);
      expect(cfg.budgets.defaultWriteBudget.maxStackEntries, 1000);
      expect(cfg.mcpServer.enabled, true);
      expect(cfg.mcpServer.bindAddress, '127.0.0.1');
      expect(cfg.mcpServer.bindPort, 8841);
      expect(cfg.mcpServer.bearerAuthRealm, 'tom-brain-memory');
      expect(cfg.replication.role, ReplicationRole.authority);
      expect(cfg.replication.writeLogDir, '/var/lib/tom_brain/write-log');
      expect(cfg.replication.authorityEndpoint, isNull);
    });

    test('parses worker topology with authorityEndpoint', () {
      final cfg = MemoryConfigLoader.parse('''
memory:
  root: /tmp/tom_brain
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: worker
    authorityEndpoint: tcp://big-beast.local:8841
''');
      expect(cfg.replication.role, ReplicationRole.worker);
      expect(
        cfg.replication.authorityEndpoint,
        'tcp://big-beast.local:8841',
      );
      expect(cfg.replication.writeLogDir, isNull);
    });

    test('parses mirror topology with authorityEndpoint', () {
      final cfg = MemoryConfigLoader.parse('''
memory:
  root: /tmp/tom_brain
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: mirror
    authorityEndpoint: tcp://big-beast.local:8841
''');
      expect(cfg.replication.role, ReplicationRole.mirror);
      expect(
        cfg.replication.authorityEndpoint,
        'tcp://big-beast.local:8841',
      );
    });

    test('omitted optional sections fall back to typed defaults', () {
      final cfg = MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: authority
    writeLogDir: /tmp/write-log
''');

      expect(cfg.retrieval.rrfK, 60);
      expect(cfg.retrieval.mmrLambda, 0.7);
      expect(cfg.trails.fsyncEveryAppend, true);
      expect(cfg.trails.compressAfter, const Duration(days: 7));
      expect(cfg.trails.coldStorageAfter, const Duration(days: 90));
      expect(cfg.classification.minConfidence, 0.55);
      expect(cfg.classification.minMargin, 0.05);
      expect(cfg.classification.coldStartMinExamples, 8);
      expect(cfg.budgets.defaultWriteBudget.maxNodes, 5000);
      expect(cfg.mcpServer.enabled, false);
      expect(cfg.mcpServer.bindAddress, isNull);
      expect(cfg.mcpServer.bindPort, isNull);
    });

    test('mcpServer disabled requires no bind', () {
      final cfg = MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  mcpServer:
    enabled: false
  replication:
    role: authority
    writeLogDir: /tmp/write-log
''');
      expect(cfg.mcpServer.enabled, false);
      expect(cfg.mcpServer.bindAddress, isNull);
    });

    test('integer doubles parse as doubles for lambda', () {
      final cfg = MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  retrieval:
    mmr:
      lambda: 1
  replication:
    role: authority
    writeLogDir: /tmp/write-log
''');
      expect(cfg.retrieval.mmrLambda, 1.0);
    });
  });

  group('MemoryConfigLoader.parse — env substitution', () {
    test('expands `\${NAME}` tokens in string fields', () {
      final cfg = MemoryConfigLoader.parse(
        '''
memory:
  root: \${BRAIN_ROOT}/memory
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: authority
    writeLogDir: \${BRAIN_ROOT}/write-log
''',
        envVars: {'BRAIN_ROOT': '/srv/brain'},
      );
      expect(cfg.root, '/srv/brain/memory');
      expect(cfg.replication.writeLogDir, '/srv/brain/write-log');
    });

    test('raises on unknown env var', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: \${UNSET_VAR}/memory
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: authority
    writeLogDir: /tmp/write-log
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('memory.root'),
              contains('UNSET_VAR'),
            ),
          ),
        ),
      );
    });

    test('raises on unterminated `\${` token', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: "\${UNCLOSED"
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: authority
    writeLogDir: /tmp/write-log
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('unterminated'),
          ),
        ),
      );
    });

    test('raises on empty `\${}` token', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: "\${}"
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: authority
    writeLogDir: /tmp/write-log
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('empty'),
          ),
        ),
      );
    });

    test('plain `\$` without `{` is left as-is', () {
      final cfg = MemoryConfigLoader.parse('''
memory:
  root: "/srv/\$brain/memory"
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: authority
    writeLogDir: /tmp/write-log
''');
      expect(cfg.root, r'/srv/$brain/memory');
    });
  });

  group('MemoryConfigLoader.parse — schema violations', () {
    test('missing `memory:` root raises', () {
      expect(
        () => MemoryConfigLoader.parse('other: 1\n'),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('memory'),
          ),
        ),
      );
    });

    test('missing required `root` raises with key path', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: authority
    writeLogDir: /tmp/write-log
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('memory.root'),
          ),
        ),
      );
    });

    test('missing required `sqliteVec.extensionPath` raises', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec: {}
  replication:
    role: authority
    writeLogDir: /tmp/write-log
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('memory.sqliteVec.extensionPath'),
          ),
        ),
      );
    });

    test('wrong type for an integer field raises', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  retrieval:
    rrf:
      k: "sixty"
  replication:
    role: authority
    writeLogDir: /tmp/write-log
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('memory.retrieval.rrf.k'),
          ),
        ),
      );
    });

    test('out-of-range mmr lambda raises', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  retrieval:
    mmr:
      lambda: 2.5
  replication:
    role: authority
    writeLogDir: /tmp/write-log
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('memory.retrieval.mmr.lambda'),
          ),
        ),
      );
    });

    test('non-positive rrf.k raises', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  retrieval:
    rrf:
      k: 0
  replication:
    role: authority
    writeLogDir: /tmp/write-log
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('memory.retrieval.rrf.k'),
          ),
        ),
      );
    });

    test('coldStorageAfterDays < compressAfterDays raises', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  trails:
    compressAfterDays: 30
    coldStorageAfterDays: 7
  replication:
    role: authority
    writeLogDir: /tmp/write-log
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('coldStorageAfterDays'),
          ),
        ),
      );
    });

    test('negative budget value raises', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  budgets:
    defaultWriteBudget:
      maxNodes: -1
  replication:
    role: authority
    writeLogDir: /tmp/write-log
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('maxNodes'),
          ),
        ),
      );
    });

    test('unknown replication role raises', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: leader
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('memory.replication.role'),
              contains('leader'),
            ),
          ),
        ),
      );
    });

    test('authority without writeLogDir raises', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: authority
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('writeLogDir'),
          ),
        ),
      );
    });

    test('worker without authorityEndpoint raises', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: worker
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('authorityEndpoint'),
          ),
        ),
      );
    });

    test('worker with writeLogDir raises', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: worker
    authorityEndpoint: tcp://a:1
    writeLogDir: /tmp/wl
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('writeLogDir'),
          ),
        ),
      );
    });

    test('mcpServer.enabled=true without bind raises', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  mcpServer:
    enabled: true
  replication:
    role: authority
    writeLogDir: /tmp/write-log
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('memory.mcpServer.bind'),
          ),
        ),
      );
    });

    test('malformed bind raises', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  mcpServer:
    enabled: true
    bind: not-a-bind
  replication:
    role: authority
    writeLogDir: /tmp/write-log
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('bind'),
          ),
        ),
      );
    });

    test('bind with out-of-range port raises', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  mcpServer:
    enabled: true
    bind: 127.0.0.1:99999
  replication:
    role: authority
    writeLogDir: /tmp/write-log
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('port'),
          ),
        ),
      );
    });

    test('bearerAuthRealm explicit empty string raises', () {
      expect(
        () => MemoryConfigLoader.parse('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  mcpServer:
    enabled: true
    bind: 127.0.0.1:8841
    bearerAuthRealm: ""
  replication:
    role: authority
    writeLogDir: /tmp/write-log
'''),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('bearerAuthRealm'),
          ),
        ),
      );
    });

    test('malformed YAML raises wrapped exception', () {
      expect(
        () => MemoryConfigLoader.parse('memory:\n  root: [unclosed'),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('YAML parse failed'),
          ),
        ),
      );
    });

    test('non-map document raises', () {
      expect(
        () => MemoryConfigLoader.parse('- 1\n- 2\n'),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('YAML map'),
          ),
        ),
      );
    });
  });

  group('MemoryConfigLoader.loadFromFile', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'a83_config_loader_',
      );
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('reads file content and parses it', () {
      final file = File('${tempDir.path}/memory.yaml');
      file.writeAsStringSync('''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  replication:
    role: authority
    writeLogDir: /tmp/write-log
''');

      final cfg = MemoryConfigLoader.loadFromFile(file.path);
      expect(cfg.root, '/tmp/x');
      expect(cfg.sqliteVec.extensionPath, '/opt/vec0.so');
      expect(cfg.replication.role, ReplicationRole.authority);
    });

    test('missing file raises a MemoryConfigException', () {
      expect(
        () => MemoryConfigLoader.loadFromFile(
          '${tempDir.path}/does-not-exist.yaml',
        ),
        throwsA(
          isA<MemoryConfigException>().having(
            (e) => e.message,
            'message',
            contains('not found'),
          ),
        ),
      );
    });

    test('loadFromFile and parse produce equal MemoryConfig', () {
      const yaml = '''
memory:
  root: /tmp/x
  sqliteVec:
    extensionPath: /opt/vec0.so
  retrieval:
    rrf: { k: 42 }
    mmr: { lambda: 0.3 }
  replication:
    role: authority
    writeLogDir: /tmp/write-log
''';
      final file = File('${tempDir.path}/memory.yaml')
        ..writeAsStringSync(yaml);

      final fromFile = MemoryConfigLoader.loadFromFile(file.path);
      final fromString = MemoryConfigLoader.parse(yaml);

      expect(fromFile.root, fromString.root);
      expect(
        fromFile.sqliteVec.extensionPath,
        fromString.sqliteVec.extensionPath,
      );
      expect(fromFile.retrieval.rrfK, fromString.retrieval.rrfK);
      expect(
        fromFile.retrieval.mmrLambda,
        fromString.retrieval.mmrLambda,
      );
    });
  });
}
