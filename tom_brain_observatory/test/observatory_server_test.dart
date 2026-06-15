// startObservatoryServer / ObservatoryOptions — the assembly factored out of
// `bin/observatory.dart` so both the standalone bin and the brain's in-process
// isolate (`tom_brain_run`'s `observatory_isolate_host.dart`) share one body.
//
// What is proven:
//   1. `ObservatoryOptions.fromArgs` lifts the single positional <trail-root>
//      and the `--key=value` flags, applies the loopback defaults, and tolerates
//      a non-integer `--port` (falling back to the default).
//   2. `fromArgs` rejects a missing / extra positional with an ArgumentError, so
//      both entrypoints can report usage identically.
//   3. `startObservatoryServer` binds a loopback socket and reports its URL, and
//      its `close()` releases the socket — the read-only teardown the in-process
//      host relies on (no `exit`, the socket simply closes).

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_observatory/tom_brain_observatory.dart';

void main() {
  group('ObservatoryOptions.fromArgs', () {
    test('lifts the positional trail root and applies loopback defaults', () {
      final options = ObservatoryOptions.fromArgs(['/trail/root']);
      expect(options.trailRoot, '/trail/root');
      expect(options.host, ObservatoryOptions.defaultHost);
      expect(options.port, ObservatoryOptions.defaultPort);
      expect(options.cognitionDir, isNull);
      expect(options.runConfigDir, isNull);
      expect(options.memoryMcpUrl, isNull);
      expect(options.webDir, isNull);
      expect(options.scriptsDir, isNull);
    });

    test('lifts every --key=value flag', () {
      final options = ObservatoryOptions.fromArgs([
        '/trail',
        '--host=0.0.0.0',
        '--port=9001',
        '--cognition=/c',
        '--run-config=/r',
        '--memory-mcp-url=http://127.0.0.1:8765/mcp',
        '--memory-mcp-token=tok',
        '--web=/w',
        '--scripts=/s',
      ]);
      expect(options.trailRoot, '/trail');
      expect(options.host, '0.0.0.0');
      expect(options.port, 9001);
      expect(options.cognitionDir, '/c');
      expect(options.runConfigDir, '/r');
      expect(options.memoryMcpUrl, 'http://127.0.0.1:8765/mcp');
      expect(options.memoryMcpToken, 'tok');
      expect(options.webDir, '/w');
      expect(options.scriptsDir, '/s');
    });

    test('falls back to the default port on a non-integer --port', () {
      final options = ObservatoryOptions.fromArgs(['/trail', '--port=lots']);
      expect(options.port, ObservatoryOptions.defaultPort);
    });

    test('rejects a missing or extra positional with ArgumentError', () {
      expect(() => ObservatoryOptions.fromArgs(['--port=9001']),
          throwsArgumentError);
      expect(() => ObservatoryOptions.fromArgs(['/a', '/b']),
          throwsArgumentError);
    });
  });

  group('startObservatoryServer', () {
    late Directory trailDir;

    setUp(() => trailDir = Directory.systemTemp.createTempSync('obs_srv_test'));
    tearDown(() => trailDir.deleteSync(recursive: true));

    test('binds a loopback socket and reports its URL, then closes', () async {
      // Port 0 → an OS-assigned ephemeral port, so the test never collides with
      // a running observatory. No cognition / memory configured: the assembly
      // degrades to the trail surface only (the read-only-mirror posture).
      final server = await startObservatoryServer(
        ObservatoryOptions(trailRoot: trailDir.path, port: 0),
      );
      addTearDown(server.close);

      expect(server.url.scheme, 'http');
      expect(server.url.host, ObservatoryOptions.defaultHost);
      expect(server.port, greaterThan(0));
      expect(server.url.port, server.port);

      // Capture the bound address before closing — `server.boundHost`/`port`
      // read the live socket, which is gone after `close()`.
      final boundHost = server.boundHost;
      final boundPort = server.port;

      // The socket is live: a bare TCP connect succeeds while it serves.
      final socket = await Socket.connect(boundHost, boundPort);
      await socket.close();
      socket.destroy();

      // close() releases the socket — re-binding the same port now succeeds.
      await server.close();
      final rebound = await HttpServer.bind(boundHost, boundPort);
      await rebound.close();
    });
  });
}
