// Profile entry-procedure override tests
// (Plan step 6; `session_configuration.md` § 5.1; decisions SCP-21…SCP-25).
//
// Step 6 gives `resolveProcedureId` a *first* door, ahead of the existing
// hint/classifier doors: a profile's boot-resolved `entryProcedure` (its
// `mode` or an explicit override) chooses the entry procedure. The non-obvious
// constraint (SCP-21): `Access.profile` is never null — it defaults to
// `ResolvedProfile.cognitiveDefault()` whose entry is `prompt_analyzer_v1` — so
// the first door must be an *override*, firing only for a non-cognitive-baseline
// entry. The cognitive default flows through the existing doors unchanged,
// preserving their loud-rejection contract (the reason `d16`/`d17` still pass
// byte-for-byte).
//
// These tests pin:
//
//   1. Each mode reaches its entry procedure: `cognitive` →
//      `prompt_analyzer_v1` (through the fallback doors), `answer` →
//      `answer_with_memory_v1` (first door), `passthrough` → `passthrough_v1`
//      (first door).
//   2. An explicit `entryProcedure` wins over the mode default and over any
//      kindHint.
//   3. The cognitive default still rejects an unknown hint loudly — proof the
//      first door is inert for it and the fallback doors are intact.
//   4. The selector's `resolveEntryProcedure` validates against the closed
//      entry set (distinct from the kindHint door's `knownProcedureIds`).
//   5. The mode/entry *conflict* is a boot (step 3) concern, not re-litigated
//      at dispatch: the dispatcher trusts the already-resolved entry.

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show
        InboundClassifier,
        ProcedureSelector,
        SystemProcedures,
        UnknownProcedureHint,
        defaultEntryProcedures,
        resolveProcedureId;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        InboundRequest,
        OutboundChunk,
        Persona,
        ProfileMode,
        ResolvedIdentity,
        ResolvedProfile,
        Session;

/// Builds an [Access] carrying [profile] (default: the cognitive default), an
/// optional centroid [kindHint], and otherwise the byte-compatible defaults the
/// other dispatcher tests use.
Access _accessWith({
  ResolvedProfile profile = const ResolvedProfile.cognitiveDefault(),
  String text = 'what is the time?',
  String? kindHint,
}) =>
    Access(
      envelope: InboundRequest(text: text, kindHint: kindHint),
      identity: ResolvedIdentity(principalId: 'p1'),
      session: Session(sessionId: 's1'),
      persona: Persona.assistant(),
      profile: profile,
      deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
    );

/// A profile of [mode] with an optional explicit [entryProcedure] override —
/// mirroring what `ProfileRegistry.resolve` stamps at boot (the explicit entry
/// wins over the mode default; the conflict guard is boot's job, step 3).
ResolvedProfile _profile(
  ProfileMode mode, {
  String? entryProcedure,
}) =>
    ResolvedProfile(
      id: 'p-${mode.wireName}',
      mode: mode,
      entryProcedure: entryProcedure ?? mode.defaultEntryProcedure,
    );

String _resolve(Access access) => resolveProcedureId(
      access,
      classifier: InboundClassifier(),
      selector: ProcedureSelector(),
    );

void main() {
  group('step 6 — profile entry door (resolveProcedureId)', () {
    test('cognitive mode resolves to prompt_analyzer_v1 via the fallback doors',
        () {
      // The cognitive entry IS prompt_analyzer_v1, so the first door is inert
      // and the no-hint classifier resolves user_prompt → prompt_analyzer_v1.
      expect(
        _resolve(_accessWith(profile: _profile(ProfileMode.cognitive))),
        SystemProcedures.promptAnalyzerV1,
      );
    });

    test('the default profile (cognitiveDefault) resolves the same', () {
      expect(_resolve(_accessWith()), SystemProcedures.promptAnalyzerV1);
    });

    test('answer mode routes directly to answer_with_memory_v1 (first door)',
        () {
      expect(
        _resolve(_accessWith(profile: _profile(ProfileMode.answer))),
        SystemProcedures.answerWithMemoryV1,
      );
    });

    test('passthrough mode routes directly to passthrough_v1 (first door)', () {
      expect(
        _resolve(_accessWith(profile: _profile(ProfileMode.passthrough))),
        SystemProcedures.passthroughV1,
      );
    });

    test('retrieval mode routes directly to retrieve_v1 (first door)', () {
      // SC-Q4: the zero-LLM diagnostic mode reaches its entry the same way the
      // other non-cognitive modes do — the first door fires on the non-baseline
      // entry. The entry is substrate-free by construction (retrieve_v1 imports
      // no substrate bridge), but routing does not care; it only resolves the id.
      expect(
        _resolve(_accessWith(profile: _profile(ProfileMode.retrieval))),
        SystemProcedures.retrieveV1,
      );
    });

    test('an explicit entryProcedure wins over the cognitive mode default', () {
      // A cognitive profile that explicitly pins answer_with_memory_v1: the
      // explicit entry is non-baseline, so the first door fires and wins.
      final profile = _profile(
        ProfileMode.cognitive,
        entryProcedure: SystemProcedures.answerWithMemoryV1,
      );
      expect(_resolve(_accessWith(profile: profile)),
          SystemProcedures.answerWithMemoryV1);
    });

    test('the profile entry first door wins over a conflicting kindHint', () {
      // answer mode (entry answer_with_memory_v1) with a prompt_analyzer_v1
      // centroid hint: the first door fires before the hint door is consulted.
      final access = _accessWith(
        profile: _profile(ProfileMode.answer),
        kindHint: SystemProcedures.promptAnalyzerV1,
      );
      expect(_resolve(access), SystemProcedures.answerWithMemoryV1);
    });

    test('the cognitive default still rejects an unknown kindHint loudly', () {
      // Proof the first door is inert for the cognitive baseline and the
      // fallback hint door (with its loud rejection) is preserved (SCP-21).
      expect(
        () => _resolve(_accessWith(kindHint: 'background_research')),
        throwsA(isA<UnknownProcedureHint>()),
      );
    });

    test('the dispatcher trusts the resolved entry — no mode/entry re-check', () {
      // A "cognitive" profile whose entry is passthrough_v1 is a config the
      // boot guard (step 3) would reject; if one ever reached the dispatcher it
      // routes by the resolved entry, not by the mode. The conflict is boot's
      // concern, never re-litigated here.
      final odd = ResolvedProfile(
        id: 'odd',
        mode: ProfileMode.cognitive,
        entryProcedure: SystemProcedures.passthroughV1,
      );
      expect(_resolve(_accessWith(profile: odd)),
          SystemProcedures.passthroughV1);
    });
  });

  group('step 6 — ProcedureSelector.resolveEntryProcedure', () {
    test('each shipped entry procedure resolves to itself', () {
      final selector = ProcedureSelector();
      expect(selector.resolveEntryProcedure(SystemProcedures.promptAnalyzerV1),
          SystemProcedures.promptAnalyzerV1);
      expect(selector.resolveEntryProcedure(SystemProcedures.answerWithMemoryV1),
          SystemProcedures.answerWithMemoryV1);
      expect(selector.resolveEntryProcedure(SystemProcedures.passthroughV1),
          SystemProcedures.passthroughV1);
      expect(selector.resolveEntryProcedure(SystemProcedures.retrieveV1),
          SystemProcedures.retrieveV1);
    });

    test('the entry is trimmed before it is matched', () {
      expect(
        ProcedureSelector().resolveEntryProcedure('  passthrough_v1\n'),
        SystemProcedures.passthroughV1,
      );
    });

    test('an unknown entry raises UnknownProcedureHint naming the entry set',
        () {
      final selector = ProcedureSelector();
      try {
        selector.resolveEntryProcedure('research_v1');
        fail('expected UnknownProcedureHint');
      } on UnknownProcedureHint catch (e) {
        expect(e.procedureId, 'research_v1');
        expect(e.knownProcedureIds, <String>[
          SystemProcedures.promptAnalyzerV1,
          SystemProcedures.answerWithMemoryV1,
          SystemProcedures.passthroughV1,
          SystemProcedures.retrieveV1,
        ]);
      }
    });

    test('knownEntryProcedures reports the closed four-entry set', () {
      expect(ProcedureSelector().knownEntryProcedures, <String>[
        SystemProcedures.promptAnalyzerV1,
        SystemProcedures.answerWithMemoryV1,
        SystemProcedures.passthroughV1,
        SystemProcedures.retrieveV1,
      ]);
    });

    test('the entry set is distinct from the kindHint door knownProcedureIds',
        () {
      // SCP-22: widening the entry set must not widen the kindHint door — d16
      // pins knownProcedureIds == [prompt_analyzer_v1].
      final selector = ProcedureSelector();
      expect(selector.knownProcedureIds,
          <String>[SystemProcedures.promptAnalyzerV1]);
      expect(
        () => selector
            .resolveHintedProcedure(SystemProcedures.answerWithMemoryV1),
        throwsA(isA<UnknownProcedureHint>()),
        reason: 'answer_with_memory_v1 is a valid entry but not a routable hint',
      );
    });

    test('defaultEntryProcedures is the four mode entries', () {
      expect(defaultEntryProcedures, <String>{
        SystemProcedures.promptAnalyzerV1,
        SystemProcedures.answerWithMemoryV1,
        SystemProcedures.passthroughV1,
        SystemProcedures.retrieveV1,
      });
    });

    test('an injected entry set widens the admitted entries', () {
      // "Fed from the resolved profile" (SCP-25): the run side may add a
      // profile's custom entry to the validation registry.
      final selector = ProcedureSelector(
        entryProcedures: const <String>{
          SystemProcedures.promptAnalyzerV1,
          'research_v1',
        },
      );
      expect(selector.resolveEntryProcedure('research_v1'), 'research_v1');
      expect(
        () => selector.resolveEntryProcedure(SystemProcedures.passthroughV1),
        throwsA(isA<UnknownProcedureHint>()),
      );
    });
  });
}
