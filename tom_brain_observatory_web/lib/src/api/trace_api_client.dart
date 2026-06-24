// The read-only client over the same-origin Trail Read API (§ 8.5). The web app
// is served by the very process that exposes `/api`, so requests resolve against
// `Uri.base` (the document origin) — there is no base-URL config and no CORS
// (`prompt_tracing_plan.md` PT-2.0). The client is read-only: it issues only
// `GET`s against `/api/traces`, mirroring OBS-1..OBS-5.
//
// [TraceApiClient] is the abstraction the views depend on; tests inject a stub
// (PT-2.1) instead of a live brain. [HttpTraceApiClient] is the one production
// implementation.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../model/authoring.dart';
import '../model/catalogue.dart';
import '../model/dream_run.dart';
import '../model/live_step.dart';
import '../model/llm_call_detail.dart';
import '../model/llm_call_source.dart';
import '../model/prompt_trace.dart';
import '../model/runtime.dart';
import 'sse.dart';

/// The read-only Trail Read API surface the UI depends on.
abstract interface class TraceApiClient {
  /// `GET /api/traces` — the prompt list (§ 4.1), newest-first. [limit] caps the
  /// window when given; otherwise the server default applies.
  Future<List<PromptListRow>> listTraces({int? limit});

  /// `GET /api/traces/{turnId}` — one [PromptTrace], or `null` when the host has
  /// no trace for the turn (§ 4.1 — absence is a clean not-found).
  Future<PromptTrace?> traceFor(String turnId);

  /// `GET /api/llm?path=` + exactly one of `turn=`/`run=` — the full §3.7 detail
  /// behind a run-tree `LlmCall`'s [rawPath] link, resolved against the run named
  /// by [source] (a foreground turn or a turn-less dream run, MSPP-55/56), or
  /// `null` when the host has no such dump (§ 4.5 / PT-2.4).
  Future<LlmCallDetail?> llmCallDetail(LlmCallSource source, String rawPath);

  /// `GET /api/procedures` — the ids of every procedure script the running brain
  /// hosts under `scripts/system/*.dart` (§ 4.6 / § 8.3(5)), sorted. Feeds the
  /// gear editor's Procedures tab so each script is offerable beside its yaml
  /// config — the same scripts the Run Tree opens by id. Empty when no script
  /// root is configured (absence is not an error).
  Future<List<String>> listProcedureScripts();

  /// `GET /api/procedures/{procedureId}` — the verbatim d4rt source of a
  /// procedure script (§ 4.6 / PT-3.1), or `null` when the host exposes no such
  /// script (no script root, or the id is unknown — absence is not an error).
  Future<String?> procedureScript(String procedureId);

  /// `PUT /api/procedures/{procedureId}` — the source-authoring write (§ 6.3,
  /// AUTH-1…AUTH-3): saves an edited d4rt [source] back to the brain's
  /// `scripts/system/<procedureId>.dart` so it is re-read on the next run
  /// (AUTH-5). The brain's own validator gates the save: a `200` returns
  /// [AuthoringResult.saved]; a `422` returns the findings (the file is left
  /// untouched). A containment refusal (`403`) or absent script root (`404`)
  /// throws — those are misconfigurations, not editable outcomes.
  Future<AuthoringResult> writeProcedureScript(
      String procedureId, String source);

  /// `GET /api/templates?id=<roleId>&part=<part>` — the verbatim override prose
  /// of a role's `<roleId>.<part>.md`, `part ∈ {persona, objective}` (§ 6.3),
  /// served via the unified template surface (step 15; the old
  /// `/api/prompts/{roleId}/{part}` route is removed). An empty body is the
  /// "create override" starting point; `null` is still mapped from a `404`
  /// defensively, though the template route reports an absent half as an empty
  /// body 200.
  Future<String?> readPromptFile(String roleId, String part);

  /// `PUT /api/templates?id=<roleId>&part=<part>` — writes (materialising if
  /// absent) a role's override [prose] so the brain re-reads it the next time it
  /// assembles a call for that role (AUTH-5). A `200` returns
  /// [AuthoringResult.saved]; a `422` (blank prose / malformed placeholder)
  /// returns a finding. A `403`/`503` throws.
  Future<AuthoringResult> writePromptFile(
      String roleId, String part, String prose);

  /// `GET /api/catalogue` — the registry-derived editable index the gear
  /// configuration editor browses (§ 6.4 / § 13.4), or `null` when no cognition
  /// config is wired (the host answers `503` "config unavailable" — the UI
  /// degrades to an "unavailable" notice rather than an error).
  Future<CognitionCatalogue?> catalogue();

  /// `GET /api/config?kind=<kind>&name=<name>` — the verbatim text of a
  /// registered config file (§ 6.4); [kind] is the wire alphabet
  /// (`registry` / `procedure` / `llm_route` / `substrate`). `null` when the
  /// host has no such file on disk (`404` — a registered-but-absent config).
  /// A containment refusal (`403`) or absent config (`503`) throws.
  Future<String?> readConfigFile(String kind, String name);

  /// `PUT /api/config?kind=<kind>&name=<name>` — writes a registered config file
  /// so the brain re-reads it (AUTH-5). The brain's own loader validates first:
  /// a `200` returns [AuthoringResult.saved]; a `422` returns the loader's
  /// located rejection as one finding (the on-disk file is left untouched). A
  /// `403`/`503` throws.
  Future<AuthoringResult> writeConfigFile(
      String kind, String name, String content);

  /// `GET /api/runtime` — the live, in-process values the running brain bound
  /// (§ 6.4 Runtime tab, § 8.3(13)): gateway ports + base paths, the Telegram
  /// toggle, the resolved roots. `null` when the observatory was launched
  /// standalone (the host answers `503` "runtime unavailable" — there is no live
  /// brain to ask, so the Runtime tab shows only the on-disk config).
  Future<RuntimeSnapshot?> runtime();

  /// `GET /api/meta` — the static capability surface (plan step 9): whether the
  /// three authoring PUTs may write. `false` when the observatory was launched
  /// `--observatory-readonly`, so the editors grey their Save controls up front
  /// rather than discovering it from a `409` on save. Degrades to `true` (the
  /// historical writable default) when the host predates the route, so an older
  /// backend keeps working.
  Future<bool> configWritable();

  /// `GET /api/dream/lanes` — the Module-3 lane selector (§ 5A.2): the configured
  /// cadence lanes plus the synthetic `other` lane when any dream run is
  /// unclaimed. Empty in unconfigured mode (absence is never an error, § 8.1).
  Future<List<DreamLane>> listDreamLanes();

  /// `GET /api/dream/runs?lane=<id>` — the Module-3 run list (§ 5A.2): the recent
  /// turn-less dream runs, newest-first, optionally filtered to one [lane]
  /// (including `other`). Empty when no dream runs exist.
  Future<List<DreamRunRow>> listDreamRuns({String? lane});

  /// `GET /api/dream/runs/{runId}` — one drilled-in dream run as its run-tree
  /// (§ 5A.4), or `null` when no turn-less log with that id exists (the host
  /// answers `404`) — the dreaming-side mirror of [traceFor].
  Future<DreamRun?> dreamRunFor(String runId);

  /// `GET /api/traces/{turnId}/stream` — the SSE live-tail of a turn (§ 4.8):
  /// one [LiveStep] per cognitive step as the brain appends it, the stream
  /// closing after the turn's `✅ DONE`. The streaming Reply view (§ 3.5)
  /// replays the `💬 assistant` steps and the terminal banner from this.
  Stream<LiveStep> tailTurn(String turnId);

  /// `GET /api/stream` — the list-level live-tail (§ 4.8): a tick on connect and
  /// whenever a session live-trail changes, so the prompt list re-fetches.
  Stream<void> listChanges();

  /// `GET /api/dream/stream[?lane=]` — the dreaming-side live-tail (§ 5A.5,
  /// MSPP-57/58): a refresh tick per appended run-tree operation of the active
  /// dream run, plus a terminal tick when it completes, so Module 3 re-fetches
  /// the lane list / open run-tree without a manual refresh — the dream-side
  /// mirror of [listChanges]. Consumed as a signal (not a delta builder): the
  /// views re-fetch through the `/api/dream/*` GETs. One connection follows the
  /// newest run to completion then ends (the backend's one-run contract); a
  /// connection error ends the stream quietly so the views degrade to
  /// fresh-parse-on-refresh.
  Stream<void> dreamChanges({String? lane});
}

/// Talks to the same-origin `/api` via [http]. URLs resolve against [origin]
/// (defaulting to `Uri.base`, the document origin) so no base URL is configured.
class HttpTraceApiClient implements TraceApiClient {
  final http.Client _http;
  final Uri _origin;

  HttpTraceApiClient({http.Client? httpClient, Uri? origin})
      : _http = httpClient ?? http.Client(),
        _origin = origin ?? Uri.base;

  @override
  Future<List<PromptListRow>> listTraces({int? limit}) async {
    final uri = _resolve('api/traces', <String, String>{
      if (limit != null) 'limit': '$limit',
    });
    final res = await _http.get(uri);
    if (res.statusCode != 200) {
      throw http.ClientException('GET $uri → ${res.statusCode}', uri);
    }
    final rows = jsonDecode(res.body) as List<dynamic>;
    return <PromptListRow>[
      for (final row in rows) PromptListRow.fromJson(row as Map<String, dynamic>),
    ];
  }

  @override
  Future<PromptTrace?> traceFor(String turnId) async {
    final uri = _resolve('api/traces/$turnId', const <String, String>{});
    final res = await _http.get(uri);
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw http.ClientException('GET $uri → ${res.statusCode}', uri);
    }
    return PromptTrace.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<LlmCallDetail?> llmCallDetail(
      LlmCallSource source, String rawPath) async {
    final uri = _resolve('api/llm', <String, String>{
      ...source.queryParameters,
      'path': rawPath,
    });
    final res = await _http.get(uri);
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw http.ClientException('GET $uri → ${res.statusCode}', uri);
    }
    return LlmCallDetail.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<List<String>> listProcedureScripts() async {
    final uri = _resolve('api/procedures', const <String, String>{});
    final res = await _http.get(uri);
    if (res.statusCode != 200) {
      throw http.ClientException('GET $uri → ${res.statusCode}', uri);
    }
    return <String>[
      for (final id in jsonDecode(res.body) as List<dynamic>) id as String,
    ];
  }

  @override
  Future<String?> procedureScript(String procedureId) async {
    final uri = _resolve('api/procedures/$procedureId', const <String, String>{});
    final res = await _http.get(uri);
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw http.ClientException('GET $uri → ${res.statusCode}', uri);
    }
    return res.body;
  }

  @override
  Future<AuthoringResult> writeProcedureScript(
      String procedureId, String source) async {
    final uri = _resolve('api/procedures/$procedureId', const <String, String>{});
    final res = await _http.put(uri,
        body: source,
        headers: const <String, String>{'content-type': 'text/plain'});
    return _authoringResult(uri, 'PUT', res);
  }

  @override
  Future<String?> readPromptFile(String roleId, String part) async {
    final uri = _resolve(
        'api/templates', <String, String>{'id': roleId, 'part': part});
    final res = await _http.get(uri);
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw http.ClientException('GET $uri → ${res.statusCode}', uri);
    }
    return res.body;
  }

  @override
  Future<AuthoringResult> writePromptFile(
      String roleId, String part, String prose) async {
    final uri = _resolve(
        'api/templates', <String, String>{'id': roleId, 'part': part});
    final res = await _http.put(uri,
        body: prose,
        headers: const <String, String>{'content-type': 'text/plain'});
    return _authoringResult(uri, 'PUT', res);
  }

  @override
  Future<CognitionCatalogue?> catalogue() async {
    final uri = _resolve('api/catalogue', const <String, String>{});
    final res = await _http.get(uri);
    if (res.statusCode == 503) return null;
    if (res.statusCode != 200) {
      throw http.ClientException('GET $uri → ${res.statusCode}', uri);
    }
    return CognitionCatalogue.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<String?> readConfigFile(String kind, String name) async {
    final uri =
        _resolve('api/config', <String, String>{'kind': kind, 'name': name});
    final res = await _http.get(uri);
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw http.ClientException('GET $uri → ${res.statusCode}', uri);
    }
    return res.body;
  }

  @override
  Future<AuthoringResult> writeConfigFile(
      String kind, String name, String content) async {
    final uri =
        _resolve('api/config', <String, String>{'kind': kind, 'name': name});
    final res = await _http.put(uri,
        body: content,
        headers: const <String, String>{'content-type': 'text/plain'});
    if (res.statusCode == 200) return AuthoringResult.saved;
    if (res.statusCode == 422) {
      // A config rejection is `{error, detail}` (the loader's located message),
      // not a `findings[]` array — surface the detail as one finding.
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return AuthoringResult.rejected(<AuthoringFinding>[
        AuthoringFinding(
          code: 'config.invalid',
          message: (body['detail'] ?? body['error']) as String? ?? 'rejected',
        ),
      ]);
    }
    throw http.ClientException('PUT $uri → ${res.statusCode}', uri);
  }

  @override
  Future<RuntimeSnapshot?> runtime() async {
    final uri = _resolve('api/runtime', const <String, String>{});
    final res = await _http.get(uri);
    if (res.statusCode == 503) return null;
    if (res.statusCode != 200) {
      throw http.ClientException('GET $uri → ${res.statusCode}', uri);
    }
    return RuntimeSnapshot.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  @override
  Future<bool> configWritable() async {
    final uri = _resolve('api/meta', const <String, String>{});
    final http.Response res;
    try {
      res = await _http.get(uri);
    } catch (_) {
      return true; // unreachable meta → assume writable (historical default).
    }
    if (res.statusCode != 200) return true; // older host w/o the route.
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['configWritable'] as bool? ?? true;
  }

  @override
  Future<List<DreamLane>> listDreamLanes() async {
    final uri = _resolve('api/dream/lanes', const <String, String>{});
    final res = await _http.get(uri);
    if (res.statusCode != 200) {
      throw http.ClientException('GET $uri → ${res.statusCode}', uri);
    }
    return <DreamLane>[
      for (final lane in jsonDecode(res.body) as List<dynamic>)
        DreamLane.fromJson(lane as Map<String, dynamic>),
    ];
  }

  @override
  Future<List<DreamRunRow>> listDreamRuns({String? lane}) async {
    final uri = _resolve('api/dream/runs', <String, String>{
      'lane': ?lane,
    });
    final res = await _http.get(uri);
    if (res.statusCode != 200) {
      throw http.ClientException('GET $uri → ${res.statusCode}', uri);
    }
    return <DreamRunRow>[
      for (final row in jsonDecode(res.body) as List<dynamic>)
        DreamRunRow.fromJson(row as Map<String, dynamic>),
    ];
  }

  @override
  Future<DreamRun?> dreamRunFor(String runId) async {
    final uri = _resolve('api/dream/runs/$runId', const <String, String>{});
    final res = await _http.get(uri);
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw http.ClientException('GET $uri → ${res.statusCode}', uri);
    }
    return DreamRun.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Maps a source-authoring `PUT` response into an [AuthoringResult]: `200` →
  /// [AuthoringResult.saved]; `422` → the validator findings (a procedure carries
  /// a `findings[]` array; a prompt carries a single `error` string, normalised
  /// into one finding). Anything else (`403`/`404`/5xx) is a misconfiguration,
  /// not an editable outcome, so it throws.
  AuthoringResult _authoringResult(Uri uri, String method, http.Response res) {
    if (res.statusCode == 200) return AuthoringResult.saved;
    if (res.statusCode == 422) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final raw = body['findings'];
      if (raw is List) {
        return AuthoringResult.rejected(<AuthoringFinding>[
          for (final f in raw)
            AuthoringFinding.fromJson(f as Map<String, dynamic>),
        ]);
      }
      return AuthoringResult.rejected(<AuthoringFinding>[
        AuthoringFinding(
          code: 'prompt.invalid',
          message: body['error'] as String? ?? 'rejected',
        ),
      ]);
    }
    throw http.ClientException('$method $uri → ${res.statusCode}', uri);
  }

  @override
  Stream<LiveStep> tailTurn(String turnId) async* {
    final uri = _resolve('api/traces/$turnId/stream', const <String, String>{});
    final res = await _http.send(http.Request('GET', uri));
    yield* sseDataFrames(res.stream).map((data) =>
        LiveStep.fromJson(jsonDecode(data) as Map<String, dynamic>));
  }

  @override
  Stream<void> listChanges() async* {
    final uri = _resolve('api/stream', const <String, String>{});
    final res = await _http.send(http.Request('GET', uri));
    yield* sseDataFrames(res.stream).map((_) {});
  }

  @override
  Stream<void> dreamChanges({String? lane}) async* {
    final uri = _resolve('api/dream/stream', <String, String>{'lane': ?lane});
    // One connection follows the newest dream run to completion then ends
    // (MSPP-58): every SSE frame — each appended op and the terminal `done` —
    // is one refresh tick. A connection failure ends the stream quietly so the
    // views fall back to fresh-parse-on-refresh; reaching the end of the SSE
    // frames is the run's clean completion, which simply ends the stream.
    final http.StreamedResponse res;
    try {
      res = await _http.send(http.Request('GET', uri));
    } catch (_) {
      return;
    }
    if (res.statusCode != 200) return;
    yield* sseDataFrames(res.stream).map((_) {});
  }

  /// Resolve [path] (and optional [query]) against the document origin. Relative
  /// resolution keeps every request same-origin without a configured base URL.
  Uri _resolve(String path, Map<String, String> query) {
    final base = _origin.resolve(path);
    return query.isEmpty ? base : base.replace(queryParameters: query);
  }
}
