// End-to-end regression for the "didn't remember my name after a restart"
// defect on the Telegram channel (access spec § 6.5 / § 7.2 / § 21.10; umbrella
// Hard principle 6).
//
// This pins the *whole* continuity chain a Telegram turn depends on, across a
// simulated process restart, at the unit level — the test that would have
// caught the live failure:
//
//   1. The TelegramSessionRegistry maps the user to a persisted `default`
//      session id and adopts it into the SessionManager (so resolve treats it
//      as a known dedicated session).
//   2. The SessionManager records the turn against that dedicated history and
//      its answer is back-filled (engine seam) + mirrored to the global record.
//   3. The histories persist; on "restart" (fresh registry + manager over the
//      same backing stores) the registry re-adopts the SAME id and the manager
//      rehydrates the dedicated history — so the next turn resolves to the
//      conversation that already knows the user's name.
//
// Both halves had to be right: the registry must re-mint nothing (session id
// stable across restart) AND the manager must rehydrate the dedicated history
// with the prior answer in it. Either one missing and the brain "forgets".

import 'package:tom_brain_access/tom_brain_access.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

ResolvedIdentity _identity(String principalId) =>
    ResolvedIdentity(principalId: principalId);

/// One Telegram turn, exactly as the edge + assembler drive it: resolve the
/// user's active session (registry, adopting into the manager), stamp the id,
/// resolve against the manager, back-fill the engine's answer, mirror it to the
/// global record, and persist. Returns the answered-from history.
ConversationHistory _telegramTurn({
  required TelegramSessionRegistry registry,
  required SessionManager manager,
  required String userId,
  required String principalId,
  required String prompt,
  required String answer,
}) {
  final TelegramActiveSession active = registry.resolveActive(userId);
  final SessionResolution res = manager.resolve(
    identity: _identity(principalId),
    channel: AccessChannel.telegram,
    envelope: InboundRequest(text: prompt, sessionId: active.sessionId),
  );
  // Engine back-fills the answer into the answered-from history (the dispatcher
  // seam), then access mirrors it to the global record and persists.
  res.history.amendLastTurnAnswer(answer);
  manager.backfillGlobalAnswer(
    identity: _identity(principalId),
    channel: AccessChannel.telegram,
    resolution: res,
  );
  manager.persist();
  return res.history;
}

void main() {
  test(
      'a Telegram user is still remembered after a restart (session id stable, '
      'history rehydrated)', () {
    const userId = '424242';
    const principalId = 'owner';

    // Shared durable backings — the on-disk stores in production. A "restart" is
    // a fresh registry + manager over the SAME backing store, exactly what a
    // file-backed deployment sees on reboot.
    final edgeStore = MapEdgeStateStore();
    final historyStore = MapHistoryStore();

    // ── Run 1 ──────────────────────────────────────────────────────────
    final manager1 = SessionManager(historyStore: historyStore);
    final registry1 = TelegramSessionRegistry(
      store: edgeStore,
      adoptSession: manager1.ensureSession,
    );

    _telegramTurn(
      registry: registry1,
      manager: manager1,
      userId: userId,
      principalId: principalId,
      prompt: 'My name is Alexis.',
      answer: 'Nice to meet you, Alexis!',
    );

    // ── Restart: fresh registry + manager over the same stores ─────────
    final manager2 = SessionManager(historyStore: historyStore);
    final registry2 = TelegramSessionRegistry(
      store: edgeStore,
      // Re-adoption must not mint a new id: the persisted default id is reused.
      mintSessionId: () => fail('a restart must not mint a fresh session id'),
      adoptSession: manager2.ensureSession,
    );

    final ConversationHistory answeredFrom = _telegramTurn(
      registry: registry2,
      manager: manager2,
      userId: userId,
      principalId: principalId,
      prompt: 'What is my name?',
      answer: 'Your name is Alexis.',
    );

    // The second turn answered from the SAME dedicated session, which still
    // holds the first turn — so the brain has the name in context.
    final prompts = [for (final t in answeredFrom.durableRecord) t.userPrompt];
    expect(prompts, ['My name is Alexis.', 'What is my name?']);
    expect(answeredFrom.durableRecord.first.brainAnswer, 'Nice to meet you, Alexis!');

    // And the global "all prompts" record carries every answer (bug #1).
    final global = manager2.peekGlobal(
        principalId: principalId, channel: AccessChannel.telegram);
    final globalAnswers = [for (final t in global!.durableRecord) t.brainAnswer];
    expect(globalAnswers, ['Nice to meet you, Alexis!', 'Your name is Alexis.']);
  });
}
