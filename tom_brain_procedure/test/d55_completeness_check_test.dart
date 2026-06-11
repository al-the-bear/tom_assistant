// D.55 — Phase-D completeness check (the per-invariant sentinel).
//
// Plan step D.55 ("Completeness check: per-invariant table; explicitly tick
// definition § 14 invariants 1, 3, 4, 7, 8, 10 — those the dispatcher must
// guarantee in the prototype").
//
// The narrative deliverable is `phase_d_completeness_coverage.md` (the
// per-invariant coverage matrix, the Phase-D counterpart of
// `phase_c_completeness_coverage.md`). This suite is the *sentinel* that
// pins, as code, the six `tom_brain_definition.md` § 14 invariants the
// dispatcher half is responsible for. Each invariant has richer
// behavioural coverage in its own step's suite (routing → D.16/D.51,
// run-as-memory-object → D.26/D.27/D.28, single-fg/bg → D.18/D.22, fallback
// floor → D.29/D.32, config forward-only → D.47); no single test crosses
// all six into one "does the dispatcher still uphold the hard invariants?"
// attestation. If a future change re-routes `user_prompt`, renames a run
// stack, alters the queue-depth default, adds a second run slot, lets a v1
// fallback step below the floor, or breaks config round-trip identity, this
// suite fails with a message that names the § 14 invariant.
//
// Drives the package's public barrel + the shared barrel only (no
// `lib/src/` imports), per the plan's "API tests" convention — the same
// posture as the D.51 attestation sentinel.

import 'package:test/test.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show InboundKinds;

final DateTime _at = DateTime.utc(2026, 6, 2, 10, 30, 0);

void main() {
  // ── def § 14.1 — No backwards compatibility ──────────────────────────
  //
  // The dispatcher half ships forward-only. Its observable schema surface
  // is `DispatcherConfig`: there is no version-upgrade path and no compat
  // shim — `toYamlString → fromYamlString` is identity, so a config can
  // only ever be read in its current shape. (The D.19 migration that
  // replaced the busy-foreground `RunSlotBusy` rejection with the
  // `ForegroundQueueFull` backpressure signal kept *no* old-behaviour shim;
  // both symbols survive but name distinct, non-overlapping conditions.)
  group('def §14.1 — no backwards compatibility (forward-only config)', () {
    test('DispatcherConfig round-trips identically (no compat path)', () {
      final cfg = DispatcherConfig(
        foregroundQueueDepth: 2,
        hardStepDeadline: const Duration(seconds: 30),
        schedulerEnabled: true,
      );
      expect(DispatcherConfig.fromYamlString(cfg.toYamlString()), cfg);
    });

    test('a defaults config also round-trips identically', () {
      final cfg = DispatcherConfig();
      expect(DispatcherConfig.fromYamlString(cfg.toYamlString()), cfg);
    });

    test('foreground overflow and background double-submit are distinct types',
        () {
      // The migrated overflow signal (ForegroundQueueFull) does not collapse
      // into the legacy busy-slot signal (RunSlotBusy): no shim aliases them.
      expect(ForegroundQueueFull, isNot(equals(RunSlotBusy)));
    });
  });

  // ── def § 14.3 — The process owns the result ─────────────────────────
  //
  // Every inbound is answered by a *procedure*, never by a raw model call
  // the dispatcher makes itself. The single routing entry maps a kind to a
  // procedure id; an unrouted kind is rejected loudly rather than passed
  // through to a model. There is no model-passthrough branch in the
  // dispatcher's selection surface.
  group('def §14.3 — the process owns the result (procedure, not passthrough)',
      () {
    test('routing targets a procedure id, never a model', () {
      // After the § 4.0.1 route-flip the kind maps to the entry router
      // procedure id — still a procedure, never a raw model call.
      expect(defaultProcedureRouting,
          <String, String>{'user_prompt': 'prompt_analyzer_v1'});
      expect(ProcedureSelector().select(InboundKinds.userPrompt),
          SystemProcedures.promptAnalyzerV1);
    });

    test('an unrouted kind is rejected loudly (no silent model passthrough)',
        () {
      expect(() => ProcedureSelector().select('raw_completion'),
          throwsA(isA<UnsupportedProcedureKind>()));
    });
  });

  // ── def § 14.4 — Memory is co-author ─────────────────────────────────
  //
  // Every run is a first-class memory object: the dispatcher pushes a
  // `ProcedureRun` marker onto `inflight` at start and onto `recent_runs`
  // at end. The run's trail + the recalled memory contents jointly author
  // the answer (the behavioural proof is D.26/D.27/D.28 + D.37/D.39/D.54);
  // this sentinel pins the stack + node-type vocabulary that makes a run
  // observable in memory.
  group('def §14.4 — memory is co-author (every run is a memory object)', () {
    test('the run stacks and node type carry their canonical names', () {
      expect(inflightStackName, 'inflight');
      expect(recentRunsStackName, 'recent_runs');
      expect(procedureRunNodeType, 'ProcedureRun');
    });

    test('the inflight and recent_runs stacks are distinct', () {
      expect(inflightStackName, isNot(equals(recentRunsStackName)));
    });
  });

  // ── def § 14.7 — The primitive API is the only surface for procedures ─
  //
  // The dispatcher addresses procedures *by id* and hands the id to the
  // engine, which runs the body inside the two-layer d4rt sandbox — the
  // dispatcher never executes procedure code itself nor injects a
  // non-bridged surface. The load-bearing sandbox proof is Phase C
  // (`c50_d4rt_sandbox_proof_test.dart`, PE-1); the dispatcher's duty is
  // only to route by id, which this pins.
  group('def §14.7 — primitive API is the only surface (route by id)', () {
    test('the routing target is a procedure-id string, not executable code',
        () {
      final target = ProcedureSelector().select(InboundKinds.userPrompt);
      expect(target, isA<String>());
      expect(target, SystemProcedures.promptAnalyzerV1);
    });
  });

  // ── def § 14.8 — System procedure v1 is permanent ────────────────────
  //
  // `answer_with_memory_v1` is the well-known floor branch the entry router
  // selects for a normal prompt, and the fallback chain can never step below
  // it: a fallback-class failure on v1 *surfaces* (toVersion == null), it does
  // not demote v1. After the § 4.0.1 route-flip a `user_prompt` routes to the
  // entry router `prompt_analyzer_v1`, whose two-phase run selects this floor
  // branch. The behavioural proof is D.29/D.32 (v1-only chain surfaces); this
  // pins that the floor's fallback event surfaces rather than stepping down.
  group('def §14.8 — system procedure v1 is permanent', () {
    test('every user_prompt routes to the entry router, which selects the v1 '
        'floor branch', () {
      expect(SystemProcedures.answerWithMemoryV1, 'answer_with_memory_v1');
      expect(ProcedureSelector().select(InboundKinds.userPrompt),
          SystemProcedures.promptAnalyzerV1);
    });

    test('a fallback on v1 surfaces — it is never stepped below', () {
      final floor = FallbackTried(
        occurredAt: _at,
        procedureId: SystemProcedures.answerWithMemoryV1,
        fromVersion: 1,
        toVersion: null,
        trigger: FallbackTrigger.runtimeCrash,
      );
      expect(floor.toVersion, isNull);
      expect(floor.surfaced, isTrue,
          reason: 'v1 is the floor: a fallback on it surfaces, never demotes');
    });
  });

  // ── def § 14.10 — Single foreground, single background ────────────────
  //
  // Exactly two run slots; a single foreground (depth-4 FIFO queue behind
  // it) and a single background. The behavioural proof is D.18/D.19/D.22
  // (one fg / one bg, queue overflow at depth); this pins the two-slot
  // closed set and the config↔runtime depth agreement.
  group('def §14.10 — single foreground, single background', () {
    test('there are exactly two run slots: foreground and background', () {
      expect(RunSlot.values, <RunSlot>[RunSlot.foreground, RunSlot.background]);
    });

    test('the foreground FIFO depth default agrees across config and runtime',
        () {
      expect(defaultForegroundQueueDepth, 1000000);
      expect(DispatcherConfig().foregroundQueueDepth, 1000000);
      expect(RunCoordinator().foregroundQueueDepth, 1000000);
    });
  });
}
