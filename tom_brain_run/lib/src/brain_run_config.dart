// BrainRunConfig — the typed whole-process configuration for the run assembly
// (Plan-2 step #31).
//
// The single YAML config file wires the whole cognition: the `substrate:`
// section (oMLX endpoint + model, Ollama embed endpoint + model, role routing),
// the `memory:` section (the on-disk memory directory + sqlite-vec binary), and
// the `access:` section (the channel ports / tokens + edge-security policies).
// Each section is owned and parsed by its package's own loader; this value type
// is the assembled result the run process boots from.
//
// Why one value carrying three sub-configs (not a flat merge):
//
//   * Each sub-config is the *same* typed object its owning package already
//     hands to its boot path — `SubstrateConfig` to `buildSubstrate` /
//     `substrate.open`, `MemoryConfig` to `createSqliteTomBrainMemory`,
//     `AccessConfig` to `startBrainAccessProcess`. Re-wrapping them flat would
//     fork those contracts; carrying them whole keeps one schema per section.
//   * The whole-process document's sibling sections (`substrate` / `memory` /
//     `engine` / `dispatcher` / `access`) map one-to-one onto the owning
//     loaders. `BrainRunConfig` is the three the run assembly consumes;
//     `engine:` / `dispatcher:` carry their own defaults and are not yet part
//     of the run surface (the prototype boots with the boot's default queue
//     depth and classifier fallback).

import 'package:tom_brain_access/tom_brain_access.dart'
    show AccessConfig;
import 'package:tom_brain_memory/tom_brain_memory.dart' show MemoryConfig;
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show McpServersConfig;
import 'package:tom_brain_shared/tom_brain_shared.dart' show HistoryConfig;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show SubstrateConfig;

import 'cognition_run_config.dart';
import 'dream_config.dart';
import 'tools_config.dart';
import 'trail_config.dart';

/// The assembled whole-process configuration: the three sections the run
/// assembly boots a cognition from (Plan-2 step #31).
///
/// Produced by `BrainRunConfigLoader.parse` / `loadFromFile`, which delegates
/// each section to its owning loader (`SubstrateConfigLoader`,
/// `MemoryConfigLoader`, `AccessConfigLoader`). Constructed directly in tests
/// for fine-grained scenarios.
final class BrainRunConfig {
  /// The typed `substrate:` section — provider catalogue, role routing,
  /// embedding choice, router tunables. Handed to `buildSubstrate` to
  /// manufacture the live facade, and threaded through the boot so
  /// `substrate.open` validates routed roles against the registry.
  final SubstrateConfig substrate;

  /// The typed `memory:` section — on-disk root, sqlite-vec binary, retrieval /
  /// trails / replication tunables. Handed to `createSqliteTomBrainMemory`.
  final MemoryConfig memory;

  /// The typed `access:` section — the channel ports / tokens, the per-channel
  /// identity bindings, the rate-limit / quota / anchor policies. Handed to
  /// `startBrainAccessProcess`.
  final AccessConfig access;

  /// The optional `trail:` section (`tom_brain_logging.md` §4.1 / §8). `null`
  /// when the document carries no `trail:` block — which selects
  /// [TrailMode.unconfigured] (CWD `brain.log` + `components/*.log` only). A
  /// value selects [TrailMode.full] (the whole tree under `trail.root`).
  final TrailConfig? trail;

  /// The optional `tools:` section (§ 21.4) — the file-scope roots the engine's
  /// `file.*` tools resolve against. `null` when the document carries no
  /// `tools:` block, leaving the engine on its neutral placeholder root. A
  /// value threads its non-empty `fileScope` list onto the procedure engine.
  final ToolsConfig? tools;

  /// The optional `dream:` section (item b) — the boot-time dream-cadence
  /// policy (whether the loop starts, the daily windows it runs in, the
  /// heartbeat override). `null` when the document carries no `dream:` block,
  /// in which case the run assembly stands up no dream loop at all.
  final DreamConfig? dream;

  /// The optional `cognition:` section (`prompt_configuration.md` §7.4) — the
  /// cognition config tree the run assembly turns into the two `sub.run` seams
  /// (the `PromptResolver` + `RouteChainResolver`). `null` when the document
  /// carries no `cognition:` block, in which case no resolvers are wired and any
  /// `sub.run` raises `UnregisteredPromptException` (the pre-migration
  /// prototype behaviour).
  final CognitionRunConfig? cognition;

  /// The parsed `mcpServers:` section (§ 21.3, § 21.6) — the outbound MCP
  /// servers the run assembly connects to and whose tools merge into the
  /// procedure tool loop (request f). Never `null`: an absent `mcpServers:`
  /// block yields an empty registry (the cognition simply has no MCP servers),
  /// in which case the run assembly builds no MCP client at all.
  final McpServersConfig mcpServers;

  /// The parsed top-level `history:` block (history-compaction quest; hub
  /// § 22.6b/c). Carries the `defaults` sizing plus per-lane overrides for every
  /// cognition lane. The access section resolves the `foreground` answer lane
  /// from the same block into [AccessConfig.answerLaneSizing]; the run assembly
  /// hands this whole config to the dream cadence's `FreeTimeScheduler` so each
  /// dreaming lane resolves its own prior-run window (todo #14). Never `null`:
  /// an absent block yields [HistoryConfig.standard] (every lane on the
  /// code-default sizing).
  final HistoryConfig history;

  /// Assembles the parsed sections into the run configuration.
  ///
  /// [trail], [tools], [dream] and [cognition] are optional: an absent `trail:`
  /// block leaves [trail] `null` (unconfigured mode); an absent `tools:` block
  /// leaves [tools] `null` (the engine's placeholder file-scope root); an absent
  /// `dream:` block leaves [dream] `null` (no dream loop at boot); an absent
  /// `cognition:` block leaves [cognition] `null` (no prompt / route resolvers).
  /// [mcpServers] defaults to an empty registry (no MCP servers configured).
  BrainRunConfig({
    required this.substrate,
    required this.memory,
    required this.access,
    this.trail,
    this.tools,
    this.dream,
    this.cognition,
    McpServersConfig? mcpServers,
    this.history = const HistoryConfig.standard(),
  }) : mcpServers = mcpServers ?? McpServersConfig(const []);

  /// The active trail mode, derived from whether a `trail:` block was
  /// configured (`tom_brain_logging.md` §4.1): [TrailMode.unconfigured] when
  /// [trail] is `null`, [TrailMode.full] otherwise.
  TrailMode get trailMode =>
      trail == null ? TrailMode.unconfigured : TrailMode.full;
}
