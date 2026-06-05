// #30 — the real BrainProvisioner higher assembly.
//
// Plan-2 step #30 (verbatim, `prototype_implementation_plan_2.md`):
//
//   "Build the real `BrainProvisioner` higher assembly. The non-stub sibling of
//    `standUpSmokeProcess`: boot `BrainProcessBoot` with the real
//    `SqliteTomBrainMemory` (on-disk, isolate-hosted), the real substrate
//    (router → `OpenAiPassthroughProvider`@oMLX for the LLM,
//    `OllamaEmbeddingService` for embeddings), project the `RunCoordinator` onto
//    the `QueueSnapshot`, and hand back a `ProvisionedBrain`. […]
//    Test: provisioner boots and tears down cleanly with a stub LLM + real
//    on-disk memory. Verify: `BrainAccessProcess` binds a port over the real
//    cognition and answers `/healthz` + `/v1/models`."
//
// ── What this suite proves ───────────────────────────────────────────
//
// It drives the real boot path through [provisionBrain] / [standUpBrainProcess]
// over the **real on-disk `SqliteTomBrainMemory`** (isolate-hosted via the
// production `createSqliteTomBrainMemory` factory, indexing through the packaged
// `vec0` extension). The substrate is a **stub LLM** ([SmokeSubstrate]) — the
// canonical compile-checked substrate stub the smoke ships — so the real memory
// boots without a live model. The plan's *Test* line asks for exactly this
// pairing: a stub LLM + real on-disk memory.
//
//   Group A — provisioner lifecycle: [provisionBrain] boots the cognition over
//   real memory, hands back a `ProvisionedBrain` whose queue snapshot reads idle
//   at stand-up, and tears the whole cognition (including the memory isolate)
//   down cleanly through `ProvisionedBrain.shutdown`.
//
//   Group B — stand-up over real cognition: [standUpBrainProcess] binds a real
//   socket over the booted cognition and the process answers `GET /healthz`
//   (200, liveness body) and `GET /v1/models` (200, OpenAI models list) — proof
//   the access process is live over the real memory-backed brain.
//
// ── Why the real substrate is NOT built here ─────────────────────────
//
// The plan's *Test* substitutes a stub LLM precisely so the suite stays green
// off-box (no oMLX, no Ollama). `buildOmlxOllamaSubstrate` (the real substrate)
// is exercised at the assembly level — it is pure construction with no live
// call until a chat completion runs, which `/healthz` + `/v1/models` never
// trigger. A future live-integration step drives the real substrate end-to-end.
//
// ── Off-box skip ─────────────────────────────────────────────────────
//
// The single precondition is the packaged `vec0` binary (the store loads the
// sqlite-vec extension at `open`). Absent it, the whole suite is *skipped*, not
// failed — mirroring the memory package's live-integration suites — so the run
// stays green on a platform with no packaged binary.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show MemoryConfig, SqliteVecBinaryResolver;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart'
    show SmokeSubstrate;
import 'package:test/test.dart';

/// Locates `<workspace>/tom_binaries/sqlite_vec`. Mirrors the memory package's
/// live-integration suites (p2_16 – p2_19).
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

/// An "effectively unlimited" cap for the permissive run-test access config —
/// the test never wants to be throttled.
const int _unlimitedQuota = 1000000;

/// The satisfy-validation placeholder for `AccessConfig.openAiPort`. The test
/// binds the real ephemeral port through its injected serve seam (`0`), but
/// `AccessConfig` validates `openAiPort > 0`, so this non-zero placeholder
/// stands in. The real bound port is read back from `BrainProcess.port`.
const int _placeholderPort = 1;

/// The bearer token a request authenticates with against the permissive config.
const String _bearerToken = 'run-token';

/// A permissive access config: one bearer binding, no rate / quota caps, an
/// empty anchor policy. `openAiPort` is the placeholder — the test's serve seam
/// binds the real ephemeral port.
AccessConfig _permissiveConfig() => AccessConfig(
      openAiPort: _placeholderPort,
      rateLimitPolicy: RateLimitPolicy(
        capacity: _unlimitedQuota,
        refillTokens: _unlimitedQuota.toDouble(),
        refillPeriod: const Duration(seconds: 1),
      ),
      dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: _unlimitedQuota),
      anchorPolicy: AnchorPolicy(disallowedSignatures: const <String>[]),
      bearerTokenBindings: <String, IdentityBinding>{
        _bearerToken: IdentityBinding(principalId: 'run-user'),
      },
    );

/// Issues a `GET` against a bound process and returns the status + decoded body.
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

  /// A fresh real-store config rooted in a unique temp dir, with teardown
  /// registered for the directory. Points the store at the packaged vec0.
  MemoryConfig freshMemoryConfig() {
    final Directory root =
        Directory.systemTemp.createTempSync('tom_brain_run_30_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    return MemoryConfig.forTesting(root: root.path, binariesRoot: vecRoot!);
  }

  group('#30 provisionBrain — real on-disk memory + stub LLM', () {
    test('boots a ProvisionedBrain whose queue snapshot reads idle, then tears '
        'down cleanly', () async {
      final SmokeSubstrate substrate = SmokeSubstrate();

      final ProvisionedBrain provisioned = await provisionBrain(
        substrate: substrate,
        memoryConfig: freshMemoryConfig(),
      );

      // The queue snapshot is projected from the live RunCoordinator: idle at
      // stand-up (no foreground run, nothing waiting, not draining).
      final QueueSnapshot snapshot = provisioned.queueSnapshot();
      expect(snapshot.foregroundRunning, isFalse);
      expect(snapshot.foregroundWaiting, 0);
      expect(snapshot.draining, isFalse);

      // Clean teardown: shutdown drains the foreground, disposes the memory
      // isolate, and closes the stub substrate exactly once.
      await provisioned.shutdown();
      expect(substrate.closeCount, 1,
          reason: 'shutdown closes the substrate once');
    });
  }, skip: skipNoBinary);

  group('#30 standUpBrainProcess — access process over real cognition', () {
    late BrainProcess process;
    late SmokeSubstrate substrate;

    setUp(() async {
      substrate = SmokeSubstrate();
      process = await standUpBrainProcess(
        config: _permissiveConfig(),
        substrate: substrate,
        memoryConfig: freshMemoryConfig(),
        // Bind an OS-assigned ephemeral port (the config carries the
        // satisfy-validation placeholder); read the real port back.
        serve: (handler, _) => serveWithShelfIo(handler, 0),
      );
    });

    tearDown(() async {
      await process.stop();
    });

    test('binds a real local port', () {
      expect(process.port, greaterThan(0));
    });

    test('GET /healthz answers 200 with the liveness body', () async {
      final result = await _get(process.port, '/healthz');

      expect(result.statusCode, 200);
      final body = result.body as Map<String, Object?>;
      expect(body['status'], 'ok');
      expect(body['uptime_s'], isA<int>());
      final queues = body['queues'] as Map<String, Object?>;
      final foreground = queues['foreground'] as Map<String, Object?>;
      expect(foreground['running'], isFalse);
      expect(foreground['waiting'], 0);
      expect(queues['draining'], isFalse);
    });

    test('GET /v1/models answers 200 with the models-list body', () async {
      final result = await _get(process.port, '/v1/models');

      expect(result.statusCode, 200);
      final body = result.body as Map<String, Object?>;
      expect(body['object'], 'list');
      final data = body['data'] as List<Object?>;
      expect(data, isNotEmpty);
      final first = data.first as Map<String, Object?>;
      expect(first['object'], 'model');
      expect(first['id'], isA<String>());
    });

    test('stop() tears the cognition down — the substrate closes once and a '
        'second stop is a no-op', () async {
      await process.stop();
      expect(substrate.closeCount, 1,
          reason: 'the access-process teardown invokes the cognition shutdown');

      await process.stop();
      expect(substrate.closeCount, 1, reason: 'teardown runs at most once');
    });
  }, skip: skipNoBinary);
}
