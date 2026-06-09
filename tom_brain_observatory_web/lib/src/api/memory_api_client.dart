// The read-only client over the same-origin `/api/memory/*` surface
// (`prompt_tracing.md` § 5.2–5.6, § 8.4). Like [TraceApiClient] for Module 1,
// this is the abstraction the Module-2 views depend on; tests inject a stub. The
// client issues only the nine reads — there is no write method, so OBS-2 holds
// at the client exactly as at the backend.
//
// When the brain's memory connector is deferred, the backend answers every route
// `503` "memory unavailable" (§ 8.4); the HTTP client surfaces that as a
// [MemoryUnavailable] exception so a view can render the unavailable state rather
// than treating it as a hard error.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../model/memory_nodes.dart';

/// The memory connector is not wired (the backend answered `503`). Views catch
/// this and render "memory unavailable" — it is environmental, never a crash.
class MemoryUnavailable implements Exception {
  final String message;
  const MemoryUnavailable([this.message = 'memory unavailable']);

  @override
  String toString() => 'MemoryUnavailable: $message';
}

/// The read-only memory surface the Module-2 views depend on.
abstract interface class MemoryApiClient {
  /// `GET /api/memory/nodes?type=` — the composed browse-by-type (§ 5.2).
  Future<TypeBrowseResult> browseNodes(
    String typeName, {
    List<String> knownIds,
    bool traverseEdges,
  });

  /// `GET /api/memory/nodes/{id}` — node detail (§ 5.2), or `null` when absent.
  Future<MemoryNode?> node(String id);

  /// `GET /api/memory/edges?id=` — incident edges (§ 5.3).
  Future<List<MemoryEdge>> edges(
    String id, {
    EdgeDirection direction,
    Set<String>? types,
  });

  /// `POST /api/memory/recall` — single-seed recall (§ 5.4).
  Future<RecallResult> recall({
    String? text,
    List<double>? embedding,
    Set<RecallMode>? modes,
    int? k,
    int? wallClockMs,
  });

  /// `POST /api/memory/recall/multi` — multi-seed recall (§ 5.4).
  Future<RecallResult> recallMulti({
    required List<RecallSeedSpec> seeds,
    int? k,
    int? wallClockMs,
  });

  /// `GET /api/memory/stacks` — the stack inventory (§ 5.5).
  Future<List<MemoryStackSummary>> stacks();

  /// `GET /api/memory/stacks/{name}?k=` — the top-K of a stack (§ 5.5).
  Future<List<MemoryStackEntry>> stackPeek(String name, {int? k});

  /// `POST /api/memory/classify` — the centroid classification probe (§ 5.6).
  Future<MemoryClassification> classify(
    List<double> embedding, {
    ClassifyTarget target,
  });

  /// `GET /api/memory/profiles` — the profiles plus the current binding (§ 5.6).
  Future<MemoryProfiles> profiles();
}

/// Talks to the same-origin `/api/memory/*` via [http], resolving against
/// [origin] (default `Uri.base`) so no base URL is configured.
class HttpMemoryApiClient implements MemoryApiClient {
  final http.Client _http;
  final Uri _origin;

  HttpMemoryApiClient({http.Client? httpClient, Uri? origin})
      : _http = httpClient ?? http.Client(),
        _origin = origin ?? Uri.base;

  @override
  Future<TypeBrowseResult> browseNodes(
    String typeName, {
    List<String> knownIds = const <String>[],
    bool traverseEdges = false,
  }) async {
    final uri = _resolve('api/memory/nodes', <String, String>{
      'type': typeName,
      if (knownIds.isNotEmpty) 'knownIds': knownIds.join(','),
      if (traverseEdges) 'traverseEdges': 'true',
    });
    return TypeBrowseResult.fromJson(await _getJson(uri));
  }

  @override
  Future<MemoryNode?> node(String id) async {
    final uri = _resolve('api/memory/nodes/$id', const <String, String>{});
    final res = await _http.get(uri);
    if (res.statusCode == 404) return null;
    return MemoryNode.fromJson(_decode(uri, res));
  }

  @override
  Future<List<MemoryEdge>> edges(
    String id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<String>? types,
  }) async {
    final uri = _resolve('api/memory/edges', <String, String>{
      'id': id,
      'direction': direction.wireName,
      if (types != null && types.isNotEmpty) 'types': types.join(','),
    });
    final body = await _getJson(uri);
    return <MemoryEdge>[
      for (final raw in (body['edges'] as List?) ?? const <dynamic>[])
        MemoryEdge.fromJson((raw as Map).cast<String, dynamic>()),
    ];
  }

  @override
  Future<RecallResult> recall({
    String? text,
    List<double>? embedding,
    Set<RecallMode>? modes,
    int? k,
    int? wallClockMs,
  }) async {
    final body = await _postJson('api/memory/recall', <String, dynamic>{
      if (text != null) 'text': text,
      if (embedding != null) 'embedding': embedding,
      if (modes != null) 'modes': <String>[for (final m in modes) m.wireName],
      if (k != null) 'k': k,
      if (wallClockMs != null) 'wallClockMs': wallClockMs,
    });
    return RecallResult.fromJson(body);
  }

  @override
  Future<RecallResult> recallMulti({
    required List<RecallSeedSpec> seeds,
    int? k,
    int? wallClockMs,
  }) async {
    final body = await _postJson('api/memory/recall/multi', <String, dynamic>{
      'seeds': <dynamic>[for (final seed in seeds) seed.toJson()],
      if (k != null) 'k': k,
      if (wallClockMs != null) 'wallClockMs': wallClockMs,
    });
    return RecallResult.fromJson(body);
  }

  @override
  Future<List<MemoryStackSummary>> stacks() async {
    final body = await _getJson(
        _resolve('api/memory/stacks', const <String, String>{}));
    return <MemoryStackSummary>[
      for (final raw in (body['stacks'] as List?) ?? const <dynamic>[])
        MemoryStackSummary.fromJson((raw as Map).cast<String, dynamic>()),
    ];
  }

  @override
  Future<List<MemoryStackEntry>> stackPeek(String name, {int? k}) async {
    final uri = _resolve('api/memory/stacks/$name', <String, String>{
      if (k != null) 'k': '$k',
    });
    final body = await _getJson(uri);
    return <MemoryStackEntry>[
      for (final raw in (body['entries'] as List?) ?? const <dynamic>[])
        MemoryStackEntry.fromJson((raw as Map).cast<String, dynamic>()),
    ];
  }

  @override
  Future<MemoryClassification> classify(
    List<double> embedding, {
    ClassifyTarget target = ClassifyTarget.nodeType,
  }) async {
    final body = await _postJson('api/memory/classify', <String, dynamic>{
      'embedding': embedding,
      'target': target.wireName,
    });
    return MemoryClassification.fromJson(body);
  }

  @override
  Future<MemoryProfiles> profiles() async => MemoryProfiles.fromJson(
      await _getJson(_resolve('api/memory/profiles', const <String, String>{})));

  // ─── plumbing ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _getJson(Uri uri) async =>
      _decode(uri, await _http.get(uri));

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final uri = _resolve(path, const <String, String>{});
    final res = await _http.post(
      uri,
      headers: const <String, String>{'content-type': 'application/json'},
      body: jsonEncode(body),
    );
    return _decode(uri, res);
  }

  /// Decode a JSON body, mapping `503` to [MemoryUnavailable] and any other
  /// non-`200` to a [http.ClientException].
  Map<String, dynamic> _decode(Uri uri, http.Response res) {
    if (res.statusCode == 503) {
      final detail = _safeError(res.body);
      throw MemoryUnavailable(detail ?? 'memory unavailable');
    }
    if (res.statusCode != 200) {
      throw http.ClientException('${uri.path} → ${res.statusCode}', uri);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  String? _safeError(String body) {
    try {
      return (jsonDecode(body) as Map)['error'] as String?;
    } catch (_) {
      return null;
    }
  }

  Uri _resolve(String path, Map<String, String> query) {
    final base = _origin.resolve(path);
    return query.isEmpty ? base : base.replace(queryParameters: query);
  }
}
