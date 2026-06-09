// MemoryRetrievalConfig failure types (Extension H, step #31;
// `tom_brain_procedure_specification.md` § 23.4, § 23.7).
//
// The `memory_retrieval/` config family loads through the canonical
// plain-map loader (`loadYamlAsMap`) and is mutated through the
// AST-preserving writer. Two failure shapes surface as typed errors so a
// boot/server path can route on the wire code without string-matching the
// message — mirroring `LlmConfigInvalid` (Extension F):
//
//   • `retrieval.config.invalid`       — a present document has the wrong
//                                        shape (a non-map block, a
//                                        non-string/number field).
//   • `retrieval.config.llm_in_memory` — an LLM-bearing strategy (one
//                                        carrying a `role:`) is enabled on
//                                        a surface constrained to non-LLM
//                                        strategies (the memory MCP server,
//                                        § 23.7). Raised by
//                                        `MemoryRetrievalConfig.checkNonLlm`.

library;

/// Wire code for a structurally invalid `memory_retrieval/` document.
const String memoryRetrievalConfigInvalidCode = 'retrieval.config.invalid';

/// Wire code for an LLM strategy enabled on a non-LLM-only surface (§ 23.7).
const String retrievalConfigLlmInMemoryCode = 'retrieval.config.llm_in_memory';

/// Thrown when a `memory_retrieval/` config is structurally invalid, or when
/// an LLM strategy is enabled on a surface that forbids it.
///
/// Carries a human-readable [message] and, when the problem is localised to
/// one field, the dotted [path] of the offending key (e.g.
/// `strategies.vector.prompt.weight`). The [code] distinguishes the two
/// failure families: a generic structural problem
/// ([memoryRetrievalConfigInvalidCode]) versus the non-LLM-surface violation
/// ([retrievalConfigLlmInMemoryCode]).
final class MemoryRetrievalConfigInvalid implements Exception {
  /// Builds a structural-invalid error with [message] and an optional field
  /// [path]. Defaults to the [memoryRetrievalConfigInvalidCode] family.
  const MemoryRetrievalConfigInvalid(this.message, {this.path})
      : code = memoryRetrievalConfigInvalidCode;

  /// Builds the non-LLM-surface violation ([retrievalConfigLlmInMemoryCode]),
  /// naming the offending `family.name` strategy in [path].
  const MemoryRetrievalConfigInvalid.llmInMemory(this.message, {this.path})
      : code = retrievalConfigLlmInMemoryCode;

  /// Describes what is wrong with the configuration.
  final String message;

  /// The dotted path of the offending field, when local to a single key.
  /// `null` for document-level problems.
  final String? path;

  /// The wire code carried by this failure — one of the two § 23.4 families.
  final String code;

  @override
  String toString() {
    final at = path == null ? '' : ' (at "$path")';
    return '$code: $message$at';
  }
}
