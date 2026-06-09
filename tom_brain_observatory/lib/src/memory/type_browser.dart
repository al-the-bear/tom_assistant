// PT-5.2 — browse-by-type composition (`prompt_tracing.md` § 5.2, § 8.4).
//
// "List all nodes of type X" is the node browser's primary entry point, but no
// v1 MCP tool serves a bulk-by-type listing (`memory_specification.md` § 3.2 —
// recorded there as the `memory.nodes.byType` candidate addition). Until that
// tool exists, this browser COMPOSES the answer from the nine read tools the
// [MemoryReadClient] exposes, never reaching past the MCP surface into the DB
// (OBS-3, `prompt_tracing.md` § 6.2):
//
//   1. recall seeded by the type name — a similarity-ranked candidate set;
//   2. node ids surfaced in prompt traces, fetched via `memory.get`;
//   3. edge traversal from the hits, fetching the neighbours via `memory.get`.
//
// The gathered nodes are filtered to the requested `typeName`, deduped by id
// (insertion order preserved), and returned as a deliberately NON-exhaustive
// result — a composition is a best-effort browse, never a completeness claim.
// Because every door is a [MemoryReadClient] read method, OBS-2 holds
// transitively: the browser cannot write or touch the DB.

import 'memory_nodes.dart';
import 'memory_read_client.dart';

/// The result of a composed browse-by-type (PT-5.2). [exhaustive] is always
/// `false`: this is a best-effort composition over the read tools, not a
/// complete listing (which awaits the `memory.nodes.byType` candidate tool,
/// `memory_specification.md` § 3.2). [sources] names the read tools that
/// contributed, in the order they were used.
final class TypeBrowseResult {
  /// The `typeName` browsed.
  final String typeName;

  /// The matching nodes, deduped by id in discovery order.
  final List<MemoryNode> nodes;

  /// Always `false` for a composed browse — never a completeness claim.
  final bool exhaustive;

  /// The read tools that contributed, in use order (`recall`, `get`, `edgesOf`).
  final List<String> sources;

  TypeBrowseResult({
    required this.typeName,
    required this.exhaustive,
    List<MemoryNode> nodes = const <MemoryNode>[],
    List<String> sources = const <String>[],
  })  : nodes = List<MemoryNode>.unmodifiable(nodes),
        sources = List<String>.unmodifiable(sources);

  /// The wire shape the backend re-serializes for the browser.
  Map<String, Object?> toJson() => <String, Object?>{
        'typeName': typeName,
        'exhaustive': exhaustive,
        'nodes': <Object?>[for (final node in nodes) node.toJson()],
        'sources': sources,
      };
}

/// Composes browse-by-type from the [MemoryReadClient]'s read tools (PT-5.2).
final class TypeBrowser {
  /// The read-only client this browser composes over — its only memory door.
  final MemoryReadClient client;

  TypeBrowser(this.client);

  /// Browses nodes of [typeName], composing the result from recall (seeded by
  /// the type name), the [knownIds] surfaced in traces (`memory.get`), and —
  /// when [traverseEdges] is set — one hop of edge traversal from the hits.
  ///
  /// [recallK] bounds the recall seed. The result is filtered to [typeName],
  /// deduped by id, and is always [TypeBrowseResult.exhaustive] `== false`.
  Future<TypeBrowseResult> browse(
    String typeName, {
    List<String> knownIds = const <String>[],
    bool traverseEdges = false,
    int recallK = 20,
  }) async {
    final gathered = <String, MemoryNode>{};
    final sources = <String>[];

    // 1. Recall seeded by the type name — always the first composition source.
    final seeded = await client.recall(text: typeName, k: recallK);
    sources.add('recall');
    for (final node in seeded.nodes) {
      gathered[node.id] = node;
    }

    // 2. Ids surfaced in traces — fetched directly.
    if (knownIds.isNotEmpty) {
      sources.add('get');
      for (final node in await client.get(knownIds)) {
        gathered[node.id] = node;
      }
    }

    // 3. One hop of edge traversal from the hits, then fetch the neighbours.
    if (traverseEdges && gathered.isNotEmpty) {
      sources.add('edgesOf');
      final neighbourIds = <String>{};
      for (final seedId in gathered.keys.toList()) {
        for (final edge in await client.edgesOf(seedId)) {
          if (edge.from != seedId) neighbourIds.add(edge.from);
          if (edge.to != seedId) neighbourIds.add(edge.to);
        }
      }
      neighbourIds.removeAll(gathered.keys);
      if (neighbourIds.isNotEmpty) {
        sources.add('get');
        for (final node in await client.get(neighbourIds.toList())) {
          gathered[node.id] = node;
        }
      }
    }

    final matches = <MemoryNode>[
      for (final node in gathered.values)
        if (node.typeName == typeName) node,
    ];

    return TypeBrowseResult(
      typeName: typeName,
      nodes: matches,
      exhaustive: false,
      sources: sources,
    );
  }
}
