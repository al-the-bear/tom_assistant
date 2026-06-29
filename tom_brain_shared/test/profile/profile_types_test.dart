// Profile-axis shared value types (session_configuration_plan.md step 2).
//
// The Profile is the third selection axis (alongside Session and Memory). The
// raw config-side `Profile` aggregate lives in `tom_brain_run` (it references
// `McpServerConfig`, which `tom_brain_shared` may not depend on — SCP-6); the
// value sub-types it composes and the boot-resolved bundle `Access` actually
// reads live here. This suite proves the shared contract:
//
//   * `ProfileMode`       — the closed cognitive/answer/passthrough/retrieval
//                           alphabet,
//                           its mode→entry-procedure mapping (spec § 3.2), and
//                           a wire (de)serialisation surface.
//   * `ProfileBudget`     — the optional per-profile budget envelope, with
//                           value equality + JSON round-trip.
//   * `ProfileRateLimits` — likewise for the per-profile rate-limits.
//   * `ResolvedProfile`   — the immutable bundle stamped on `Access`, including
//                           the byte-compatible `cognitiveDefault()` (SC-5).
//   * `Access.profile`    — the new non-null field, defaulting to
//                           `ResolvedProfile.cognitiveDefault()`.

import 'package:test/test.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        DeliverCallback,
        InboundRequest,
        OutboundChunk,
        Persona,
        ProfileBudget,
        ProfileMode,
        ProfileRateLimits,
        ResolvedIdentity,
        ResolvedProfile,
        Session;

Stream<OutboundChunk> _echoDeliver(OutboundChunk chunk) =>
    Stream<OutboundChunk>.value(chunk);

Access _accessWith({ResolvedProfile? profile, DeliverCallback? deliver}) {
  final d = deliver ?? _echoDeliver;
  // `Access.profile` is non-null with a default, so the parameter type is
  // non-nullable: only pass it when the test supplies one, otherwise let the
  // `cognitiveDefault()` default apply.
  return profile == null
      ? Access(
          envelope: InboundRequest(text: 'hello'),
          identity: ResolvedIdentity(principalId: 'p1'),
          session: Session(sessionId: 's1'),
          persona: Persona.assistant(),
          deliver: d,
        )
      : Access(
          envelope: InboundRequest(text: 'hello'),
          identity: ResolvedIdentity(principalId: 'p1'),
          session: Session(sessionId: 's1'),
          persona: Persona.assistant(),
          deliver: d,
          profile: profile,
        );
}

void main() {
  group('ProfileMode', () {
    test('is the closed cognitive/answer/passthrough/retrieval alphabet', () {
      // SC-Q4 widened the alphabet with the zero-LLM `retrieval` diagnostic
      // mode (procedure spec § 24.9); it remains closed at four.
      expect(ProfileMode.values,
          containsAll(<ProfileMode>[
            ProfileMode.cognitive,
            ProfileMode.answer,
            ProfileMode.passthrough,
            ProfileMode.retrieval,
          ]));
      expect(ProfileMode.values, hasLength(4));
    });

    test('maps each mode to its default entry procedure (spec § 3.2)', () {
      expect(ProfileMode.cognitive.defaultEntryProcedure, 'prompt_analyzer_v1');
      expect(ProfileMode.answer.defaultEntryProcedure, 'answer_with_memory_v1');
      expect(ProfileMode.passthrough.defaultEntryProcedure, 'passthrough_v1');
      expect(ProfileMode.retrieval.defaultEntryProcedure, 'retrieve_v1');
    });

    test('wireName / fromWire round-trip for every mode', () {
      for (final mode in ProfileMode.values) {
        expect(ProfileMode.fromWire(mode.wireName), mode);
      }
      expect(ProfileMode.cognitive.wireName, 'cognitive');
    });

    test('fromWire rejects an unknown token', () {
      expect(() => ProfileMode.fromWire('turbo'), throwsArgumentError);
    });
  });

  group('ProfileBudget', () {
    test('all fields default to null (inherit the procedure header)', () {
      const b = ProfileBudget();
      expect(b.maxLlmCalls, isNull);
      expect(b.maxToolCalls, isNull);
      expect(b.maxTokens, isNull);
      expect(b.wallClock, isNull);
    });

    test('carries the fields it is given', () {
      const b = ProfileBudget(
        maxLlmCalls: 24,
        maxToolCalls: 8,
        maxTokens: 4096,
        wallClock: Duration(seconds: 180),
      );
      expect(b.maxLlmCalls, 24);
      expect(b.maxToolCalls, 8);
      expect(b.maxTokens, 4096);
      expect(b.wallClock, const Duration(seconds: 180));
    });

    test('value equality / hashCode', () {
      const a = ProfileBudget(maxLlmCalls: 24, wallClock: Duration(seconds: 1));
      const b = ProfileBudget(maxLlmCalls: 24, wallClock: Duration(seconds: 1));
      const c = ProfileBudget(maxLlmCalls: 25, wallClock: Duration(seconds: 1));
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('JSON round-trips through fromJson', () {
      const b = ProfileBudget(
        maxLlmCalls: 24,
        maxToolCalls: 8,
        maxTokens: 4096,
        wallClock: Duration(seconds: 180),
      );
      expect(ProfileBudget.fromJson(b.toJson()), equals(b));
      // The empty envelope round-trips too.
      expect(ProfileBudget.fromJson(const ProfileBudget().toJson()),
          equals(const ProfileBudget()));
    });
  });

  group('ProfileRateLimits', () {
    test('all fields default to null (inherit the global value)', () {
      const r = ProfileRateLimits();
      expect(r.requestsPerMinute, isNull);
      expect(r.concurrentRuns, isNull);
    });

    test('value equality / hashCode + JSON round-trip', () {
      const a = ProfileRateLimits(requestsPerMinute: 30, concurrentRuns: 2);
      const b = ProfileRateLimits(requestsPerMinute: 30, concurrentRuns: 2);
      const c = ProfileRateLimits(requestsPerMinute: 60, concurrentRuns: 2);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(ProfileRateLimits.fromJson(a.toJson()), equals(a));
    });
  });

  group('ResolvedProfile', () {
    ResolvedProfile sample() => ResolvedProfile(
          id: 'research',
          mode: ProfileMode.cognitive,
          entryProcedure: 'prompt_analyzer_v1',
          role: 'researcher',
          anchored: true,
          templateOverlay: 'research',
          offeredMcpServers: const ['web', 'research/docs'],
          budget: const ProfileBudget(maxLlmCalls: 24),
          rateLimits: const ProfileRateLimits(requestsPerMinute: 30),
          defaultSession: 'weekend',
          defaultMemory: 'research',
        );

    test('carries every field it is given', () {
      final p = sample();
      expect(p.id, 'research');
      expect(p.mode, ProfileMode.cognitive);
      expect(p.entryProcedure, 'prompt_analyzer_v1');
      expect(p.role, 'researcher');
      expect(p.anchored, isTrue);
      expect(p.templateOverlay, 'research');
      expect(p.offeredMcpServers, ['web', 'research/docs']);
      expect(p.budget, const ProfileBudget(maxLlmCalls: 24));
      expect(p.rateLimits, const ProfileRateLimits(requestsPerMinute: 30));
      expect(p.defaultSession, 'weekend');
      expect(p.defaultMemory, 'research');
    });

    test('value equality / hashCode over all fields', () {
      expect(sample(), equals(sample()));
      expect(sample().hashCode, equals(sample().hashCode));
    });

    test('inequality when any single field differs', () {
      final base = sample();
      ResolvedProfile copy({
        String? id,
        ProfileMode? mode,
        String? entryProcedure,
        Object? role = _unset,
        bool? anchored,
        Object? templateOverlay = _unset,
        List<String>? offeredMcpServers,
        Object? budget = _unset,
        Object? rateLimits = _unset,
        Object? defaultSession = _unset,
        Object? defaultMemory = _unset,
      }) =>
          ResolvedProfile(
            id: id ?? base.id,
            mode: mode ?? base.mode,
            entryProcedure: entryProcedure ?? base.entryProcedure,
            role: role == _unset ? base.role : role as String?,
            anchored: anchored ?? base.anchored,
            templateOverlay: templateOverlay == _unset
                ? base.templateOverlay
                : templateOverlay as String?,
            offeredMcpServers: offeredMcpServers ?? base.offeredMcpServers,
            budget: budget == _unset ? base.budget : budget as ProfileBudget?,
            rateLimits: rateLimits == _unset
                ? base.rateLimits
                : rateLimits as ProfileRateLimits?,
            defaultSession: defaultSession == _unset
                ? base.defaultSession
                : defaultSession as String?,
            defaultMemory: defaultMemory == _unset
                ? base.defaultMemory
                : defaultMemory as String?,
          );
      expect(base, isNot(equals(copy(id: 'other'))));
      expect(base, isNot(equals(copy(mode: ProfileMode.answer))));
      expect(base, isNot(equals(copy(entryProcedure: 'answer_with_memory_v1'))));
      expect(base, isNot(equals(copy(role: null))));
      expect(base, isNot(equals(copy(anchored: false))));
      expect(base, isNot(equals(copy(templateOverlay: null))));
      expect(base, isNot(equals(copy(offeredMcpServers: const ['web']))));
      expect(base, isNot(equals(copy(budget: null))));
      expect(base, isNot(equals(copy(rateLimits: null))));
      expect(base, isNot(equals(copy(defaultSession: null))));
      expect(base, isNot(equals(copy(defaultMemory: null))));
    });

    test('JSON round-trips through fromJson', () {
      expect(ResolvedProfile.fromJson(sample().toJson()), equals(sample()));
      expect(
        ResolvedProfile.fromJson(
            const ResolvedProfile.cognitiveDefault().toJson()),
        equals(const ResolvedProfile.cognitiveDefault()),
      );
    });

    test('offeredMcpServers is an unmodifiable defensive copy', () {
      final source = <String>['web'];
      final p = ResolvedProfile(
        id: 'x',
        mode: ProfileMode.cognitive,
        entryProcedure: 'prompt_analyzer_v1',
        offeredMcpServers: source,
      );
      source.add('leak');
      expect(p.offeredMcpServers, ['web']);
      expect(() => p.offeredMcpServers.add('y'), throwsUnsupportedError);
    });

    test('cognitiveDefault() is byte-compatible with today (SC-5)', () {
      const d = ResolvedProfile.cognitiveDefault();
      expect(d.id, 'default');
      expect(d.mode, ProfileMode.cognitive);
      expect(d.entryProcedure, 'prompt_analyzer_v1');
      expect(d.role, isNull);
      expect(d.anchored, isTrue);
      expect(d.templateOverlay, isNull);
      expect(d.offeredMcpServers, isEmpty);
      expect(d.budget, isNull);
      expect(d.rateLimits, isNull);
      expect(d.defaultSession, isNull);
      expect(d.defaultMemory, isNull);
    });

    test('cognitiveDefault() is a const, canonicalised singleton shape', () {
      // The const constructor lets `Access.profile` carry it as a compile-time
      // default; two const instances are identical.
      const a = ResolvedProfile.cognitiveDefault();
      const b = ResolvedProfile.cognitiveDefault();
      expect(identical(a, b), isTrue);
      expect(a, equals(b));
    });
  });

  group('Access.profile', () {
    test('defaults to ResolvedProfile.cognitiveDefault() when unsupplied', () {
      final access = _accessWith();
      expect(access.profile, const ResolvedProfile.cognitiveDefault());
    });

    test('carries an explicitly supplied profile', () {
      final relay = ResolvedProfile(
        id: 'relay',
        mode: ProfileMode.passthrough,
        entryProcedure: 'passthrough_v1',
        anchored: false,
      );
      final access = _accessWith(profile: relay);
      expect(access.profile, relay);
      expect(access.profile.anchored, isFalse);
    });

    test('profile participates in equality / hashCode', () {
      final shared = _echoDeliver;
      final a = _accessWith(deliver: shared);
      final b = _accessWith(deliver: shared);
      final c = _accessWith(
        deliver: shared,
        profile: ResolvedProfile(
          id: 'quick',
          mode: ProfileMode.answer,
          entryProcedure: 'answer_with_memory_v1',
        ),
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });
}

/// Sentinel marking "argument not supplied" so a copy helper can distinguish
/// "leave unchanged" from "set to null" for nullable fields.
const Object _unset = Object();
