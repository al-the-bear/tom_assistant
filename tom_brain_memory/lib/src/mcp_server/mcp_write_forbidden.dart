// A.77 — McpWriteForbidden: the closed-set rejection raised when an MCP
// caller invokes `memory.persistNote` with a NodeType outside the v1
// allow-list ({Claim, Question, AutomationIdea, InterestItem}).
//
// Memory spec § 3.2 names `memory.persistNote` as the one constrained
// write the MCP surface exposes; spec § 15 names `McpWriteForbidden`
// as the rejection reason. The exception is Dart-internal: at the wire
// boundary the tool wrapper converts it into a
// `CallToolResult(isError: true, ...)` so an LLM-driven caller can
// see the failure reason and self-correct (cf. the `dart_mcp`
// `CallToolResult` doc comment: tool-domain errors belong inside the
// result, not as a JSON-RPC error).
//
// The forbidden-vs-permitted decision lives in this file (the
// `allowedPersistNoteTypeNames` set) — a single source of truth that
// the tool wrapper and the tests share.

/// Set of NodeType names `memory.persistNote` accepts.
///
/// Closed by design — spec § 1.7 "no backwards compatibility" makes
/// adding a NodeType a version bump, not a silent extension. The MCP
/// tool wrapper checks the caller's `typeName` against this set
/// *before* touching the underlying memory store, so a forbidden
/// write never reaches `TomBrainMemory.persist` and never appears in
/// the trail / WAL.
const allowedPersistNoteTypeNames = <String>{
  'Claim',
  'Question',
  'AutomationIdea',
  'InterestItem',
};

/// Raised when an MCP `memory.persistNote` call names a NodeType not
/// in [allowedPersistNoteTypeNames].
///
/// Caught by the MCP tool wrapper and translated into a
/// `CallToolResult(isError: true, content: [TextContent(text: ...)])`
/// with a message that names the forbidden type and lists the
/// permitted ones — the LLM-driven caller has enough information to
/// retry against a permitted type.
class McpWriteForbidden implements Exception {
  /// The NodeType the caller asked to persist (the forbidden one).
  final String requestedTypeName;

  /// The full permitted set, included in the exception for symmetry
  /// with the wire-side error message — both `toString` and the
  /// wrapper-generated text content list the same names.
  final Set<String> allowedTypeNames;

  const McpWriteForbidden({
    required this.requestedTypeName,
    this.allowedTypeNames = allowedPersistNoteTypeNames,
  });

  @override
  String toString() =>
      'McpWriteForbidden: NodeType "$requestedTypeName" is not in the '
      'memory.persistNote allow-list '
      '(${allowedTypeNames.toList()..sort()}). See memory_specification.md '
      'Section 3.2 for the v1 contract.';
}
