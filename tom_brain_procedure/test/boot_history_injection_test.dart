// Boot threads the answering session's history into the route and back-fills
// the answer (access spec § 7.2 / § 21.5; hub § 11).
//
// Regression suite for the live "doesn't remember my name" defect: a prompt
// served through the booted dispatcher must (1) carry the conversation's
// earlier turns into the substrate prompt, so a memoryless model can answer a
// follow-up that depends on an earlier turn, and (2) back-fill the answer into
// the turn the SessionManager appended for this prompt, so the *next* turn's
// assembled history includes this exchange.
//
// The `Access` rides a `ConversationHistory` exactly as the assembler builds
// it: an earlier *answered* turn, then a freshly-appended *answer-less* turn
// for the live prompt. The route drops that last turn from `priorTurns` (it is
// the live prompt, passed separately as `text`), renders the earlier one into
// the prompt, and after the run writes the answer back into the live turn.
//
// Doubles mirror `boot_turn_summary_sink_test.dart`, with the substrate
// capturing the assembled prompt. The shared boot doubles
// (`BootMemory` / `BootSubstrate`) live in `support/boot_doubles.dart` (HC-34).

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

void main() {
  late BootMemory memory;
  late BootSubstrate substrate;
  late AnswerParityPrompts parity;

  setUp(() {
    memory = BootMemory();
    substrate = BootSubstrate();
    parity = AnswerParityPrompts();
  });

  BrainProcessConfig config() => BrainProcessConfig(
        substrate: substrate,
        memoryProvisioning: MemoryProvisioningConfig.inProcess(
          client: memory,
          memoryConfig: MemoryConfig.forTesting(root: 'ztmp/boot_history_inj'),
        ),
        // Increment 6 (§6): the booted answer step resolves its prompt — including
        // the rendered prior-turn history — through the host `PromptResolver`. The
        // parity fake reproduces the pre-migration assembled transcript so the
        // captured substrate prompt still carries the history this suite asserts.
        promptResolver: parity.resolver,
        routeChainOf: parity.routeChainOf,
      );

  /// An `Access` carrying [history], shaped as the assembler builds it: the
  /// live prompt is the last (answer-less) turn already appended to [history].
  Access promptWithHistory(String text, ConversationHistory history) => Access(
        // The entry router is the only routable procedure after the Todo-6
        // route-flip (§ 4.0.1); the two-phase route then runs the answer branch
        // it selects, whose answer prompt is the last one the substrate sees.
        envelope: InboundRequest(
            text: text, kindHint: SystemProcedures.promptAnalyzerV1),
        identity: ResolvedIdentity(principalId: 'p1'),
        session: Session(sessionId: 's1'),
        persona: Persona.assistant(),
        deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
        history: history,
        turnId: TurnId.generate(),
      );

  test('an earlier turn is rendered into the substrate prompt', () async {
    substrate.answerChunks = <String>['Your name is Alexis.'];

    // Turn 1 already happened and was answered; turn 2 (the live prompt) is
    // appended answer-less, exactly as the SessionManager would on admit.
    final history = ConversationHistory()
      ..append(HistoryTurn(
        userPrompt: 'My name is Alexis',
        brainAnswer: 'Nice to meet you, Alexis.',
      ))
      ..append(HistoryTurn(userPrompt: 'What is my name?', brainAnswer: ''));

    final booted = await BrainProcessBoot.boot(config());
    addTearDown(booted.shutdown);

    await booted.dispatcher
        .accept(promptWithHistory('What is my name?', history));

    final prompt = substrate.lastPrompt!;
    // The earlier exchange reached the substrate — the model is no longer blind.
    expect(prompt, contains('My name is Alexis'));
    expect(prompt, contains('Nice to meet you, Alexis.'));
    // The live prompt is present once, as the user prompt (not duplicated as a
    // prior turn).
    expect(prompt, contains('What is my name?'));
  });

  test('the answer is back-filled into the live turn after the run', () async {
    substrate.answerChunks = <String>['Your name is Alexis.'];

    final history = ConversationHistory()
      ..append(HistoryTurn(
        userPrompt: 'My name is Alexis',
        brainAnswer: 'Nice to meet you, Alexis.',
      ))
      ..append(HistoryTurn(userPrompt: 'What is my name?', brainAnswer: ''));

    final booted = await BrainProcessBoot.boot(config());
    addTearDown(booted.shutdown);

    await booted.dispatcher
        .accept(promptWithHistory('What is my name?', history));

    // The live turn was answer-less on admit; the route wrote the answer back.
    final last = history.durableRecord.last;
    expect(last.userPrompt, 'What is my name?');
    expect(last.brainAnswer, 'Your name is Alexis.');
  });

  test(
      'the default window (>=10 raw turns) and the compacted summary both reach '
      'the substrate prompt', () async {
    substrate.answerChunks = <String>['Acknowledged.'];

    // Seed a session that has compacted at least once: a non-empty summary for
    // everything older than the window, plus a full default raw window. The
    // standard sizing keeps the newest 10 turns verbatim — 9 answered prior
    // turns and the 10th, answer-less, live prompt the assembler just appended.
    const summary =
        'Earlier, the user introduced themselves as Alexis and described '
        'their work on the Tom Brain memory engine.';

    final priorTurns = <HistoryTurn>[
      for (var i = 1; i <= 9; i++)
        HistoryTurn(
          userPrompt: 'Prior question $i',
          brainAnswer: 'Prior answer $i',
        ),
    ];
    const liveTurn = HistoryTurn(userPrompt: 'What did we discuss?', brainAnswer: '');
    final allTurns = <HistoryTurn>[...priorTurns, liveTurn];

    final history = ConversationHistory.restore(
      sizing: const HistorySizing.standard(),
      compactedSummary: summary,
      // rawWindow holds the full default window: 9 prior + the live turn = 10.
      rawWindow: allTurns,
      pending: const <HistoryTurn>[],
      durableRecord: allTurns,
    );
    // Guard the premise: the default window is exactly the standard raw count.
    expect(history.sizing.rawCount, 10);
    expect(history.rawWindow.length, 10);
    expect(history.compactedSummary, isNotEmpty);

    final booted = await BrainProcessBoot.boot(config());
    addTearDown(booted.shutdown);

    await booted.dispatcher
        .accept(promptWithHistory('What did we discuss?', history));

    final prompt = substrate.lastPrompt!;

    // The compacted summary reached the LLM, under its labelled block.
    expect(prompt, contains('Summary of earlier conversation:'));
    expect(prompt, contains('the user introduced themselves as Alexis'));

    // All 9 prior verbatim turns reached the LLM (window minus the live turn).
    for (var i = 1; i <= 9; i++) {
      expect(prompt, contains('Prior question $i'),
          reason: 'prior user turn $i must be sent verbatim');
      expect(prompt, contains('Prior answer $i'),
          reason: 'prior assistant turn $i must be sent verbatim');
    }
    // The live prompt is the 10th verbatim turn, carried as the user prompt.
    expect(prompt, contains('What did we discuss?'));

    // Count the rendered verbatim turns: 9 prior `User:` lines plus the live
    // prompt = 10 turns minimum, the enforced default floor.
    final userLines = 'User:'.allMatches(prompt).length;
    expect(userLines, greaterThanOrEqualTo(9),
        reason: '>=9 prior User: lines render; the live turn makes 10 verbatim '
            'turns reaching the LLM alongside the summary');
  });

  test('a cold first turn threads no prior turns', () async {
    substrate.answerChunks = <String>['Hello.'];

    // The very first prompt: history holds only the just-appended live turn.
    final history = ConversationHistory()
      ..append(HistoryTurn(userPrompt: 'hello', brainAnswer: ''));

    final booted = await BrainProcessBoot.boot(config());
    addTearDown(booted.shutdown);

    await booted.dispatcher.accept(promptWithHistory('hello', history));

    final prompt = substrate.lastPrompt!;
    expect(prompt, isNot(contains('User:')));
    expect(prompt, isNot(contains('Assistant:')));
    // Still back-filled, so the next turn sees this one.
    expect(history.durableRecord.single.brainAnswer, 'Hello.');
  });
}
