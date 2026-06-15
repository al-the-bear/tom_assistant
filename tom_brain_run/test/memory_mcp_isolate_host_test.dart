// spawnMemoryMcpIsolate / MemoryMcpIsolateHost — the read-mostly memory MCP
// server the run assembly hosts in a third isolate so the in-process Trail
// Observatory's `/api/memory/*` routes have something to connect to (the whole
// inspection surface comes up under `run_tom_brain.sh`, in one process).
//
// What is proven:
//   1. `spawnMemoryMcpIsolate` opens the on-disk store at the run config's
//      `memory:` root in a real second isolate and hands back a host whose `url`
//      is the loopback `/mcp` endpoint the spawned isolate actually bound (the
//      handshake works end to end).
//   2. `stop()` tears the isolate down (the bound port is free again afterwards)
//      and is idempotent — a second call is a no-op, so a duplicate shutdown
//      signal never throws.
//
// The store needs the packaged sqlite-vec binary; when it is absent for this
// platform the whole group skips (mirroring the run package's r30 suite).

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show SqliteVecBinaryResolver;
import 'package:tom_brain_run/tom_brain_run.dart';

/// Locates `<workspace>/tom_binaries/sqlite_vec`, walking up from the CWD.
/// Mirrors `r30_provision_brain_test.dart`.
String? _findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate =
        Directory('${dir.path}${Platform.pathSeparator}tom_binaries'
            '${Platform.pathSeparator}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  final String? vecRoot = _findSqliteVecRoot();
  final SqliteVecBinaryResolver resolver = SqliteVecBinaryResolver();

  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final String path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }

  final String? skipNoBinary = resolvedPath == null
      ? 'No packaged vec0 binary for this platform under '
          'tom_binaries/sqlite_vec (resolver.isSupported='
          '${resolver.isSupported}, vecRoot=$vecRoot).'
      : null;

  group('spawnMemoryMcpIsolate', () {
    late Directory tempDir;
    late String configPath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mem_mcp_iso_test');
      final storeRoot = Directory('${tempDir.path}/store')..createSync();
      // The loader only reads the `memory:` block, so a minimal run config with
      // just the store root + the packaged vec binary is enough to boot.
      configPath = '${tempDir.path}/brain_run.yaml';
      File(configPath).writeAsStringSync(
        'memory:\n'
        '  root: ${storeRoot.path}\n'
        '  sqliteVec:\n'
        '    binariesRoot: $vecRoot\n',
      );
    });
    tearDown(() => tempDir.deleteSync(recursive: true));

    test('hosts the memory MCP server in a second isolate and reports its URL',
        () async {
      final host = await spawnMemoryMcpIsolate(configPath);
      expect(host, isNotNull, reason: 'the server should come up');
      addTearDown(() => host!.stop());

      // The bound URL is the loopback `/mcp` Streamable-HTTP endpoint the
      // observatory connects to.
      expect(host!.url.scheme, 'http');
      expect(host.url.host, '127.0.0.1');
      expect(host.url.port, greaterThan(0));
      expect(host.url.path, '/mcp');

      // The socket really listens in the other isolate.
      final socket = await Socket.connect(host.url.host, host.url.port);
      await socket.close();
      socket.destroy();
    });

    test('stop() tears the isolate down and frees the port, idempotently',
        () async {
      final host = await spawnMemoryMcpIsolate(configPath);
      expect(host, isNotNull);
      final boundPort = host!.url.port;

      await host.stop();
      // The port is free again: re-binding it here succeeds once the isolate's
      // socket has closed.
      final rebound = await HttpServer.bind(host.url.host, boundPort);
      await rebound.close();

      // Idempotent: a second stop (e.g. a duplicate SIGINT) is a no-op.
      await host.stop();
    });
  }, skip: skipNoBinary);
}
