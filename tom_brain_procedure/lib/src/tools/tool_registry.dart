// ToolRegistry — the in-process catalogue `tool.list` / `tool.invoke` read
// (`tom_brain_procedure_specification.md` § 21.2).
//
// A flat name→tool map. The composition root registers the basic tool set
// (§ 21.4) plus any host-supplied tools; the LLM loop lists and invokes
// through it. The registry holds *descriptors* only — it neither builds the
// `ToolContext` nor runs anything; `tool.invoke` (a later step) looks a tool
// up here, validates `args` against its `inputSchema`, then calls `run`.

import 'brain_tool.dart';
import 'tool_errors.dart';
import 'tool_group.dart';

/// A registry of [BrainTool]s keyed by name (§ 21.2).
///
/// Registration is exclusive: a second tool claiming a registered name is
/// refused with [ToolAlreadyRegistered] rather than shadowing the first, so
/// collisions surface at wiring time. Lookups are by exact name; [list]
/// returns the catalogue, optionally narrowed to one [ToolGroup].
final class ToolRegistry {
  final Map<String, BrainTool> _byName = <String, BrainTool>{};

  /// Registers [tool] under its [BrainTool.name].
  ///
  /// Throws [ToolAlreadyRegistered] if the name is already taken.
  void register(BrainTool tool) {
    if (_byName.containsKey(tool.name)) {
      throw ToolAlreadyRegistered(tool.name);
    }
    _byName[tool.name] = tool;
  }

  /// Returns the tool registered under [name], or `null` if none is.
  BrainTool? lookup(String name) => _byName[name];

  /// Whether a tool is registered under [name].
  bool contains(String name) => _byName.containsKey(name);

  /// The registered tool names.
  Iterable<String> get names => _byName.keys;

  /// The registered tools, optionally narrowed to a single [group].
  ///
  /// Order is registration order (insertion order of the backing map). The
  /// policy narrowing (§ 21.8) and any `tool.list` filter apply on top of
  /// this raw catalogue — the registry itself enforces no policy.
  List<BrainTool> list({ToolGroup? group}) {
    final all = _byName.values;
    if (group == null) return all.toList(growable: false);
    return all.where((t) => t.group == group).toList(growable: false);
  }
}
