// PT-5.1 — the Memory MCP read client (`prompt_tracing.md` § 5.1, § 8.4): the
// observatory's typed facade over the brain's memory MCP server. It registers
// ONLY the nine read tools (`memory_specification.md` § 3.2) and proves OBS-2
// (§ 6.2) structurally — `memory.persistNote` is named here only as the tool
// this client refuses to wire. Every method marshals its arguments to the MCP
// tool schema (`tom_brain_memory/lib/src/mcp_server/mcp_tools.dart`) and decodes
// the tool's payload into the read-only view models in `memory_nodes.dart`.
//
// The single door to memory is [_call], which asserts the tool is one of the
// nine reads before delegating to the injected [McpReadConnection]. Wiring the
// write tool into any method would route through [_call] with a name outside
// [readToolNames] — a `StateError` the OBS-2 surface test turns red on.

import 'mcp_read_connection.dart';
import 'memory_nodes.dart';

// The connection seam and its failure type are part of this client's surface —
// a consumer that holds a [MemoryReadClient] also handles [McpReadException].
export 'mcp_read_connection.dart' show McpReadConnection, McpReadException;

/// A typed, read-only client over the brain's memory MCP server. Holds no DB
/// handle (OBS-3): every memory access flows through the injected
/// [McpReadConnection], confined to the nine read tools.
final class MemoryReadClient {
  /// The connection to the brain's memory MCP server (a `dart_mcp`-backed
  /// connector in production, a fake in tests).
  final McpReadConnection connection;

  MemoryReadClient(this.connection);

  /// The nine read tools this client is allowed to call (`memory_specification.md`
  /// § 3.2). This set is the OBS-2 contract — it never contains [writeToolName].
  static const Set<String> readToolNames = <String>{
    'memory.recall',
    'memory.recall.multi',
    'memory.get',
    'memory.edgesOf',
    'memory.stack.list',
    'memory.stack.peek',
    'memory.classify',
    'memory.profiles.list',
    'memory.profile.current',
  };

  /// The one constrained write tool the memory MCP server exposes
  /// (`memory_specification.md` § 3.2). Named here only so OBS-2 can assert it
  /// is *excluded* from [readToolNames] — this client never wires it.
  static const String writeToolName = 'memory.persistNote';

  /// `memory.recall` (§ 5.4): single-seed fused-and-diversified recall. [modes]
  /// are marshalled to their wire tokens; every argument is omitted when null
  /// so the server applies its own defaults. [profile] view-scopes the read to
  /// a named profile (OBS-2: a read-only view switch, never a brain switch).
  Future<RecallResult> recall({
    String? text,
    List<double>? embedding,
    Set<RecallMode>? modes,
    int? k,
    int? wallClockMs,
    String? profile,
  }) async {
    final payload = await _call('memory.recall', <String, Object?>{
      'text': ?text,
      'embedding': ?embedding,
      if (modes != null)
        'modes': <String>[for (final m in modes) m.wireName],
      'k': ?k,
      'wallClockMs': ?wallClockMs,
      'profile': ?profile,
    });
    return RecallResult.fromJson(payload);
  }

  /// `memory.recall.multi` (§ 5.4): multi-seed recall returning per-node seed
  /// provenance. Each [RecallSeedSpec] marshals itself to the `seeds[]` shape.
  /// [profile] view-scopes the read (see [recall]).
  Future<RecallResult> recallMulti({
    required List<RecallSeedSpec> seeds,
    int? k,
    int? wallClockMs,
    String? profile,
  }) async {
    final payload = await _call('memory.recall.multi', <String, Object?>{
      'seeds': <Object?>[for (final seed in seeds) seed.toJson()],
      'k': ?k,
      'wallClockMs': ?wallClockMs,
      'profile': ?profile,
    });
    return RecallResult.fromJson(payload);
  }

  /// `memory.get` (§ 5.2): the nodes for [ids], in request order where present.
  /// [profile] view-scopes the read (see [recall]).
  Future<List<MemoryNode>> get(List<String> ids, {String? profile}) async {
    final payload = await _call('memory.get', <String, Object?>{
      'ids': ids,
      'profile': ?profile,
    });
    return _nodes(payload);
  }

  /// `memory.edgesOf` (§ 5.3): edges incident to [id]. [direction] and [types]
  /// are marshalled to their wire tokens; [types] is omitted when null (all
  /// edge types). [profile] view-scopes the read (see [recall]).
  Future<List<MemoryEdge>> edgesOf(
    String id, {
    EdgeDirection direction = EdgeDirection.both,
    Set<String>? types,
    String? profile,
  }) async {
    final payload = await _call('memory.edgesOf', <String, Object?>{
      'id': id,
      'direction': direction.wireName,
      if (types != null) 'types': types.toList(),
      'profile': ?profile,
    });
    return <MemoryEdge>[
      for (final raw in (payload['edges'] as List?) ?? const <Object?>[])
        MemoryEdge.fromJson((raw as Map).cast<String, Object?>()),
    ];
  }

  /// `memory.stack.list` (§ 5.5): the stack inventory. [profile] view-scopes the
  /// read (see [recall]).
  Future<List<MemoryStackSummary>> stackList({String? profile}) async {
    final payload = await _call('memory.stack.list', <String, Object?>{
      'profile': ?profile,
    });
    return <MemoryStackSummary>[
      for (final raw in (payload['stacks'] as List?) ?? const <Object?>[])
        MemoryStackSummary.fromJson((raw as Map).cast<String, Object?>()),
    ];
  }

  /// `memory.stack.peek` (§ 5.5): the top [k] entries of stack [name]. [profile]
  /// view-scopes the read (see [recall]).
  Future<List<MemoryStackEntry>> stackPeek(
    String name, {
    int? k,
    String? profile,
  }) async {
    final payload = await _call('memory.stack.peek', <String, Object?>{
      'name': name,
      'k': ?k,
      'profile': ?profile,
    });
    return <MemoryStackEntry>[
      for (final raw in (payload['entries'] as List?) ?? const <Object?>[])
        MemoryStackEntry.fromJson((raw as Map).cast<String, Object?>()),
    ];
  }

  /// `memory.classify` (§ 5.6): the centroid classification of [embedding].
  /// [target] is marshalled to its wire token. [profile] view-scopes the read
  /// (see [recall]).
  Future<MemoryClassification> classify(
    List<double> embedding, {
    ClassifyTarget target = ClassifyTarget.nodeType,
    String? profile,
  }) async {
    final payload = await _call('memory.classify', <String, Object?>{
      'embedding': embedding,
      'target': target.wireName,
      'profile': ?profile,
    });
    return MemoryClassification.fromJson(payload);
  }

  /// `memory.profiles.list` (§ 5.5): the named memory profiles.
  Future<List<String>> profilesList() async {
    final payload =
        await _call('memory.profiles.list', const <String, Object?>{});
    return <String>[
      for (final p in (payload['profiles'] as List?) ?? const <Object?>[])
        p as String,
    ];
  }

  /// `memory.profile.current` (§ 5.5): the active profile name, or `null` on the
  /// unprofiled root.
  Future<String?> profileCurrent() async {
    final payload =
        await _call('memory.profile.current', const <String, Object?>{});
    return payload['profile'] as String?;
  }

  /// Decodes a `{nodes: [...]}` payload into view models.
  List<MemoryNode> _nodes(Map<String, Object?> payload) => <MemoryNode>[
        for (final raw in (payload['nodes'] as List?) ?? const <Object?>[])
          MemoryNode.fromJson((raw as Map).cast<String, Object?>()),
      ];

  /// The single door to memory (OBS-2): refuses any tool outside [readToolNames]
  /// before delegating to the connection. A method wired to [writeToolName]
  /// would trip this guard — the structural proof that this client cannot write.
  Future<Map<String, Object?>> _call(
    String tool,
    Map<String, Object?> args,
  ) {
    if (!readToolNames.contains(tool)) {
      throw StateError(
        'MemoryReadClient refuses to call non-read tool "$tool" '
        '(read-only invariant OBS-2)',
      );
    }
    return connection.callTool(tool, args);
  }
}
