// NodeTypeDecl — schema-and-policy declaration for a node type.
//
// From `memory_specification.md` § 4.1. A node type is itself a node
// (type `NodeType`); the `NodeTypeDecl` value is its materialised
// schema. Registration is gated by the `propose_node_type_v1`
// procedure (§ 4.1 "Adding a new node type") and writes through
// `TomBrainMemory.registerNodeType`.
//
// The declaration carries the type's schema (typed field map), its
// indexing and retention policy, a classification centroid (set
// later by `dream_recentroid_v1`), and the per-type permission table
// for the closed 12-edge alphabet (§ 4.2).

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainVersion, NodeId, Vec;

import '../edges/edge_type.dart';

/// Type of a single declared field on a node-type schema.
///
/// `vec` and `nodeRef` are first-class because they appear in the
/// SQLite table layout (vectors land in `vectors.db`; node refs are
/// `TEXT` columns stamped with the `n_` prefix and indexed for graph
/// walks). The other shapes resolve to standard SQLite affinities.
enum FieldType {
  string,
  integer,
  boolean,
  vec,
  nodeRef,
  enumeration,
  json,
}

/// Typed declaration of one field on a [NodeTypeDecl].
final class FieldSpec {
  /// Field name as it appears in the schema map.
  final String name;

  /// Type of the field.
  final FieldType type;

  /// Whether the column may be SQL `NULL`.
  final bool nullable;

  /// Whether the field is eligible for FTS5 indexing
  /// (`indexPolicy` decides whether it is *actually* indexed).
  final bool ftsEligible;

  /// Whether the field is eligible for vector indexing
  /// (`indexPolicy` decides whether it is *actually* indexed).
  /// Only meaningful when [type] is [FieldType.vec].
  final bool vectorEligible;

  /// For [FieldType.enumeration], the allowed values. Empty for
  /// other types.
  final List<String> enumValues;

  /// For [FieldType.nodeRef], an optional restriction on which node
  /// types may be referenced. Empty = any type.
  final Set<String> nodeRefTypes;

  const FieldSpec({
    required this.name,
    required this.type,
    this.nullable = false,
    this.ftsEligible = false,
    this.vectorEligible = false,
    this.enumValues = const <String>[],
    this.nodeRefTypes = const <String>{},
  });
}

/// Per-type indexing decisions. Drives which fields land in FTS5 and
/// which embed-bearing fields land in `vectors.db` (§ 2.2, § 2.3).
final class IndexPolicy {
  /// Field names indexed in FTS5.
  final Set<String> ftsFields;

  /// Field names indexed in the vector store.
  final Set<String> vectorFields;

  /// Custom tokeniser override (§ 2.3). `null` falls back to the
  /// default `unicode61 remove_diacritics 2`.
  final String? ftsTokeniser;

  const IndexPolicy({
    this.ftsFields = const <String>{},
    this.vectorFields = const <String>{},
    this.ftsTokeniser,
  });

  /// Policy that indexes nothing — useful for `Tombstone`, which
  /// participates in queries only via `derived_from` edges.
  static const IndexPolicy indexNothing =
      IndexPolicy(ftsFields: <String>{}, vectorFields: <String>{});
}

/// Per-type embedding policy. Names the substrate embedding model and
/// the fields whose text feeds the embedding (§ 2.4 "Embeddings").
///
/// The model identity round-trips through `vectors.db` per row so a
/// mid-life model swap is detectable rather than silent.
final class EmbeddingPolicy {
  /// Substrate-side embedding model identity, e.g.
  /// `nomic-embed-text@v1.5` (§ 10.4).
  final String modelIdentity;

  /// Vector dimension expected for [modelIdentity]. Vectors with a
  /// different dimension are rejected on persist.
  final int dimensions;

  /// Field names whose text is embedded into a single vector.
  final List<String> sourceFields;

  const EmbeddingPolicy({
    required this.modelIdentity,
    required this.dimensions,
    required this.sourceFields,
  });

  /// Sentinel policy meaning "this type has no embedding."
  static const EmbeddingPolicy none = EmbeddingPolicy(
    modelIdentity: '',
    dimensions: 0,
    sourceFields: <String>[],
  );

  /// True for the [none] sentinel.
  bool get isNone =>
      dimensions == 0 && modelIdentity.isEmpty && sourceFields.isEmpty;
}

/// Per-type retention rule. Drives node demotion (§ 5.3 / § 9.4),
/// never deletion outside of a user-explicit `forget`.
final class RetentionPolicy {
  /// Default retention horizon in milliseconds. `null` means
  /// indefinite (the `Tombstone` baseline; immutability is forever).
  final int? defaultHorizonMs;

  /// Whether reinforcement (re-reference) resets the horizon.
  final bool reinforcementResetsHorizon;

  /// Whether the demotion path may detach the node from indexes
  /// (FTS / vector) while keeping the SQL row queryable by id.
  final bool demoteFromIndexes;

  const RetentionPolicy({
    this.defaultHorizonMs,
    this.reinforcementResetsHorizon = true,
    this.demoteFromIndexes = true,
  });

  /// Indefinite retention — the [Tombstone] policy.
  static const RetentionPolicy indefinite = RetentionPolicy(
    defaultHorizonMs: null,
    reinforcementResetsHorizon: false,
    demoteFromIndexes: false,
  );
}

/// Schema-and-policy declaration for a node type.
///
/// See `memory_specification.md` § 4.1 for the canonical structure.
final class NodeTypeDecl {
  /// Canonical name. PascalCase, matches the `NodeType` row.
  final String typeName;

  /// Declaration version. Bumped on schema change; the previous
  /// version is reachable via [supersedes].
  final BrainVersion version;

  /// Predecessor declaration (when this is an evolution).
  final NodeId? supersedes;

  /// Typed field map. Keys are field names; values are the field's
  /// `FieldSpec`.
  final Map<String, FieldSpec> schema;

  /// Embedding policy for the type. `EmbeddingPolicy.none` for types
  /// without embeddings (`Tombstone`, `Stack`, `StackEntry`).
  final EmbeddingPolicy embeddingPolicy;

  /// Index policy — what gets FTS / vector indexed.
  final IndexPolicy indexPolicy;

  /// Retention policy — demotion rules.
  final RetentionPolicy retentionPolicy;

  /// Centroid for cheap classification (§ 7). `null` until enough
  /// examples accumulate (default `n=8`) — cold-started types skip
  /// classification.
  final Vec? classificationCentroid;

  /// Edge labels this type may emit (outgoing).
  final Set<EdgeType> allowedOutgoing;

  /// Edge labels this type may receive (incoming).
  final Set<EdgeType> allowedIncoming;

  /// Optional id of a procedure that validates candidate nodes of
  /// this type before commit. `null` = no extra validation pass.
  final String? validatorScriptId;

  const NodeTypeDecl({
    required this.typeName,
    required this.version,
    required this.schema,
    required this.embeddingPolicy,
    required this.indexPolicy,
    required this.retentionPolicy,
    required this.allowedOutgoing,
    required this.allowedIncoming,
    this.supersedes,
    this.classificationCentroid,
    this.validatorScriptId,
  });
}
