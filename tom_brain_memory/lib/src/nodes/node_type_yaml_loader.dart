// NodeTypeYamlLoader — parses the bootstrap node-type manifest.
//
// Plan step A.32:
//   "Implement `NodeTypeDecl` and the YAML manifest loader for the 21
//    bootstrap types listed in `memory_specification.md` § 4.1."
//
// The `NodeTypeDecl` shape was laid down at A.24 (see
// `node_type_decl.dart`). This file owns the *loader*: it converts the
// declarative YAML manifest shipped at
// `lib/src/nodes/bootstrap_node_types.yaml` into a `List<NodeTypeDecl>`
// the runtime can hand to `registerNodeType` (A.33).
//
// Why a YAML manifest, not Dart constants?
//
//   - The bootstrap table in spec § 4.1 is *data*, not behaviour. A
//     declarative file lets the spec, the manifest, and the runtime
//     stay in lockstep without a code-generation step.
//   - The same loader will accept user-supplied node-type proposals
//     (`propose_node_type_v1` writes a YAML fragment; A.33 routes it
//     through the same parser before committing).
//   - One file change = the registry changes; no recompile of consumers.
//
// What this file does NOT do:
//
//   - It does not write to the database. Producing a `NodeTypeDecl`
//     and persisting it via `registerNodeType` are two steps; this
//     loader only handles the first.
//   - It does not validate `allowedOutgoing` / `allowedIncoming`
//     against the global permission table (the cross-type consistency
//     check is A.33's job). Individual edge labels *are* validated
//     against `EdgeType.fromWireName`, so a typo is caught early.
//   - It does not embed the manifest text as a constant — the file is
//     loaded from the package's `lib/src/nodes/` directory at runtime
//     via `Isolate.resolvePackageUri`. Tests pass the YAML in directly
//     via [parse] to keep them hermetic.

import 'dart:io';
import 'dart:isolate';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainVersion, NodeId;
import 'package:yaml/yaml.dart';

import '../edges/edge_type.dart';
import 'node_type_decl.dart';

/// Package URI of the bootstrap manifest shipped with this package.
///
/// Resolved through `Isolate.resolvePackageUri` at runtime by
/// [loadBootstrapManifest]. Exposed publicly so callers that want to
/// hash the manifest, watch the file, or copy it elsewhere can do so
/// without re-deriving the location.
const String kBootstrapManifestPackageUri =
    'package:tom_brain_memory/src/nodes/bootstrap_node_types.yaml';

/// Manifest-format version this loader supports.
///
/// Bumped only when the YAML shape itself changes (not when the list
/// of bootstrap types is edited). A mismatch raises
/// [NodeTypeManifestException]; per quest hard-principle 1 there is no
/// backwards-compatibility shim — a newer manifest needs a newer loader
/// in the same change.
const int kSupportedManifestVersion = 1;

/// Thrown when the bootstrap manifest is structurally wrong (missing
/// required keys, unknown field type, unknown edge wire-name, …).
///
/// The thrown messages are written to be read by an engineer staring
/// at the YAML — they name the offending type and field whenever
/// possible. We never silently coerce: a malformed manifest is a
/// load-time crash, not a runtime mystery.
class NodeTypeManifestException implements Exception {
  /// Human-readable explanation. Always includes the type name (and
  /// field name where applicable) so the YAML location is obvious.
  final String message;

  const NodeTypeManifestException(this.message);

  @override
  String toString() => 'NodeTypeManifestException: $message';
}

/// Parses + materialises bootstrap node-type declarations from YAML.
///
/// Intentionally a namespace-only class (all members static): the
/// loader has no per-instance state, and `NodeTypeYamlLoader.parse`
/// reads better at call sites than a free function.
abstract final class NodeTypeYamlLoader {
  NodeTypeYamlLoader._();

  /// Parses the YAML [content] and returns the declared node types.
  ///
  /// Pure: no I/O, no clock, no random. Production callers will
  /// reach this through [loadBootstrapManifest]; tests reach it
  /// directly with hand-rolled YAML strings.
  static List<NodeTypeDecl> parse(String content) {
    final doc = loadYaml(content);
    if (doc is! YamlMap) {
      throw const NodeTypeManifestException(
        'Manifest root must be a YAML map (got a non-map document).',
      );
    }

    final manifestVersion = doc['manifest_version'];
    if (manifestVersion is! int) {
      throw const NodeTypeManifestException(
        'Manifest root must declare `manifest_version: <int>`.',
      );
    }
    if (manifestVersion != kSupportedManifestVersion) {
      throw NodeTypeManifestException(
        'Unsupported manifest_version $manifestVersion '
        '(this loader supports $kSupportedManifestVersion). '
        'Bump the loader in the same change as the manifest format.',
      );
    }

    final defaults = _parseEmbeddingDefaults(doc['embedding_defaults']);
    final types = doc['types'];
    if (types is! YamlList) {
      throw const NodeTypeManifestException(
        'Manifest must contain a `types:` list of node-type entries.',
      );
    }

    final results = <NodeTypeDecl>[];
    final seen = <String>{};
    for (final entry in types) {
      if (entry is! YamlMap) {
        throw const NodeTypeManifestException(
          'Each `types:` entry must be a YAML map.',
        );
      }
      final decl = _parseNodeType(entry, defaults);
      if (!seen.add(decl.typeName)) {
        throw NodeTypeManifestException(
          'Duplicate type name "${decl.typeName}" in manifest.',
        );
      }
      results.add(decl);
    }
    return List<NodeTypeDecl>.unmodifiable(results);
  }

  /// Reads + parses the bootstrap manifest shipped at
  /// [kBootstrapManifestPackageUri].
  ///
  /// Resolves the package URI through `Isolate.resolvePackageUri` so
  /// the file is found whether the consumer runs under `dart test`,
  /// `dart run`, or AOT compilation. Throws
  /// [NodeTypeManifestException] when the file is missing or
  /// unreadable; throws [NodeTypeManifestException] from [parse] when
  /// the YAML is structurally wrong.
  static Future<List<NodeTypeDecl>> loadBootstrapManifest() async {
    final uri = Uri.parse(kBootstrapManifestPackageUri);
    final resolved = await Isolate.resolvePackageUri(uri);
    if (resolved == null) {
      throw NodeTypeManifestException(
        'Could not resolve $uri — the running isolate has no '
        'package_config that knows about `tom_brain_memory`.',
      );
    }
    final file = File.fromUri(resolved);
    if (!file.existsSync()) {
      throw NodeTypeManifestException(
        'Bootstrap manifest not found at ${file.path}.',
      );
    }
    return parse(await file.readAsString());
  }

  // ---------- internal parsers ----------

  static _DefaultsRecord _parseEmbeddingDefaults(Object? raw) {
    if (raw == null) {
      return const _DefaultsRecord(modelIdentity: null, dimensions: null);
    }
    if (raw is! YamlMap) {
      throw const NodeTypeManifestException(
        '`embedding_defaults` must be a YAML map when present.',
      );
    }
    final model = raw['model_identity'];
    final dims = raw['dimensions'];
    if (model != null && model is! String) {
      throw const NodeTypeManifestException(
        '`embedding_defaults.model_identity` must be a string.',
      );
    }
    if (dims != null && dims is! int) {
      throw const NodeTypeManifestException(
        '`embedding_defaults.dimensions` must be an integer.',
      );
    }
    return _DefaultsRecord(
      modelIdentity: model as String?,
      dimensions: dims as int?,
    );
  }

  static NodeTypeDecl _parseNodeType(YamlMap entry, _DefaultsRecord defaults) {
    final name = _requireString(entry, 'name', context: '(unknown type)');
    final versionRaw = entry['version'];
    if (versionRaw is! int) {
      throw NodeTypeManifestException(
        'Type "$name": `version` must be an integer.',
      );
    }
    final version = BrainVersion.fromInt(versionRaw);

    NodeId? supersedes;
    final supersedesRaw = entry['supersedes'];
    if (supersedesRaw != null) {
      if (supersedesRaw is! String) {
        throw NodeTypeManifestException(
          'Type "$name": `supersedes` must be a `n_<ulid>` string.',
        );
      }
      supersedes = NodeId.fromString(supersedesRaw);
    }

    final schema = _parseSchema(entry['schema'], name);
    final embeddingPolicy = _parseEmbedding(entry['embedding'], name, defaults);
    final indexPolicy = _parseIndex(entry['index'], name, schema);
    final retentionPolicy = _parseRetention(entry['retention'], name);
    final allowedOutgoing = _parseEdgeSet(
      entry['allowed_outgoing'],
      name,
      'allowed_outgoing',
    );
    final allowedIncoming = _parseEdgeSet(
      entry['allowed_incoming'],
      name,
      'allowed_incoming',
    );

    final validatorRaw = entry['validator_script_id'];
    String? validatorScriptId;
    if (validatorRaw != null) {
      if (validatorRaw is! String || validatorRaw.isEmpty) {
        throw NodeTypeManifestException(
          'Type "$name": `validator_script_id` must be a non-empty string.',
        );
      }
      validatorScriptId = validatorRaw;
    }

    return NodeTypeDecl(
      typeName: name,
      version: version,
      supersedes: supersedes,
      schema: schema,
      embeddingPolicy: embeddingPolicy,
      indexPolicy: indexPolicy,
      retentionPolicy: retentionPolicy,
      allowedOutgoing: allowedOutgoing,
      allowedIncoming: allowedIncoming,
      validatorScriptId: validatorScriptId,
    );
  }

  static Map<String, FieldSpec> _parseSchema(Object? raw, String typeName) {
    if (raw is! YamlMap) {
      throw NodeTypeManifestException(
        'Type "$typeName": `schema` must be a map of field-name → spec.',
      );
    }
    final result = <String, FieldSpec>{};
    for (final key in raw.keys) {
      if (key is! String) {
        throw NodeTypeManifestException(
          'Type "$typeName": schema field name must be a string (got $key).',
        );
      }
      final specRaw = raw[key];
      if (specRaw is! YamlMap) {
        throw NodeTypeManifestException(
          'Type "$typeName" field "$key": field spec must be a map.',
        );
      }
      result[key] = _parseFieldSpec(specRaw, typeName, key);
    }
    return Map<String, FieldSpec>.unmodifiable(result);
  }

  static FieldSpec _parseFieldSpec(
    YamlMap spec,
    String typeName,
    String fieldName,
  ) {
    final typeRaw = spec['type'];
    if (typeRaw is! String) {
      throw NodeTypeManifestException(
        'Type "$typeName" field "$fieldName": `type` is required (string).',
      );
    }
    final fieldType = _fieldTypeFromWire(typeRaw, typeName, fieldName);

    final nullable = _readBool(spec, 'nullable', defaultValue: false);
    final fts = _readBool(spec, 'fts', defaultValue: false);
    final vector = _readBool(spec, 'vector', defaultValue: false);

    final enumValues = <String>[];
    final valuesRaw = spec['values'];
    if (valuesRaw != null) {
      if (fieldType != FieldType.enumeration) {
        throw NodeTypeManifestException(
          'Type "$typeName" field "$fieldName": `values` is only valid for '
          'enum fields.',
        );
      }
      if (valuesRaw is! YamlList) {
        throw NodeTypeManifestException(
          'Type "$typeName" field "$fieldName": `values` must be a list of '
          'strings.',
        );
      }
      for (final v in valuesRaw) {
        if (v is! String) {
          throw NodeTypeManifestException(
            'Type "$typeName" field "$fieldName": enum value must be a string '
            '(got $v).',
          );
        }
        enumValues.add(v);
      }
    } else if (fieldType == FieldType.enumeration) {
      throw NodeTypeManifestException(
        'Type "$typeName" field "$fieldName": enum field requires `values`.',
      );
    }

    final refs = <String>{};
    final refsRaw = spec['refs'];
    if (refsRaw != null) {
      if (fieldType != FieldType.nodeRef) {
        throw NodeTypeManifestException(
          'Type "$typeName" field "$fieldName": `refs` is only valid for '
          'nodeRef fields.',
        );
      }
      if (refsRaw is! YamlList) {
        throw NodeTypeManifestException(
          'Type "$typeName" field "$fieldName": `refs` must be a list of '
          'type names.',
        );
      }
      for (final r in refsRaw) {
        if (r is! String) {
          throw NodeTypeManifestException(
            'Type "$typeName" field "$fieldName": ref entry must be a string '
            '(got $r).',
          );
        }
        refs.add(r);
      }
    }

    return FieldSpec(
      name: fieldName,
      type: fieldType,
      nullable: nullable,
      ftsEligible: fts,
      vectorEligible: vector,
      enumValues: List<String>.unmodifiable(enumValues),
      nodeRefTypes: Set<String>.unmodifiable(refs),
    );
  }

  static FieldType _fieldTypeFromWire(
    String wire,
    String typeName,
    String fieldName,
  ) {
    switch (wire) {
      case 'string':
        return FieldType.string;
      case 'integer':
        return FieldType.integer;
      case 'boolean':
        return FieldType.boolean;
      case 'vec':
        return FieldType.vec;
      case 'nodeRef':
        return FieldType.nodeRef;
      case 'enum':
      case 'enumeration':
        return FieldType.enumeration;
      case 'json':
        return FieldType.json;
      default:
        throw NodeTypeManifestException(
          'Type "$typeName" field "$fieldName": unknown field type "$wire". '
          'Allowed: string, integer, boolean, vec, nodeRef, enum, json.',
        );
    }
  }

  static EmbeddingPolicy _parseEmbedding(
    Object? raw,
    String typeName,
    _DefaultsRecord defaults,
  ) {
    if (raw == null) {
      throw NodeTypeManifestException(
        'Type "$typeName": `embedding` is required '
        '(use `none` for types without embeddings).',
      );
    }
    if (raw is String) {
      if (raw == 'none') return EmbeddingPolicy.none;
      throw NodeTypeManifestException(
        'Type "$typeName": `embedding` string shorthand must be `none` '
        '(got "$raw").',
      );
    }
    if (raw is! YamlMap) {
      throw NodeTypeManifestException(
        'Type "$typeName": `embedding` must be `none` or a map.',
      );
    }
    final sources = raw['source_fields'];
    if (sources is! YamlList || sources.isEmpty) {
      throw NodeTypeManifestException(
        'Type "$typeName": `embedding.source_fields` must be a non-empty '
        'list of field names.',
      );
    }
    final sourceFields = <String>[];
    for (final s in sources) {
      if (s is! String) {
        throw NodeTypeManifestException(
          'Type "$typeName": `embedding.source_fields` entry must be a string '
          '(got $s).',
        );
      }
      sourceFields.add(s);
    }

    final modelRaw = raw['model_identity'];
    final model = modelRaw ?? defaults.modelIdentity;
    if (model is! String || model.isEmpty) {
      throw NodeTypeManifestException(
        'Type "$typeName": embedding `model_identity` is required either '
        'inline or via `embedding_defaults`.',
      );
    }

    final dimsRaw = raw['dimensions'];
    final dims = dimsRaw ?? defaults.dimensions;
    if (dims is! int || dims <= 0) {
      throw NodeTypeManifestException(
        'Type "$typeName": embedding `dimensions` must be a positive integer '
        '(inline or via `embedding_defaults`).',
      );
    }

    return EmbeddingPolicy(
      modelIdentity: model,
      dimensions: dims,
      sourceFields: List<String>.unmodifiable(sourceFields),
    );
  }

  static IndexPolicy _parseIndex(
    Object? raw,
    String typeName,
    Map<String, FieldSpec> schema,
  ) {
    if (raw == null) {
      return const IndexPolicy(
        ftsFields: <String>{},
        vectorFields: <String>{},
      );
    }
    if (raw is! YamlMap) {
      throw NodeTypeManifestException(
        'Type "$typeName": `index` must be a map.',
      );
    }
    final ftsFields = _parseStringSet(
      raw['fts_fields'],
      typeName: typeName,
      key: 'index.fts_fields',
    );
    final vectorFields = _parseStringSet(
      raw['vector_fields'],
      typeName: typeName,
      key: 'index.vector_fields',
    );
    final tokeniser = raw['fts_tokeniser'];
    if (tokeniser != null && tokeniser is! String) {
      throw NodeTypeManifestException(
        'Type "$typeName": `index.fts_tokeniser` must be a string.',
      );
    }

    // Cross-check: every indexed field must exist in the schema.
    for (final f in ftsFields) {
      if (!schema.containsKey(f)) {
        throw NodeTypeManifestException(
          'Type "$typeName": `index.fts_fields` names "$f" which is not in '
          'the schema.',
        );
      }
    }
    for (final f in vectorFields) {
      if (!schema.containsKey(f)) {
        throw NodeTypeManifestException(
          'Type "$typeName": `index.vector_fields` names "$f" which is not '
          'in the schema.',
        );
      }
    }

    return IndexPolicy(
      ftsFields: Set<String>.unmodifiable(ftsFields),
      vectorFields: Set<String>.unmodifiable(vectorFields),
      ftsTokeniser: tokeniser as String?,
    );
  }

  static RetentionPolicy _parseRetention(Object? raw, String typeName) {
    if (raw == null) {
      throw NodeTypeManifestException(
        'Type "$typeName": `retention` is required '
        '(use `indefinite` for never-demoted types).',
      );
    }
    if (raw is String) {
      if (raw == 'indefinite') return RetentionPolicy.indefinite;
      throw NodeTypeManifestException(
        'Type "$typeName": `retention` string shorthand must be `indefinite` '
        '(got "$raw").',
      );
    }
    if (raw is! YamlMap) {
      throw NodeTypeManifestException(
        'Type "$typeName": `retention` must be `indefinite` or a map.',
      );
    }
    final horizonRaw = raw['default_horizon_ms'];
    if (horizonRaw != null && horizonRaw is! int) {
      throw NodeTypeManifestException(
        'Type "$typeName": `retention.default_horizon_ms` must be an int or '
        'null.',
      );
    }
    final reinforce =
        _readBool(raw, 'reinforcement_resets_horizon', defaultValue: true);
    final demote = _readBool(raw, 'demote_from_indexes', defaultValue: true);
    return RetentionPolicy(
      defaultHorizonMs: horizonRaw as int?,
      reinforcementResetsHorizon: reinforce,
      demoteFromIndexes: demote,
    );
  }

  static Set<EdgeType> _parseEdgeSet(
    Object? raw,
    String typeName,
    String keyName,
  ) {
    if (raw == null) return const <EdgeType>{};
    if (raw is! YamlList) {
      throw NodeTypeManifestException(
        'Type "$typeName": `$keyName` must be a list of edge wire-names.',
      );
    }
    final result = <EdgeType>{};
    for (final entry in raw) {
      if (entry is! String) {
        throw NodeTypeManifestException(
          'Type "$typeName": `$keyName` entry must be a string (got $entry).',
        );
      }
      try {
        result.add(EdgeType.fromWireName(entry));
      } on FormatException catch (e) {
        throw NodeTypeManifestException(
          'Type "$typeName" in `$keyName`: ${e.message}',
        );
      }
    }
    return Set<EdgeType>.unmodifiable(result);
  }

  static Set<String> _parseStringSet(
    Object? raw, {
    required String typeName,
    required String key,
  }) {
    if (raw == null) return <String>{};
    if (raw is! YamlList) {
      throw NodeTypeManifestException(
        'Type "$typeName": `$key` must be a list of strings.',
      );
    }
    final result = <String>{};
    for (final v in raw) {
      if (v is! String) {
        throw NodeTypeManifestException(
          'Type "$typeName": `$key` entry must be a string (got $v).',
        );
      }
      result.add(v);
    }
    return result;
  }

  static String _requireString(
    YamlMap map,
    String key, {
    required String context,
  }) {
    final v = map[key];
    if (v is! String || v.isEmpty) {
      throw NodeTypeManifestException(
        '$context: `$key` is required and must be a non-empty string.',
      );
    }
    return v;
  }

  static bool _readBool(YamlMap map, String key, {required bool defaultValue}) {
    final v = map[key];
    if (v == null) return defaultValue;
    if (v is! bool) {
      throw NodeTypeManifestException(
        '`$key` must be a boolean (got $v).',
      );
    }
    return v;
  }
}

class _DefaultsRecord {
  final String? modelIdentity;
  final int? dimensions;
  const _DefaultsRecord({
    required this.modelIdentity,
    required this.dimensions,
  });
}
