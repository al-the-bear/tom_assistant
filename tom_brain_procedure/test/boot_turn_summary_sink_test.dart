// Boot threads the turn-summary sink to the dispatch route
// (`tom_brain_logging.md` §5.4 / §5.5 / §10 step #5 — the boot half of the seam).
//
// `BrainProcessConfig.turnSummarySink` is the production seam the `SummaryFanout`
// binds onto for its per-turn §5.4 / §5.5 narrative blocks. The user prompt and
// the final answer are not on any `LlmTrailRecord` — they are only known at the
// dispatch edge — so the route emits one [TurnSummary] when a turn completes.
// This suite proves boot threads that sink through `_buildRoute`, so a prompt
// served through the booted dispatcher fires exactly one [TurnSummary] carrying
// the turn's id, session, principal, persona, prompt, and final answer. A boot
// with no sink stays silent.
//
// Doubles mirror `boot_llm_trail_sink_test.dart` (in-process memory + answering
// substrate). The turn summary is emitted once per dispatch route (the route's
// `finally`), so the two-phase route-flip (router classification + answer
// branch, § 4.0.1) still fires exactly one [TurnSummary] per accepted turn.
// The shared boot doubles (`BootMemory` / `BootSubstrate`) live in
// `support/boot_doubles.dart` (HC-34); `BootSubstrate(emitWire: true)` carries a
// `CapturedWirePrompt` on completion as this suite's answering substrate did.

import 'package:test/test.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart' show MemoryConfig;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show
        Access,
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
    substrate = BootSubstrate(emitWire: true);
    parity = AnswerParityPrompts();
  });

  BrainProcessConfig configWith({TurnSummarySink? turnSummarySink}) =>
      BrainProcessConfig(
        substrate: substrate,
        memoryProvisioning: MemoryProvisioningConfig.inProcess(
          client: memory,
          memoryConfig: MemoryConfig.forTesting(root: 'ztmp/boot_turn_sink'),
        ),
        turnSummarySink: turnSummarySink,
        // Increment 6 (§6): the booted answer step resolves its prompt through
        // the host `PromptResolver`; the parity fake supplies the assembled
        // prompt so the turn runs to completion and the summary sink fires.
        promptResolver: parity.resolver,
        routeChainOf: parity.routeChainOf,
      );

  Access userPrompt(String text, {TurnId? turnId}) => Access(
        envelope: InboundRequest(
            text: text, kindHint: SystemProcedures.promptAnalyzerV1),
        identity: ResolvedIdentity(principalId: 'p1'),
        session: Session(sessionId: 's1'),
        persona: Persona.assistant(),
        deliver: (chunk) => Stream<OutboundChunk>.value(chunk),
        turnId: turnId,
      );

  group('boot threads the turnSummarySink onto the route (§10 step #5)', () {
    test('a completed turn fires one summary carrying prompt + final answer',
        () async {
      substrate.answerChunks = <String>['an answer'];
      final summaries = <TurnSummary>[];
      final turnId = TurnId.generate();

      final booted = await BrainProcessBoot.boot(
          configWith(turnSummarySink: summaries.add));
      addTearDown(booted.shutdown);

      await booted.dispatcher
          .accept(userPrompt('what is a quasar?', turnId: turnId));

      expect(summaries, hasLength(1),
          reason: 'one completed turn fires exactly one turn summary');
      final summary = summaries.single;
      expect(summary.turnId, turnId.value);
      expect(summary.sessionId, 's1');
      expect(summary.principalId, 'p1');
      expect(summary.persona, Persona.assistant().personaId);
      expect(summary.userPrompt, 'what is a quasar?');
      expect(summary.finalAnswer, 'an answer',
          reason: 'the answer the run produced rides onto the summary');
    });

    test('a turn with no turnId fires no summary (nothing to key a block on)',
        () async {
      substrate.answerChunks = <String>['an answer'];
      final summaries = <TurnSummary>[];

      final booted = await BrainProcessBoot.boot(
          configWith(turnSummarySink: summaries.add));
      addTearDown(booted.shutdown);

      await booted.dispatcher.accept(userPrompt('what is a quasar?'));

      expect(summaries, isEmpty,
          reason: 'no turnId → no §5.4 / §5.5 block can be keyed');
    });

    test('with no sink bound boot wires no emitter and stays silent', () async {
      substrate.answerChunks = <String>['an answer'];
      final booted = await BrainProcessBoot.boot(configWith());
      addTearDown(booted.shutdown);

      // The run still completes — the sink is purely observational. The
      // exchange was persisted (cold path), proving the run actually ran.
      await booted.dispatcher
          .accept(userPrompt('what is a quasar?', turnId: TurnId.generate()));
      expect(
          memory
              .persistedOfType('Conclusion')
              .single
              .draft
              .values['statement'],
          'an answer');
    });
  });
}
