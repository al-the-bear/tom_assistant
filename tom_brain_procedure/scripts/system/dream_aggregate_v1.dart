/// @procedure
/// id: dream_aggregate_v1
/// version: 1
/// summary: Re-derive allowlisted semantic nodes from every source profile
///   into the reserved `global` profile (cross-profile aggregation).
/// successCriterion: The cross-profile aggregation pass runs once and returns
///   its summary (whether it ran, the source profiles scanned, and the node
///   scan/derive counts).
/// budget: { wallClockMs: 86400000, tokenSpend: 0, toolCalls: 0, memoryWrites: 1000000 }
/// inputs: []
/// outputs:
///   - { name: ran, type: bool }
///   - { name: sourceProfiles, type: List }
///   - { name: nodesScanned, type: int }
///   - { name: nodesDerived, type: int }
/// requires: [ aggregateProfilesIntoGlobal, note ]
//
// dream_aggregate_v1 — the global-aggregation cognitive agent (memory § 2.6,
// Phase 2; `tom_brain_completion_plan_2.md` item 1).
//
// This is the thinnest possible procedure: it triggers the single coarse
// `mem.aggregateProfilesIntoGlobal()` engine call and returns its summary. The
// entire cross-profile mechanic — enumerating source profiles, re-deriving
// every allowlisted semantic node, stamping provenance, and writing into the
// reserved `global` profile under the in-engine `aggregator` agent identity —
// lives below the primitive API in the memory engine. The procedure neither
// sees nor configures it.
//
// ── Why the procedure cannot write `global` itself (memory § 2.6, GA-8) ──
//
// A d4rt procedure cannot set `Scope.agentName`, so it can never carry the
// `aggregator` identity the live write path demands for a `profile:global`
// write. Any attempt this procedure made to `mem.persist` into `global`
// directly would be rejected with `GlobalProfileWriteForbidden`. The only
// sanctioned path into `global` is this single delegating primitive, which the
// engine runs under the registered `aggregator` agent on a transient `global`
// child store. That is the structural guarantee the global tier is authored
// solely by the aggregation pass.
//
// ── Off by default ──────────────────────────────────────────────────
//
// This agent only runs when a deployment wires an `aggregate` cadence lane that
// fires `dream_aggregate_v1` (the default `CadenceSchedule` has no such lane),
// AND the memory config enables aggregation (`aggregation.enabled: true`). With
// aggregation disabled the engine pass is a no-op that returns `ran: false`, so
// even a misconfigured lane mutates nothing.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  // The single coarse engine call. Everything about how the pass works is the
  // engine's concern; the procedure only triggers it and reports the summary.
  final summary = await mem.aggregateProfilesIntoGlobal();

  final ran = summary['ran'] == true;
  final sourceProfiles = summary['sourceProfiles'] is List
      ? summary['sourceProfiles'] as List
      : const <String>[];
  final nodesScanned =
      summary['nodesScanned'] is int ? summary['nodesScanned'] as int : 0;
  final nodesDerived =
      summary['nodesDerived'] is int ? summary['nodesDerived'] as int : 0;

  note('progress', {
    'agent': 'dream_aggregate_v1',
    'ran': ran,
    'sourceProfiles': sourceProfiles.length,
    'nodesDerived': nodesDerived,
  });

  return <String, Object?>{
    'ran': ran,
    'sourceProfiles': sourceProfiles,
    'nodesScanned': nodesScanned,
    'nodesDerived': nodesDerived,
  };
}
