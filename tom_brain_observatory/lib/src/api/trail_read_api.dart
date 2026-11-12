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
import 'package:tom_brain_config/tom_brain_config.dart'
    show
        BrainRunConfigLoader,
        CatalogueConfigFile,
        CatalogueConfigKind,
        CataloguePart,
        CognitionConfig,
        CognitionConfigException,
        CognitionConfigLoader;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show SubstrateConfigException, SubstrateConfigLoader;

import '../live/dream_tail.dart';
import '../live/live_tail.dart';
import '../launch/runtime_snapshot.dart';
import '../memory/memory_read_client.dart';
import '../model/dream_run.dart';
import '../model/prompt_trace.dart';
import '../parse/dream_list_builder.dart';
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

  /// The run-config root the `substrate` config file ([substrateConfigFile],
  /// default `brain_run.yaml`) resolves against for `GET`/`PUT /api/config`
  /// (plan step 16). The whole-process run config can live outside the cognition
  /// root, so it is a distinct containment root (AUTH-2) — but it defaults to
  /// [cognitionRoot] when not separately configured (the common single-tree
  /// layout). The registry/procedure/llm config kinds always resolve against
  /// [cognitionRoot]; only the substrate kind uses this root.
  final Directory? runConfigRoot;

  /// The file the `substrate:` provider/model block lives in, relative to
  /// [runConfigRoot] (default `brain_run.yaml`, § 6.4 / route 10). Shared with
  /// the catalogue surface so the config-file inventory and the `/api/config`
  /// resolution agree on the substrate path.
  final String substrateConfigFile;

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

  /// The live runtime snapshot the running brain threaded in (§ 8.3(13)),
  /// served by `GET /api/runtime` for the Runtime tab's "currently running"
  /// display (§ 6.4). `null` when the observatory runs standalone (no live brain
  /// to ask) — the route then `503`s "runtime unavailable".
  final RuntimeSnapshot? runtime;

  /// Whether the three authoring PUTs (procedure script, template, config) may
  /// write (`--observatory-readonly` forces this `false`, plan step 9). When
  /// `false` every PUT short-circuits `409 config_is_immutable` *before* the
  /// AUTH guards — the authoring surface is closed, not merely validated
  /// stricter — and `GET /api/meta` reports it so the editor greys its controls.
  /// Defaults to `true` (the common in-process-against-a-running-brain case,
  /// where retuning config is the point).
  final bool configWritable;

  TrailReadApi({
    required this.host,
    this.listLimit = 10,
    this.webRoot,
    this.scriptRoot,
    this.cognition,
    this.cognitionRoot,
    Directory? runConfigRoot,
    MemoryReadClient? memory,
    this.substrateConfigFile = 'brain_run.yaml',
    this.runtime,
    this.configWritable = true,
  })  : runConfigRoot = runConfigRoot ?? cognitionRoot,
        _memoryApi = MemoryReadApi(client: memory),
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
      ..get('/api/procedures', _listProcedureScripts)
      ..get('/api/procedures/<procedureId>', _procedureScript)
      ..put('/api/procedures/<procedureId>', _writeProcedureScript)
      ..get('/api/templates', _readTemplateFile)
      ..put('/api/templates', _writeTemplateFile)
      ..get('/api/config', _readConfigFile)
      ..put('/api/config', _writeConfigFile)
      ..get('/api/dream/lanes', _dreamLanes)
      ..get('/api/dream/stream', _dreamStream)
      ..get('/api/dream/runs', _dreamRuns)
      ..get('/api/dream/runs/<runId>', _dreamRun)
      ..get('/api/runtime', _runtimeSnapshot)
      ..get('/api/meta', _meta);
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

  /// `GET /api/llm?path=<rawPath>` with **exactly one** of `turn=<turnId>` or
  /// `run=<runId>` — the verbatim raw LLM dump (§ 3.7) behind a run-tree
  /// `LlmCall`'s `rawPath` link. The run-tree JSON only carries the link
  /// (§ 3.9); this endpoint serves the full §4.5 detail (hashes, wire body,
  /// answer) the front-end needs (PT-2.4).
  ///
  /// `turn=` resolves the link against a turn-bound run's procedure-log folder;
  /// `run=` resolves it against a **turn-less dream/free-time run**'s folder
  /// (MSPP-55, the dreaming-side counterpart — a dream has no `turnId`, § 5A.4).
  /// The two differ only in how the procedure log is located
  /// ([TrailHost.procedureLogFor] vs [TrailHost.dreamRunLog]); the link
  /// resolution, the containment guard, and the verbatim pass-through are
  /// identical, so the endpoint stays a single seam.
  ///
  /// `rawPath` is the `../../llm/…raw.json` link from the run-tree `.log`,
  /// resolved against that run's procedure-log folder. A containment guard
  /// refuses anything that does not resolve under `<root>/llm/` or that is not a
  /// `.raw.json` — the link can only address an LLM dump, never an arbitrary
  /// file (read-only, OBS-1). The body is passed through verbatim: it is already
  /// the JSON the brain wrote, so the endpoint re-parses nothing.
  Response _llmRaw(Request request) {
    final turnId = request.url.queryParameters['turn'];
    final runId = request.url.queryParameters['run'];
    final rawPath = request.url.queryParameters['path'];
    if (rawPath == null || (turnId == null) == (runId == null)) {
      return _json(
          <String, Object?>{
            'error': 'requires ?path= and exactly one of ?turn= or ?run='
          },
          status: HttpStatus.badRequest);
    }
    final File? procedureLog = turnId != null
        ? host.procedureLogFor(turnId)
        : host.dreamRunLog(runId!);
    if (procedureLog == null) {
      final what = turnId != null ? 'turn $turnId' : 'dream run $runId';
      return _json(<String, Object?>{'error': 'no run for $what'},
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

  /// `GET /api/procedures` — the ids of every procedure script the running brain
  /// hosts under [scriptRoot] (`scripts/system/<id>.dart`, § 4.6 / § 8.3(5)), as
  /// a sorted JSON array of stems. Feeds the gear editor's Procedures tab so each
  /// script is offerable for inspection/authoring beside its yaml config — the
  /// same scripts the Run Tree opens by id.
  ///
  /// Only top-level `.dart` files are listed (their stem, without the suffix);
  /// any other file is ignored. When [scriptRoot] is `null` (no script root
  /// configured) the list is empty — absence is never an error, mirroring the
  /// `503`-free degradation of the catalogue route.
  Response _listProcedureScripts(Request request) {
    final root = scriptRoot;
    final ids = <String>[
      if (root != null && root.existsSync())
        for (final entity in root.listSync())
          if (entity is File && entity.path.endsWith('.dart'))
            p.basenameWithoutExtension(entity.path),
    ]..sort();
    return _json(ids);
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
    final immutable = _immutableConfig();
    if (immutable != null) return immutable;
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
    final immutable = _immutableConfig();
    if (immutable != null) return immutable;
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

  /// `GET /api/config?kind=<kind>&name=<name>` — the verbatim text of a
  /// registered config file (§ 6.3, § 8.3(10)): `kind ∈ {registry, procedure,
  /// llm_route, substrate, run}` (`run` is the whole `brain_run.yaml`, § 6.4
  /// Runtime tab). The registered set comes from the cognition
  /// catalogue (route 12), so an unregistered kind/name — or a path that escapes
  /// its containment root — is `403`, never an arbitrary file read. Served
  /// `text/plain`.
  ///
  /// Unlike a template override (offered as an empty document to create), a
  /// config file the brain needs at boot must exist: a registered-but-absent
  /// config is a misconfiguration, served `404` (not an empty body). `503`
  /// "config unavailable" when no cognition config is wired.
  Response _readConfigFile(Request request) {
    final config = cognition;
    if (config == null || cognitionRoot == null) {
      return _json(<String, Object?>{'error': 'config unavailable'},
          status: HttpStatus.serviceUnavailable);
    }
    final kind = request.url.queryParameters['kind'];
    final name = request.url.queryParameters['name'];
    if (kind == null || name == null) {
      return _json(<String, Object?>{'error': 'requires ?kind= and ?name='},
          status: HttpStatus.badRequest);
    }
    final resolved = _configFilePath(kind, name);
    if (resolved == null) {
      return _json(<String, Object?>{'error': 'not a registered config file'},
          status: HttpStatus.forbidden);
    }
    final file = File(resolved);
    if (!file.existsSync()) {
      return _json(<String, Object?>{'error': 'no config file $kind/$name'},
          status: HttpStatus.notFound);
    }
    return Response.ok(
      file.readAsStringSync(),
      headers: <String, String>{'content-type': 'text/plain; charset=utf-8'},
    );
  }

  /// `PUT /api/config?kind=<kind>&name=<name>` — writes a registered config file
  /// so the brain re-reads it (AUTH-5; no signal, the brain pulls). The body is
  /// the verbatim YAML.
  ///
  /// The AUTH guards land in order:
  ///   - AUTH-2 (containment): the kind/name must resolve, via the catalogue, to
  ///     a `.yaml` file inside its containment root — the cognition root for
  ///     registry/procedure/llm_route, the run-config root for substrate
  ///     ([_configFilePath]); an unregistered or escaping target is `403` before
  ///     any write.
  ///   - AUTH-3 (validate-before-write): the proposed content is parsed by the
  ///     brain's *own* loader — `SubstrateConfigLoader` for the `substrate:`
  ///     block, `CognitionConfigLoader` for registry/procedure/llm_route — the
  ///     same fail-fast validation the brain applies at boot (unknown key,
  ///     missing default, unknown llm route). A config the brain would reject at
  ///     boot is rejected `422` here with the loader's located message, the
  ///     on-disk file left untouched. The proposed edit is validated *in memory*
  ///     (the other config files are read from disk and the edited one
  ///     substituted) — never by mutating a temp tree — so the read-only
  ///     filesystem discipline (OBS-1, the authoring surface writes only via
  ///     `writeAsStringSync`) holds.
  ///
  /// On success the response reports the AUTH-4 effect: a procedure config edit
  /// (per-prompt settings) is `next-use`; a registry / llm_route / substrate edit
  /// (structure + provider routing the loader reads at boot) is `next-boot`.
  /// `503` "config unavailable" when no cognition config is wired.
  Future<Response> _writeConfigFile(Request request) async {
    final immutable = _immutableConfig();
    if (immutable != null) return immutable;
    final config = cognition;
    if (config == null || cognitionRoot == null) {
      return _json(<String, Object?>{'error': 'config unavailable'},
          status: HttpStatus.serviceUnavailable);
    }
    final kind = request.url.queryParameters['kind'];
    final name = request.url.queryParameters['name'];
    if (kind == null || name == null) {
      return _json(<String, Object?>{'error': 'requires ?kind= and ?name='},
          status: HttpStatus.badRequest);
    }
    final resolved = _configFilePath(kind, name);
    if (resolved == null) {
      return _json(<String, Object?>{'error': 'not a registered config file'},
          status: HttpStatus.forbidden);
    }
    final body = await request.readAsString();
    final rejection = _validateConfig(kind, name, body);
    if (rejection != null) {
      return _json(
        <String, Object?>{'error': 'config validation failed', 'detail': rejection},
        status: HttpStatus.unprocessableEntity,
      );
    }
    File(resolved).writeAsStringSync(body);
    return _json(<String, Object?>{
      'ok': true,
      'kind': kind,
      'name': name,
      'effect': _effectFor(kind),
    });
  }

  /// `GET /api/dream/lanes` — the Module-3 lane selector (§ 5A.2): the configured
  /// cadence lanes (id, agent set, recent-run count) plus the synthetic `other`
  /// lane when any discovered dream run is unclaimed. A pure read of the
  /// `procedures/` trail — empty array in unconfigured mode, never an error.
  Response _dreamLanes(Request request) {
    final lanes = dreamLanes(host, schedule: runtime?.cadence);
    return _json(<Object?>[for (final lane in lanes) lane.toJson()]);
  }

  /// `GET /api/dream/runs?lane=<id>` — the Module-3 run list (§ 5A.2): the recent
  /// turn-less dream runs, newest-first, optionally filtered to one lane. Empty
  /// array when no dream runs exist (absence is never an error, § 4.1).
  Response _dreamRuns(Request request) {
    final lane = request.url.queryParameters['lane'];
    final rows = dreamRunRows(host, lane: lane, schedule: runtime?.cadence);
    return _json(<Object?>[for (final row in rows) row.toJson()]);
  }

  /// `GET /api/dream/stream?lane=<id>` — the Module-3 dreaming live-tail (§ 5A.5):
  /// an SSE that adopts the active (newest) turn-less dream run — optionally
  /// confined to a lane — replays its run-tree operations, tails each appended op
  /// as a `data:` frame, and closes with a terminal `{"done": true, …}` frame on
  /// the run's outcome. Backed by a read-only recursive watch over `procedures/`
  /// (OBS-5: no hook in the brain). Idle (open, no frames) when no dream run is
  /// active — absence is never an error (§ 4.1).
  Response _dreamStream(Request request) {
    final lane = request.url.queryParameters['lane'];
    final frames = tailNewestDreamRun(
      host: host,
      lane: lane,
      schedule: runtime?.cadence,
      changes: dreamRunChanges(host),
    );
    return _sse(frames);
  }

  /// `GET /api/dream/runs/{runId}` — one drilled-in dream run as the full § 3.6
  /// `ProcedureRun` tree (§ 5A.4), or `404` when no turn-less log with that id
  /// exists — the dreaming-side mirror of `GET /api/traces/{turnId}`.
  Response _dreamRun(Request request, String runId) {
    final DreamRun? run = dreamRunFor(host, runId, schedule: runtime?.cadence);
    if (run == null) {
      return _json(<String, Object?>{'error': 'no dream run $runId'},
          status: HttpStatus.notFound);
    }
    return _json(run.toJson());
  }

  /// `GET /api/runtime` — the live in-process snapshot the running brain bound
  /// (§ 8.3(13)): the gateway ports + base paths, the Telegram toggle, and the
  /// resolved roots, for the Runtime tab's "currently running" display (§ 6.4).
  /// `503` "runtime unavailable" when the observatory runs standalone (no live
  /// brain threaded a snapshot in) — the tab then shows only the on-disk config,
  /// never a wrong "running" value.
  Response _runtimeSnapshot(Request request) {
    final snapshot = runtime;
    if (snapshot == null) {
      return _json(<String, Object?>{'error': 'runtime unavailable'},
          status: HttpStatus.serviceUnavailable);
    }
    return _json(snapshot.toJson());
  }

  /// `GET /api/meta` — the static, always-available capability surface (plan
  /// step 9): currently just `{"configWritable": bool}`, so the editor UI can
  /// grey its authoring controls up front rather than discovering the read-only
  /// posture from a `409` on save. Always `200` (unlike `/api/runtime`, which
  /// `503`s standalone), so the front-end has one reliable place to ask.
  Response _meta(Request request) =>
      _json(<String, Object?>{'configWritable': configWritable});

  /// The `409 config_is_immutable` short-circuit shared by the three authoring
  /// PUTs (plan step 9): `null` when [configWritable] is set (the PUT proceeds
  /// to its AUTH guards), or the immutable response when it is not. Returned
  /// *first* in each handler, so a read-only observatory closes the authoring
  /// surface entirely — no write target is ever resolved or touched.
  Response? _immutableConfig() => configWritable
      ? null
      : _json(<String, Object?>{'error': 'config_is_immutable'},
          status: HttpStatus.conflict);

  /// Resolves the on-disk path of the registered config file for [kind]/[name]
  /// via the cognition catalogue (route 12, the authoritative inventory), or
  /// `null` when [kind] is not a config wire kind, [kind]/[name] is not a
  /// registered config, or the resolved path escapes its containment root (the
  /// AUTH-2 guard). Registry/procedure/llm_route resolve against the cognition
  /// root; substrate resolves against the run-config root. The path is taken
  /// from the catalogue, never concatenated from raw input, so a traversal
  /// `name` simply fails to match and is refused.
  String? _configFilePath(String kind, String name) {
    final config = cognition;
    final cognitionDir = cognitionRoot;
    if (config == null || cognitionDir == null) return null;
    // The `run` kind is the whole `brain_run.yaml` document (§ 6.4 Runtime tab),
    // which is the same file the `substrate:` block lives in — it resolves
    // against the run-config root, independent of the cognition catalogue.
    if (kind == 'run') return _runConfigFilePath(name);
    final wanted = _kindFromWire(kind);
    if (wanted == null) return null;

    final catalogue =
        config.catalogue(substrateConfigFile: substrateConfigFile);
    CatalogueConfigFile? entry;
    for (final cf in catalogue.configFiles) {
      if (cf.kind == wanted && cf.name == name) {
        entry = cf;
        break;
      }
    }
    if (entry == null) return null;

    final Directory? root = wanted == CatalogueConfigKind.substrate
        ? runConfigRoot
        : cognitionDir;
    if (root == null) return null;
    final rootPath = p.normalize(root.absolute.path);
    final resolved = p.normalize(p.join(rootPath, entry.path));
    if (!p.isWithin(rootPath, resolved) || !resolved.endsWith('.yaml')) {
      return null;
    }
    return resolved;
  }

  /// Resolves the on-disk path of the whole-process run config for the `run`
  /// kind (§ 6.4 Runtime tab, § 8.3(10)): the `brain_run.yaml` file under the
  /// run-config root. [name] must be that file's stem (default `brain_run`) —
  /// the AUTH-2 stem guard — and the resolved path must stay within the
  /// run-config root and carry the `.yaml` extension. Returns `null` (refused
  /// `403` by the caller) when no run-config root is wired, the name does not
  /// match, or containment fails.
  String? _runConfigFilePath(String name) {
    final root = runConfigRoot;
    if (root == null) return null;
    if (name != _stemOf(substrateConfigFile)) return null;
    final rootPath = p.normalize(root.absolute.path);
    final resolved = p.normalize(p.join(rootPath, substrateConfigFile));
    if (!p.isWithin(rootPath, resolved) || !resolved.endsWith('.yaml')) {
      return null;
    }
    return resolved;
  }

  /// Maps a `/api/config` wire `kind` to its catalogue [CatalogueConfigKind].
  /// The wire alphabet (§ 8.3(10): `registry`/`procedure`/`llm_route`/
  /// `substrate`) names the per-route llm config `llm_route`, while the catalogue
  /// enum names it `llm`; this is the single translation point. Returns `null`
  /// for any other token (refused `403` by the caller).
  static CatalogueConfigKind? _kindFromWire(String kind) {
    switch (kind) {
      case 'registry':
        return CatalogueConfigKind.registry;
      case 'procedure':
        return CatalogueConfigKind.procedure;
      case 'llm_route':
        return CatalogueConfigKind.llm;
      case 'substrate':
        return CatalogueConfigKind.substrate;
      default:
        return null;
    }
  }

  /// The AUTH-4 effect a [kind] edit takes (§ 6.4, AUTH-4): a `procedure` config
  /// carries per-prompt settings the resolver reads live, so an edit takes effect
  /// on the **next use**; `registry` / `llm_route` / `substrate` are structure +
  /// provider routing the loader reads at **boot**, so an edit takes effect on the
  /// next process start. The editor states this so the operator is not surprised.
  static String _effectFor(String kind) =>
      kind == 'procedure' ? 'next-use' : 'next-boot';

  /// Validates a proposed config [body] for [kind]/[name] (AUTH-3), returning the
  /// owning loader's located message on rejection or `null` when it parses
  /// clean. A `substrate` edit goes through [SubstrateConfigLoader.parse] (it
  /// reads only the `substrate:` block, tolerating siblings); a registry /
  /// procedure / llm_route edit goes through [CognitionConfigLoader.parse] with
  /// the proposed file substituted into the on-disk tree.
  ///
  /// Validation never mutates disk: the *other* config files are read and the
  /// edited one is replaced in memory, then the pure `parse` is run — the same
  /// boot-time fail-fast, with no temp tree to copy or delete.
  String? _validateConfig(String kind, String name, String body) {
    // The `run` kind validates the whole `brain_run.yaml` through the full
    // run-config loader — the same fail-fast the brain applies at boot. Each
    // section loader throws its own located exception (substrate / memory /
    // access / trail / tools); the broad `on Exception` carries that located
    // message for the sections whose exception types this package does not
    // import. Env tokens (`${env:…}`) are expanded from the process environment
    // so a config that resolves at boot also resolves at validation.
    if (kind == 'run') {
      try {
        BrainRunConfigLoader.parse(body, envVars: Platform.environment);
        return null;
      } on SubstrateConfigException catch (e) {
        return e.message;
      } on Exception catch (e) {
        return e.toString();
      }
    }
    final wanted = _kindFromWire(kind);
    if (wanted == null) return 'unknown config kind "$kind"';
    try {
      if (wanted == CatalogueConfigKind.substrate) {
        SubstrateConfigLoader.parse(body);
      } else {
        _parseCognitionEdit(wanted, name, body);
      }
      return null;
    } on SubstrateConfigException catch (e) {
      return e.message;
    } on CognitionConfigException catch (e) {
      return e.message;
    }
  }

  /// Re-parses the cognition tree with the [kind]/[name] config replaced by
  /// [body], using the pure [CognitionConfigLoader.parse]. Reads the unedited
  /// registry / procedure / llm files off disk; substitutes the edited one; runs
  /// the same template-existence probe (rooted at the cognition root) the brain
  /// uses at boot. Throws [CognitionConfigException] when the proposed tree is
  /// invalid.
  ///
  /// A registry edit that references a procedure/route config file not already
  /// registered surfaces as a located "referenced config was not provided"
  /// rejection — adding a wholly new procedure is a multi-file operation outside
  /// a single config write, so it is conservatively refused here rather than
  /// validated against a guessed file set.
  void _parseCognitionEdit(CatalogueConfigKind kind, String name, String body) {
    final config = cognition!;
    final rootPath = p.normalize(cognitionRoot!.absolute.path);

    final String registryYaml = kind == CatalogueConfigKind.registry
        ? body
        : File(p.join(rootPath, 'registry.yaml')).readAsStringSync();

    final Map<String, String> procedureConfigs = <String, String>{};
    for (final proc in config.registry.procedures.values) {
      final file = File(p.join(rootPath, proc.configFile));
      procedureConfigs[proc.configFile] =
          file.existsSync() ? file.readAsStringSync() : '';
    }
    if (kind == CatalogueConfigKind.procedure) {
      final proc = config.registry.procedures[name];
      if (proc != null) procedureConfigs[proc.configFile] = body;
    }

    final Map<String, String> routeConfigs = <String, String>{};
    final llmDir = Directory(p.join(rootPath, config.registry.llmFolder));
    if (llmDir.existsSync()) {
      for (final entity in llmDir.listSync()) {
        if (entity is File && entity.path.endsWith('.yaml')) {
          routeConfigs[_stemOf(entity.path)] = entity.readAsStringSync();
        }
      }
    }
    if (kind == CatalogueConfigKind.llm) routeConfigs[name] = body;

    CognitionConfigLoader.parse(
      registryYaml: registryYaml,
      procedureConfigs: procedureConfigs,
      llmRouteConfigs: routeConfigs,
      templateExists: (relativePath) =>
          File(p.join(rootPath, relativePath)).existsSync(),
    );
  }

  /// The filename stem of [path] (`default` for `…/default.yaml`), matching the
  /// route-name key `CognitionConfigLoader.loadFromDir` uses for `llm/` configs.
  static String _stemOf(String path) {
    final name = p.basename(path);
    final dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
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
