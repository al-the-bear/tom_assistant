// A.77 — MCP tool registrations for the seven v1 tools in
// `memory_specification.md` § 3.2.
//
// The seven tools are the read-only retrieval surface plus the one
// constrained write (`memory.persistNote`). Each tool is a thin
// marshalling shim: parse arguments from the JSON-RPC `arguments`
// map, call into the in-process `TomBrainMemory` Dart API, and encode
// the result as a `CallToolResult` carrying a single `TextContent`
// whose `text` is JSON.
//
// Design notes:
//
//   - The wrappers are intentionally one-call-per-primitive. Spec
//     § 3.3 says "the bridge is one-call-per-primitive; it does *not*
//     add caching, batching, or logic" — the same rule applies here.
//   - Tool-domain errors (forbidden NodeType, malformed input) flow
//     through `CallToolResult(isError: true, ...)` per the dart_mcp
//     guidance. Transport-level failures (the channel breaks)
//     surface as JSON-RPC errors, which `ToolsSupport.callTool`
//     re-throws unchanged.
//   - Spec § 3.2 says writes are "tagged with the MCP caller's
//     identity". When the server has an authenticator and the
//     handshake produced a principal, the producer is
//     `mcp:<principal.user.username>`; otherwise `mcp:anonymous`. See
//     Q-A.77.3 for the chosen format.
//
// JSON shapes (canonical for the v1 wire surface):
//
//   Node:
//     {
//       "id": "n_<ULID>",
//       "typeName": "Question",
//       "values": {...},
//       "embedding": [..] | null,
//       "createdAt": "2026-05-31T12:34:56.789Z",
//       "status": "active" | "demoted" | "archived" | "forgotten"
//     }
//
//   Edge:
//     {
//       "id": "e_<ULID>",
//       "from": "n_<ULID>",
//       "type": "mentions",
//       "to": "n_<ULID>",
//       "weight": 1.0,
//       "attrs": {...}
//     }
//
//   StackSummary:
//     { "name": "...", "size": N, "topPriority": F, "bootstrap": bool }
//
//   StackEntry:
//     {
//       "id": "se_<ULID>", "stackName": "...", "nodeId": "n_<ULID>",
//       "priority": F, "pushedAt": "...", "status": "active"|"archived",
//       "attrs": {...}
//     }
//
//   ClassificationResult:
//     {
//       "decision": "confident" | "uncertain" | "unknown",
//       "bestMatch": "..." | null,
//       "bestSimilarity": F,
//       "secondSimilarity": F
//     }
//
//   RecallResult:
//     {
//       "nodes": [<Node>, ...],
//       "report": {
//         "candidatesPerMode": {"bm25": 5, "vector": 0, ...},
//         "fusionStrategy": "rrf",
//         "diversityStrategy": "mmr",
//         "diversityLambda": 0.7 | null,
//         "elapsedMs": 12,
//         "embeddingsCallouts": 0,
//         "reRankInvoked": false,
//         "degraded": false
//       }
//     }
//
//   persistNote success:
//     { "nodeId": "n_<ULID>" }
//
//   error (any tool): CallToolResult.isError == true, content[0] is a
//   TextContent with a human-readable message.

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeId, Vec;
import 'package:tom_core_kernel/tom_core_kernel.dart' show TomPrincipal;

import '../api/scope.dart';
import '../api/tom_brain_memory.dart';
import '../classification/classification_result.dart';
import '../edges/edge.dart';
import '../edges/edge_type.dart';
import '../nodes/node.dart';
import '../retrieval/recall_query.dart';
import '../retrieval/recall_result.dart';
import '../stacks/stack_types.dart';
import 'mcp_write_forbidden.dart';

/// Resolves the bearer-authenticated principal for the current MCP
/// connection. The `TomBrainMemoryMcpServer` exposes this via its
/// `principal` getter; we accept a callback so the wiring stays
/// testable without coupling the tool helpers to the server class.
typedef PrincipalResolver = TomPrincipal? Function();

/// Registers the seven v1 tools (memory spec § 3.2) on [server] with
/// implementations that forward to [memory].
///
/// Producer attribution on `memory.persistNote` reads the principal
/// from [resolvePrincipal] at call time (per-connection). When the
/// resolver returns `null` the producer falls back to
/// `mcp:anonymous`.
///
/// Called once per `TomBrainMemoryMcpServer` construction (from the
/// server constructor body when the optional `memory` parameter is
/// non-null). The seven tools are registered in the order they appear
/// in the spec table — listTools output mirrors that ordering.
void registerMemoryTools(
  ToolsSupport server,
  TomBrainMemory memory, {
  required PrincipalResolver resolvePrincipal,
}) {
  server.registerTool(
    _recallTool,
    (request) => _runRecall(request, memory),
  );
  server.registerTool(_getTool, (request) => _runGet(request, memory));
  server.registerTool(
    _edgesOfTool,
    (request) => _runEdgesOf(request, memory),
  );
  server.registerTool(
    _stackListTool,
    (request) => _runStackList(request, memory),
  );
  server.registerTool(
    _stackPeekTool,
    (request) => _runStackPeek(request, memory),
  );
  server.registerTool(
    _classifyTool,
    (request) => _runClassify(request, memory),
  );
  server.registerTool(
    _persistNoteTool,
    (request) => _runPersistNote(request, memory, resolvePrincipal),
  );
}

// ─── Tool declarations ────────────────────────────────────────────

final _recallTool = Tool(
  name: 'memory.recall',
  description:
      'Four-mode retrieval over the property graph (BM25, vector, '
      'graph-walk, symbolic). Returns the fused-and-diversified node '
      'list with a per-mode cost report.',
  annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
  inputSchema: ObjectSchema(
    properties: {
      'text': Schema.string(
        description: 'Query text for BM25 and (when no embedding is supplied) '
            'vector mode.',
      ),
      'embedding': Schema.list(
        description: 'Pre-computed query embedding for vector mode.',
        items: Schema.num(),
      ),
      'seeds': Schema.list(
        description: 'Seed node ids for graph-walk mode.',
        items: Schema.string(),
      ),
      'modes': Schema.list(
        description:
            'Subset of {bm25, vector, graphWalk, symbolic}. Default: bm25.',
        items: Schema.string(),
      ),
      'k': Schema.int(
        description: 'Post-fusion cap on the returned node list.',
        minimum: 1,
      ),
      'wallClockMs': Schema.int(
        description: 'Wall-clock budget in milliseconds.',
        minimum: 1,
      ),
    },
    additionalProperties: false,
  ),
);

final _getTool = Tool(
  name: 'memory.get',
  description:
      'Bulk fetch nodes by id. Missing ids are elided; demoted and '
      'archived nodes are returned with status reflecting lifecycle.',
  annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
  inputSchema: ObjectSchema(
    properties: {
      'ids': Schema.list(
        description: 'Node ids (canonical "n_<ULID>" form).',
        items: Schema.string(),
      ),
    },
    required: ['ids'],
    additionalProperties: false,
  ),
);

final _edgesOfTool = Tool(
  name: 'memory.edgesOf',
  description:
      'Returns edges touching the given node, optionally filtered by '
      'direction and edge types.',
  annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
  inputSchema: ObjectSchema(
    properties: {
      'id': Schema.string(description: 'Node id.'),
      'direction': Schema.string(
        description: 'One of "outgoing", "incoming", "both" (default).',
      ),
      'types': Schema.list(
        description:
            'Optional edge-type filter (wire names from the closed '
            '12-edge alphabet).',
        items: Schema.string(),
      ),
    },
    required: ['id'],
    additionalProperties: false,
  ),
);

final _stackListTool = Tool(
  name: 'memory.stack.list',
  description: 'Returns the stack inventory: name, size, top priority, '
      'and bootstrap flag per stack.',
  annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
  inputSchema: ObjectSchema(
    properties: {},
    additionalProperties: false,
  ),
);

final _stackPeekTool = Tool(
  name: 'memory.stack.peek',
  description: 'Read-only top-K view of a stack, honouring the stack\'s '
      'current priority policy.',
  annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
  inputSchema: ObjectSchema(
    properties: {
      'name': Schema.string(description: 'Stack name.'),
      'k': Schema.int(
        description: 'How many entries to return. Default 16.',
        minimum: 1,
      ),
    },
    required: ['name'],
    additionalProperties: false,
  ),
);

final _classifyTool = Tool(
  name: 'memory.classify',
  description: 'LLM-independent centroid classification. Returns the '
      'best-matching key and a decision band.',
  annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
  inputSchema: ObjectSchema(
    properties: {
      'embedding': Schema.list(
        description: 'Input embedding (float list).',
        items: Schema.num(),
      ),
      'target': Schema.string(
        description: 'One of "nodeType" (default) or "procedure".',
      ),
    },
    required: ['embedding'],
    additionalProperties: false,
  ),
);

final _persistNoteTool = Tool(
  name: 'memory.persistNote',
  description:
      'Constrained persist for MCP callers. NodeType MUST be one of '
      '{Claim, Question, AutomationIdea, InterestItem}; any other '
      'type is rejected as McpWriteForbidden. Writes are tagged with '
      'the MCP caller\'s identity (anonymous when no authenticator).',
  annotations: ToolAnnotations(
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false,
  ),
  inputSchema: ObjectSchema(
    properties: {
      'typeName': Schema.string(
        description:
            'NodeType. Must be Claim, Question, AutomationIdea, or '
            'InterestItem.',
      ),
      'values': ObjectSchema(
        description: 'Field values keyed by field name.',
        properties: {},
      ),
      'embedding': Schema.list(
        description: 'Optional pre-computed embedding.',
        items: Schema.num(),
      ),
      'idempotencyKey': Schema.string(
        description:
            'Optional idempotency key. A re-call with the same key is '
            'a no-op that returns the original NodeId.',
      ),
    },
    required: ['typeName', 'values'],
    additionalProperties: false,
  ),
);

// ─── Tool implementations ─────────────────────────────────────────

Future<CallToolResult> _runRecall(
  CallToolRequest request,
  TomBrainMemory memory,
) async {
  final args = request.arguments ?? const <String, Object?>{};
  final query = _parseRecallQuery(args);
  final result = await memory.recall(query);
  return _ok(_encodeRecallResult(result));
}

Future<CallToolResult> _runGet(
  CallToolRequest request,
  TomBrainMemory memory,
) async {
  final args = request.arguments ?? const <String, Object?>{};
  final idsRaw = args['ids'];
  if (idsRaw is! List) {
    return _err('Argument "ids" must be a list of node ids.');
  }
  final ids = <NodeId>[];
  for (final raw in idsRaw) {
    if (raw is! String) {
      return _err('Every element of "ids" must be a string node id.');
    }
    try {
      ids.add(NodeId.fromString(raw));
    } on FormatException catch (e) {
      return _err('Invalid NodeId "$raw": ${e.message}');
    }
  }
  final nodes = await memory.getMany(ids);
  return _ok({'nodes': nodes.map(_encodeNode).toList()});
}

Future<CallToolResult> _runEdgesOf(
  CallToolRequest request,
  TomBrainMemory memory,
) async {
  final args = request.arguments ?? const <String, Object?>{};
  final idRaw = args['id'];
  if (idRaw is! String) {
    return _err('Argument "id" is required and must be a node id string.');
  }
  final NodeId id;
  try {
    id = NodeId.fromString(idRaw);
  } on FormatException catch (e) {
    return _err('Invalid NodeId "$idRaw": ${e.message}');
  }
  final direction = _parseDirection(args['direction']);
  if (direction == null) {
    return _err(
      'Argument "direction" must be one of "outgoing", "incoming", "both".',
    );
  }
  Set<EdgeType>? types;
  final typesRaw = args['types'];
  if (typesRaw != null) {
    if (typesRaw is! List) {
      return _err('Argument "types" must be a list of edge-type wire names.');
    }
    final parsed = <EdgeType>{};
    for (final raw in typesRaw) {
      if (raw is! String) {
        return _err('Every element of "types" must be a string.');
      }
      try {
        parsed.add(EdgeType.fromWireName(raw));
      } on FormatException catch (e) {
        return _err('Invalid EdgeType "$raw": ${e.message}');
      }
    }
    types = parsed;
  }
  final edges = await memory.edgesOf(id, direction: direction, types: types);
  return _ok({'edges': edges.map(_encodeEdge).toList()});
}

Future<CallToolResult> _runStackList(
  CallToolRequest request,
  TomBrainMemory memory,
) async {
  final summaries = await memory.stacks.list();
  return _ok({'stacks': summaries.map(_encodeStackSummary).toList()});
}

Future<CallToolResult> _runStackPeek(
  CallToolRequest request,
  TomBrainMemory memory,
) async {
  final args = request.arguments ?? const <String, Object?>{};
  final nameRaw = args['name'];
  if (nameRaw is! String) {
    return _err('Argument "name" is required and must be a string.');
  }
  final k = (args['k'] as int?) ?? 16;
  final entries = await memory.stacks.peek(nameRaw, k: k);
  return _ok({'entries': entries.map(_encodeStackEntry).toList()});
}

Future<CallToolResult> _runClassify(
  CallToolRequest request,
  TomBrainMemory memory,
) async {
  final args = request.arguments ?? const <String, Object?>{};
  final embedding = _parseEmbedding(args['embedding']);
  if (embedding == null) {
    return _err(
      'Argument "embedding" must be a non-empty list of numbers.',
    );
  }
  final targetName = (args['target'] as String?) ?? 'nodeType';
  final ClassificationTarget target;
  switch (targetName) {
    case 'nodeType':
      target = ClassificationTarget.nodeType;
    case 'procedure':
      target = ClassificationTarget.procedure;
    default:
      return _err(
        'Argument "target" must be "nodeType" or "procedure"; got "$targetName".',
      );
  }
  final result = await memory.classify(embedding, target: target);
  return _ok(_encodeClassification(result));
}

Future<CallToolResult> _runPersistNote(
  CallToolRequest request,
  TomBrainMemory memory,
  PrincipalResolver resolvePrincipal,
) async {
  final args = request.arguments ?? const <String, Object?>{};
  final typeName = args['typeName'];
  if (typeName is! String || typeName.isEmpty) {
    return _err('Argument "typeName" is required and must be a non-empty string.');
  }
  if (!allowedPersistNoteTypeNames.contains(typeName)) {
    // Translate the McpWriteForbidden into a tool-domain isError —
    // see Q-A.77.2 for the rationale (LLMs need to see the cause to
    // self-correct).
    final ex = McpWriteForbidden(requestedTypeName: typeName);
    return _err(ex.toString());
  }
  final valuesRaw = args['values'];
  if (valuesRaw is! Map) {
    return _err('Argument "values" is required and must be an object.');
  }
  final values = valuesRaw.cast<String, Object?>();
  final embedding = args.containsKey('embedding')
      ? _parseEmbedding(args['embedding'])
      : null;
  if (args.containsKey('embedding') && embedding == null) {
    return _err('Argument "embedding" must be a non-empty list of numbers.');
  }
  final idempotencyKey = args['idempotencyKey'] as String?;

  final principal = resolvePrincipal();
  final producer = principal != null
      ? 'mcp:${principal.user.username}'
      : 'mcp:anonymous';

  final draft = NodeDraft(
    typeName: typeName,
    values: values,
    embedding: embedding,
  );
  final scope = Scope(
    producer: producer,
    idempotencyKey: idempotencyKey,
  );
  final nodeId = await memory.persist(draft, scope: scope);
  return _ok({'nodeId': nodeId.value});
}

// ─── Argument parsers ─────────────────────────────────────────────

RecallQuery _parseRecallQuery(Map<String, Object?> args) {
  final text = args['text'] as String?;
  final embedding = args.containsKey('embedding')
      ? _parseEmbedding(args['embedding'])
      : null;
  Set<NodeId>? seeds;
  final seedsRaw = args['seeds'];
  if (seedsRaw is List) {
    final parsed = <NodeId>{};
    for (final raw in seedsRaw) {
      if (raw is String) {
        try {
          parsed.add(NodeId.fromString(raw));
        } on FormatException {
          // Skip malformed seeds rather than failing the whole call
          // — they reflect upstream drift, not a tool-shape error.
        }
      }
    }
    if (parsed.isNotEmpty) seeds = parsed;
  }
  final modes = <RecallMode>{};
  final modesRaw = args['modes'];
  if (modesRaw is List) {
    for (final raw in modesRaw) {
      final mode = _parseMode(raw);
      if (mode != null) modes.add(mode);
    }
  }
  if (modes.isEmpty) {
    modes.add(RecallMode.bm25);
  }
  final k = (args['k'] as int?) ?? 20;
  final wallClockMs = (args['wallClockMs'] as int?) ?? 120;
  return RecallQuery(
    modes: modes,
    text: text,
    embedding: embedding,
    seeds: seeds,
    k: k,
    budget: RecallBudget(wallClockMs: wallClockMs),
  );
}

RecallMode? _parseMode(Object? raw) {
  if (raw is! String) return null;
  switch (raw) {
    case 'bm25':
      return RecallMode.bm25;
    case 'vector':
      return RecallMode.vector;
    case 'graphWalk':
      return RecallMode.graphWalk;
    case 'symbolic':
      return RecallMode.symbolic;
  }
  return null;
}

EdgeDirection? _parseDirection(Object? raw) {
  if (raw == null) return EdgeDirection.both;
  if (raw is! String) return null;
  switch (raw) {
    case 'outgoing':
      return EdgeDirection.outgoing;
    case 'incoming':
      return EdgeDirection.incoming;
    case 'both':
      return EdgeDirection.both;
  }
  return null;
}

Vec? _parseEmbedding(Object? raw) {
  if (raw is! List || raw.isEmpty) return null;
  final values = <double>[];
  for (final el in raw) {
    if (el is num) {
      values.add(el.toDouble());
    } else {
      return null;
    }
  }
  return Vec.fromList(values);
}

// ─── Result encoders ──────────────────────────────────────────────

Map<String, Object?> _encodeNode(Node node) => {
      'id': node.id.value,
      'typeName': node.typeName,
      'values': node.values,
      'embedding': node.embedding?.values.toList(),
      'createdAt': node.createdAt.toUtc().toIso8601String(),
      'status': node.status.name,
    };

Map<String, Object?> _encodeEdge(Edge edge) => {
      'id': edge.id.value,
      'from': edge.from.value,
      'type': edge.type.wireName,
      'to': edge.to.value,
      'weight': edge.weight,
      'attrs': edge.attrs,
    };

Map<String, Object?> _encodeStackSummary(StackSummary s) => {
      'name': s.name,
      'size': s.size,
      'topPriority': s.topPriority,
      'bootstrap': s.bootstrap,
    };

Map<String, Object?> _encodeStackEntry(StackEntry e) => {
      'id': e.id.value,
      'stackName': e.stackName,
      'nodeId': e.nodeId.value,
      'priority': e.priority,
      'pushedAt': e.pushedAt.toUtc().toIso8601String(),
      'status': e.status.name,
      'attrs': e.attrs,
    };

Map<String, Object?> _encodeClassification(ClassificationResult r) => {
      'decision': r.decision.name,
      'bestMatch': r.bestMatch,
      'bestSimilarity': r.bestSimilarity,
      'secondSimilarity': r.secondSimilarity,
    };

Map<String, Object?> _encodeRecallResult(RecallResult r) => {
      'nodes': r.nodes.map(_encodeNode).toList(),
      'report': {
        'candidatesPerMode': {
          for (final entry in r.report.candidatesPerMode.entries)
            entry.key.name: entry.value,
        },
        'fusionStrategy': r.report.fusionStrategy.name,
        'diversityStrategy': r.report.diversityStrategy.name,
        'diversityLambda': r.report.diversityLambda,
        'elapsedMs': r.report.elapsedMs,
        'embeddingsCallouts': r.report.embeddingsCallouts,
        'reRankInvoked': r.report.reRankInvoked,
        'degraded': r.report.degraded,
      },
    };

// ─── CallToolResult helpers ───────────────────────────────────────

CallToolResult _ok(Map<String, Object?> payload) => CallToolResult(
      content: [TextContent(text: jsonEncode(payload))],
    );

CallToolResult _err(String message) => CallToolResult(
      isError: true,
      content: [TextContent(text: message)],
    );
