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

  group('D.36 the budget caps are the real per-run ceilings', () {
    test('all four enforced dimensions carry the § 4.4 caps', () async {
      final resolver = await systemResolver();
      final budget = resolver.resolve('answer_with_memory_v1').header.budget;
      expect(budget.wallClockMs, 60000);
      expect(budget.tokenSpend, 8000);
      expect(budget.toolCalls, 12);
      expect(budget.memoryWrites, 6);
    });
  });
}
