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
    show BrainTime, BrainVersion, DemotionReason, NodeId, Vec;
import 'package:tom_core_agentic/tom_core_agentic.dart' show MapFieldReader;

import '../budget/budget_ledger.dart' show BudgetLedger;
import 'bridge_call_recorder.dart';

/// Re-exposes the memory primitive set to d4rt procedure scripts.
///
/// Mirrors the memory rows of `tom_brain_procedure_prototype_specification.md`
/// § 5.1: `recall`, `classify`, `persist`, `edge`, `propose_node_type`,
/// and the seven `stack.*` operations. Each method delegates to the wrapped
/// [TomBrainMemoryClient] and converts between d4rt primitives and the
/// memory domain types.
class MemoryBridge {
  /// The interface-boundary memory client every method delegates to
  /// (PE-10). Injected by the host (C.16).
  final TomBrainMemoryClient client;

  /// Per-run recording hook (E.3.2). `null` on the shared template bridge
  /// the engine is constructed with; the engine binds a per-run instance to
  /// the active recorder so every effect call lands on that run's trail and
  /// folds into its effort tally. Not part of the d4rt-facing constructor
  /// surface — a procedure script only ever sees the injected instance and
  /// calls its methods, it never constructs the bridge.
  final BridgeCallRecorder? _onCall;

  /// Per-run budget ledger (PE-8). `null` on the shared template bridge and
  /// whenever the run's header budget enforces no count/spend cap (a
  /// wall-clock-only budget); the engine binds a per-run instance over the
  /// run's header budget otherwise. When wired, every primitive call is
  /// gated through [BudgetLedger.check] before its side effect and folded
  /// into the ledger's tally after — a call that would exceed an applicable
  /// cap throws `ProcedureBudgetExceeded` *before* the effect runs.
  final BudgetLedger? _budget;

  /// The cognitive-agent identity this run writes under, or `null` for a
  /// non-agent run (PE-10 / memory § 9). When set, every write this bridge
  /// issues carries it as the write's [Scope.agentName], so the memory
  /// store's `AgentRegistry` confines the write to the agent's declared
  /// scopes and rejects an out-of-scope write with `AgentScopeViolation`.
  /// A `null` agentName leaves writes unscoped — the user-facing procedures
  /// (`answer_with_memory_v1`) run this way. The engine threads it from the
  /// run's procedure binding; a dream/cognitive procedure run binds its
  /// agent id, an ordinary run binds `null`.
  final String? agentName;

  /// Wraps [client]. The host constructs this natively and registers the
  /// instance with the d4rt runtime. [onCall], when supplied, records each
  /// completed primitive call against the issuing run (E.3.2). [budget], when
  /// supplied, enforces the run's procedure-header budget (PE-8). [agentName],
  /// when supplied, scopes every write this bridge issues to that registered
  /// cognitive agent (memory § 9).
  MemoryBridge(
    this.client, {
    BridgeCallRecorder? onCall,
    BudgetLedger? budget,
    this.agentName,
  })  : _onCall = onCall,
        _budget = budget;

  /// Delegates to [body], gating it through the budget ledger and recording
  /// it on the run trail when those hooks are wired.
  ///
  /// [BudgetLedger.check] runs *before* [body], so a call that would exceed
  /// an applicable budget throws `ProcedureBudgetExceeded` and the side effect
  /// never happens. After [body] settles, the call is charged to the ledger
  /// and recorded (name [primitive], argument map [input], the flattened
  /// [resultOf] of the value, the measured wall-clock cost). With neither
  /// hook wired the call is a straight delegate with zero overhead. A throwing
  /// [body] — or a budget refusal — propagates without a recording: a failed
  /// or refused call is not a recorded successful call; the engine records the
  /// crash / refusal on its own path.
  Future<T> _record<T>(
    String primitive,
    Map<String, Object?> input,
    Future<T> Function() body, {
    required Map<String, Object?> Function(T value) resultOf,
  }) async {
    final onCall = _onCall;
    final budget = _budget;
    if (onCall == null && budget == null) return body();
    budget?.check(primitive);
    final watch = Stopwatch()..start();
    final value = await body();
    watch.stop();
    final result = resultOf(value);
    budget?.charge(primitive, result: result);
    if (onCall != null) {
      await onCall(primitive, input, result,
          elapsedMs: watch.elapsedMilliseconds);
    }
    return value;
  }

  /// Void counterpart of [_record] for primitives that return nothing:
  /// they record an empty result map (only the fact and the cost of the
  /// call), never a return payload. Same budget gate as [_record].
  Future<void> _recordVoid(
    String primitive,
    Map<String, Object?> input,
    Future<void> Function() body,
  ) async {
    final onCall = _onCall;
    final budget = _budget;
    if (onCall == null && budget == null) return body();
    budget?.check(primitive);
    final watch = Stopwatch()..start();
    await body();
    watch.stop();
    budget?.charge(primitive);
    if (onCall != null) {
      await onCall(primitive, input, _noResult,
          elapsedMs: watch.elapsedMilliseconds);
    }
  }

  /// The empty result map void primitives record (they carry no return
  /// payload, only the fact and the cost of the call).
  static const Map<String, Object?> _noResult = <String, Object?>{};

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
  }) =>
      _record<Map<String, Object?>>(
        'recall',
        <String, Object?>{'text': text, 'modes': modes, 'k': k},
        () async {
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
        },
        resultOf: (value) => value,
      );

  // ── classify ────────────────────────────────────────────────────

  /// Classifies [embedding] against the per-key centroids for [target]
  /// (memory § 7.2; spec § 5.1). This is the LLM-free, centroid-distance
  /// path — memory measures cosine similarity to each known centroid and
  /// returns the best match together with the confidence / margin band.
  ///
  /// [target] is the centroid family to compare against by wire name
  /// (`nodeType` or `procedure`); it defaults to `nodeType`. The returned
  /// map mirrors [ClassificationResult]:
  ///
  /// ```
  /// {
  ///   'decision': 'confident' | 'uncertain' | 'unknown',
  ///   'bestMatch': String?,        // null on the cold-start `unknown`
  ///   'bestSimilarity': double,    // 0.0 when no centroid matched
  ///   'secondSimilarity': double,  // 0.0 when there is no runner-up
  /// }
  /// ```
  ///
  /// A `'unknown'` decision is the spec's true cold-classification
  /// signal: the input sits far from every existing centroid (below
  /// `minConfidence`) **or** no centroid for [target] exists yet (cold
  /// start). `answer_with_memory_v1` reads exactly this to fire its
  /// curiosity / interest path, replacing the earlier empty-recall proxy.
  Future<Map<String, Object?>> classify(
    List<double> embedding, {
    String target = 'nodeType',
  }) =>
      _record<Map<String, Object?>>(
        'classify',
        <String, Object?>{'target': target},
        () async {
          final result = await client.classify(
            Vec.fromList(embedding),
            target: ClassificationTarget.values.byName(target),
          );
          return <String, Object?>{
            'decision': result.decision.name,
            'bestMatch': result.bestMatch,
            'bestSimilarity': result.bestSimilarity,
            'secondSimilarity': result.secondSimilarity,
          };
        },
        resultOf: (value) => value,
      );

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
  }) =>
      _record<String>(
        'persist',
        <String, Object?>{'typeName': typeName, 'values': values},
        () async {
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
              agentName: agentName,
            ),
          );
          return id.value;
        },
        resultOf: (id) => <String, Object?>{'id': id},
      );

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
  }) =>
      _record<String>(
        'edge',
        <String, Object?>{'from': from, 'type': type, 'to': to},
        () async {
          final id = await client.edge(
            NodeId.fromString(from),
            EdgeType.fromWireName(type),
            NodeId.fromString(to),
            scope: Scope(
              producer: producer,
              idempotencyKey: idempotencyKey,
              causedBy: causedBy,
              runId: runId,
              agentName: agentName,
            ),
            weight: weight,
            attrs: attrs,
          );
          return id.value;
        },
        resultOf: (id) => <String, Object?>{'id': id},
      );

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
  Future<void> proposeNodeType(Map<String, Object?> decl) => _recordVoid(
        'proposeNodeType',
        <String, Object?>{'decl': decl},
        () => client.registerNodeType(_buildNodeTypeDecl(decl)),
      );

  // ── stack.* ─────────────────────────────────────────────────────

  /// `stack.list` — summary row per stack.
  Future<List<Map<String, Object?>>> stackList() =>
      _record<List<Map<String, Object?>>>(
        'stackList',
        _noResult,
        () async {
          final summaries = await client.stacks.list();
          return summaries.map(_summaryToMap).toList();
        },
        resultOf: (entries) => <String, Object?>{'entries': entries},
      );

  /// `stack.create` — creates a non-bootstrap stack from a primitive
  /// declaration map (see [_buildStackDecl] for the supported shape).
  Future<void> stackCreate(Map<String, Object?> decl) => _recordVoid(
        'stackCreate',
        <String, Object?>{'decl': decl},
        () => client.stacks.create(_buildStackDecl(decl)),
      );

  /// `stack.push` — atomically pushes [nodeId] onto [name]. Returns the
  /// new stack-entry id string.
  Future<String> stackPush(
    String name,
    String nodeId, {
    double priority = 0.0,
    Map<String, Object?>? attrs,
    String? producer,
    String? runId,
  }) =>
      _record<String>(
        'stackPush',
        <String, Object?>{
          'name': name,
          'nodeId': nodeId,
          'priority': priority,
        },
        () async {
          final id = await client.stacks.push(
            name,
            NodeId.fromString(nodeId),
            priority: priority,
            attrs: attrs,
            scope: producer == null
                ? null
                : Scope(producer: producer, runId: runId, agentName: agentName),
          );
          return id.value;
        },
        resultOf: (id) => <String, Object?>{'id': id},
      );

  /// `stack.peek` — top-[k] read honouring the stack's priority policy.
  Future<List<Map<String, Object?>>> stackPeek(
    String name, {
    int k = 16,
  }) =>
      _record<List<Map<String, Object?>>>(
        'stackPeek',
        <String, Object?>{'name': name, 'k': k},
        () async {
          final entries = await client.stacks.peek(name, k: k);
          return entries.map(_entryToMap).toList();
        },
        resultOf: (entries) => <String, Object?>{'entries': entries},
      );

  /// `stack.pop` — atomically pops the top entry, or `null` when empty.
  Future<Map<String, Object?>?> stackPop(String name) =>
      _record<Map<String, Object?>?>(
        'stackPop',
        <String, Object?>{'name': name},
        () async {
          final entry = await client.stacks.pop(name);
          return entry == null ? null : _entryToMap(entry);
        },
        resultOf: (entry) => entry ?? _noResult,
      );

  /// `stack.update` — updates priority / status / attrs of an entry.
  /// [status] is a [StackEntryStatus] name (`active` / `archived`).
  Future<void> stackUpdate(
    String name,
    String nodeId, {
    double? priority,
    String? status,
    Map<String, Object?>? attrs,
  }) =>
      _recordVoid(
        'stackUpdate',
        <String, Object?>{'name': name, 'nodeId': nodeId},
        () => client.stacks.update(
          name,
          NodeId.fromString(nodeId),
          priority: priority,
          status:
              status == null ? null : StackEntryStatus.values.byName(status),
          attrs: attrs,
        ),
      );

  /// `stack.remove` — removes the entry's membership; the node stays.
  Future<void> stackRemove(String name, String nodeId) => _recordVoid(
        'stackRemove',
        <String, Object?>{'name': name, 'nodeId': nodeId},
        () => client.stacks.remove(name, NodeId.fromString(nodeId)),
      );

  // ── demote ──────────────────────────────────────────────────────

  /// Demotes a node — hides it from retrieval, keeps it addressable by
  /// id (memory § 9.5). Reversible. [reason] is the [DemotionReason] wire
  /// name (`retentionHorizon`, `prunerDecision`, `supersession`,
  /// `migrationArchive`, `operatorOverride`).
  ///
  /// The `Pruner` (`dream_prune_v1`) and `Reconsolidator`
  /// (`dream_reconsolidate_v1`) are the cognitive callers — a Pruner
  /// "cannot create new nodes, only demote". `demote` carries no agent
  /// scope: the store's `AgentRegistry` guards node / edge / stack *writes*
  /// (graph mutations), and demotion mutates lifecycle status, not the
  /// graph, so it passes through scope enforcement. The Pruner's
  /// *inability* to create — its empty node write-scope set — is what the
  /// registry enforces; demotion is the one mutation that remains open to
  /// it.
  Future<void> demote(String nodeId, String reason) => _recordVoid(
        'demote',
        <String, Object?>{'nodeId': nodeId, 'reason': reason},
        () => client.demote(
          NodeId.fromString(nodeId),
          DemotionReason.values.byName(reason),
        ),
      );

  // ── update_centroid ─────────────────────────────────────────────

  /// Replaces the centroid for [forKey] (a node-type name or procedure id)
  /// with [centroid] (memory § 7.3). `dream_recentroid_v1` is the only
  /// normal-operation writer — memory never auto-recomputes.
  Future<void> updateCentroid(String forKey, List<double> centroid) =>
      _recordVoid(
        'updateCentroid',
        <String, Object?>{'forKey': forKey},
        () => client.updateCentroid(forKey, Vec.fromList(centroid)),
      );

  // ── find_uncertain ──────────────────────────────────────────────

  /// Returns the ids of nodes whose best similarity against the centroid
  /// for [forKey] falls in `[low, high]` (memory § 7.4) — the borderline
  /// batch `dream_recentroid_v1` sends to an LLM for re-classification.
  /// [limit] caps the returned id count.
  Future<List<String>> findUncertain(
    String forKey, {
    required double low,
    required double high,
    int limit = 200,
  }) =>
      _record<List<String>>(
        'findUncertain',
        <String, Object?>{
          'forKey': forKey,
          'low': low,
          'high': high,
          'limit': limit,
        },
        () async {
          final ids = await client.findUncertain(
            forKey: forKey,
            low: low,
            high: high,
            limit: limit,
          );
          return ids.map((id) => id.value).toList();
        },
        resultOf: (ids) => <String, Object?>{'ids': ids},
      );

  // ── primitive ⇄ domain conversions ──────────────────────────────

  /// Formats [dt] as the canonical Tom Brain wire timestamp (E.3.8).
  ///
  /// Routes through [BrainTime] rather than calling `toIso8601String()` on
  /// the raw `DateTime` so the d4rt boundary always emits the same UTC
  /// `…Z` form the rest of the stack uses. `.toUtc()` is the named
  /// conversion [BrainTime.fromDateTime] requires; a local-time instant is
  /// normalised here instead of leaking a zone-offset string to scripts.
  static String _isoUtc(DateTime dt) =>
      BrainTime.fromDateTime(dt.toUtc()).toIso8601String();

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
        'createdAt': _isoUtc(node.createdAt),
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
        'pushedAt': _isoUtc(e.pushedAt),
        'status': e.status.name,
        'attrs': e.attrs,
      };

  /// Descriptive-`FormatException` reader for the d4rt-supplied declaration
  /// maps below. d4rt scripts are an untrusted boundary (PE-1): a malformed
  /// field must fail with a located, engineer-readable error naming the
  /// offending field, never an opaque `TypeError` from a bare `as` cast.
  static const MapFieldReader _reader = MapFieldReader(FormatException.new);

  static NodeTypeDecl _buildNodeTypeDecl(Map<String, Object?> decl) {
    final typeName =
        _reader.optionalString(decl, 'typeName', 'proposeNodeType.typeName');
    if (typeName == null || typeName.isEmpty) {
      throw const FormatException(
        'proposeNodeType requires a non-empty "typeName".',
      );
    }
    final versionValue =
        _reader.optionalNum(decl, 'version', 'proposeNodeType.version');
    final version = versionValue == null
        ? BrainVersion.initial
        : BrainVersion.fromInt(versionValue.toInt());

    final schemaRaw =
        _reader.optionalMap(decl, 'schema', 'proposeNodeType.schema');
    final schema = <String, FieldSpec>{};
    if (schemaRaw != null) {
      for (final entry in schemaRaw.entries) {
        final fieldName =
            _reader.stringValue(entry.key, 'proposeNodeType.schema key')!;
        final fieldPath = 'proposeNodeType.schema.$fieldName';
        schema[fieldName] = _buildFieldSpec(
          fieldName,
          _reader.mapValue(entry.value, fieldPath)!,
          fieldPath,
        );
      }
    }

    return NodeTypeDecl(
      typeName: typeName,
      version: version,
      schema: schema,
      embeddingPolicy: EmbeddingPolicy.none,
      indexPolicy: const IndexPolicy(),
      retentionPolicy: const RetentionPolicy(),
      allowedOutgoing: _parseEdgeSet(
          decl, 'allowedOutgoing', 'proposeNodeType.allowedOutgoing'),
      allowedIncoming: _parseEdgeSet(
          decl, 'allowedIncoming', 'proposeNodeType.allowedIncoming'),
    );
  }

  static FieldSpec _buildFieldSpec(
    String name,
    Map<Object?, Object?> spec,
    String path,
  ) {
    return FieldSpec(
      name: name,
      type: FieldType.values
          .byName(_reader.optionalString(spec, 'type', '$path.type') ?? 'string'),
      nullable: _reader.optionalBool(spec, 'nullable', '$path.nullable') ?? false,
      ftsEligible:
          _reader.optionalBool(spec, 'ftsEligible', '$path.ftsEligible') ?? false,
      vectorEligible:
          _reader.optionalBool(spec, 'vectorEligible', '$path.vectorEligible') ??
              false,
    );
  }

  static Set<EdgeType> _parseEdgeSet(
    Map<Object?, Object?> decl,
    String key,
    String path,
  ) {
    final raw = _reader.optionalList(decl, key, path);
    if (raw == null) return const <EdgeType>{};
    return raw
        .map((e) => EdgeType.fromWireName(_reader.stringValue(e, '$path[]')!))
        .toSet();
  }

  static StackDecl _buildStackDecl(Map<String, Object?> decl) {
    final name = _reader.optionalString(decl, 'name', 'stackCreate.name');
    if (name == null || name.isEmpty) {
      throw const FormatException(
        'stackCreate requires a non-empty "name".',
      );
    }
    return StackDecl(
      name: name,
      summary: _reader.optionalString(decl, 'summary', 'stackCreate.summary') ?? '',
      entryNodeType:
          _reader.optionalString(decl, 'entryNodeType', 'stackCreate.entryNodeType') ??
              'Node',
      harvesterHook:
          _reader.optionalString(decl, 'harvesterHook', 'stackCreate.harvesterHook'),
      policy: _buildStackPolicy(
        _reader.optionalMap(decl, 'policy', 'stackCreate.policy'),
        'stackCreate.policy',
      ),
    );
  }

  static StackPolicy _buildStackPolicy(
    Map<Object?, Object?>? policy,
    String path,
  ) {
    if (policy == null) {
      return const StackPolicy(
        priority: PriorityPolicyKind.fifo,
        retention: RetentionPolicyKind.unbounded,
      );
    }
    return StackPolicy(
      priority: PriorityPolicyKind.values.byName(
          _reader.optionalString(policy, 'priority', '$path.priority') ?? 'fifo'),
      retention: RetentionPolicyKind.values.byName(
          _reader.optionalString(policy, 'retention', '$path.retention') ??
              'unbounded'),
      maxCount: _reader.optionalNum(policy, 'maxCount', '$path.maxCount')?.toInt(),
      maxAgeMs: _reader.optionalNum(policy, 'maxAgeMs', '$path.maxAgeMs')?.toInt(),
      halflifeMs:
          _reader.optionalNum(policy, 'halflifeMs', '$path.halflifeMs')?.toInt(),
    );
  }
}
