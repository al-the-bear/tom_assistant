// E.46 — end-to-end stand-up smoke.
//
// Plan step E.46 (verbatim): "Stand up the process with a stub substrate + an
// in-isolate memory + the OpenAI adapter on a local port."
//
// This suite drives the real boot path through [standUpSmokeProcess]: a whole
// cognition (stub [SmokeSubstrate] in-process + an in-isolate [SmokeMemory]
// over the production isolate transport) is booted, the access process is
// stood up over its dispatcher, and a real socket is bound on a local
// (OS-assigned) port. It then proves the process is *live*:
//
//   1. it bound a real port (`> 0`);
//   2. `GET /healthz` answers `200` with the `{ status, uptime_s, queues }`
//      liveness body (status `ok` while serving);
//   3. `GET /v1/models` answers `200` with the OpenAI models-list body — proof
//      the OpenAI adapter is mounted on the same socket;
//   4. it tears down cleanly — the stub substrate is closed exactly once and a
//      second `stop()` is a no-op.
//
// E.46 asserts *stand-up*, not a chat roundtrip: the boot route runs a
// procedure to completion in memory but does not yet wire `Access.deliver`
// back to the channel (that is E.47). So no `POST /v1/chat/completions` is
// driven here.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart';
import 'package:test/test.dart';

/// Issues a `GET` against the bound smoke process and returns the status code
/// and decoded JSON body.
Future<({int statusCode, Object? body})> _get(int port, String path) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request =
        await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    final HttpClientResponse response = await request.close();
    final String text = await response.transform(utf8.decoder).join();
    final Object? body = text.isEmpty ? null : jsonDecode(text);
    return (statusCode: response.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
}

void main() {
  group('E.46 stand-up smoke', () {
    late SmokeProcess smoke;

    setUp(() async {
      smoke = await standUpSmokeProcess();
    });

    tearDown(() async {
      await smoke.stop();
    });

    test('binds a real local port', () {
      expect(smoke.port, greaterThan(0));
    });

    test('GET /healthz answers 200 with the liveness body', () async {
      final result = await _get(smoke.port, '/healthz');

      expect(result.statusCode, 200);
      final body = result.body as Map<String, Object?>;
      expect(body['status'], 'ok');
      expect(body['uptime_s'], isA<int>());
      // The queue snapshot is projected from the live coordinator: idle at
      // stand-up (no foreground run, nothing waiting, not draining).
      final queues = body['queues'] as Map<String, Object?>;
      final foreground = queues['foreground'] as Map<String, Object?>;
      expect(foreground['running'], isFalse);
      expect(foreground['waiting'], 0);
      expect(queues['draining'], isFalse);
    });

    test('GET /v1/models answers 200 with the models-list body', () async {
      final result = await _get(smoke.port, '/v1/models');

      expect(result.statusCode, 200);
      final body = result.body as Map<String, Object?>;
      expect(body['object'], 'list');
      final data = body['data'] as List<Object?>;
      expect(data, isNotEmpty);
      // Every entry is a `model` object carrying an id.
      final first = data.first as Map<String, Object?>;
      expect(first['object'], 'model');
      expect(first['id'], isA<String>());
    });

    test('the stub substrate is opened lazily — boot skips the open with no '
        'substrate config', () {
      // The smoke boots with no `SubstrateConfig`, so boot skips
      // `substrate.open` (the stub needs none). The substrate is still the live
      // instance the engine bound against.
      expect(smoke.substrate.openCount, 0);
    });
  });

  group('E.46 clean teardown', () {
    test('stop() closes the substrate exactly once and is idempotent',
        () async {
      final SmokeProcess smoke = await standUpSmokeProcess();
      final int boundPort = smoke.port;
      expect(boundPort, greaterThan(0));

      await smoke.stop();
      expect(smoke.substrate.closeCount, 1,
          reason: 'shutdown closes the substrate once');

      // A second stop is a no-op — the teardown runs at most once.
      await smoke.stop();
      expect(smoke.substrate.closeCount, 1);
    });
  });
}
