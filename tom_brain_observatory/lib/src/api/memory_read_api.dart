// PT-6 backend — the `/api/memory/*` HTTP surface (`prompt_tracing.md` § 8.4).
// The Module-2 web client cannot speak MCP (no browser MCP transport) and OBS-3
// forbids any DB path, so the backend holds the [MemoryReadClient] and re-exposes
// its nine read tools over same-origin HTTP. This class registers those routes on
// a [TrailReadApi]'s router; each route marshals the request to one read method
// and re-serializes the typed result (`memory_nodes.dart` `toJson`).
//
// The [client] is OPTIONAL: at run-assembly the real `dart_mcp`-backed connector
// is injected; absent it (the connector is deferred) every route answers
// `503 {"error": "memory unavailable"}` — reported, never crashed, mirroring
// [McpReadException]. There is no route for `memory.persistNote` — OBS-2 (§ 6.2)
// holds at the HTTP surface exactly as at the client: the write tool has no door.

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../memory/memory_nodes.dart';
import '../memory/memory_read_client.dart';
import '../memory/type_browser.dart';

/// Registers the `/api/memory/*` read routes over an optional [MemoryReadClient].
final class MemoryReadApi {
  /// The read-only client the routes marshal to, or `null` when the memory
  /// connector is deferred (every route then answers `503` "memory unavailable").
  final MemoryReadClient? client;

  /// The browse-by-type composition over [client] (§ 5.2), built only when a
  /// client is present.
  late final TypeBrowser? _browser =
      client == null ? null : TypeBrowser(client!);

  MemoryReadApi({this.client});

  /// Adds the nine read routes to [router] (full `/api/memory/...` paths, so the
  /// host router matches them alongside the trail routes without a mount).
  void registerRoutes(Router router) {
    router
      ..get('/api/memory/nodes', _browseNodes)
      ..get('/api/memory/nodes/<id>', _getNode)
      ..get('/api/memory/edges', _edges)
      ..post('/api/memory/recall', _recall)
      ..post('/api/memory/recall/multi', _recallMulti)
      ..get('/api/memory/stacks', _stacks)
      ..get('/api/memory/stacks/<name>', _stackPeek)
      ..post('/api/memory/classify', _classify)
      ..get('/api/memory/profiles', _profiles);
  }

  /// `GET /api/memory/nodes?type=<t>&knownIds=<csv>&traverseEdges=<bool>&profile=<p>`
  /// — the composed browse-by-type (§ 5.2). `?type=` is required; `?profile=`
  /// view-scopes the read (OBS-2).
  Future<Response> _browseNodes(Request request) => _guard((client) async {
        final q = request.url.queryParameters;
        final type = q['type'];
        if (type == null || type.isEmpty) {
          return _badRequest('GET /api/memory/nodes requires ?type=');
        }
        final result = await _browser!.browse(
          type,
          knownIds: _csv(q['knownIds']),
          traverseEdges: q['traverseEdges'] == 'true',
          profile: _profileOf(q['profile']),
        );
        return _json(result.toJson());
      });

  /// `GET /api/memory/nodes/<id>?profile=<p>` — node detail via `memory.get`
  /// (§ 5.2). `404` when the store holds no node for [id].
  Future<Response> _getNode(Request request, String id) => _guard((client) async {
        final nodes = await client.get(
          <String>[id],
          profile: _profileOf(request.url.queryParameters['profile']),
        );
        if (nodes.isEmpty) {
          return _json(<String, Object?>{'error': 'no node $id'},
              status: 404);
        }
        return _json(nodes.first.toJson());
      });

  /// `GET /api/memory/edges?id=<id>&direction=<d>&types=<csv>&profile=<p>` —
  /// incident edges (§ 5.3). `?id=` is required; `direction` defaults to `both`.
  Future<Response> _edges(Request request) => _guard((client) async {
        final q = request.url.queryParameters;
        final id = q['id'];
        if (id == null || id.isEmpty) {
          return _badRequest('GET /api/memory/edges requires ?id=');
        }
        final types = _csv(q['types']);
        final edges = await client.edgesOf(
          id,
          direction: EdgeDirection.values.firstWhere(
            (d) => d.wireName == q['direction'],
            orElse: () => EdgeDirection.both,
          ),
          types: types.isEmpty ? null : types.toSet(),
          profile: _profileOf(q['profile']),
        );
        return _json(<String, Object?>{
          'edges': <Object?>[for (final edge in edges) edge.toJson()],
        });
      });

  /// `POST /api/memory/recall` — single-seed recall (§ 5.4). Body:
  /// `{text?, embedding?, modes?, k?, wallClockMs?, profile?}`.
  Future<Response> _recall(Request request) => _guard((client) async {
        final body = await _body(request);
        final result = await client.recall(
          text: body['text'] as String?,
          embedding: _doubleList(body['embedding']),
          modes: _modes(body['modes']),
          k: (body['k'] as num?)?.toInt(),
          wallClockMs: (body['wallClockMs'] as num?)?.toInt(),
          profile: _profileOf(body['profile']),
        );
        return _json(result.toJson());
      });

  /// `POST /api/memory/recall/multi` — multi-seed recall (§ 5.4). Body:
  /// `{seeds: [...], k?, wallClockMs?, profile?}`.
  Future<Response> _recallMulti(Request request) => _guard((client) async {
        final body = await _body(request);
        final result = await client.recallMulti(
          seeds: <RecallSeedSpec>[
            for (final raw in (body['seeds'] as List?) ?? const <Object?>[])
              RecallSeedSpec.fromJson((raw as Map).cast<String, Object?>()),
          ],
          k: (body['k'] as num?)?.toInt(),
          wallClockMs: (body['wallClockMs'] as num?)?.toInt(),
          profile: _profileOf(body['profile']),
        );
        return _json(result.toJson());
      });

  /// `GET /api/memory/stacks?profile=<p>` — the stack inventory (§ 5.5).
  Future<Response> _stacks(Request request) => _guard((client) async {
        final stacks = await client.stackList(
          profile: _profileOf(request.url.queryParameters['profile']),
        );
        return _json(<String, Object?>{
          'stacks': <Object?>[for (final s in stacks) s.toJson()],
        });
      });

  /// `GET /api/memory/stacks/<name>?k=<k>&profile=<p>` — the top-K of a stack
  /// (§ 5.5).
  Future<Response> _stackPeek(Request request, String name) =>
      _guard((client) async {
        final q = request.url.queryParameters;
        final k = int.tryParse(q['k'] ?? '');
        final entries = await client.stackPeek(
          name,
          k: k,
          profile: _profileOf(q['profile']),
        );
        return _json(<String, Object?>{
          'entries': <Object?>[for (final e in entries) e.toJson()],
        });
      });

  /// `POST /api/memory/classify` — the centroid classification probe (§ 5.6).
  /// Body: `{embedding: [...], target?, profile?}`.
  Future<Response> _classify(Request request) => _guard((client) async {
        final body = await _body(request);
        final embedding = _doubleList(body['embedding']);
        if (embedding == null) {
          return _badRequest('POST /api/memory/classify requires an embedding');
        }
        final result = await client.classify(
          embedding,
          target: ClassifyTarget.values.firstWhere(
            (t) => t.wireName == body['target'],
            orElse: () => ClassifyTarget.nodeType,
          ),
          profile: _profileOf(body['profile']),
        );
        return _json(result.toJson());
      });

  /// `GET /api/memory/profiles` — the profile list plus the current binding
  /// (§ 5.6), combined from the two read tools.
  Future<Response> _profiles(Request request) => _guard((client) async {
        final profiles = await client.profilesList();
        final current = await client.profileCurrent();
        return _json(<String, Object?>{
          'profiles': profiles,
          'current': current,
        });
      });

  // ─── plumbing ──────────────────────────────────────────────────────────

  /// Runs [body] with the wired client, or answers `503` "memory unavailable"
  /// when the connector is deferred or a read fails ([McpReadException]) — the
  /// memory surface is always environmental, never a crash (§ 8.4).
  Future<Response> _guard(
    Future<Response> Function(MemoryReadClient client) body,
  ) async {
    final c = client;
    if (c == null) return _unavailable();
    try {
      return await body(c);
    } on McpReadException catch (e) {
      return _unavailable(detail: e.message);
    }
  }

  /// The view-scoping profile name from a `profile` request value (a query
  /// parameter on GET, a body field on POST), or `null` when absent/blank.
  /// A blank profile means "the bound profile" — never an empty-named one.
  String? _profileOf(Object? raw) =>
      (raw is String && raw.isNotEmpty) ? raw : null;

  /// The comma-separated values of [raw], or an empty list when absent/blank.
  List<String> _csv(String? raw) => (raw == null || raw.isEmpty)
      ? const <String>[]
      : raw.split(',').where((s) => s.isNotEmpty).toList();

  /// The recall modes for a `modes` body value (a list of wire tokens), or
  /// `null` when absent (the server then applies its own default set).
  Set<RecallMode>? _modes(Object? raw) {
    if (raw is! List) return null;
    final modes = <RecallMode>{
      for (final token in raw) ?RecallMode.fromWire(token as String),
    };
    return modes.isEmpty ? null : modes;
  }

  Future<Map<String, Object?>> _body(Request request) async {
    final text = await request.readAsString();
    if (text.isEmpty) return const <String, Object?>{};
    return (jsonDecode(text) as Map).cast<String, Object?>();
  }

  Response _json(Object? body, {int status = 200}) => Response(
        status,
        body: jsonEncode(body),
        headers: const <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );

  Response _badRequest(String message) =>
      _json(<String, Object?>{'error': message}, status: 400);

  Response _unavailable({String detail = 'memory unavailable'}) =>
      _json(<String, Object?>{'error': detail}, status: 503);
}

/// Decodes a JSON number list into `List<double>`, or `null` when absent.
List<double>? _doubleList(Object? raw) {
  if (raw is! List) return null;
  return <double>[for (final v in raw) (v as num).toDouble()];
}
