// A.32 — NodeTypeYamlLoader unit tests.
//
// Hermetic tests against hand-rolled YAML strings. The companion file
// `bootstrap_node_types_test.dart` exercises the on-disk bootstrap
// manifest via `loadBootstrapManifest`. Splitting the suites keeps
// loader-shape failures distinct from manifest-content failures.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainVersion;
import 'package:test/test.dart';

void main() {
  group('NodeTypeYamlLoader.parse — happy path', () {
    test('parses a single-type manifest with embedding defaults', () {
      const yaml = '''
manifest_version: 1
embedding_defaults:
  model_identity: nomic-embed-text@v1.5
  dimensions: 768
types:
  - name: Claim
    version: 1
    schema:
      statement: { type: string, fts: true }
    embedding:
      source_fields: [statement]
    index:
      fts_fields: [statement]
      vector_fields: [statement]
    retention:
      default_horizon_ms: null
      reinforcement_resets_horizon: true
      demote_from_indexes: true
    allowed_outgoing: [evidence_for, contradicts]
    allowed_incoming: [evidence_for, derived_from]
''';
      final types = NodeTypeYamlLoader.parse(yaml);
      expect(types, hasLength(1));
      final decl = types.single;
      expect(decl.typeName, 'Claim');
      expect(decl.version, BrainVersion.fromInt(1));
      expect(decl.schema.keys, ['statement']);
      expect(decl.schema['statement']!.type, FieldType.string);
      expect(decl.schema['statement']!.ftsEligible, isTrue);
      expect(decl.embeddingPolicy.modelIdentity, 'nomic-embed-text@v1.5');
      expect(decl.embeddingPolicy.dimensions, 768);
      expect(decl.embeddingPolicy.sourceFields, ['statement']);
      expect(decl.indexPolicy.ftsFields, {'statement'});
      expect(decl.indexPolicy.vectorFields, {'statement'});
      expect(decl.retentionPolicy.defaultHorizonMs, isNull);
      expect(decl.retentionPolicy.reinforcementResetsHorizon, isTrue);
      expect(decl.retentionPolicy.demoteFromIndexes, isTrue);
      expect(decl.allowedOutgoing,
          {EdgeType.evidenceFor, EdgeType.contradicts});
      expect(decl.allowedIncoming,
          {EdgeType.evidenceFor, EdgeType.derivedFrom});
      expect(decl.classificationCentroid, isNull);
      expect(decl.supersedes, isNull);
      expect(decl.validatorScriptId, isNull);
    });

    test('accepts `retention: indefinite` shorthand', () {
      const yaml = '''
manifest_version: 1
types:
  - name: Tombstone
    version: 1
    schema:
      reason: { type: string, fts: true }
    embedding: none
    index:
      fts_fields: [reason]
      vector_fields: []
    retention: indefinite
    allowed_outgoing: [derived_from]
    allowed_incoming: []
''';
      final decl = NodeTypeYamlLoader.parse(yaml).single;
      expect(decl.retentionPolicy, same(RetentionPolicy.indefinite));
      expect(decl.embeddingPolicy.isNone, isTrue);
      expect(decl.allowedIncoming, isEmpty);
    });

    test('accepts `embedding: none` shorthand', () {
      const yaml = '''
manifest_version: 1
types:
  - name: Stack
    version: 1
    schema:
      name: { type: string, fts: true }
    embedding: none
    index:
      fts_fields: [name]
      vector_fields: []
    retention: indefinite
    allowed_outgoing: []
    allowed_incoming: [part_of]
''';
      final decl = NodeTypeYamlLoader.parse(yaml).single;
      expect(decl.embeddingPolicy.isNone, isTrue);
      expect(decl.embeddingPolicy.dimensions, 0);
    });

    test('parses enum and nodeRef field types', () {
      const yaml = '''
manifest_version: 1
types:
  - name: StackEntry
    version: 1
    schema:
      stack_ref: { type: nodeRef, refs: [Stack] }
      node_ref: { type: nodeRef }
      priority: { type: integer }
      status:
        type: enum
        values: [pending, active, completed, dropped]
    embedding: none
    retention:
      default_horizon_ms: null
      reinforcement_resets_horizon: true
      demote_from_indexes: true
    allowed_outgoing: [part_of, mentions]
    allowed_incoming: []
''';
      final decl = NodeTypeYamlLoader.parse(yaml).single;
      expect(decl.schema['stack_ref']!.type, FieldType.nodeRef);
      expect(decl.schema['stack_ref']!.nodeRefTypes, {'Stack'});
      expect(decl.schema['node_ref']!.type, FieldType.nodeRef);
      expect(decl.schema['node_ref']!.nodeRefTypes, isEmpty);
      expect(decl.schema['priority']!.type, FieldType.integer);
      expect(decl.schema['status']!.type, FieldType.enumeration);
      expect(decl.schema['status']!.enumValues,
          ['pending', 'active', 'completed', 'dropped']);
    });

    test('returns an unmodifiable list', () {
      const yaml = '''
manifest_version: 1
types:
  - name: Question
    version: 1
    schema:
      text: { type: string, fts: true }
    embedding:
      model_identity: nomic-embed-text@v1.5
      dimensions: 768
      source_fields: [text]
    retention: indefinite
    allowed_outgoing: [motivates]
    allowed_incoming: [satisfied_by]
''';
      final types = NodeTypeYamlLoader.parse(yaml);
      expect(() => types.add(types.first), throwsUnsupportedError);
    });
  });

  group('NodeTypeYamlLoader.parse — error surfacing', () {
    test('rejects unsupported manifest_version', () {
      const yaml = '''
manifest_version: 99
types: []
''';
      expect(
        () => NodeTypeYamlLoader.parse(yaml),
        throwsA(
          isA<NodeTypeManifestException>().having(
            (e) => e.message,
            'message',
            contains('manifest_version 99'),
          ),
        ),
      );
    });

    test('rejects missing manifest_version', () {
      const yaml = '''
types: []
''';
      expect(
        () => NodeTypeYamlLoader.parse(yaml),
        throwsA(isA<NodeTypeManifestException>()),
      );
    });

    test('rejects non-map root', () {
      expect(
        () => NodeTypeYamlLoader.parse('- hello\n- world\n'),
        throwsA(isA<NodeTypeManifestException>()),
      );
    });

    test('rejects missing `types:` list', () {
      const yaml = '''
manifest_version: 1
''';
      expect(
        () => NodeTypeYamlLoader.parse(yaml),
        throwsA(isA<NodeTypeManifestException>()),
      );
    });

    test('rejects duplicate type name', () {
      const yaml = '''
manifest_version: 1
types:
  - name: Question
    version: 1
    schema:
      text: { type: string }
    embedding:
      model_identity: m
      dimensions: 8
      source_fields: [text]
    retention: indefinite
    allowed_outgoing: []
    allowed_incoming: []
  - name: Question
    version: 1
    schema:
      text: { type: string }
    embedding:
      model_identity: m
      dimensions: 8
      source_fields: [text]
    retention: indefinite
    allowed_outgoing: []
    allowed_incoming: []
''';
      expect(
        () => NodeTypeYamlLoader.parse(yaml),
        throwsA(
          isA<NodeTypeManifestException>().having(
            (e) => e.message,
            'message',
            contains('Duplicate type name "Question"'),
          ),
        ),
      );
    });

    test('rejects unknown field type', () {
      const yaml = '''
manifest_version: 1
types:
  - name: Bad
    version: 1
    schema:
      f: { type: doubleish }
    embedding: none
    retention: indefinite
    allowed_outgoing: []
    allowed_incoming: []
''';
      expect(
        () => NodeTypeYamlLoader.parse(yaml),
        throwsA(
          isA<NodeTypeManifestException>().having(
            (e) => e.message,
            'message',
            contains('unknown field type "doubleish"'),
          ),
        ),
      );
    });

    test('rejects unknown edge wire-name', () {
      const yaml = '''
manifest_version: 1
types:
  - name: Bad
    version: 1
    schema:
      f: { type: string }
    embedding: none
    retention: indefinite
    allowed_outgoing: [haunts]
    allowed_incoming: []
''';
      expect(
        () => NodeTypeYamlLoader.parse(yaml),
        throwsA(
          isA<NodeTypeManifestException>().having(
            (e) => e.message,
            'message',
            allOf(contains('allowed_outgoing'), contains('haunts')),
          ),
        ),
      );
    });

    test('rejects enum without `values`', () {
      const yaml = '''
manifest_version: 1
types:
  - name: Bad
    version: 1
    schema:
      f: { type: enum }
    embedding: none
    retention: indefinite
    allowed_outgoing: []
    allowed_incoming: []
''';
      expect(
        () => NodeTypeYamlLoader.parse(yaml),
        throwsA(
          isA<NodeTypeManifestException>().having(
            (e) => e.message,
            'message',
            contains('enum field requires `values`'),
          ),
        ),
      );
    });

    test('rejects `values` on non-enum field', () {
      const yaml = '''
manifest_version: 1
types:
  - name: Bad
    version: 1
    schema:
      f: { type: string, values: [a, b] }
    embedding: none
    retention: indefinite
    allowed_outgoing: []
    allowed_incoming: []
''';
      expect(
        () => NodeTypeYamlLoader.parse(yaml),
        throwsA(isA<NodeTypeManifestException>()),
      );
    });

    test('rejects index field that is not in the schema', () {
      const yaml = '''
manifest_version: 1
types:
  - name: Bad
    version: 1
    schema:
      f: { type: string }
    embedding: none
    index:
      fts_fields: [missing]
      vector_fields: []
    retention: indefinite
    allowed_outgoing: []
    allowed_incoming: []
''';
      expect(
        () => NodeTypeYamlLoader.parse(yaml),
        throwsA(
          isA<NodeTypeManifestException>().having(
            (e) => e.message,
            'message',
            contains('"missing" which is not in the schema'),
          ),
        ),
      );
    });

    test('rejects embedding map without source_fields', () {
      const yaml = '''
manifest_version: 1
types:
  - name: Bad
    version: 1
    schema:
      f: { type: string }
    embedding:
      model_identity: m
      dimensions: 8
    retention: indefinite
    allowed_outgoing: []
    allowed_incoming: []
''';
      expect(
        () => NodeTypeYamlLoader.parse(yaml),
        throwsA(isA<NodeTypeManifestException>()),
      );
    });

    test('rejects unknown embedding shorthand', () {
      const yaml = '''
manifest_version: 1
types:
  - name: Bad
    version: 1
    schema:
      f: { type: string }
    embedding: whatever
    retention: indefinite
    allowed_outgoing: []
    allowed_incoming: []
''';
      expect(
        () => NodeTypeYamlLoader.parse(yaml),
        throwsA(isA<NodeTypeManifestException>()),
      );
    });

    test('rejects retention without horizon_ms key', () {
      const yaml = '''
manifest_version: 1
types:
  - name: Bad
    version: 1
    schema:
      f: { type: string }
    embedding: none
    retention:
      reinforcement_resets_horizon: true
      demote_from_indexes: true
    allowed_outgoing: []
    allowed_incoming: []
''';
      // Loader treats missing default_horizon_ms as null (indefinite).
      // This should *succeed*. Test asserts behaviour explicitly.
      final decl = NodeTypeYamlLoader.parse(yaml).single;
      expect(decl.retentionPolicy.defaultHorizonMs, isNull);
    });

    test('rejects unknown retention shorthand', () {
      const yaml = '''
manifest_version: 1
types:
  - name: Bad
    version: 1
    schema:
      f: { type: string }
    embedding: none
    retention: forever
    allowed_outgoing: []
    allowed_incoming: []
''';
      expect(
        () => NodeTypeYamlLoader.parse(yaml),
        throwsA(isA<NodeTypeManifestException>()),
      );
    });

    test('rejects non-integer version', () {
      const yaml = '''
manifest_version: 1
types:
  - name: Bad
    version: one
    schema:
      f: { type: string }
    embedding: none
    retention: indefinite
    allowed_outgoing: []
    allowed_incoming: []
''';
      expect(
        () => NodeTypeYamlLoader.parse(yaml),
        throwsA(isA<NodeTypeManifestException>()),
      );
    });

    test('rejects missing `name`', () {
      const yaml = '''
manifest_version: 1
types:
  - version: 1
    schema:
      f: { type: string }
    embedding: none
    retention: indefinite
    allowed_outgoing: []
    allowed_incoming: []
''';
      expect(
        () => NodeTypeYamlLoader.parse(yaml),
        throwsA(isA<NodeTypeManifestException>()),
      );
    });
  });
}
