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
import '../model/live_step.dart';
import '../model/llm_call_detail.dart';
import '../model/prompt_trace.dart';
import 'sse.dart';

/// The read-only Trail Read API surface the UI depends on.
abstract interface class TraceApiClient {
  /// `GET /api/traces` — the prompt list (§ 4.1), newest-first. [limit] caps the
  /// window when given; otherwise the server default applies.
  Future<List<PromptListRow>> listTraces({int? limit});

  /// `GET /api/traces/{turnId}` — one [PromptTrace], or `null` when the host has
  /// no trace for the turn (§ 4.1 — absence is a clean not-found).
  Future<PromptTrace?> traceFor(String turnId);

  /// `GET /api/llm?turn=&path=` — the full §3.7 detail behind a run-tree
  /// `LlmCall`'s [rawPath] link, or `null` when the host has no such dump
  /// (§ 4.5 / PT-2.4).
  Future<LlmCallDetail?> llmCallDetail(String turnId, String rawPath);

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

  /// `GET /api/prompts/{roleId}/{part}` — the verbatim override prose of a
  /// role's `<roleId>.<part>.md`, `part ∈ {persona, objective}` (§ 6.3), or
  /// `null` when no override exists yet (the `404` the editor turns into a
  /// "create override" starting point) or no prompts root is configured.
  Future<String?> readPromptFile(String roleId, String part);

  /// `PUT /api/prompts/{roleId}/{part}` — writes (materialising if absent) a
  /// role's override [prose] so the brain re-reads it the next time it assembles
  /// a call for that role (AUTH-5). A `200` returns [AuthoringResult.saved]; a
  /// `422` (blank prose) returns a finding. A `403`/`404` throws.
  Future<AuthoringResult> writePromptFile(
      String roleId, String part, String prose);

  /// `GET /api/traces/{turnId}/stream` — the SSE live-tail of a turn (§ 4.8):
  /// one [LiveStep] per cognitive step as the brain appends it, the stream
  /// closing after the turn's `✅ DONE`. The streaming Reply view (§ 3.5)
  /// replays the `💬 assistant` steps and the terminal banner from this.
  Stream<LiveStep> tailTurn(String turnId);

  /// `GET /api/stream` — the list-level live-tail (§ 4.8): a tick on connect and
  /// whenever a session live-trail changes, so the prompt list re-fetches.
  Stream<void> listChanges();
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
  Future<LlmCallDetail?> llmCallDetail(String turnId, String rawPath) async {
    final uri = _resolve('api/llm', <String, String>{
      'turn': turnId,
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
    final uri =
        _resolve('api/prompts/$roleId/$part', const <String, String>{});
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
    final uri =
        _resolve('api/prompts/$roleId/$part', const <String, String>{});
    final res = await _http.put(uri,
        body: prose,
        headers: const <String, String>{'content-type': 'text/plain'});
    return _authoringResult(uri, 'PUT', res);
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

  /// Resolve [path] (and optional [query]) against the document origin. Relative
  /// resolution keeps every request same-origin without a configured base URL.
  Uri _resolve(String path, Map<String, String> query) {
    final base = _origin.resolve(path);
    return query.isEmpty ? base : base.replace(queryParameters: query);
  }
}
