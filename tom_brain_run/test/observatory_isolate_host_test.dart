// spawnObservatoryIsolate / ObservatoryIsolateHost — the in-process Trail
// Observatory the run assembly hosts in a second isolate (it is the official
// config + control surface, so `brain_serve` owns its lifecycle rather than
// leaving the operator to launch a separate process).
//
// What is proven:
//   1. `spawnObservatoryIsolate` brings the read-only backend up in a real
//      second isolate and hands back a host whose `url` is the loopback socket
//      the spawned isolate actually bound (the handshake works end to end).
//   2. `stop()` tears the isolate down (the bound port is free again afterwards)
//      and is idempotent — a second call is a no-op, so a duplicate shutdown
//      signal never throws.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_run/tom_brain_run.dart';

void main() {
  group('spawnObservatoryIsolate', () {
    late Directory trailDir;

    setUp(() => trailDir = Directory.systemTemp.createTempSync('obs_iso_test'));
    tearDown(() => trailDir.deleteSync(recursive: true));

    test('hosts the observatory in a second isolate and reports its URL',
        () async {
      // Port 0 → an OS-assigned ephemeral port inside the spawned isolate; the
      // handshake carries the actually-bound URL back to the host.
      final host = await spawnObservatoryIsolate(
        ObservatoryOptions(trailRoot: trailDir.path, port: 0),
      );
      expect(host, isNotNull, reason: 'the backend should come up');
      addTearDown(() => host!.stop());

      expect(host!.url.scheme, 'http');
      expect(host.url.host, ObservatoryOptions.defaultHost);
      expect(host.url.port, greaterThan(0));

      // The socket really listens in the other isolate.
      final socket = await Socket.connect(host.url.host, host.url.port);
      await socket.close();
      socket.destroy();
    });

    test('stop() tears the isolate down and frees the port, idempotently',
        () async {
      final host = await spawnObservatoryIsolate(
        ObservatoryOptions(trailRoot: trailDir.path, port: 0),
      );
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
  });
}
