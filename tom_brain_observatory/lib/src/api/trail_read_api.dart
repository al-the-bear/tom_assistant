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

import '../live/live_tail.dart';
import '../model/prompt_trace.dart';
import '../parse/prompt_list_builder.dart';
import '../parse/prompt_trace_parser.dart';
import '../parse/trail_host.dart';

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
  /// (PT-3.1), or `null` when the observatory has no script root to expose (the
  /// endpoint then 404s — absence is never an error, § 4.1).
  final Directory? scriptRoot;

  TrailReadApi({
    required this.host,
    this.listLimit = 10,
    this.webRoot,
    this.scriptRoot,
  });

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

  Router get _apiRouter => Router()
    ..get('/api/stream', _listStream)
    ..get('/api/traces', _listTraces)
    ..get('/api/traces/<turnId>/stream', _turnStream)
    ..get('/api/traces/<turnId>', _singleTrace)
    ..get('/api/llm', _llmRaw)
    ..get('/api/procedures/<procedureId>', _procedureScript);

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
