// `ExtensionLog` — category-tagged wrapper over `tomLog` for the Extension-F
// surfaces (Extension F step 16; `tom_brain_procedure_specification.md`
// § 13).
//
// Spec § 13 names five Extension-F logging categories the prototype emits
// under — the tool registry / invocation paths, the MCP client, and the
// prompt-template / placeholder assembly:
//
//   - `tom_brain.tools.registry`
//   - `tom_brain.tools.invoke`
//   - `tom_brain.mcp.client`
//   - `tom_brain.prompt.template`
//   - `tom_brain.placeholder`
//
// These sit beside the engine's five categories (`EngineLog`, C.43) and the
// dispatcher's five (`DispatcherLog`, D.48). The three facades share one
// idiom — a closed `enum` of canonical `tom_brain.<area>` strings and a
// `const`-instance [CategoryLog] subclass — so an operator reads
// `[tom_brain.<component>.<area>]` uniformly across the whole brain.
//
// Wiring status: like its siblings `SubstrateLog` (B.37) and the freshly
// shipped step-15 surfaces, this facade ships surface-first. Call-site
// emissions are added as each Extension-F lifecycle point acquires operator
// value (the tool registry/invoke paths already emit typed `ToolEvent`s, the
// MCP client typed `McpEvent`s; the log facade is the human-readable
// counterpart wired alongside them as the surfaces mature).

import 'package:tom_core_agentic/tom_core_agentic.dart';

/// Closed enumeration of the five Extension-F logging categories the
/// prototype emits under (spec § 13).
///
/// The `name` field carries the canonical string identifier used as the
/// log-line prefix. Adding a category is a deliberate edit of this enum and
/// the matching [ExtensionLog] static — there is no way to construct an
/// ad-hoc category from a string.
enum ExtensionLogCategory {
  /// Tool registry: registration, policy narrowing, `tool.list` enumeration.
  toolsRegistry('tom_brain.tools.registry'),

  /// Tool invocation: `tool.invoke` dispatch, denial, budget pre-charge,
  /// success / failure.
  toolsInvoke('tom_brain.tools.invoke'),

  /// MCP client: outbound connect, `mcp.list` / `mcp.call` roundtrips,
  /// environmental failures.
  mcpClient('tom_brain.mcp.client'),

  /// Prompt-template loader: `<type>.yaml` resolution, model binding,
  /// eager boot validation.
  promptTemplate('tom_brain.prompt.template'),

  /// Placeholder resolver: `setup` script execution, `${{ }}` evaluation,
  /// system + user prompt assembly.
  placeholder('tom_brain.placeholder');

  const ExtensionLogCategory(this.name);

  /// Canonical string identifier for this category, used as the log prefix
  /// and as the operator-facing name (e.g. in filter rules).
  final String name;
}

/// A thin, category-tagged facade over the global [tomLog] instance for the
/// Extension-F surfaces.
///
/// Construct via the five const statics ([toolsRegistry], [toolsInvoke],
/// [mcpClient], [promptTemplate], [placeholder]) — those are the only legal
/// categories. Each method prepends `'[<category>] '` to the message before
/// forwarding to the matching `tomLog` method, preserving the lazy
/// `() => String` contract. Mirrors `EngineLog` (C.43) and `DispatcherLog`
/// (D.48).
final class ExtensionLog extends CategoryLog {
  /// The category this logger emits under. Read-only and final.
  final ExtensionLogCategory category;

  /// Internal: constructs a logger for [category]. Not exposed; the five
  /// static instances below are the public surface.
  const ExtensionLog._(this.category);

  @override
  String get categoryName => category.name;

  /// Tool-registry logger. See [ExtensionLogCategory.toolsRegistry].
  static const ExtensionLog toolsRegistry =
      ExtensionLog._(ExtensionLogCategory.toolsRegistry);

  /// Tool-invocation logger. See [ExtensionLogCategory.toolsInvoke].
  static const ExtensionLog toolsInvoke =
      ExtensionLog._(ExtensionLogCategory.toolsInvoke);

  /// MCP-client logger. See [ExtensionLogCategory.mcpClient].
  static const ExtensionLog mcpClient =
      ExtensionLog._(ExtensionLogCategory.mcpClient);

  /// Prompt-template logger. See [ExtensionLogCategory.promptTemplate].
  static const ExtensionLog promptTemplate =
      ExtensionLog._(ExtensionLogCategory.promptTemplate);

  /// Placeholder-resolver logger. See [ExtensionLogCategory.placeholder].
  static const ExtensionLog placeholder =
      ExtensionLog._(ExtensionLogCategory.placeholder);

  /// All five loggers in the order they appear on
  /// [ExtensionLogCategory.values]. Convenience for tests and for
  /// operator-facing tools that want to enumerate the surface.
  static const List<ExtensionLog> all = <ExtensionLog>[
    toolsRegistry,
    toolsInvoke,
    mcpClient,
    promptTemplate,
    placeholder,
  ];

  @override
  String toString() => 'ExtensionLog(${category.name})';
}
