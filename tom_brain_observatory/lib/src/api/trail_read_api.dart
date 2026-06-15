// The Trail Read API (`prompt_tracing.md` § 8.3) — one shelf handler serving the
// read-only JSON API under `/api` and the embedded Flutter-web build under `/`,
// from a single process and origin (§ 8.5). Two endpoints in Phase 1:
//
//   GET /api/traces            → the §4.1 prompt list (last-N rows, newest-first)
//   GET /api/traces/{turnId}   → the §3.2 PromptTrace for one turn (404 if absent)
//
// Read-only is load-bearing (OBS-1, § 6.2): every request is a *fresh* parse of
// the immutable trail — the handler holds no cache that could diverge from what
// the brain wrote (§ 8.3) — and no path in this file ever opens a trail file for
// writing. The static root is read-only too (PT-1.5).
//
// `/api/*` is dispatched before the static root so an unknown `turnId` returns a
// real `404` instead of falling through to the SPA's `index.html`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show ProcedureValidationChain;
import 'package:tom_brain_run/tom_brain_run.dart'
    show CataloguePart, CognitionConfig;

import '../live/live_tail.dart';
import '../memory/memory_read_client.dart';
import '../model/prompt_trace.dart';
import '../parse/prompt_list_builder.dart';
import '../parse/prompt_trace_parser.dart';
import '../parse/trail_host.dart';
import 'catalogue_read_api.dart';
import 'memory_read_api.dart';

/// A read-only shelf service over one [TrailHost], optionally serving an
/// embedded web build from [webRoot]. Construct it, then mount [handler].
final class TrailReadApi {
  /// The host whose trail tree is read (fresh on every request).
  final TrailHost host;

  /// The default prompt-list window (`GET /api/traces`), configurable (§ 8.3).
  final int listLimit;

  /// The directory the embedded web build is served from at `/`, or `null` to
  /// serve only the `/api` surface (the web build lands in PT-2.0).
  final Directory? webRoot;

  /// The directory the running brain's procedure scripts live in
  /// (`scripts/system/`, § 4.6), served read-only by `GET /api/procedures/<id>`
  /// (PT-3.1) and written by `PUT /api/procedures/<id>` under the authoring
  /// guards (§ 6.3, AUTH-1…AUTH-3), or `null` when the observatory has no script
  /// root to expose (the endpoints then 404 — absence is never an error, § 4.1).
  final Directory? scriptRoot;

  /// The parsed cognition config, shared with the catalogue surface and used to
  /// resolve a `GET`/`PUT /api/templates` request's `?id=`/`?part=` to a
  /// registered template/role file (route 12 is the authoritative file set,
  /// § 6.3, § 8.3(9)). `null` when no cognition root was configured — the
  /// template routes then answer `503` "config unavailable", mirroring the
  /// catalogue route.
  final CognitionConfig? cognition;

  /// The cognition root directory the catalogue's root-relative paths resolve
  /// against, so `GET`/`PUT /api/templates` can read and write the on-disk
  /// template file. `null` when no cognition root was configured (the template
  /// routes then `503`). Containment to this root is the AUTH-2 guard.
  final Directory? cognitionRoot;

  /// The Module-2 memory read surface (`prompt_tracing.md` § 8.4), serving
  /// `/api/memory/*` over the injected [memory] client. The client is optional:
  /// absent it (the `dart_mcp` connector is deferred at run-assembly) every
  /// `/api/memory/*` route answers `503` "memory unavailable" — the routes
  /// always exist, so the UI gets a clean signal, never a 404.
  final MemoryReadApi _memoryApi;

  /// The editable-catalogue read surface (`prompt_tracing.md` § 8.3, plan
  /// step 14), serving `GET /api/catalogue` over the injected [cognition] config.
  /// The config is optional: absent it (the observatory was launched without a
  /// cognition root) the route answers `503` "config unavailable" — the route
  /// always exists, so the UI gets a clean signal, never a 404.
  final CatalogueReadApi _catalogueApi;

  TrailReadApi({
    required this.host,
    this.listLimit = 10,
    this.webRoot,
    this.scriptRoot,
    this.cognition,
    this.cognitionRoot,
    MemoryReadClient? memory,
    String substrateConfigFile = 'brain_run.yaml',
  })  : _memoryApi = MemoryReadApi(client: memory),
        _catalogueApi = CatalogueReadApi(
          config: cognition,
          substrateConfigFile: substrateConfigFile,
        );

  /// The closed set of editable template parts (§ 6.3, AUTH-1): the two halves
  /// of a prompt pair, a fragment's single file, and a role's persona/objective
  /// prose. Anything else is refused (`403`).
  static const Set<String> _templateParts = {
    'system',
    'user',
    'fragment',
    'persona',
    'objective',
  };

  /// The parts whose file must be non-empty on write (AUTH-3): a fragment and a
  /// role's prose carry meaning only when present, so an empty body is rejected
  /// `422`. A prompt pair's `system` / `user` half may be written empty — the
  /// empty-override signal the editor uses (§ 6.3).
  static const Set<String> _nonEmptyParts = {
    'fragment',
    'persona',
    'objective',
  };

  /// Whether a path key (a procedure id) is a single clean segment — ASCII word
  /// characters, underscore, and dash only. Procedure ids are identifiers
  /// (`answer_with_memory_v1`), so this allow-list is their exact shape. It is
  /// the AUTH-2 first line: it rejects a separator, a `..` traversal, and a
  /// percent-encoded `%2F` (which `shelf_router` leaves undecoded, so a raw
  /// containment check alone would treat it as a literal in-root filename)
  /// before any path is built.
  static bool _isSafeKey(String key) =>
      key.isNotEmpty && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(key);

  /// The composed handler: `/api/*` routed to the JSON API, everything else to
  /// the static root (when [webRoot] is set) with SPA fallback.
  Handler get handler {
    final api = _apiRouter.call;
    final static = webRoot == null ? null : _staticHandler(webRoot!);
    return (Request request) {
      if (_isApiPath(request.url.path)) return api(request);
      if (static != null) return static(request);
      return Response.notFound('not found');
    };
  }

  /// True when the request path addresses the JSON API (`api` or `api/…`).
  static bool _isApiPath(String path) => path == 'api' || path.startsWith('api/');

  Router get _apiRouter {
    final router = Router()
      ..get('/api/stream', _listStream)
      ..get('/api/traces', _listTraces)
      ..get('/api/traces/<turnId>/stream', _turnStream)
      ..get('/api/traces/<turnId>', _singleTrace)
      ..get('/api/llm', _llmRaw)
      ..get('/api/procedures/<procedureId>', _procedureScript)
      ..put('/api/procedures/<procedureId>', _writeProcedureScript)
      ..get('/api/templates', _readTemplateFile)
      ..put('/api/templates', _writeTemplateFile);
    _memoryApi.registerRoutes(router); // /api/memory/* (§ 8.4)
    _catalogueApi.registerRoutes(router); // /api/catalogue (§ 8.3, step 14)
    return router;
  }

  /// `GET /api/traces` — the prompt list as a JSON array (§ 4.1). An optional
  /// `?limit=` overrides the default window.
  Response _listTraces(Request request) {
    final limit = int.tryParse(request.url.queryParameters['limit'] ?? '') ??
        listLimit;
    final rows = promptList(host, limit: limit);
    return _json(<Object?>[for (final row in rows) row.toJson()]);
  }

  /// `GET /api/traces/{turnId}` — one PromptTrace, or `404` when the host has no
  /// trace for the turn (§ 4.1 — absence is a clean not-found, not an error).
  Response _singleTrace(Request request, String turnId) {
    final PromptTrace? trace = promptTraceFor(host, turnId);
    if (trace == null) {
      return _json(<String, Object?>{'error': 'no trace for turn $turnId'},
          status: HttpStatus.notFound);
    }
    return _json(trace.toJson());
  }

  /// `GET /api/traces/{turnId}/stream` — the SSE live-tail of one turn (§ 4.8):
  /// one `data:` event per cognitive step as the brain appends it to the
  /// per-session streaming live-trail, the stream closing after the turn's
  /// `✅ DONE`. Backed by a read-only file watch over that session's
  /// `*.live-trail.md` (OBS-5: no hook inside the brain). `404` when no session
  /// has written this turn yet — absence is never an error (§ 4.1).
  Response _turnStream(Request request, String turnId) {
    final file = host.liveTrailFileForTurn(turnId);
    if (file == null) {
      return _json(<String, Object?>{'error': 'no live trail for turn $turnId'},
          status: HttpStatus.notFound);
    }
    final steps = tailTurnSteps(
      file: file,
      turnId: turnId,
      changes: liveTrailChanges(file),
    );
    return _sse(steps.map((step) => step.toJson()));
  }

  /// `GET /api/stream` — the list-level live-tail (§ 4.8): an SSE `{"changed":
  /// true}` tick the prompt list re-fetches `/api/traces` on. It emits once on
  /// connect (so a fresh client immediately syncs) and again whenever any
  /// session live-trail changes. Read-only — a directory watch, never a hook.
  Response _listStream(Request request) {
    final dir = Directory(p.join(host.root.path, 'sessions'));
    return _sse(_listChanges(dir).map((_) => <String, Object?>{'changed': true}));
  }

  /// `GET /api/llm?turn=<turnId>&path=<rawPath>` — the verbatim raw LLM dump
  /// (§ 3.7) behind a run-tree `LlmCall`'s `rawPath` link. The run-tree JSON
  /// only carries the link (§ 3.9); this endpoint serves the full §4.5 detail
  /// (hashes, wire body, answer) the front-end needs (PT-2.4).
  ///
  /// `rawPath` is the `../../llm/…raw.json` link from the run-tree `.log`,
  /// resolved against that turn's procedure-log folder. A containment guard
  /// refuses anything that does not resolve under `<root>/llm/` or that is not a
  /// `.raw.json` — the link can only address an LLM dump, never an arbitrary
  /// file (read-only, OBS-1). The body is passed through verbatim: it is already
  /// the JSON the brain wrote, so the endpoint re-parses nothing.
  Response _llmRaw(Request request) {
    final turnId = request.url.queryParameters['turn'];
    final rawPath = request.url.queryParameters['path'];
    if (turnId == null || rawPath == null) {
      return _json(<String, Object?>{'error': 'requires ?turn= and ?path='},
          status: HttpStatus.badRequest);
    }
    final procedureLog = host.procedureLogFor(turnId);
    if (procedureLog == null) {
      return _json(<String, Object?>{'error': 'no run for turn $turnId'},
          status: HttpStatus.notFound);
    }
    final file = host.llmRawFromLink(procedureLog, rawPath);
    final llmRoot = p.normalize(p.join(host.root.absolute.path, 'llm'));
    final resolved = p.normalize(file.absolute.path);
    if (!p.isWithin(llmRoot, resolved) || !resolved.endsWith('.raw.json')) {
      return _json(<String, Object?>{'error': 'path is not an llm dump'},
          status: HttpStatus.forbidden);
    }
    if (!file.existsSync()) {
      return _json(<String, Object?>{'error': 'no llm dump at $rawPath'},
          status: HttpStatus.notFound);
    }
    return Response.ok(
      file.readAsStringSync(),
      headers: <String, String>{'content-type': 'application/json; charset=utf-8'},
    );
  }

  /// `GET /api/procedures/{procedureId}` — the verbatim d4rt source of the
  /// running brain's procedure script `scripts/system/<procedureId>.dart`
  /// (§ 4.6, § 8.3(5)), so the Module-1 inspector can show what actually ran
  /// (PT-3.1). Served as `text/plain`; the front-end renders it read-only.
  ///
  /// A containment guard refuses any `procedureId` that resolves outside the
  /// [scriptRoot] (path-traversal via `../`) or that is not a `.dart` file —
  /// only a script *inside the script directory* is ever reachable (read-only,
  /// OBS-1). The body is passed through verbatim. When [scriptRoot] is `null`
  /// (no script root configured) or the script is absent, the result is `404` —
  /// absence is never an error (§ 4.1).
  Response _procedureScript(Request request, String procedureId) {
    final root = scriptRoot;
    if (root == null) {
      return _json(<String, Object?>{'error': 'no script root configured'},
          status: HttpStatus.notFound);
    }
    final scriptsRoot = p.normalize(root.absolute.path);
    final resolved =
        p.normalize(p.join(scriptsRoot, '$procedureId.dart'));
    if (!p.isWithin(scriptsRoot, resolved) || !resolved.endsWith('.dart')) {
      return _json(<String, Object?>{'error': 'not a procedure script'},
          status: HttpStatus.forbidden);
    }
    final file = File(resolved);
    if (!file.existsSync()) {
      return _json(<String, Object?>{'error': 'no script $procedureId'},
          status: HttpStatus.notFound);
    }
    return Response.ok(
      file.readAsStringSync(),
      headers: <String, String>{'content-type': 'text/plain; charset=utf-8'},
    );
  }

  /// `PUT /api/procedures/{procedureId}` — the source-authoring surface (§ 6.3,
  /// § 8.3(8)): writes a procedure script back to
  /// `scripts/system/<procedureId>.dart` so the running brain re-reads it on its
  /// next run (AUTH-5; no signal, the brain pulls). The body is the verbatim
  /// d4rt source.
  ///
  /// The three AUTH guards land in order:
  ///   - AUTH-2 (containment): the same normalise + `isWithin` + `.dart` guard
  ///     the read path uses — an id that escapes [scriptRoot] is refused `403`
  ///     before any read or write.
  ///   - AUTH-3 (validate-before-write): the body is run through the brain's own
  ///     [ProcedureValidationChain] (header → sandbox → contract, LLM-free,
  ///     executes nothing). A body with a malformed header, a sandbox violation,
  ///     or a broken contract is rejected `422` with the findings, and the
  ///     on-disk file is left untouched — a bad save can never reach the brain.
  ///
  /// `404` when [scriptRoot] is `null` (no script root configured), mirroring
  /// the read endpoint — absence is never an error (§ 4.1).
  Future<Response> _writeProcedureScript(
    Request request,
    String procedureId,
  ) async {
    final root = scriptRoot;
    if (root == null) {
      return _json(<String, Object?>{'error': 'no script root configured'},
          status: HttpStatus.notFound);
    }
    final scriptsRoot = p.normalize(root.absolute.path);
    final resolved = p.normalize(p.join(scriptsRoot, '$procedureId.dart'));
    if (!_isSafeKey(procedureId) ||
        !p.isWithin(scriptsRoot, resolved) ||
        !resolved.endsWith('.dart')) {
      return _json(<String, Object?>{'error': 'not a procedure script'},
          status: HttpStatus.forbidden);
    }
    final source = await request.readAsString();
    final validation = ProcedureValidationChain.shared.validate(source);
    if (!validation.ok) {
      return _json(
        <String, Object?>{
          'error': 'procedure validation failed',
          'findings': <Object?>[
            for (final finding in validation.findings) finding.toMap(),
          ],
        },
        status: HttpStatus.unprocessableEntity,
      );
    }
    File(resolved).writeAsStringSync(source);
    return _json(<String, Object?>{'ok': true, 'id': procedureId});
  }

  /// `GET /api/templates?id=<promptId>&part=<part>` — the verbatim text of any
  /// registered template file (§ 6.3, § 8.3(9)): a prompt pair's `system` /
  /// `user` half, a `fragment`'s single file, or a role's `persona` / `objective`
  /// prose. The registered file set comes from the cognition catalogue (route
  /// 12), so an unregistered id/part is `403`, never an arbitrary file read.
  /// Served `text/plain`.
  ///
  /// A registered-but-absent half (one side of a pair, or a not-yet-created role
  /// override) is the empty-override signal: it is served as an **empty body
  /// 200**, not a `404` — the editor turns an empty body into "create override"
  /// (§ 6.3). `503` "config unavailable" when no cognition config is wired,
  /// mirroring the catalogue route.
  Response _readTemplateFile(Request request) {
    final config = cognition;
    final root = cognitionRoot;
    if (config == null || root == null) {
      return _json(<String, Object?>{'error': 'config unavailable'},
          status: HttpStatus.serviceUnavailable);
    }
    final id = request.url.queryParameters['id'];
    final part = request.url.queryParameters['part'];
    if (id == null || part == null) {
      return _json(<String, Object?>{'error': 'requires ?id= and ?part='},
          status: HttpStatus.badRequest);
    }
    final resolved = _templateFilePath(id, part);
    if (resolved == null) {
      return _json(<String, Object?>{'error': 'not a registered template file'},
          status: HttpStatus.forbidden);
    }
    final file = File(resolved);
    final body = file.existsSync() ? file.readAsStringSync() : '';
    return Response.ok(
      body,
      headers: <String, String>{'content-type': 'text/plain; charset=utf-8'},
    );
  }

  /// `PUT /api/templates?id=<promptId>&part=<part>` — writes (materialising if
  /// absent) any registered template file so the brain re-reads it on its next
  /// assembled call for that template/role (AUTH-5; no signal, the brain pulls).
  /// The body is the verbatim template/prose text.
  ///
  /// The AUTH guards land in order:
  ///   - AUTH-2 (containment): the id/part must resolve, via the catalogue, to a
  ///     file inside the cognition root ending `.md` ([_templateFilePath]); an
  ///     unregistered or escaping target is `403` before any write.
  ///   - AUTH-3 (validate-before-write): the body is placeholder-scanned — a
  ///     malformed (unterminated) `${…}` / `${{…}}` token is rejected `422` with
  ///     the offending token, the file left untouched. A prompt pair's `system`
  ///     / `user` half may be empty (the empty-override signal); a fragment /
  ///     persona / objective must be non-empty (`422` otherwise).
  ///
  /// `503` "config unavailable" when no cognition config is wired.
  Future<Response> _writeTemplateFile(Request request) async {
    final config = cognition;
    final root = cognitionRoot;
    if (config == null || root == null) {
      return _json(<String, Object?>{'error': 'config unavailable'},
          status: HttpStatus.serviceUnavailable);
    }
    final id = request.url.queryParameters['id'];
    final part = request.url.queryParameters['part'];
    if (id == null || part == null) {
      return _json(<String, Object?>{'error': 'requires ?id= and ?part='},
          status: HttpStatus.badRequest);
    }
    final resolved = _templateFilePath(id, part);
    if (resolved == null) {
      return _json(<String, Object?>{'error': 'not a registered template file'},
          status: HttpStatus.forbidden);
    }
    final body = await request.readAsString();
    final malformed = _malformedPlaceholder(body);
    if (malformed != null) {
      return _json(
        <String, Object?>{'error': 'malformed placeholder', 'detail': malformed},
        status: HttpStatus.unprocessableEntity,
      );
    }
    if (_nonEmptyParts.contains(part) && body.trim().isEmpty) {
      return _json(
        <String, Object?>{'error': '$part template must be non-empty'},
        status: HttpStatus.unprocessableEntity,
      );
    }
    File(resolved).writeAsStringSync(body);
    return _json(<String, Object?>{'ok': true, 'id': id, 'part': part});
  }

  /// Resolves the on-disk path of the registered template file for [id]/[part]
  /// via the cognition catalogue (route 12, the authoritative file set), or
  /// `null` when [part] is not editable, [id] is not a registered template/role,
  /// or the resolved path escapes the cognition root (the AUTH-2 containment
  /// guard). The path is taken from the catalogue, never concatenated from raw
  /// caller input, so a traversal `id` simply fails to match and is refused.
  String? _templateFilePath(String id, String part) {
    final config = cognition;
    final root = cognitionRoot;
    if (config == null || root == null || !_templateParts.contains(part)) {
      return null;
    }
    final catalogue = config.catalogue();
    String? relative;
    if (part == 'persona' || part == 'objective') {
      for (final role in catalogue.roles) {
        if (role.name != id) continue;
        relative = part == 'persona' ? role.personaPath : role.objectivePath;
        break;
      }
    } else {
      final wanted = part == 'system'
          ? CataloguePart.system
          : part == 'user'
              ? CataloguePart.user
              : CataloguePart.fragment;
      for (final template in catalogue.templates) {
        if (template.id != id) continue;
        for (final file in template.files) {
          if (file.part != wanted) continue;
          relative = file.path;
          break;
        }
        break;
      }
    }
    if (relative == null) return null;
    final cognitionDir = p.normalize(root.absolute.path);
    final resolved = p.normalize(p.join(cognitionDir, relative));
    if (!p.isWithin(cognitionDir, resolved) || !resolved.endsWith('.md')) {
      return null;
    }
    return resolved;
  }

  /// Scans [text] for a malformed placeholder (AUTH-3): an unterminated
  /// `${ … }` or `${{ … }}` token. Returns a human-readable description of the
  /// first offending token, or `null` when every placeholder is well-formed.
  ///
  /// The brain's resolver (`tom_core_agentic`) tolerates an unterminated `${` by
  /// emitting it as literal text; the editor is deliberately stricter on write
  /// so an author gets immediate feedback rather than a silently-literal token.
  static String? _malformedPlaceholder(String text) {
    var index = 0;
    while (true) {
      final open = text.indexOf(r'${', index);
      if (open < 0) return null;
      if (text.startsWith(r'${{', open)) {
        final end = _expressionEnd(text, open + 3);
        if (end < 0) return 'unterminated \${{ … }} at offset $open';
        index = end + 2;
      } else {
        final close = text.indexOf('}', open + 2);
        if (close < 0) return 'unterminated \${ … } at offset $open';
        index = close + 1;
      }
    }
  }

  /// Index of the first `}` of the closing `}}` for a `${{` expression opened at
  /// [start] (just past the `${{`), or `-1` if unterminated. Mirrors the brain
  /// resolver's brace-balanced scan so an inner `{ }` does not close it early.
  static int _expressionEnd(String text, int start) {
    var depth = 0;
    for (var i = start; i < text.length; i++) {
      final char = text[i];
      if (char == '{') {
        depth++;
      } else if (char == '}') {
        if (depth > 0) {
          depth--;
        } else if (i + 1 < text.length && text[i + 1] == '}') {
          return i;
        } else {
          return -1;
        }
      }
    }
    return -1;
  }

  /// The static root (PT-1.5): the web build served read-only, with an
  /// `index.html` SPA fallback for unknown app routes. `createStaticHandler`
  /// refuses path-traversal outside [root]; the fallback only ever serves the
  /// build's own `index.html`, never a file outside the root.
  Handler _staticHandler(Directory root) {
    final files = createStaticHandler(root.path, defaultDocument: 'index.html');
    final index = File(p.join(root.path, 'index.html'));
    return Cascade().add(files).add((_) => _spaFallback(index)).handler;
  }

  Response _spaFallback(File index) => index.existsSync()
      ? Response.ok(index.readAsBytesSync(),
          headers: <String, String>{'content-type': 'text/html'})
      : Response.notFound('not found');

  Response _json(Object? body, {int status = HttpStatus.ok}) => Response(
        status,
        body: jsonEncode(body),
        headers: <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );

  /// Wraps [events] as a `text/event-stream` response, one `data: <json>` frame
  /// per event. When the source stream closes (a finished turn) the SSE closes;
  /// when the client disconnects shelf cancels the body subscription, tearing
  /// down the underlying file watch (the source streams' `onCancel`).
  Response _sse(Stream<Object?> events) => Response.ok(
        events.map((event) =>
            utf8.encode('data: ${jsonEncode(event)}\n\n')),
        headers: <String, String>{
          'content-type': 'text/event-stream; charset=utf-8',
          'cache-control': 'no-cache',
        },
      );

  /// A read-only change signal for the list-level stream: an immediate tick on
  /// connect plus a tick whenever a `*.live-trail.md` under [dir] changes (an
  /// OS directory watch). Opens nothing for writing (OBS-5); cancelling the
  /// subscription tears the watch down (the `async*` body returns).
  Stream<void> _listChanges(Directory dir) async* {
    yield null; // Sync the client immediately on connect.
    if (!dir.existsSync()) return;
    yield* dir
        .watch()
        .where((event) => event.path.endsWith('.live-trail.md'))
        .map((_) {});
  }
}
