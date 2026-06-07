// MCP-configuration failure type (Extension F step 8;
// `tom_brain_procedure_prototype_specification.md` § 21.3, § 21.10).
//
// The `mcpServers:` block (`mcp_server_config.dart`) loads through the
// canonical plain-map loader. A present-but-malformed document (unknown
// transport, missing `id`, duplicate id, wrong-typed field) surfaces as one
// typed error carrying a wire code, so a boot path can route on the code
// without string-matching the message — the same idiom `LlmConfigInvalid`
// (§ 21.6) follows.
//
// A configured-but-*unreachable* server is **not** a config error: it is an
// environmental failure surfaced at connect time as `McpFailure`
// (`mcp.unreachable`, PE-6). The loader validates shape only.

library;

/// Wire code for a structurally invalid `mcpServers:` document.
const String mcpConfigInvalidCode = 'mcp.config.invalid';

/// Thrown when a present `mcpServers:` block has the wrong shape.
///
/// Carries a human-readable [message] and, when the problem is localised to
/// one field, the dotted [path] of the offending key (e.g.
/// `mcp.mcpServers[0].transport`). The string form prefixes
/// `mcp.config.invalid:` so the failure class is greppable in logs.
final class McpConfigInvalid implements Exception {
  /// Builds a structural-invalid error with [message] and an optional field
  /// [path].
  const McpConfigInvalid(this.message, {this.path});

  /// Describes what is wrong with the configuration document.
  final String message;

  /// The dotted path of the offending field, when the problem is local to a
  /// single key. `null` for document-level problems.
  final String? path;

  /// The wire code carried by every structural-invalid failure.
  String get code => mcpConfigInvalidCode;

  @override
  String toString() {
    final at = path == null ? '' : ' (at "$path")';
    return '$code: $message$at';
  }
}
