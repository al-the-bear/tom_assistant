// Shared test harness for the read-only / no-interference conformance suite
// (Phase 8, `prompt_tracing_plan.md` § 9) and the per-endpoint tests it
// consolidates. It collects the helpers that were copy-pasted across the
// endpoint tests — `obsGet`/`obsPost` (drive the shelf handler), `drainSse`
// (read an SSE body to its decoded `data:` payloads), and `FsSnapshot` (the
// no-mutation invariant) — plus `exerciseEveryEndpoint` (hit every route once)
// and `libDartSources` (the source-structure proofs of OBS-3/4/5).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_observatory/tom_brain_observatory.dart';

/// The committed fixture trail tree every endpoint test reads.
const String fixtureHostPath = 'test/fixtures/trail/fixturehost';

/// The fixture web build served at `/` (PT-1.5).
const String fixtureWebRootPath = 'test/fixtures/webroot';

/// The fixture procedure-script root served by `GET /api/procedures/<id>`.
const String fixtureScriptRootPath = 'test/fixtures/scripts';

/// A finished fixture turn (its live-trail block ends with `✅ DONE`, so the
/// per-turn SSE stream emits all its steps then closes — exercisable offline).
const String fixtureFinishedTurn = '260101-120000.000001';

/// The run-tree `rawPath` link the §3.7 LLM dump endpoint resolves, relative to
/// `procedures/<proc>/` (matches `llm_raw_endpoint_test.dart`).
const String fixtureLlmLink =
    '../../llm/assistant_to_user/260101-120000.000001__02.raw.json';

/// Drives the composed shelf handler with a `GET` to [path].
Future<Response> obsGet(TrailReadApi api, String path) async =>
    api.handler(Request('GET', Uri.parse('http://localhost/$path')));

/// Drives the composed shelf handler with a `POST` of [body] (JSON) to [path].
Future<Response> obsPost(
  TrailReadApi api,
  String path, {
  Object? body,
}) async =>
    api.handler(Request(
      'POST',
      Uri.parse('http://localhost/$path'),
      body: body == null ? null : jsonEncode(body),
      headers: const <String, String>{'content-type': 'application/json'},
    ));

/// Reads an SSE body to completion, returning the decoded `data:` payloads.
Future<List<Object?>> drainSse(Response res) async {
  final body = await res.readAsString();
  return <Object?>[
    for (final line in const LineSplitter().convert(body))
      if (line.startsWith('data: '))
        jsonDecode(line.substring('data: '.length)),
  ];
}

/// Reads the first SSE chunk of a never-closing stream (e.g. `/api/stream`),
/// then stops — so the conformance walk can touch that route without hanging.
Future<void> drainFirstSseChunk(Response res) async {
  await res.read().first;
}

/// Issues one request to **every** route the [api] exposes — the JSON trace
/// endpoints, both SSE streams, the raw-LLM and procedure-script endpoints, the
/// static root, and the nine `/api/memory/*` routes — so a single no-mutation
/// snapshot can prove OBS-1 across the whole surface at once. [api] must be
/// wired with a web root, a script root, and a memory client for the full walk.
Future<void> exerciseEveryEndpoint(TrailReadApi api) async {
  // Trace JSON (§ 4.1): list, capped list, one trace, an absent trace (404).
  await obsGet(api, 'api/traces');
  await obsGet(api, 'api/traces?limit=1');
  await obsGet(api, 'api/traces/$fixtureFinishedTurn');
  await obsGet(api, 'api/traces/991231-235959.999999');

  // Live-tail (§ 4.8): the finished turn streams to completion; the list stream
  // emits one tick then we stop.
  await drainSse(await obsGet(api, 'api/traces/$fixtureFinishedTurn/stream'));
  await drainFirstSseChunk(await obsGet(api, 'api/stream'));

  // Raw LLM dump (§ 3.7) + procedure source (§ 4.6).
  await obsGet(
    api,
    'api/llm?turn=$fixtureFinishedTurn'
        '&path=${Uri.encodeQueryComponent(fixtureLlmLink)}',
  );
  await obsGet(api, 'api/procedures/answer_with_memory_v1');

  // Static root + an asset + an SPA fallback (§ 8.5).
  await obsGet(api, '');
  await obsGet(api, 'assets/main.dart.js');
  await obsGet(api, 'traces/some-spa-route');

  // Memory read surface (§ 8.4) — the nine read routes.
  await obsGet(api, 'api/memory/nodes?type=Question');
  await obsGet(api, 'api/memory/nodes/n_question1');
  await obsGet(api, 'api/memory/edges?id=n_question1');
  await obsPost(api, 'api/memory/recall', body: <String, Object?>{'text': 'x'});
  await obsPost(api, 'api/memory/recall/multi', body: <String, Object?>{
    'seeds': <Object?>[
      <String, Object?>{'mode': 'bm25', 'text': 'x'},
    ],
  });
  await obsGet(api, 'api/memory/stacks');
  await obsGet(api, 'api/memory/stacks/working');
  await obsPost(api, 'api/memory/classify',
      body: <String, Object?>{'embedding': <double>[0.1, 0.2]});
  await obsGet(api, 'api/memory/profiles');
}

/// A no-mutation fingerprint of every file under a trail root: path → (modified,
/// changed, size, mode). Dart's [FileStat] exposes no inode number, so this uses
/// the inode *change* time ([FileStat.changed]) — which moves on truncate /
/// rewrite / replace — together with size and the full path set as the portable
/// equivalent of a "mtime + inode" invariant. Access time is deliberately
/// excluded (a read updates atime; that is allowed — OBS-4 permits read I/O).
final class FsSnapshot {
  FsSnapshot._(this._files);

  final Map<String, String> _files;

  /// Fingerprints every regular file under [root] (recursively).
  factory FsSnapshot.capture(String root) {
    final files = <String, String>{};
    for (final entity in Directory(root).listSync(recursive: true)) {
      if (entity is! File) continue;
      final stat = entity.statSync();
      files[entity.path] = '${stat.modified.microsecondsSinceEpoch}'
          '|${stat.changed.microsecondsSinceEpoch}'
          '|${stat.size}'
          '|${stat.mode}';
    }
    return FsSnapshot._(files);
  }

  /// The set of files that were created, deleted, or modified between this
  /// snapshot and [other]. Empty ⇒ the tree is byte-for-byte untouched.
  List<String> diff(FsSnapshot other) {
    final changes = <String>[];
    for (final entry in _files.entries) {
      if (!other._files.containsKey(entry.key)) {
        changes.add('deleted: ${entry.key}');
      } else if (other._files[entry.key] != entry.value) {
        changes.add('modified: ${entry.key}');
      }
    }
    for (final path in other._files.keys) {
      if (!_files.containsKey(path)) changes.add('created: $path');
    }
    return changes;
  }
}

/// Every `lib/**/*.dart` source as path → content — the substrate for the
/// source-structure proofs (no write IO anywhere; the memory door holds no
/// `dart:io`). Run from the package root, where the test harness executes.
Map<String, String> libDartSources() => <String, String>{
      for (final entity in Directory('lib').listSync(recursive: true))
        if (entity is File && entity.path.endsWith('.dart'))
          entity.path: entity.readAsStringSync(),
    };
