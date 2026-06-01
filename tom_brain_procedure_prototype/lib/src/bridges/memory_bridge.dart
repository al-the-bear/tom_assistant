// MemoryBridge — the d4rt-bridged re-export of the brain's memory
// primitive set (Plan step C.12;
// `tom_brain_procedure_prototype_specification.md` § 5.1).
//
// This is a **plain Dart class** (no annotation — `@D4rtBridged` does
// not exist in the d4rt ecosystem; see Q-C.3.1 / C.3 in
// `prototype_implementation_details.md`). `tom_d4rt_generator` selects
// it for bridging because `build.yaml` (C.11) lists this file under the
// `all` module's `barrelFiles`. The generated bridge registers through
// `BrainBridges.register(d4rt)` (C.14 / C.16). The generator-output
// round-trip smoke lands at C.15; this step (C.12) authors only the
// source class and its native unit tests.
//
// ── Why primitive-typed signatures (Q-C.3.3) ────────────────────────
//
// Every method accepts and returns d4rt-native primitives — `String`,
// `num`/`int`/`double`, `bool`, `List`, `Map<String, Object?>`. The
// bridge translates those primitives into the memory domain types
// (`NodeDraft`, `RecallQuery`, `EdgeType`, `StackDecl`, …) on the way
// in and back into plain maps/lists on the way out. Keeping the bridged
// surface primitive means the generator never has to bridge the entire
// `tom_brain_memory` domain-type graph — the single most expensive and
// fragile thing it could be asked to do. The typed result wrappers the
// spec mentions in § 5.3 (`RecallResult`, `LlmResult`, …) are layered
// in `lib/api/` later (C.38–C.41) and wrap these primitive returns;
// they are deliberately *not* the bridged shape. (Q-C.12.1 records the
// § 5.1 ⇄ § 5.3 tension and this resolution.)
//
// ── Interface boundary (PE-10) ──────────────────────────────────────
//
// The bridge wraps a `TomBrainMemoryClient` — the consumer-facing
// contract (A.78) — never the concrete `SqliteTomBrainMemory` and never
// `tom_brain_memory/lib/src/` internals. The host injects whichever
// implementation the deployment topology chose (in-process or
// isolate-bridged); the bridge cannot tell the difference.
//
// ── Stack surface naming ────────────────────────────────────────────
//
// The spec lists the stack primitives as `stack.list / create / push /
// peek / pop / update / remove`. Dart method names cannot contain a
// dot, so they are exposed here as `stackList`, `stackCreate`,
// `stackPush`, `stackPeek`, `stackPop`, `stackUpdate`, `stackRemove`.
// Whether the d4rt-facing surface presents them under a dotted `stack.`
// namespace (e.g. via a nested bridge object) or flat is a host-wiring
// decision deferred to C.16 (Q-C.12.2).

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show BrainVersion, NodeId, Vec;

/// Re-exposes the memory primitive set to d4rt procedure scripts.
///
/// Mirrors the memory rows of `tom_brain_procedure_prototype_specification.md`
/// § 5.1: `recall`, `persist`, `edge`, `propose_node_type`, and the
/// seven `stack.*` operations. Each method delegates to the wrapped
/// [TomBrainMemoryClient] and converts between d4rt primitives and the
/// memory domain types.
class MemoryBridge {
  /// The interface-boundary memory client every method delegates to
  /// (PE-10). Injected by the host (C.16).
  final TomBrainMemoryClient client;

  /// Wraps [client]. The host constructs this natively and registers
  /// the instance with the d4rt runtime.
  MemoryBridge(this.client);

  // ── recall ──────────────────────────────────────────────────────

  /// Runs the four-mode retrieval pipeline.
  ///
  /// [text] is the query text (BM25 + memory-side embedded vector mode).
  /// [modes] names the modes to run by wire name (`bm25`, `vector`,
  /// `graph_walk`, `symbolic`); defaults to `['bm25', 'vector']` — the
  /// pair `answer_with_memory_v1` uses. [k] caps the post-fusion result
  /// list.
  ///
  /// Returns `{'nodes': [...], 'report': {...}}` where each node is the
  /// flattened map from [_nodeToMap] and the report mirrors
  /// [RecallReport].
  Future<Map<String, Object?>> recall(
    String text, {
    List<String> modes = const <String>['bm25', 'vector'],
    int k = 8,
  }) async {
    final query = RecallQuery(
      text: text,
      modes: modes.map(_parseMode).toSet(),
      k: k,
    );
    final result = await client.recall(query);
    return <String, Object?>{
      'nodes': result.nodes.map(_nodeToMap).toList(),
      'report': _reportToMap(result.report),
    };
  }

  // ── persist ─────────────────────────────────────────────────────

  /// Persists a candidate node and returns its stable id string.
  ///
  /// [typeName] must match a registered node type. [values] is the
  /// field map. [producer] is the write's provenance identity (required
  /// by [Scope]); [idempotencyKey], [causedBy], and [runId] are
  /// optional provenance/idempotency hooks. [embedding], when supplied,
  /// is a pre-computed vector that saves memory a substrate callout.
  Future<String> persist(
    String typeName,
    Map<String, Object?> values, {
    required String producer,
    String? idempotencyKey,
    String? causedBy,
    String? runId,
    List<double>? embedding,
  }) async {
    final draft = NodeDraft(
      typeName: typeName,
      values: values,
      embedding: embedding == null ? null : Vec.fromList(embedding),
    );
    final id = await client.persist(
      draft,
      scope: Scope(
        producer: producer,
        idempotencyKey: idempotencyKey,
        causedBy: causedBy,
        runId: runId,
      ),
    );
    return id.value;
  }

  // ── edge ────────────────────────────────────────────────────────

  /// Creates an edge from the closed 12-edge alphabet and returns its
  /// id string.
  ///
  /// [from] / [to] are node-id strings; [type] is the edge wire name
  /// (e.g. `produced_by`, `derived_from`). [producer] is the write
  /// provenance; [weight] defaults to 1.0; [attrs] carries optional
  /// per-edge metadata (e.g. `{'kind': 'depends_on'}`).
  Future<String> edge(
    String from,
    String type,
    String to, {
    required String producer,
    double weight = 1.0,
    String? idempotencyKey,
    String? causedBy,
    String? runId,
    Map<String, Object?>? attrs,
  }) async {
    final id = await client.edge(
      NodeId.fromString(from),
      EdgeType.fromWireName(type),
      NodeId.fromString(to),
      scope: Scope(
        producer: producer,
        idempotencyKey: idempotencyKey,
        causedBy: causedBy,
        runId: runId,
      ),
      weight: weight,
      attrs: attrs,
    );
    return id.value;
  }

  // ── propose_node_type ───────────────────────────────────────────

  /// Registers a new node type from a primitive declaration map.
  ///
  /// Delegated; not exercised by `answer_with_memory_v1` (§ 5.1). The
  /// supported map subset is:
  ///
  /// ```
  /// {
  ///   'typeName': 'MyType',           // required
  ///   'version': 1,                    // optional, defaults to 1
  ///   'schema': {                      // optional field map
  ///     'title': {'type': 'string', 'nullable': false,
  ///               'ftsEligible': true},
  ///   },
  ///   'allowedOutgoing': ['mentions'], // optional edge wire names
  ///   'allowedIncoming': ['produced_by'],
  /// }
  /// ```
  ///
  /// Embedding / index / retention policies default to "none / index
  /// nothing / default retention". The full policy surface is out of
  /// the prototype's scope (Q-C.12.3).
  Future<void> proposeNodeType(Map<String, Object?> decl) =>
      client.registerNodeType(_buildNodeTypeDecl(decl));

  // ── stack.* ─────────────────────────────────────────────────────

  /// `stack.list` — summary row per stack.
  Future<List<Map<String, Object?>>> stackList() async {
    final summaries = await client.stacks.list();
    return summaries.map(_summaryToMap).toList();
  }

  /// `stack.create` — creates a non-bootstrap stack from a primitive
  /// declaration map (see [_buildStackDecl] for the supported shape).
  Future<void> stackCreate(Map<String, Object?> decl) =>
      client.stacks.create(_buildStackDecl(decl));

  /// `stack.push` — atomically pushes [nodeId] onto [name]. Returns the
  /// new stack-entry id string.
  Future<String> stackPush(
    String name,
    String nodeId, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    String? producer,
    String? runId,
  }) async {
    final id = await client.stacks.push(
      name,
      NodeId.fromString(nodeId),
      priority: priority,
      attrs: attrs,
      scope: producer == null
          ? null
          : Scope(producer: producer, runId: runId),
    );
    return id.value;
  }

  /// `stack.peek` — top-[k] read honouring the stack's priority policy.
  Future<List<Map<String, Object?>>> stackPeek(
    String name, {
    int k = 16,
  }) async {
    final entries = await client.stacks.peek(name, k: k);
    return entries.map(_entryToMap).toList();
  }

  /// `stack.pop` — atomically pops the top entry, or `null` when empty.
  Future<Map<String, Object?>?> stackPop(String name) async {
    final entry = await client.stacks.pop(name);
    return entry == null ? null : _entryToMap(entry);
  }

  /// `stack.update` — updates priority / status / attrs of an entry.
  /// [status] is a [StackEntryStatus] name (`active` / `archived`).
  Future<void> stackUpdate(
    String name,
    String nodeId, {
    double? priority,
    String? status,
    Map<String, Object?>? attrs,
  }) =>
      client.stacks.update(
        name,
        NodeId.fromString(nodeId),
        priority: priority,
        status: status == null ? null : StackEntryStatus.values.byName(status),
        attrs: attrs,
      );

  /// `stack.remove` — removes the entry's membership; the node stays.
  Future<void> stackRemove(String name, String nodeId) =>
      client.stacks.remove(name, NodeId.fromString(nodeId));

  // ── primitive ⇄ domain conversions ──────────────────────────────

  static RecallMode _parseMode(String wire) {
    switch (wire) {
      case 'bm25':
        return RecallMode.bm25;
      case 'vector':
        return RecallMode.vector;
      case 'graph_walk':
      case 'graphWalk':
        return RecallMode.graphWalk;
      case 'symbolic':
        return RecallMode.symbolic;
      default:
        throw FormatException(
          'Unknown recall mode "$wire" — expected one of '
          'bm25, vector, graph_walk, symbolic.',
        );
    }
  }

  static Map<String, Object?> _nodeToMap(Node node) => <String, Object?>{
        'id': node.id.value,
        'typeName': node.typeName,
        'values': node.values,
        'status': node.status.name,
        'createdAt': node.createdAt.toIso8601String(),
        if (node.embedding != null)
          'embedding': node.embedding!.values.toList(),
      };

  static Map<String, Object?> _reportToMap(RecallReport report) =>
      <String, Object?>{
        'candidatesPerMode': <String, int>{
          for (final e in report.candidatesPerMode.entries)
            e.key.name: e.value,
        },
        'fusionStrategy': report.fusionStrategy.name,
        'diversityStrategy': report.diversityStrategy.name,
        'diversityLambda': report.diversityLambda,
        'elapsedMs': report.elapsedMs,
        'embeddingsCallouts': report.embeddingsCallouts,
        'reRankInvoked': report.reRankInvoked,
        'degraded': report.degraded,
      };

  static Map<String, Object?> _summaryToMap(StackSummary s) =>
      <String, Object?>{
        'name': s.name,
        'size': s.size,
        'topPriority': s.topPriority,
        'bootstrap': s.bootstrap,
      };

  static Map<String, Object?> _entryToMap(StackEntry e) => <String, Object?>{
        'id': e.id.value,
        'stackName': e.stackName,
        'nodeId': e.nodeId.value,
        'priority': e.priority,
        'pushedAt': e.pushedAt.toIso8601String(),
        'status': e.status.name,
        'attrs': e.attrs,
      };

  static NodeTypeDecl _buildNodeTypeDecl(Map<String, Object?> decl) {
    final typeName = decl['typeName'] as String?;
    if (typeName == null || typeName.isEmpty) {
      throw const FormatException(
        'proposeNodeType requires a non-empty "typeName".',
      );
    }
    final versionValue = decl['version'];
    final version = versionValue == null
        ? BrainVersion.initial
        : BrainVersion.fromInt((versionValue as num).toInt());

    final schemaRaw = decl['schema'] as Map<Object?, Object?>?;
    final schema = <String, FieldSpec>{};
    if (schemaRaw != null) {
      for (final entry in schemaRaw.entries) {
        final fieldName = entry.key as String;
        schema[fieldName] =
            _buildFieldSpec(fieldName, entry.value as Map<Object?, Object?>);
      }
    }

    return NodeTypeDecl(
      typeName: typeName,
      version: version,
      schema: schema,
      embeddingPolicy: EmbeddingPolicy.none,
      indexPolicy: const IndexPolicy(),
      retentionPolicy: const RetentionPolicy(),
      allowedOutgoing: _parseEdgeSet(decl['allowedOutgoing']),
      allowedIncoming: _parseEdgeSet(decl['allowedIncoming']),
    );
  }

  static FieldSpec _buildFieldSpec(String name, Map<Object?, Object?> spec) {
    return FieldSpec(
      name: name,
      type: FieldType.values.byName((spec['type'] as String?) ?? 'string'),
      nullable: (spec['nullable'] as bool?) ?? false,
      ftsEligible: (spec['ftsEligible'] as bool?) ?? false,
      vectorEligible: (spec['vectorEligible'] as bool?) ?? false,
    );
  }

  static Set<EdgeType> _parseEdgeSet(Object? raw) {
    if (raw == null) return const <EdgeType>{};
    return (raw as List<Object?>)
        .map((e) => EdgeType.fromWireName(e as String))
        .toSet();
  }

  static StackDecl _buildStackDecl(Map<String, Object?> decl) {
    final name = decl['name'] as String?;
    if (name == null || name.isEmpty) {
      throw const FormatException(
        'stackCreate requires a non-empty "name".',
      );
    }
    return StackDecl(
      name: name,
      summary: (decl['summary'] as String?) ?? '',
      entryNodeType: (decl['entryNodeType'] as String?) ?? 'Node',
      harvesterHook: decl['harvesterHook'] as String?,
      policy: _buildStackPolicy(
        decl['policy'] as Map<Object?, Object?>?,
      ),
    );
  }

  static StackPolicy _buildStackPolicy(Map<Object?, Object?>? policy) {
    if (policy == null) {
      return const StackPolicy(
        priority: PriorityPolicyKind.fifo,
        retention: RetentionPolicyKind.unbounded,
      );
    }
    return StackPolicy(
      priority: PriorityPolicyKind.values
          .byName((policy['priority'] as String?) ?? 'fifo'),
      retention: RetentionPolicyKind.values
          .byName((policy['retention'] as String?) ?? 'unbounded'),
      maxCount: (policy['maxCount'] as num?)?.toInt(),
      maxAgeMs: (policy['maxAgeMs'] as num?)?.toInt(),
      halflifeMs: (policy['halflifeMs'] as num?)?.toInt(),
    );
  }
}
