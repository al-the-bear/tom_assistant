// Provider-independence of the assembled history (history-compaction plan
// todo #18; access spec § 7.2 / hub § 22.5 / § 22.7).
//
// The conversation history a prompt carries — the compacted summary, the
// verbatim raw window, and the compaction that produced them — is assembled on
// *our* side, in the dispatcher + prompt resolver, **before** and
// **independent of** which provider answers. Two run-layer concerns vary the
// provider without ever touching prompt assembly:
//
//   • the prompt's `llm:` **route** — `assistant_claude_brain` (Claude,
//     session-threaded) for the user-facing answer, the local `assistant`
//     (omlx/Ollama gemma) route for everything else. The route only selects the
//     `RouteEntry` chain `sub.send` dispatches over; the rendered prompt is
//     identical regardless.
//   • the Claude substrate's **`sessionMode`** (none / brain / quest) — it
//     controls Claude-Code session *persistence* (keyed off the turn context),
//     never the prompt text.
//
// This test pins that invariant: one fixed `ConversationHistory` (a full default
// raw window plus a non-empty compacted summary) is run through the booted
// dispatcher across a parametrised matrix of (route × sessionMode), and the
// history injected into the captured substrate prompt is asserted byte-identical
// across every combination. The matrix genuinely varies both dimensions — the
// dispatched route names and the substrate session modes are recorded and
// asserted to span Claude↔local and none/brain/quest — so the identity result is
// not a tautology: only the injected history stays constant while the provider
// configuration changes underneath it.
//
// The doubles mirror `boot_history_injection_test.dart`; the shared boot doubles
// now live in `support/boot_doubles.dart` (HC-34). `BootSubstrate` records the
// `sessionMode` it was opened under, modelling how the real substrate takes the
// mode at construction and never feeds it into the prompt.

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart' show MemoryConfig;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
        ConversationHistory,
        HistorySizing,
        HistoryTurn,
        InboundRequest,
        OutboundChunk,
        Persona,
        ResolvedIdentity,
        Session,
        TurnId;

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

import 'answer_parity_prompts.dart';
import 'support/boot_doubles.dart';

/// One (route, sessionMode) point in the provider matrix.
typedef _Combo = ({String route, String sessionMode});

void main() {
  // The provider matrix: Claude across all three session modes, plus the local
  // gemma/Ollama route. The user-facing answer pins to `assistant_claude_brain`
  // in the committed config; the local `assistant` route is the cheap default
  // every sub-judgement runs on (`config/bomber/cognition/assist_user.yaml`).
  const matrix = <_Combo>[
    (route: 'assistant_claude_brain', sessionMode: 'none'),
    (route: 'assistant_claude_brain', sessionMode: 'brain'),
    (route: 'assistant_claude_brain', sessionMode: 'quest'),
    (route: 'assistant', sessionMode: 'none'),
  ];

  /// The fixed conversation the matrix shares: a session that has compacted at
  /// least once — a non-empty summary for everything older than the window, plus
  /// a full default raw window (9 answered prior turns + the answer-less live
  /// prompt = the standard raw count of 10).
  ConversationHistory historyFixture() {
    const summary =
        'Earlier, the user introduced themselves as Alexis and described their '
        'work on the Tom Brain memory engine.';
    final priorTurns = <HistoryTurn>[
      for (var i = 1; i <= 9; i++)
        HistoryTurn(
          userPrompt: 'Prior question $i',
          brainAnswer: 'Prior answer $i',
        ),
    ];
    const liveTurn =
        HistoryTurn(userPrompt: 'What did we discuss?', brainAnswer: '');
    final allTurns = <HistoryTurn>[...priorTurns, liveTurn];
    return ConversationHistory.restore(
      sizing: const HistorySizing.standard(),
      compactedSummary: summary,
      rawWindow: allTurns,
      pending: const <HistoryTurn>[],
      durableRecord: allTurns,
    );
  }

  /// An `Access` carrying [history], shaped as the assembler builds it: the live
  /// prompt is the last (answer-less) turn already appended to [history].
  Access promptWithHistory(String text, ConversationHistory history) => Access(
        envelope: InboundRequest(
            text: text, kindHint: SystemProcedures.promptAnalyzerV1),
        identity: ResolvedIdentity(principalId: 'p1'),
        session: Session(sessionId: 's1'),
        persona: Persona.assistant(),
        deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
        history: history,
        turnId: TurnId.generate(),
      );

  /// Runs [matrix] through the booted dispatcher and captures, per combo, the
  /// assembled substrate prompt plus the route/sessionMode the run actually used.
  test(
      'the injected history is byte-identical across every (route × sessionMode) '
      'combination — assembled on our side, never by the provider', () async {
    final capturedPrompts = <String>[];
    final dispatchedRoutes = <String>{};
    final openedSessionModes = <String>{};

    for (final combo in matrix) {
      final memory = BootMemory();
      final substrate = BootSubstrate(sessionMode: combo.sessionMode);
      final parity = AnswerParityPrompts()..route = combo.route;

      final config = BrainProcessConfig(
        substrate: substrate,
        memoryProvisioning: MemoryProvisioningConfig.inProcess(
          client: memory,
          memoryConfig:
              MemoryConfig.forTesting(root: 'ztmp/history_provider_indep'),
        ),
        promptResolver: parity.resolver,
        // Record the route name `sub.send` dispatched over so the matrix proves
        // it genuinely crossed Claude↔local — then delegate to the parity chain
        // (empty; the substrate double answers regardless).
        routeChainOf: (routeName) {
          dispatchedRoutes.add(routeName);
          return parity.routeChainOf(routeName);
        },
      );

      final booted = await BrainProcessBoot.boot(config);
      addTearDown(booted.shutdown);

      await booted.dispatcher
          .accept(promptWithHistory('What did we discuss?', historyFixture()));

      capturedPrompts.add(substrate.lastPrompt!);
      openedSessionModes.add(substrate.answeredUnderSessionMode!);
    }

    // The matrix genuinely varied the provider configuration: both routes were
    // dispatched, and all three Claude session modes were opened. Without this
    // the identity assertion below would be a tautology over a constant input.
    expect(dispatchedRoutes, containsAll(<String>['assistant_claude_brain', 'assistant']),
        reason: 'the matrix must cross the Claude route and the local route');
    expect(openedSessionModes, containsAll(<String>['none', 'brain', 'quest']),
        reason: 'the matrix must cross all three Claude session modes');

    // Premise guard: the assembled prompt carries a real, non-trivial history —
    // the compacted summary and the full verbatim window — so "identical" is a
    // statement about substantive content, not an empty block.
    final first = capturedPrompts.first;
    expect(first, contains('Summary of earlier conversation:'));
    expect(first, contains('the user introduced themselves as Alexis'));
    expect(first, contains('Conversation so far:'));
    for (var i = 1; i <= 9; i++) {
      expect(first, contains('Prior question $i'));
      expect(first, contains('Prior answer $i'));
    }

    // The injected history segment — the labelled summary block plus the
    // verbatim turns, up to the live `User prompt:` — is byte-identical across
    // every combination.
    final firstHistory = _historySegment(first);
    for (var i = 1; i < capturedPrompts.length; i++) {
      expect(_historySegment(capturedPrompts[i]), firstHistory,
          reason: 'the injected history must not depend on '
              '${matrix[i].route}/${matrix[i].sessionMode}');
    }

    // Stronger lock: nothing else in the assembled prompt varies with the
    // provider either — the whole captured prompt is byte-identical.
    for (var i = 1; i < capturedPrompts.length; i++) {
      expect(capturedPrompts[i], first,
          reason: 'the whole assembled prompt is provider-blind');
    }
  });
}

/// Extracts the assembled `${history}` segment from a captured prompt: the
/// labelled summary block + the verbatim turns, ending where the live
/// `User prompt:` block begins (the recall fixture is empty, so the history runs
/// directly into the user prompt).
String _historySegment(String prompt) {
  final start = prompt.indexOf('Summary of earlier conversation:');
  final end = prompt.indexOf('User prompt:');
  if (start < 0 || end < 0 || end < start) {
    throw StateError('captured prompt has no recognisable history segment:\n'
        '$prompt');
  }
  return prompt.substring(start, end);
}
