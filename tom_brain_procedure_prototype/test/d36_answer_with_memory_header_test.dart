// D.36 — `answer_with_memory_v1` structured header.
//
// Plan step D.36 (verbatim): "Author `scripts/system/answer_with_memory_v1.dart`
// with the structured header: id: `answer_with_memory_v1`; version: 1;
// summary, success criterion, budget caps."
//
// D.8 shipped the file as a no-op stub whose header spoke stub-language
// ("No-op answer-with-memory stub"). D.36 promotes that header to the real
// procedure's contract per `tom_brain_procedure_prototype_specification.md`
// § 4.4 / § 11: the summary and success criterion now describe the
// recall → answer → persist loop, and the budget caps are the real per-run
// ceilings. The body that *fulfils* this contract is built across the
// following substeps (D.37–D.42) and stays a no-op stub for now; this suite
// therefore pins only what D.36 delivers — the header — read off the shipped
// disk artifact via the same store + resolver path the dispatcher uses.
//
// The machine-validated header fields (inputs/outputs/`requires`/signature)
// deliberately still track the no-op body, not the summary; they flip with
// the substep that introduces the behaviour they describe (see the header's
// own notes). D.36's contract is the human-readable contract fields plus the
// budget caps, so that is what this suite asserts.

import 'dart:io';

import 'package:test/test.dart';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';

void main() {
  /// Builds a resolver over the real `scripts/system/` directory — the same
  /// store + resolver path the dispatcher uses, so the test exercises the
  /// shipped artifact rather than an inline copy.
  Future<ProcedureResolver> systemResolver() async {
    final store = DiskProcedureStore(systemDir: Directory('scripts/system'));
    return ProcedureResolver.fromStore(store);
  }

  group('D.36 the structured header identifies the v1 procedure', () {
    test('id is answer_with_memory_v1 and version is 1', () async {
      final resolver = await systemResolver();
      final header = resolver.resolve('answer_with_memory_v1').header;
      expect(header.id, 'answer_with_memory_v1');
      expect(header.version, 1);
    });
  });

  group('D.36 the summary + success criterion describe the real procedure',
      () {
    test('summary describes the recall → answer → persist loop', () async {
      final resolver = await systemResolver();
      final summary = resolver.resolve('answer_with_memory_v1').header.summary;
      // Per § 4.4: "Recall relevant memory, answer the user, persist the
      // exchange." The three acts of the loop must be named.
      expect(summary.toLowerCase(), contains('recall'));
      expect(summary.toLowerCase(), contains('answer'));
      expect(summary.toLowerCase(), contains('persist'));
      // It is no longer the D.8 no-op stub language.
      expect(summary.toLowerCase(), isNot(contains('no-op')));
      expect(summary.toLowerCase(), isNot(contains('stub')));
    });

    test('success criterion names the streamed answer and the persisted nodes',
        () async {
      final resolver = await systemResolver();
      final criterion =
          resolver.resolve('answer_with_memory_v1').header.successCriterion;
      // Per § 4.4: "A streamed answer is delivered and an Event + Conclusion
      // + edges are persisted."
      final lower = criterion.toLowerCase();
      expect(lower, contains('stream'));
      expect(criterion, contains('Event'));
      expect(criterion, contains('Conclusion'));
      expect(lower, contains('edge'));
    });
  });

  group('D.36 the budget is a wall-clock deadline only (§ 5.4)', () {
    test('the user-facing answer budget caps wall-clock and nothing else',
        () async {
      final resolver = await systemResolver();
      final budget = resolver.resolve('answer_with_memory_v1').header.budget;
      // The only declared cap is the wall-clock deadline: the user-facing
      // answer budget is "virtually unlimited" on every count dimension.
      // 14400000 ms (240 min) is the spec's documented external default
      // (§ 5.4) — a runaway-stop for a genuinely hung run, not a throttle.
      expect(budget.wallClockMs, 14400000);
      // The count dimensions are intentionally unlimited (null). A fatal
      // `memoryWrites` cap (formerly 16) closed the "who are you" run
      // `budgetExceeded` with no answer once the `derived_from` edge loop
      // outran it — silent on buffered Telegram. The non-fatal per-run
      // `MemoryWriteGuard` (§ 5.4) now backstops a runaway write loop: it
      // skips+notes the offending write and lets the already-produced answer
      // through, so the count caps no longer belong on this procedure.
      expect(budget.tokenSpend, isNull);
      expect(budget.toolCalls, isNull);
      expect(budget.memoryWrites, isNull);
    });
  });
}
