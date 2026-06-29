// A.32 — bootstrap manifest content test.
//
// Loads `lib/src/nodes/bootstrap_node_types.yaml` through the actual
// `loadBootstrapManifest` codepath (package-URI resolution + file read)
// and asserts the 21 types from `memory_specification.md` § 4.1 are all
// present with the embedded fields and key edges the spec calls for.
//
// This is the cross-check that catches:
//
//   - a missing type added to the spec but not to the manifest;
//   - a typo in an edge wire-name (FormatException would otherwise
//     leak in much later when an agent tries to walk the graph);
//   - a drift between an "embedded field" in the spec and the
//     manifest's `embedding.source_fields`.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:test/test.dart';

/// The 21 bootstrap types from `memory_specification.md` § 4.1.
const _expectedTypes = <String>[
  'Event',
  'Claim',
  'Concept',
  'Conclusion',
  'Question',
  'Pattern',
  'Contradiction',
  'Source',
  'Plan',
  'PlanStep',
  'Artifact',
  'Procedure',
  'ProcedureRun',
  'AutomationIdea',
  'InterestItem',
  'NodeType',
  'Session',
  'Trail',
  'Stack',
  'StackEntry',
  'Tombstone',
];

/// Per-type "embedded fields" from the spec § 4.1 table. The manifest's
/// `embedding.source_fields` MUST be exactly this list (order matters
/// for the embedding concatenation contract — § 2.4).
const _expectedEmbeddedFields = <String, List<String>>{
  'Event': ['summary'],
  'Claim': ['statement'],
  'Concept': ['name', 'description'],
  'Conclusion': ['statement', 'rationale'],
  'Question': ['text'],
  'Pattern': ['signature', 'description'],
  'Contradiction': ['summary'],
  'Source': ['title'],
  'Plan': ['goal', 'summary'],
  'PlanStep': ['description'],
  'Artifact': ['summary'],
  'Procedure': ['name', 'summary'],
  'AutomationIdea': ['description', 'motivation'],
  'InterestItem': ['topic', 'why'],
  'NodeType': ['type_name', 'schema_summary'],
  'Session': ['summary'],
  'Trail': ['summary'],
};

/// Types the spec marks as carrying no embedding.
// `ProcedureRun` is operational run metadata: the recorder writes a
// `running` start marker (no summary) and a final record without ever
// producing an embedding vector, and memory does not embed lazily — so the
// only satisfiable policy is `none` (spec § 4.1).
const _noEmbeddingTypes = <String>{
  'Stack',
  'StackEntry',
  'Tombstone',
  'ProcedureRun',
};

/// Per-type "Key edges" from spec § 4.1, as a flat unordered set. The
/// manifest may add edges (e.g. `mentions` everywhere) but MUST contain
/// every edge wire-name listed in the spec column.
const _expectedKeyEdges = <String, Set<String>>{
  'Event': {'caused_by', 'mentions'},
  'Claim': {'evidence_for', 'contradicts', 'derived_from'},
  'Concept': {'part_of', 'mentions'},
  'Conclusion': {'evidence_for', 'derived_from', 'satisfied_by'},
  'Question': {'motivates', 'satisfied_by', 'targets'},
  'Pattern': {'derived_from', 'mentions'},
  'Contradiction': {'contradicts'},
  'Source': {'evidence_for', 'mentions'},
  'Plan': {'targets', 'part_of'},
  'PlanStep': {'part_of'},
  'Artifact': {'produced_by', 'satisfied_by', 'targets'},
  'Procedure': {'superseded_by', 'authored_by'},
  'ProcedureRun': {'produced_by', 'derived_from', 'caused_by'},
  'AutomationIdea': {'motivates', 'satisfied_by', 'derived_from'},
  'InterestItem': {'motivates', 'satisfied_by'},
  'NodeType': {'superseded_by', 'derived_from'},
  'Session': {'caused_by', 'part_of'},
  'Trail': {'produced_by'},
  // Stack has no outgoing per spec, but part_of *incoming* from
  // StackEntry is the membership pattern — the test below asserts
  // that on Stack specifically and the union check would otherwise
  // need a non-empty entry here.
  'Stack': <String>{'part_of'},
  'StackEntry': {'part_of', 'mentions'},
  'Tombstone': {'derived_from'},
};

void main() {
  late List<NodeTypeDecl> manifest;

  setUpAll(() async {
    manifest = await NodeTypeYamlLoader.loadBootstrapManifest();
  });

  group('bootstrap_node_types.yaml — completeness', () {
    test('manifest declares exactly the 21 bootstrap types', () {
      final declared = manifest.map((d) => d.typeName).toSet();
      expect(declared, equals(_expectedTypes.toSet()),
          reason: 'spec § 4.1 names 21 specific bootstrap types — '
              'the manifest must match the set exactly');
      expect(manifest.length, _expectedTypes.length,
          reason: 'duplicates would have been rejected by the loader; '
              'this guards against a future loader rule that silently '
              'dedupes');
    });

    test('every type has version=1 at bootstrap', () {
      for (final decl in manifest) {
        expect(decl.version.value, 1,
            reason: '${decl.typeName} should boot at v1');
      }
    });

    test('every type starts without a classification centroid', () {
      // Spec § 7.1: centroids only exist after n=8 examples accumulate.
      for (final decl in manifest) {
        expect(decl.classificationCentroid, isNull,
            reason: '${decl.typeName} must start cold-classification');
      }
    });

    test('no bootstrap type claims supersedes or validator', () {
      for (final decl in manifest) {
        expect(decl.supersedes, isNull,
            reason: '${decl.typeName} is a bootstrap type, not an evolution');
        expect(decl.validatorScriptId, isNull,
            reason: '${decl.typeName} predates any procedure that could '
                'validate it');
      }
    });
  });

  group('bootstrap_node_types.yaml — embedding policy', () {
    test('types with embedded fields name them as source_fields', () {
      for (final entry in _expectedEmbeddedFields.entries) {
        final decl = _decl(manifest, entry.key);
        expect(decl.embeddingPolicy.isNone, isFalse,
            reason: '${entry.key} should carry an embedding');
        expect(decl.embeddingPolicy.sourceFields, entry.value,
            reason: '${entry.key} source_fields must match spec § 4.1 '
                '"embedded fields" column exactly (order matters)');
        expect(decl.embeddingPolicy.modelIdentity, isNotEmpty,
            reason: 'embedding model identity must round-trip per § 10.4');
        expect(decl.embeddingPolicy.dimensions, 768,
            reason: 'nomic-embed-text default at A.32 is 768 dims');
      }
    });

    test('Stack / StackEntry / Tombstone / ProcedureRun declare no embedding',
        () {
      for (final typeName in _noEmbeddingTypes) {
        final decl = _decl(manifest, typeName);
        expect(decl.embeddingPolicy.isNone, isTrue,
            reason: '$typeName must opt out of embeddings per spec § 4.1');
      }
    });
  });

  group('bootstrap_node_types.yaml — edge permissions', () {
    test('key edges from spec § 4.1 are reachable in either direction', () {
      // The spec table does not split outgoing/incoming. The manifest
      // does, with directional reasoning rooted in `EdgeType` dartdoc.
      // This test only asserts the union (out ∪ in) is a superset of
      // the spec's listed key edges.
      for (final entry in _expectedKeyEdges.entries) {
        final decl = _decl(manifest, entry.key);
        final wireNames = <String>{
          ...decl.allowedOutgoing.map((e) => e.wireName),
          ...decl.allowedIncoming.map((e) => e.wireName),
        };
        for (final required in entry.value) {
          expect(wireNames, contains(required),
              reason: '${entry.key} must allow `$required` in some '
                  'direction (spec § 4.1 lists it as a key edge)');
        }
      }
    });

    test('Stack has no outgoing edges', () {
      final stack = _decl(manifest, 'Stack');
      expect(stack.allowedOutgoing, isEmpty,
          reason: 'spec § 4.1: "Stack ... (no outgoing; entries point '
              'here)"');
      expect(stack.allowedIncoming, contains(EdgeType.partOf),
          reason: 'StackEntry —part_of→ Stack is the membership pattern');
    });

    test('Tombstone only emits derived_from', () {
      final tomb = _decl(manifest, 'Tombstone');
      expect(tomb.allowedOutgoing, {EdgeType.derivedFrom},
          reason: 'spec § 4.2 example: Tombstone only emits derived_from');
      expect(tomb.allowedIncoming, isEmpty,
          reason: 'a Tombstone is a leaf; nothing should point at it');
    });

    test('Question may not have outgoing evidence_for', () {
      // edge_type.dart explicitly names this as a disallowed combination.
      final q = _decl(manifest, 'Question');
      expect(q.allowedOutgoing, isNot(contains(EdgeType.evidenceFor)),
          reason: 'spec § 4.2: "a Question may not have an outgoing '
              'evidence_for (a Question is not evidence)"');
    });

    test('produced_by points output → producing run (Q-D.39.2)', () {
      // The authoritative direction is fixed by `EdgeType.producedBy`
      // dartdoc ("output → producing run") and the `RunRecorder`, which
      // draws `producedNode --produced_by--> run`. `EdgeWriter` enforces
      // `allowedOutgoing` on the `from` endpoint and `allowedIncoming` on
      // the `to` endpoint verbatim, so the manifest grammar *is* what a
      // validating store accepts. A produced node therefore EMITS
      // `produced_by` (outgoing); the ProcedureRun that produced it
      // RECEIVES it (incoming). Listing it the other way round — as the
      // bootstrap once did for Claim/Conclusion/Plan/Procedure — makes the
      // recorder's edge `EdgeNotPermitted` against the real store.
      const emitters = <String>{
        'Claim',
        'Conclusion',
        'Plan',
        'Procedure',
        'Artifact',
        'Trail',
      };
      const receivers = <String>{'ProcedureRun'};

      for (final typeName in emitters) {
        final decl = _decl(manifest, typeName);
        expect(decl.allowedOutgoing, contains(EdgeType.producedBy),
            reason: '$typeName is a procedure output — it must EMIT '
                'produced_by toward the run (outgoing)');
        expect(decl.allowedIncoming, isNot(contains(EdgeType.producedBy)),
            reason: '$typeName is the output, not the producer — '
                'produced_by must not be incoming on it');
      }

      for (final typeName in receivers) {
        final decl = _decl(manifest, typeName);
        expect(decl.allowedIncoming, contains(EdgeType.producedBy),
            reason: '$typeName is the producing run — it must RECEIVE '
                'produced_by from its outputs (incoming)');
        expect(decl.allowedOutgoing, isNot(contains(EdgeType.producedBy)),
            reason: '$typeName is the producer, never an output — '
                'produced_by must not be outgoing on it');
      }

      // The contract is closed: no other bootstrap type touches
      // produced_by in either direction. A future type that joins the
      // produced_by grammar must register here too.
      final emittersAndReceivers = {...emitters, ...receivers};
      for (final decl in manifest) {
        if (emittersAndReceivers.contains(decl.typeName)) continue;
        expect(decl.allowedOutgoing, isNot(contains(EdgeType.producedBy)),
            reason: '${decl.typeName} is not a known produced_by emitter');
        expect(decl.allowedIncoming, isNot(contains(EdgeType.producedBy)),
            reason: '${decl.typeName} is not a known produced_by receiver');
      }
    });
  });

  group('bootstrap_node_types.yaml — index/retention sanity', () {
    test('every indexed field is in the schema (loader-enforced)', () {
      // The loader already enforces this; the assertion exists so the
      // contract is documented at the manifest level too. If the loader
      // ever loosens the check, this test becomes the back-stop.
      for (final decl in manifest) {
        for (final f in decl.indexPolicy.ftsFields) {
          expect(decl.schema.containsKey(f), isTrue,
              reason: '${decl.typeName}: FTS field "$f" missing from schema');
        }
        for (final f in decl.indexPolicy.vectorFields) {
          expect(decl.schema.containsKey(f), isTrue,
              reason:
                  '${decl.typeName}: vector field "$f" missing from schema');
        }
      }
    });

    test(
        'the 5 global-aggregation allowlist types declare optional provenance '
        'fields; non-aggregated types do not (GA-4)', () {
      const provenanceFields = <String>[
        '_sourceProfile',
        '_sourceNodeId',
        '_aggregatedAt',
      ];
      // The v1 allowlist (memory § 2.6 GA-3) — these carry provenance so a
      // copy-derived global twin can record its source.
      const allowlisted = <String>[
        'Concept',
        'Claim',
        'Conclusion',
        'Pattern',
        'InterestItem',
      ];
      for (final typeName in allowlisted) {
        final decl = _decl(manifest, typeName);
        for (final f in provenanceFields) {
          expect(decl.schema.containsKey(f), isTrue,
              reason: '$typeName must declare provenance field "$f" (GA-4)');
          expect(decl.schema[f]!.nullable, isTrue,
              reason: '$typeName.$f must be optional (null on normal nodes)');
          expect(decl.schema[f]!.type, FieldType.string,
              reason: '$typeName.$f must be a string');
          // Provenance is metadata, never content — never indexed.
          expect(decl.indexPolicy.ftsFields.contains(f), isFalse);
          expect(decl.indexPolicy.vectorFields.contains(f), isFalse);
          expect(decl.embeddingPolicy.sourceFields.contains(f), isFalse);
        }
      }
      // An episodic / non-aggregated type must NOT carry provenance — it is
      // never aggregated, so the fields would be dead weight.
      final event = _decl(manifest, 'Event');
      for (final f in provenanceFields) {
        expect(event.schema.containsKey(f), isFalse,
            reason: 'Event is never aggregated and must not declare "$f"');
      }
    });

    test('Event/Source/NodeType/Stack/Tombstone retain indefinitely', () {
      // Per spec § 1 (hard invariant: "no event is ever truly lost") and
      // § 4.1: Tombstone is the immutability anchor; Events are also
      // immutable; NodeType declarations are versioned, never demoted.
      const indefiniteTypes = ['Event', 'Source', 'NodeType', 'Stack',
        'Tombstone'];
      for (final typeName in indefiniteTypes) {
        final decl = _decl(manifest, typeName);
        expect(decl.retentionPolicy.defaultHorizonMs, isNull,
            reason: '$typeName must retain indefinitely');
        expect(decl.retentionPolicy.demoteFromIndexes, isFalse,
            reason:
                '$typeName must not be demoted out of indexes by the GC');
      }
    });
  });

  group('bootstrap_node_types.yaml — barrel surface', () {
    test('loader symbols are reachable through the top-level barrel', () {
      // tom_brain_memory.dart re-exports nodes.dart which re-exports
      // node_type_yaml_loader.dart. This test exists so a future
      // accidental drop from the barrel surfaces immediately.
      expect(kBootstrapManifestPackageUri,
          'package:tom_brain_memory/src/nodes/bootstrap_node_types.yaml');
      expect(kSupportedManifestVersion, 1);
      expect(NodeTypeManifestException, isNotNull);
      expect(NodeTypeYamlLoader, isNotNull);
    });
  });
}

NodeTypeDecl _decl(List<NodeTypeDecl> manifest, String name) {
  return manifest.firstWhere(
    (d) => d.typeName == name,
    orElse: () => throw StateError('type "$name" missing from manifest'),
  );
}
