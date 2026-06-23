// Follow-up item 8 (MSPP-62) — the MSP-4 default prefixes are applied to *every*
// token, not just configured `apiKeys[]` entries. A token authenticated against
// a `bearerTokenBindings` entry that has **no** matching `ApiKeyConfig` (the
// "unconfigured" path) now resolves through `resolveDefaultScope`, so the
// stamped `Access` carries `defaultsession_<sel>` / `defaultmemory_<sel>`
// (defaulting the selector to `default`) instead of a null scope.
//
// These tests drive `OpenAiAccessEdge` over a real booted layer wired with a
// bearer binding but **no** `apiKeys:` block (the `_edge` pattern from
// `openai_access_edge_test.dart`), and assert the routed `Access`:
//
//   * a bare unconfigured token → `defaultsession_default` /
//     `defaultmemory_default` (MSPP-62, the universalized default);
//   * an unconfigured token carrying `session-`/`memory-` markers →
//     `defaultsession_<sel>` / `defaultmemory_<sel>` (the default-prefix
//     namespace applied to the markers);
//   * a session-only marker defaults the absent memory selector to `default`.
//
// The JWT/authenticator carve-out (scope always null) is *not* exercised here —
// it is covered by the identity sweep and stays unchanged by design (MSPP-62).

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

/// Builds a booted layer + edge whose single bearer token (`secret-token`) is an
/// **unconfigured** binding — a `bearerTokenBindings` entry with no matching
/// `apiKeys[]` config, so it resolves through the MSP-4 *default* prefixes.
({OpenAiAccessEdge edge, BootedAccessLayer booted}) _unconfiguredEdge({
  required Dispatcher dispatcher,
}) {
  final booted = BrainAccessBoot.install(
    dispatcher: dispatcher,
    config: BrainAccessConfig(
      bearerTokenBindings: {
        'secret-token': IdentityBinding(principalId: 'principal-1'),
      },
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

void main() {
  group('OpenAiAccessEdge — default-prefix scope for unconfigured tokens '
      '(MSPP-62)', () {
    test('a bare unconfigured token resolves to defaultsession_default / '
        'defaultmemory_default', () async {
      final d = _answeringDispatcher();
      final f = _unconfiguredEdge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);

      final response = await _postChat(
        f.edge,
        text: 'hello there',
        token: 'secret-token',
      );

      expect(response.statusCode, 200);
      final access = d.routed.single;
      expect(access.identity.principalId, 'principal-1');
      expect(access.session.sessionId, 'defaultsession_default');
      expect(access.session.memoryProfile, 'defaultmemory_default');
    });

    test('an unconfigured token with session-/memory- markers resolves under '
        'the default prefixes', () async {
      final d = _answeringDispatcher();
      final f = _unconfiguredEdge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);

      final response = await _postChat(
        f.edge,
        text: 'hi',
        token: 'session-foo_secret-token_memory-bar',
      );

      expect(response.statusCode, 200);
      final access = d.routed.single;
      expect(access.session.sessionId, 'defaultsession_foo');
      expect(access.session.memoryProfile, 'defaultmemory_bar');
    });

    test('a session-only marker defaults the memory selector to "default"',
        () async {
      final d = _answeringDispatcher();
      final f = _unconfiguredEdge(dispatcher: d.dispatcher);
      addTearDown(f.booted.shutdown);

      final response = await _postChat(
        f.edge,
        text: 'hi',
        token: 'session-foo_secret-token',
      );

      expect(response.statusCode, 200);
      final access = d.routed.single;
      expect(access.session.sessionId, 'defaultsession_foo');
      expect(access.session.memoryProfile, 'defaultmemory_default');
    });
  });
}
