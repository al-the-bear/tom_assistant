// Step 5 (session_configuration_plan.md) — the live edge resolves a behaviour
// *profile* from a marker-bearing Bearer token, stamps it on `Access`, derives
// the persona from it, applies its cross-axis session/memory defaults, and
// composes its rate limit with the global one.
//
// These tests drive `OpenAiAccessEdge` over a real booted layer wired to a
// recording dispatcher (the `_answeringDispatcher()` pattern) plus an injected
// fake `profileResolver` (the run-side `ProfileRegistry` seam, SCP-18), and
// assert the stamped `Access.profile` / `Access.persona` / `Access.session`:
//
//   * `profile-<name>` resolves and stamps `Access.profile` (id / entry /
//     role) — configured profile;
//   * an absent profile marker resolves the built-in `default` profile;
//   * the resolver's `default` entry is authoritative even for the no-marker
//     request (default-redefinition through the seam);
//   * an unknown profile is a `400` / `profile.unknown` before any dispatch;
//   * a profile's `role` overrides the model-id persona's substrate role while
//     the persona id (the answered-as model echo) is preserved (spec § 3.3);
//   * a profile's `defaultSession` / `defaultMemory` are the no-marker fallback
//     through the per-tenant prefix, and an explicit marker still wins (SC-1);
//   * a profile's `requestsPerMinute` composes with the (open) global limiter —
//     a second request over the profile's bound is a `429` (SC-8).

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

/// A dispatcher that streams one final chunk and records the admitted `Access`.
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

/// A fake `ProfileResolver` over a fixed map: a `null` selector resolves the
/// `default` entry (mirroring the run-side `resolve(sel ?? 'default')`); an
/// unknown name throws [ProfileResolutionException] (mirroring the run side's
/// translated `UnknownProfileException`).
ProfileResolver _resolverOf(Map<String, ResolvedProfile> profiles) {
  return (String? selector) {
    final String name = selector ?? 'default';
    final ResolvedProfile? profile = profiles[name];
    if (profile == null) {
      throw ProfileResolutionException(name, 'no profile named "$name"');
    }
    return profile;
  };
}

/// Builds a booted layer + edge whose single key is scoped to `sess_` / `mem_`
/// and whose profile axis is the injected [profiles] map.
({OpenAiAccessEdge edge, BootedAccessLayer booted}) _profiledEdge({
  required Dispatcher dispatcher,
  required Map<String, ResolvedProfile> profiles,
  List<String>? allowedProfiles,
}) {
  final apiKey = ApiKeyConfig(
    key: 'secret-token',
    principal: 'principal-1',
    sessionPrefix: 'sess_',
    memoryPrefix: 'mem_',
    allowedProfiles: allowedProfiles,
  );
  final booted = BrainAccessBoot.install(
    dispatcher: dispatcher,
    config: BrainAccessConfig(
      bearerTokenBindings: {'secret-token': apiKey.toBinding()},
      apiKeys: [apiKey],
      profileResolver: _resolverOf(profiles),
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

/// The byte-compatible default profile the seam resolves for `null`/`default`.
ResolvedProfile _defaultProfile() => const ResolvedProfile.cognitiveDefault();

void main() {
  group('OpenAiAccessEdge — profile resolution + stamping', () {
    test('a profile- marker resolves and stamps Access.profile', () async {
      final d = _answeringDispatcher();
      final research = ResolvedProfile(
        id: 'research',
        mode: ProfileMode.cognitive,
        entryProcedure: 'research_v1',
        role: 'researcher',
      );
      final f = _profiledEdge(
        dispatcher: d.dispatcher,
        profiles: {'default': _defaultProfile(), 'research': research},
      );
      addTearDown(f.booted.shutdown);

      final response = await _postChat(
        f.edge,
        text: 'find me sources',
        token: 'profile-research_secret-token',
      );

      expect(response.statusCode, 200);
      final access = d.routed.single;
      expect(access.profile.id, 'research');
      expect(access.profile.entryProcedure, 'research_v1');
      expect(access.profile.role, 'researcher');
    });

    test('an absent profile marker resolves the built-in default profile',
        () async {
      final d = _answeringDispatcher();
      final f = _profiledEdge(
        dispatcher: d.dispatcher,
        profiles: {'default': _defaultProfile()},
      );
      addTearDown(f.booted.shutdown);

      final response = await _postChat(f.edge, text: 'hi', token: 'secret-token');

      expect(response.statusCode, 200);
      final access = d.routed.single;
      expect(access.profile.id, 'default');
      expect(access.profile.entryProcedure, 'prompt_analyzer_v1');
      expect(access.profile.role, isNull);
    });

    test('the resolver default is authoritative for the no-marker request',
        () async {
      final d = _answeringDispatcher();
      // The operator redefined `default` to a non-cognitive entry; the seam — not
      // the const cognitiveDefault — governs the no-marker request.
      final redefinedDefault = ResolvedProfile(
        id: 'default',
        mode: ProfileMode.answer,
        entryProcedure: 'answer_with_memory_v1',
        role: 'house_style',
      );
      final f = _profiledEdge(
        dispatcher: d.dispatcher,
        profiles: {'default': redefinedDefault},
      );
      addTearDown(f.booted.shutdown);

      final response = await _postChat(f.edge, text: 'hi', token: 'secret-token');

      expect(response.statusCode, 200);
      final access = d.routed.single;
      expect(access.profile.id, 'default');
      expect(access.profile.entryProcedure, 'answer_with_memory_v1');
      expect(access.profile.role, 'house_style');
    });

    test('an unknown profile is a 400 profile.unknown before any dispatch',
        () async {
      final d = _answeringDispatcher();
      final f = _profiledEdge(
        dispatcher: d.dispatcher,
        profiles: {'default': _defaultProfile()},
      );
      addTearDown(f.booted.shutdown);

      final response = await _postChat(
        f.edge,
        text: 'hi',
        token: 'profile-ghost_secret-token',
      );

      expect(response.statusCode, 400);
      expect(d.routed, isEmpty);
      final error = (await _json(response))['error'] as Map<String, Object?>;
      expect(error['code'], 'profile.unknown');
      expect(error['type'], 'invalid_request_error');
    });

    test("a profile's role overrides the persona's substrate role, keeping id",
        () async {
      final d = _answeringDispatcher();
      final research = ResolvedProfile(
        id: 'research',
        mode: ProfileMode.cognitive,
        entryProcedure: 'research_v1',
        role: 'researcher',
      );
      final f = _profiledEdge(
        dispatcher: d.dispatcher,
        profiles: {'default': _defaultProfile(), 'research': research},
      );
      addTearDown(f.booted.shutdown);

      final response = await _postChat(
        f.edge,
        text: 'hi',
        token: 'profile-research_secret-token',
      );

      expect(response.statusCode, 200);
      final access = d.routed.single;
      // The substrate role is the profile's; the persona id (model echo) stands.
      expect(access.persona.substrateRole, 'researcher');
      expect(access.persona.personaId, isNotEmpty);
    });

    test('the default profile (role null) leaves the model-id persona untouched',
        () async {
      final d = _answeringDispatcher();
      final f = _profiledEdge(
        dispatcher: d.dispatcher,
        profiles: {'default': _defaultProfile()},
      );
      addTearDown(f.booted.shutdown);

      final response = await _postChat(f.edge, text: 'hi', token: 'secret-token');

      expect(response.statusCode, 200);
      final access = d.routed.single;
      expect(access.persona.substrateRole, Persona.defaultSubstrateRole);
    });

    test("a profile's cross-axis defaults fall back through the prefix", () async {
      final d = _answeringDispatcher();
      final scoped = ResolvedProfile(
        id: 'scoped',
        mode: ProfileMode.cognitive,
        entryProcedure: 'prompt_analyzer_v1',
        defaultSession: 'team',
        defaultMemory: 'shared',
      );
      final f = _profiledEdge(
        dispatcher: d.dispatcher,
        profiles: {'default': _defaultProfile(), 'scoped': scoped},
      );
      addTearDown(f.booted.shutdown);

      // No session/memory markers — the profile's defaults apply through the
      // key's prefixes.
      final response = await _postChat(
        f.edge,
        text: 'hi',
        token: 'profile-scoped_secret-token',
      );

      expect(response.statusCode, 200);
      final access = d.routed.single;
      expect(access.session.sessionId, 'sess_team');
      expect(access.session.memoryProfile, 'mem_shared');
    });

    test('an explicit session marker wins over the profile default (SC-1)',
        () async {
      final d = _answeringDispatcher();
      final scoped = ResolvedProfile(
        id: 'scoped',
        mode: ProfileMode.cognitive,
        entryProcedure: 'prompt_analyzer_v1',
        defaultSession: 'team',
        defaultMemory: 'shared',
      );
      final f = _profiledEdge(
        dispatcher: d.dispatcher,
        profiles: {'default': _defaultProfile(), 'scoped': scoped},
      );
      addTearDown(f.booted.shutdown);

      // An explicit session- marker overrides the profile default; the memory
      // default still applies (no memory marker).
      final response = await _postChat(
        f.edge,
        text: 'hi',
        token: 'session-mine_profile-scoped_secret-token',
      );

      expect(response.statusCode, 200);
      final access = d.routed.single;
      expect(access.session.sessionId, 'sess_mine'); // explicit wins
      expect(access.session.memoryProfile, 'mem_shared'); // default applies
    });

    test("a profile's requestsPerMinute composes with the open global limiter",
        () async {
      final d = _answeringDispatcher();
      final throttled = ResolvedProfile(
        id: 'throttled',
        mode: ProfileMode.cognitive,
        entryProcedure: 'prompt_analyzer_v1',
        rateLimits: const ProfileRateLimits(requestsPerMinute: 1),
      );
      final f = _profiledEdge(
        dispatcher: d.dispatcher,
        profiles: {'default': _defaultProfile(), 'throttled': throttled},
      );
      addTearDown(f.booted.shutdown);

      const token = 'profile-throttled_secret-token';
      final first = await _postChat(f.edge, text: 'one', token: token);
      expect(first.statusCode, 200);

      // The global limiter is open (100/s) but the profile bound is 1/min, so the
      // second request under the fixed clock is rejected — the tighter bound wins.
      final second = await _postChat(f.edge, text: 'two', token: token);
      expect(second.statusCode, rateLimitHttpStatus);
      expect(d.routed.length, 1);
    });
  });

  group('OpenAiAccessEdge — per-key profile allowlist (I-5)', () {
    ResolvedProfile research() => ResolvedProfile(
          id: 'research',
          mode: ProfileMode.cognitive,
          entryProcedure: 'research_v1',
          role: 'researcher',
        );

    test('a profile not on the key allowlist is a 400 profile.forbidden '
        'before any dispatch', () async {
      final d = _answeringDispatcher();
      final f = _profiledEdge(
        dispatcher: d.dispatcher,
        profiles: {'default': _defaultProfile(), 'research': research()},
        allowedProfiles: const ['default'], // research not permitted
      );
      addTearDown(f.booted.shutdown);

      final response = await _postChat(
        f.edge,
        text: 'find me sources',
        token: 'profile-research_secret-token',
      );

      expect(response.statusCode, 400);
      expect(d.routed, isEmpty);
      final error = (await _json(response))['error'] as Map<String, Object?>;
      expect(error['code'], 'profile.forbidden');
      expect(error['type'], 'invalid_request_error');
      // The message names the profile but never the residual credential.
      expect(error['message'], contains('research'));
      expect(error['message'], isNot(contains('secret-token')));
    });

    test('a profile on the key allowlist resolves and dispatches', () async {
      final d = _answeringDispatcher();
      final f = _profiledEdge(
        dispatcher: d.dispatcher,
        profiles: {'default': _defaultProfile(), 'research': research()},
        allowedProfiles: const ['default', 'research'],
      );
      addTearDown(f.booted.shutdown);

      final response = await _postChat(
        f.edge,
        text: 'find me sources',
        token: 'profile-research_secret-token',
      );

      expect(response.statusCode, 200);
      expect(d.routed.single.profile.id, 'research');
    });

    test('an allowlist omitting default rejects a bare request '
        '(deny-by-default)', () async {
      final d = _answeringDispatcher();
      final f = _profiledEdge(
        dispatcher: d.dispatcher,
        profiles: {'default': _defaultProfile(), 'research': research()},
        allowedProfiles: const ['research'], // default not listed
      );
      addTearDown(f.booted.shutdown);

      // No profile- marker ⇒ resolves to `default`, which is not on the list.
      final response = await _postChat(f.edge, text: 'hi', token: 'secret-token');

      expect(response.statusCode, 400);
      expect(d.routed, isEmpty);
      final error = (await _json(response))['error'] as Map<String, Object?>;
      expect(error['code'], 'profile.forbidden');
      expect(error['message'], contains('default'));
    });

    test('an omitted allowlist permits any configured profile (unrestricted)',
        () async {
      final d = _answeringDispatcher();
      final f = _profiledEdge(
        dispatcher: d.dispatcher,
        profiles: {'default': _defaultProfile(), 'research': research()},
        // allowedProfiles omitted ⇒ null ⇒ unrestricted (SC-5).
      );
      addTearDown(f.booted.shutdown);

      final response = await _postChat(
        f.edge,
        text: 'find me sources',
        token: 'profile-research_secret-token',
      );

      expect(response.statusCode, 200);
      expect(d.routed.single.profile.id, 'research');
    });
  });
}
