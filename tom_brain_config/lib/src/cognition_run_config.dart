// CognitionRunConfig — the `cognition:` section of the whole-process config
// (`prompt_configuration.md` §7.4).
//
// The run-level pointer at the cognition config tree: the directory holding
// `registry.yaml` plus the per-procedure config / template folders and the
// `llm/` route folder the `CognitionConfigLoader` reads. The run assembly turns
// that tree into the two `sub.run` seams every procedure consults — the
// `PromptResolver` (a named prompt → loaded, placeholder-resolved
// `ResolvedPrompt`) and the `RouteChainResolver` (a named LLM route → its
// ordered failover chain).
//
// This is a *run-level* pointer only — the heavy parsing of the tree it names
// is owned by `CognitionConfigLoader`. Keeping the pointer separate mirrors how
// `memory.root` / `trail.root` name a directory the section's own loader then
// reads.

/// The typed `cognition:` section — the directory the cognition config tree
/// lives under (`prompt_configuration.md` §7.4).
///
/// Produced by `CognitionRunConfigLoader.parse`; `null` on the whole-process
/// config when no `cognition:` block is present, in which case the run assembly
/// wires no prompt / route resolvers and any `sub.run` raises
/// `UnregisteredPromptException` (the pre-migration prototype behaviour).
final class CognitionRunConfig {
  /// The cognition config root directory — the folder holding `registry.yaml`,
  /// the per-procedure config / template folders, and the `llm/` route folder.
  /// Handed to `CognitionConfigLoader.loadFromDir` and bound as the
  /// `${config_folder}` built-in.
  final String root;

  /// Binds the cognition root.
  const CognitionRunConfig({required this.root});
}

/// Thrown for a malformed `cognition:` section (a non-map block, a missing /
/// non-string `root`, or an unknown key).
class CognitionRunConfigException implements Exception {
  /// Human-readable, located explanation.
  final String message;

  /// Builds the exception with a [message].
  const CognitionRunConfigException(this.message);

  @override
  String toString() => 'CognitionRunConfigException: $message';
}
