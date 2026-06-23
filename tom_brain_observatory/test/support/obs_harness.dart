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

/// Drives the composed shelf handler with a `PUT` of a raw text [body] to
/// [path] — the source-authoring surface (§ 6.3, AUTH-1…AUTH-3) writes verbatim
/// text (a procedure script or a prompt-file half), not JSON.
Future<Response> obsPut(
  TrailReadApi api,
  String path, {
  String? body,
}) async =>
    api.handler(Request(
      'PUT',
      Uri.parse('http://localhost/$path'),
      body: body,
      headers: const <String, String>{'content-type': 'text/plain'},
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
  await obsGet(api, 'api/procedures');
  await obsGet(api, 'api/procedures/answer_with_memory_v1');

  // Dreaming-cycle monitor (§ 5A): the lane selector, the run list (all lanes
  // and one lane), one drilled-in run, and an absent run (404).
  await obsGet(api, 'api/dream/lanes');
  // The dreaming live-tail (§ 5A.5): over the finished fixture runs it replays
  // the newest run's ops then closes, so the no-mutation walk can drain it.
  await drainSse(await obsGet(api, 'api/dream/stream'));
  await obsGet(api, 'api/dream/runs');
  await obsGet(api, 'api/dream/runs?lane=fast');
  await obsGet(api, 'api/dream/runs/run_1781400000000001_0');
  await obsGet(api, 'api/dream/runs/run_does_not_exist_9');

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

  // Editable catalogue + authoring read surface (§ 8.3(9..11), steps 14–16):
  // the catalogue index and the read halves of the template / config authoring
  // routes. The ids/kinds match `writeMinimalCognitionTree`, so when [api] is
  // wired with a cognition root these execute their real read path; when it is
  // not they answer `503` "config unavailable". Either way they are reads and
  // write nothing — so OBS-1's "every endpoint mutates no trail file" walk now
  // genuinely covers the steps-14..16 surface too. The three PUT mutation routes
  // are deliberately *not* walked here: a successful write lands in its
  // sanctioned target (the procedure-script root is itself a snapshotted
  // brain-owned root), so their write behaviour is proven by the dedicated
  // endpoint tests plus the structural PT-8.4 / OBS-4 bounds, never by this
  // no-mutation walk.
  await obsGet(api, 'api/catalogue');
  await obsGet(api,
      'api/templates?id=assist_user.answer_with_memory.assembly&part=system');
  await obsGet(api, 'api/config?kind=registry&name=registry');
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

/// Writes a minimal but valid cognition tree to [root] — a registry, one
/// procedure config + its template folder, an llm route, a role persona, and a
/// `brain_run.yaml` carrying a valid `substrate:` block — so all four config
/// kinds (`registry`, `procedure`, `llm_route`, `substrate`) resolve through the
/// cognition catalogue. Shared by the config-endpoint tests (which exercise the
/// happy/422/403 paths) and the AUTH-6 conformance check (which proves the
/// anchor / tool-policy profiles are *not* among the editable kinds).
void writeMinimalCognitionTree(Directory root) {
  File('${root.path}/registry.yaml').writeAsStringSync('''
procedures:
  assist_user:
    config: assist_user.yaml
    folder: assist_user
roles:
  folder: roles
llm:
  folder: llm
  default: default
''');

  File('${root.path}/assist_user.yaml').writeAsStringSync('''
temperature: 1.0
llm: default

answer_with_memory:
  prompts:
    assembly:
      template: answer_with_memory.assembly
      tools: all
    tool_catalogue:
      template: answer_with_memory.tool_catalogue
      kind: fragment

answer_with_thinking:
  prompts:
    analysis:
      template: answer_with_thinking.analysis
      role: analyser
''');

  final Directory folder = Directory('${root.path}/assist_user')..createSync();
  File('${folder.path}/answer_with_memory.assembly.system.md')
      .writeAsStringSync('system framing\n');
  File('${folder.path}/answer_with_memory.assembly.user.md')
      .writeAsStringSync('user body\n');
  File('${folder.path}/answer_with_thinking.analysis.user.md')
      .writeAsStringSync('analysis body\n');
  File('${folder.path}/answer_with_memory.tool_catalogue.md')
      .writeAsStringSync('fragment body\n');

  Directory('${root.path}/llm').createSync();
  File('${root.path}/llm/default.yaml').writeAsStringSync('''
route:
  - provider: ollama
    model: gemma3:27b
''');

  Directory('${root.path}/roles').createSync();
  File('${root.path}/roles/analyser.persona.md')
      .writeAsStringSync('ANALYSER VOICE\n');

  // The whole-process run config the `substrate` kind resolves against
  // (run-config root defaults to the cognition root here). A minimal but valid
  // `substrate:` block — one stub provider, one role route, an embedding model.
  File('${root.path}/brain_run.yaml').writeAsStringSync('''
substrate:
  providers:
    - id: local
      kind: stub
  roleRoutes:
    assistant_to_user:
      - {providerId: local, model: base-model}
  embedding:
    providerId: local
    model: embed
    dims: 1
''');
}
