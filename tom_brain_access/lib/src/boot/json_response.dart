// Shared JSON-response shaping for the access process's shelf surfaces (G.2.4).
//
// `Response(status, body: <json>, headers: {'content-type': <json type>})` was
// rebuilt at every JSON route — the OpenAI edge's success / error envelopes
// (`openai_access_edge.dart`) and the health endpoint (`health_check.dart`).
// This collapses the triplication into one helper and keeps the content-type
// string in a single place.
//
// It is deliberately *access-local*, not a `tom_core_agentic` primitive: it is
// bound to `shelf`'s `Response`, a transport detail the domain-free core does
// not (and must not) know about. The generic move would be a transport-neutral
// "encode this map as JSON" — which is just `jsonEncode`; the value here is the
// shelf `Response` + content-type pairing, which is HTTP-edge-specific.

import 'package:shelf/shelf.dart';

/// The JSON media type every JSON response on the access edge carries. Defined
/// once here so the OpenAI edge and the health endpoint cannot drift to
/// different charset spellings.
const String jsonContentType = 'application/json; charset=utf-8';

/// Builds a shelf [Response] carrying an already-encoded JSON [body] with the
/// shared [jsonContentType]. [status] defaults to `200`; pass a `4xx` / `5xx`
/// for an error envelope. Extra [headers] (e.g. `cache-control`) merge over the
/// content-type.
Response jsonResponse(
  String body, {
  int status = 200,
  Map<String, String> headers = const <String, String>{},
}) {
  return Response(
    status,
    body: body,
    headers: <String, String>{'content-type': jsonContentType, ...headers},
  );
}
