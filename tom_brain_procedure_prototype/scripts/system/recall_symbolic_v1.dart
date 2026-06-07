/// @procedure
/// id: recall_symbolic_v1
/// version: 1
/// summary: Build symbolic recall seeds (type / time / scope / attr filters)
///   for the retrieval conductor — the always-available non-LLM strategy.
/// successCriterion: Returns a `seeds` list of symbolic `RecallSeed` maps the
///   conductor merges into `recall.multi`; never calls the substrate, so it
///   survives an LLM outage (PE-6).
/// budget: { wallClockMs: 5000, tokenSpend: 0, toolCalls: 0, memoryWrites: 0 }
/// inputs:
///   - { name: text, type: String, required: true }
/// outputs:
///   - { name: seeds, type: List }
/// requires: []
//
// recall_symbolic_v1 — the symbolic leg of the four-strategy retrieval set
// (`tom_brain_procedure_prototype_specification.md` § 23.2; plan Extension-H
// step #30).
//
// This is the cheapest, most robust strategy: it consults no model and issues
// no memory read — it only *assembles* symbolic seeds the conductor's fused
// `mem.recallMulti` then runs. Because it touches no substrate, it is the one
// strategy guaranteed to contribute even under a total LLM outage (PE-6).
//
// The prototype seed is a type filter over the high-signal node types a prompt
// most often wants back (`Conclusion`, `Claim`, `Event`). Time / scope / attr
// filters (the other shapes § 23.2 lists) need structured request metadata the
// bare-text prototype invocation does not carry yet; they are added when the
// access envelope threads scope/time hints into the conductor. The seed shape
// is the `MemoryBridge.recallMulti` seed-map contract: a `mode` plus a
// `filter` of `typeNames` / `attributes`.
import 'package:tom_brain_procedure_prototype/src/api/procedure_inputs.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  // A deterministic type-filter symbolic seed over the high-signal node types.
  // No substrate, no memory read — pure assembly, so it survives an LLM outage.
  final seeds = <Object?>[
    <String, Object?>{
      'mode': 'symbolic',
      'filter': <String, Object?>{
        'typeNames': <String>['Conclusion', 'Claim', 'Event'],
      },
      'weight': 0.5,
    },
  ];
  return <String, Object?>{'seeds': seeds};
}
