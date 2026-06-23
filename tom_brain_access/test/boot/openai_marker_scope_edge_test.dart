// Step 5 (memory_session_profiles_plan.md) — the live edge actually selects a
// session + memory profile from a marker-bearing Bearer token.
//
// These tests drive `OpenAiAccessEdge` over a real booted layer wired to a
// recording dispatcher (the `_answeringDispatcher()` pattern from
// `openai_access_edge_test.dart`) and assert the stamped `Access`:
//
//   * a token carrying `session-<sel>` / `memory-<sel>` markers around a
//     configured residual key resolves to `Access.session.sessionId ==
//     <sessionPrefix><sel>` and `Access.session.memoryProfile ==
//     <memoryPrefix><sel>` (MSP-3 / MSP-4 / MSP-5);
//   * an absent marker defaults its selector to `default` (`<prefix>default`);
//   * an unknown residual key (the markers strip to a key with no binding) is a
//     `401` before any dispatch — the markers never fabricate identity;
//   * a duplicate marker is a `400` at the edge (`marker.duplicate`, § 13).

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart' show Dispatcher;
import 'package:tom_brain_shared/tom_brain_shared.dart';

DateTime _fixedNow() => DateTime.utc(2026, 6, 2, 12);

RateLimitPolicy _openPolicy() => RateLimitPolicy(
      capacity: 100,
      refillTokens: 100,
      refillPeriod: const Duration(seconds: 1),
    );

/// A dispatcher whose route streams one final answer chunk back and records the
/// admitted `Access`, so a test can read the stamped session off `routed`.
({Dispatcher dispatcher, List<Access> routed}) _answeringDispatcher() {
  final routed = <Access>[];
  final dispatcher = Dispatcher(
    route: (access) async {
      routed.add(access);
      access.deliver(OutboundChunk(textDelta: 'the answer', isFinal: true));
    },
  );
  return (dispatcher: dispatcher, routed: routed);
}

/// Builds a booted layer + edge whose single API key (`secret-token`) is scoped
/// to the [sessionPrefix] / [memoryPrefix] namespace (MSP-4).
({OpenAiAccessEdge edge, BootedAccessLayer booted}) _scopedEdge({
  required Dispatcher dispatcher,
  String sessionPrefix = 'sess_',
  String memoryPrefix = 'mem_',
}) {
  final apiKey = ApiKeyConfig(
    key: 'secret-token',
    principal: 'principal-1',
    sessionPrefix: sessionPrefix,
    memoryPrefix: memoryPrefix,
  );
  final booted = BrainAccessBoot.install(
    dispatcher: dispatcher,
    config: BrainAccessConfig(
      // The residual key authenticates against the identity registry; the
      // apiKeys entry supplies the namespace (this mirrors the loader fold —
      // step 3 — which puts the key in both places).
      bearerTokenBindings: {'secret-token': apiKey.toBinding()},
      apiKeys: [apiKey],
      rateLimitPolicy: _openPolicy(),
      dailyQuotaPolicy: DailyQuotaPolicy(dailyCap: 100),
      anchorPolicy: AnchorPolicy(disallowedSignatures: const []),
      clock: _fixedNow,
    ),
  );
  final edge = OpenAiAccessEdge(assembler: booted.assembler);
  return (edge: edge, booted: booted);
}

Future<Response> _postChat(
  OpenAiAccessEdge edge, {
  required String text,
  required String token,
}) async {
  return await edge.handler(
    Request(
      'POST',
      Uri.parse('http://localhost/v1/chat/completions'),
      headers: <String, String>{
        'content-type': 'application/json',
        'authorization': 'Bearer $token',
      },
      body: jsonEncode(<String, Object?>{
        'model': 'tom-assistant',
        'stream': false,
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': text},
        ],
      }),
    ),
  );
}

Future<Map<String, Object?>> _json(Response response) async =>
    jsonDecode(await response.readAsString()) as Map<String, Object?>;

void main() {
  group('OpenAiAccessEdge — marker-driven session + memory selection', () {
    test(
        'a token with session-/memory- markers stamps the prefixed ids on '
        'Access (MSP-3 / MSP-4 / MSP-5)', () async {
      final d = _answeringDispatcher();
      final f = _scopedEdge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);

      final response = await _postChat(
        f.edge,
        text: 'hello there',
        token: 'session-foo_secret-token_memory-bar',
      );

      expect(response.statusCode, 200);
      final access = d.routed.single;
      expect(access.identity.principalId, 'principal-1');
      expect(access.session.sessionId, 'sess_foo');
      expect(access.session.memoryProfile, 'mem_bar');
    });

    test('an absent marker defaults its selector to "default"', () async {
      final d = _answeringDispatcher();
      final f = _scopedEdge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);

      // Only a session marker; the memory selector defaults.
      final response = await _postChat(
        f.edge,
        text: 'hi',
        token: 'session-foo_secret-token',
      );

      expect(response.statusCode, 200);
      final access = d.routed.single;
      expect(access.session.sessionId, 'sess_foo');
      expect(access.session.memoryProfile, 'mem_default');
    });

    test('a bare key (no markers) resolves to the all-default scope', () async {
      final d = _answeringDispatcher();
      final f = _scopedEdge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);

      final response = await _postChat(f.edge, text: 'hi', token: 'secret-token');

      expect(response.statusCode, 200);
      final access = d.routed.single;
      expect(access.session.sessionId, 'sess_default');
      expect(access.session.memoryProfile, 'mem_default');
    });

    test('an unknown residual key is a 401 before any dispatch', () async {
      final d = _answeringDispatcher();
      final f = _scopedEdge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);

      final response = await _postChat(
        f.edge,
        text: 'hi',
        token: 'session-foo_wrong-token_memory-bar',
      );

      expect(response.statusCode, bearerAuthHttpStatus);
      expect(d.routed, isEmpty);
      final error = (await _json(response))['error'] as Map<String, Object?>;
      expect(error['code'], 'identity_unresolved');
    });

    test('a duplicate marker is a 400 marker.duplicate', () async {
      final d = _answeringDispatcher();
      final f = _scopedEdge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);

      final response = await _postChat(
        f.edge,
        text: 'hi',
        token: 'session-foo_secret-token_session-bar',
      );

      expect(response.statusCode, 400);
      expect(d.routed, isEmpty);
      final error = (await _json(response))['error'] as Map<String, Object?>;
      expect(error['code'], 'marker.duplicate');
      expect(error['type'], 'invalid_request_error');
    });
  });
}
