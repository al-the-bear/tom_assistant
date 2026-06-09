/// @procedure
/// id: recall_semantic_v1
/// version: 1
/// summary: Build semantic recall seeds — the LLM-free concept-centroid
///   classify cheap path, falling back to the `category_selector` role when
///   the classification is not usable.
/// successCriterion: A confident/uncertain concept classification seeds a
///   symbolic recall on the nearest Concept name (no LLM); only an unknown
///   (or match-less) classification escalates to the `category_selector` role;
///   degrades to an empty list when that role result is unusable (PE-6).
/// budget: { wallClockMs: 30000, tokenSpend: 2000, toolCalls: 3, memoryWrites: 0 }
/// inputs:
///   - { name: text, type: String, required: true }
/// outputs:
///   - { name: seeds, type: List }
/// requires: [ embed, classify, retrievalRole ]
//
// recall_semantic_v1 — the semantic leg of the four-strategy retrieval set
// (`tom_brain_procedure_specification.md` § 23.2; plan Extension-H
// step #30).
//
// It seeds recall from the prompt's *meaning*. The cheap path is LLM-free: it
// embeds the prompt once (`sub.embed`) and classifies that vector against the
// per-Concept centroids (`mem.classify(target: 'concept')`, memory § 7.1).
// When the classifier is confident (or uncertain but with a best match), it
// names the nearest Concept — and the seed is a symbolic filter on that
// Concept's `name`.
//
// ── Why a symbolic seed on the Concept name, not a graph walk (Q-H.30.1) ──
//
// `classify(target: concept)` returns a Concept *name* (a String), not a
// NodeId. A graph-walk seed needs start NodeIds, which the cheap path cannot
// produce from a bare name without a second lookup. So the cheap path seeds a
// *symbolic* recall — `{typeNames: ['Concept'], attributes: [{name == best}]}`
// — which resolves the Concept by name inside the fused multi-recall. This is
// the spec's "seed from the nearest Concepts" obligation, realised as a
// name→symbolic seed. The same reasoning applies to the `category_selector`
// fallback below (also symbolic, also keyed by Concept name).
//
// ── Escalation to the LLM role ───────────────────────────────────────
//
// Only an `unknown` classification (the input sits far from every Concept
// centroid, or none exist yet — cold start) or a match-less result escalates
// to the `category_selector` role, which proposes candidate node types and
// Concept names by reasoning over the prompt. Each proposed Concept name
// becomes a symbolic seed; the proposed node types become one type-filter
// seed. A malformed role result degrades to `{ok: false}` and contributes no
// seeds (PE-6); a substrate outage throws and the conductor drops this
// strategy's seeds.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final text = inputs.get('text');
  final seeds = <Object?>[];

  // Cheap path: embed the prompt and classify against per-Concept centroids.
  final embedding = await sub.embed(text);
  final classification =
      await mem.classify(embedding['vec'], target: 'concept');
  final decision = classification['decision'];
  final bestMatch = classification['bestMatch'];

  // A confident or uncertain match names the nearest Concept — seed a
  // symbolic recall on it, no LLM needed.
  if ((decision == 'confident' || decision == 'uncertain') &&
      bestMatch is String &&
      bestMatch.isNotEmpty) {
    seeds.add(_conceptNameSeed(bestMatch));
    return <String, Object?>{'seeds': seeds};
  }

  // Unknown / match-less — escalate to the `category_selector` role.
  final selected = await sub.retrievalRole('category_selector', text);
  if (selected['ok'] != true) return <String, Object?>{'seeds': seeds};
  final output = selected['output'];
  if (output is! Map) return <String, Object?>{'seeds': seeds};

  // Each proposed Concept name becomes a symbolic seed on the name.
  final conceptNames = output['conceptNames'];
  if (conceptNames is List) {
    for (final name in conceptNames) {
      if (name is String && name.isNotEmpty) {
        seeds.add(_conceptNameSeed(name));
      }
    }
  }

  // The proposed node types become a single type-filter seed.
  final nodeTypes = output['nodeTypes'];
  if (nodeTypes is List) {
    final typeNames = <Object?>[];
    for (final nodeType in nodeTypes) {
      if (nodeType is String && nodeType.isNotEmpty) typeNames.add(nodeType);
    }
    if (typeNames.isNotEmpty) {
      seeds.add(<String, Object?>{
        'mode': 'symbolic',
        'filter': <String, Object?>{'typeNames': typeNames},
        'weight': 0.6,
      });
    }
  }

  return <String, Object?>{'seeds': seeds};
}

/// A symbolic seed that resolves the Concept whose `name` equals
/// [conceptName] (Q-H.30.1 — the cheap path cannot turn a name into a NodeId
/// for a graph walk, so it filters on the name symbolically).
Map<String, Object?> _conceptNameSeed(String conceptName) =>
    <String, Object?>{
      'mode': 'symbolic',
      'filter': <String, Object?>{
        'typeNames': <Object?>['Concept'],
        'attributes': <Object?>[
          <String, Object?>{
            'field': 'name',
            'op': 'eq',
            'value': conceptName,
          },
        ],
      },
      'weight': 0.8,
    };
