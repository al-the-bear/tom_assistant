// Extension-H profile-selection contract test — the `MemoryProfileSelector`
// folded into the two-history `SessionManager` (access spec § 7.4; hub
// § 23.6; plan step #32).
//
// Access owns the session, so it owns memory-profile selection. On the first
// admitted prompt of a session, if `selection.enabled`, the manager runs the
// `profile_selector` role (here a fake) over the prompt (+ history when
// `useHistory`) and the known profile names, then:
//
//   * confidence ≥ `inconclusiveThreshold` → pin the name on the session;
//   * below threshold → use `selection.default`, mark inconclusive, and re-run
//     the selector every `recheckEveryNTurns` turns until confident (then
//     re-pin, `access.profile.repinned`);
//   * the picked name matches no known profile → `access.profile.unknown`,
//     fall back to default, stay inconclusive;
//   * the selector call fails → `access.profile.selector.unavailable`, fall
//     back to default, stay inconclusive (PE-6 graceful degrade).
//
// `selection.enabled: false` (or no selector wired) makes no selector call and
// leaves the session on the process default profile.

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show SelectionSettings;
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

ResolvedIdentity _identity(String principalId) =>
    ResolvedIdentity(principalId: principalId);

InboundRequest _inbound({required String text, String? sessionId}) =>
    InboundRequest(text: text, sessionId: sessionId);

SessionIdMinter _counterMinter() {
  var n = 0;
  return () => 'sess-${n++}';
}

/// A fake `MemoryProfileSelector` driven by a scripted list of outcomes
/// (replayed by call index; the last entry repeats). A `null` entry throws,
/// modelling a substrate outage. Records every call's prompt + history.
final class _FakeSelector implements MemoryProfileSelector {
  _FakeSelector(this._script);

  final List<ProfileSelection?> _script;
  int calls = 0;
  final List<String> prompts = <String>[];
  final List<List<HistoryTurn>> histories = <List<HistoryTurn>>[];

  @override
  Future<ProfileSelection> select({
    required String prompt,
    required List<HistoryTurn> history,
  }) async {
    final index = calls;
    calls++;
    prompts.add(prompt);
    histories.add(history);
    final entry =
        _script[index < _script.length ? index : _script.length - 1];
    if (entry == null) {
      throw StateError('profile selector unavailable');
    }
    return entry;
  }
}

/// Resolves a turn and immediately runs profile selection, returning the
/// outcome — the access pipeline order (resolve → select).
Future<MemoryProfileSelectionOutcome> _turn(
  SessionManager manager, {
  required String text,
  String? sessionId,
}) async {
  final envelope = _inbound(text: text, sessionId: sessionId);
  final res = manager.resolve(
    identity: _identity('p1'),
    channel: AccessChannel.openai,
    envelope: envelope,
  );
  return manager.selectMemoryProfile(resolution: res, envelope: envelope);
}

ProfileSelection _pick(String profile, double confidence,
        {bool isKnownProfile = true}) =>
    ProfileSelection(
      profile: profile,
      confidence: confidence,
      isKnownProfile: isKnownProfile,
    );

const _enabled = SelectionSettings(
  enabled: true,
  defaultProfile: 'default',
  inconclusiveThreshold: 0.5,
  recheckEveryNTurns: 2,
);

void main() {
  group('selection disabled / unwired — no selector call', () {
    test('selection.enabled: false makes no selector call (process default)',
        () async {
      final selector = _FakeSelector([_pick('work', 0.9)]);
      final manager = SessionManager(
        sessionIdMinter: _counterMinter(),
        profileSelector: selector,
        selection: const SelectionSettings(), // enabled defaults to false
      );

      final outcome = await _turn(manager, text: 'hello');

      expect(outcome.status, MemoryProfileSelectionStatus.disabled);
      expect(outcome.profile, isNull);
      expect(selector.calls, 0);
    });

    test('no selector wired degrades to the process default even if enabled',
        () async {
      final manager = SessionManager(
        sessionIdMinter: _counterMinter(),
        selection: _enabled, // enabled, but profileSelector is null
      );

      final outcome = await _turn(manager, text: 'hello');

      expect(outcome.status, MemoryProfileSelectionStatus.disabled);
      expect(outcome.profile, isNull);
    });
  });

  group('confident first prompt pins the profile', () {
    test('a confident pick pins and stamps the session', () async {
      final selector = _FakeSelector([_pick('work', 0.9)]);
      final manager = SessionManager(
        sessionIdMinter: _counterMinter(),
        profileSelector: selector,
        selection: _enabled,
      );

      final res = manager.resolve(
        identity: _identity('p1'),
        channel: AccessChannel.openai,
        envelope: _inbound(text: 'help me at the office'),
      );
      final outcome = await manager.selectMemoryProfile(
        resolution: res,
        envelope: _inbound(text: 'help me at the office'),
      );

      expect(outcome.status, MemoryProfileSelectionStatus.pinned);
      expect(outcome.profile, 'work');
      expect(outcome.confidence, 0.9);
      expect(selector.calls, 1);
      // The session handle stamps the pinned profile.
      expect(res.session.withMemoryProfile(outcome.profile).memoryProfile,
          'work');
      expect(manager.peekMemoryProfile(res.sessionId), 'work');
    });

    test('a pinned profile is reused on later turns with no new selector call',
        () async {
      final selector = _FakeSelector([_pick('work', 0.9)]);
      final manager = SessionManager(
        sessionIdMinter: _counterMinter(),
        profileSelector: selector,
        selection: _enabled,
      );

      final first = await _turn(manager, text: 'office stuff');
      expect(first.status, MemoryProfileSelectionStatus.pinned);

      final second = await _turn(
        manager,
        text: 'more office stuff',
        sessionId: 'sess-0',
      );
      expect(second.status, MemoryProfileSelectionStatus.alreadyPinned);
      expect(second.profile, 'work');
      expect(selector.calls, 1, reason: 'no re-selection once confident');
    });
  });

  group('inconclusive → default → re-check after the window → re-pin', () {
    test('an inconclusive pick uses default and re-checks then re-pins',
        () async {
      // call#1 inconclusive (0.3), call#2 confident (0.9).
      final selector = _FakeSelector([_pick('work', 0.3), _pick('work', 0.9)]);
      final manager = SessionManager(
        sessionIdMinter: _counterMinter(),
        profileSelector: selector,
        selection: _enabled, // recheckEveryNTurns: 2
      );

      // Turn 1: inconclusive → default, selector called once.
      final t1 = await _turn(manager, text: 'continue');
      expect(t1.status, MemoryProfileSelectionStatus.inconclusive);
      expect(t1.profile, 'default');
      expect(selector.calls, 1);

      // Turn 2: inside the window → deferred, no selector call, still default.
      final t2 = await _turn(manager, text: 'and then', sessionId: 'sess-0');
      expect(t2.status, MemoryProfileSelectionStatus.deferred);
      expect(t2.profile, 'default');
      expect(selector.calls, 1);

      // Turn 3: window reached → re-run, now confident → re-pin.
      final t3 =
          await _turn(manager, text: 'office report', sessionId: 'sess-0');
      expect(t3.status, MemoryProfileSelectionStatus.repinned);
      expect(t3.profile, 'work');
      expect(t3.code, 'access.profile.repinned');
      expect(selector.calls, 2);
      expect(manager.peekMemoryProfile('sess-0'), 'work');
    });
  });

  group('graceful degrade (PE-6)', () {
    test('a selector failure degrades to default (selector.unavailable)',
        () async {
      final selector = _FakeSelector([null]); // throws
      final manager = SessionManager(
        sessionIdMinter: _counterMinter(),
        profileSelector: selector,
        selection: _enabled,
      );

      final outcome = await _turn(manager, text: 'hello');

      expect(outcome.status,
          MemoryProfileSelectionStatus.selectorUnavailable);
      expect(outcome.profile, 'default');
      expect(outcome.code, 'access.profile.selector.unavailable');
    });

    test('an unknown picked profile degrades to default (profile.unknown)',
        () async {
      final selector =
          _FakeSelector([_pick('nope', 0.95, isKnownProfile: false)]);
      final manager = SessionManager(
        sessionIdMinter: _counterMinter(),
        profileSelector: selector,
        selection: _enabled,
      );

      final outcome = await _turn(manager, text: 'hello');

      expect(outcome.status, MemoryProfileSelectionStatus.profileUnknown);
      expect(outcome.profile, 'default');
      expect(outcome.code, 'access.profile.unknown');
    });
  });

  group('history vs first-prompt-only input (Q-H.9)', () {
    test('useHistory: true feeds the full conversation history', () async {
      final selector = _FakeSelector([_pick('work', 0.9)]);
      final manager = SessionManager(
        sessionIdMinter: _counterMinter(),
        profileSelector: selector,
        selection: _enabled, // useHistory defaults to true
      );

      await _turn(manager, text: 'the prompt');

      expect(selector.prompts.single, 'the prompt');
      // The current turn is already on the answer-from history.
      expect(selector.histories.single, isNotEmpty);
      expect(selector.histories.single.last.userPrompt, 'the prompt');
    });

    test('useHistory: false feeds the prompt alone (empty history)', () async {
      final selector = _FakeSelector([_pick('work', 0.9)]);
      final manager = SessionManager(
        sessionIdMinter: _counterMinter(),
        profileSelector: selector,
        selection: const SelectionSettings(
          enabled: true,
          defaultProfile: 'default',
          inconclusiveThreshold: 0.5,
          useHistory: false,
        ),
      );

      await _turn(manager, text: 'the prompt');

      expect(selector.prompts.single, 'the prompt');
      expect(selector.histories.single, isEmpty);
    });
  });
}
