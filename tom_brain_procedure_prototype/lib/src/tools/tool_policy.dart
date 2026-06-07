// ToolPolicy — narrows a registry's tools to the set a prompt type may see
// (`tom_brain_procedure_prototype_specification.md` § 21.8, § 21.10).
//
// The policy keys on the two axes a `BrainTool` carries — its `group` and its
// `readOnly` flag — plus a deny / allow / enabled-groups list, following the
// Anthropic-template permission logic (Q-F.6):
//
//   all        every tool; the deny list is honoured.
//   read_only  every `readOnly` tool; the deny list is honoured.
//   groups     every tool whose `group` is in the enabled-groups set; the
//              deny list is *not* used (group membership is the gate).
//   explicit   only the allow-listed names; the deny list is *not* used (the
//              allow list is the gate).
//
// The deny list therefore narrows only the two allow-all profiles — under
// `groups` / `explicit` the inclusion set is already explicit, so re-applying
// deny would be redundant and surprising. Deny entries are globs: a trailing
// `*` matches any suffix, so `vscode.todo.*` removes the editor's todo tools
// and lets the brain's in-process `todo.*` win (the § 21.8 motivating case).
//
// The same policy is applied when the `tool.list` primitive enumerates tools
// and re-checked when `tool.invoke` runs one (step 6): a name the policy does
// not expose, invoked directly, yields a [ToolDenial] (§ 21.10).

import '../config/prompt_template_config.dart' show ToolPolicyProfile;
import 'brain_tool.dart';
import 'tool_denied.dart';
import 'tool_group.dart';

/// A resolved tool-permission policy (§ 21.8). Immutable; built either
/// directly or via [ToolPolicyConfig.policyFor].
final class ToolPolicy {
  /// The profile that selects the inclusion rule.
  final ToolPolicyProfile profile;

  /// Glob deny entries, honoured only under [ToolPolicyProfile.all] and
  /// [ToolPolicyProfile.readOnly].
  final List<String> deny;

  /// The groups exposed under [ToolPolicyProfile.groups].
  final Set<ToolGroup> enabledGroups;

  /// The tool names exposed under [ToolPolicyProfile.explicit].
  final List<String> allow;

  /// Builds a policy for [profile] with the optional [deny] / [enabledGroups]
  /// / [allow] lists (each defaulting to empty).
  const ToolPolicy(
    this.profile, {
    this.deny = const <String>[],
    this.enabledGroups = const <ToolGroup>{},
    this.allow = const <String>[],
  });

  /// Whether [tool] is exposed under this policy.
  bool exposes(BrainTool tool) {
    switch (profile) {
      case ToolPolicyProfile.all:
        return !_denied(tool.name);
      case ToolPolicyProfile.readOnly:
        return tool.readOnly && !_denied(tool.name);
      case ToolPolicyProfile.groups:
        return enabledGroups.contains(tool.group);
      case ToolPolicyProfile.explicit:
        return allow.contains(tool.name);
    }
  }

  /// The subset of [tools] this policy exposes, order preserved.
  List<BrainTool> narrow(Iterable<BrainTool> tools) =>
      tools.where(exposes).toList(growable: false);

  /// `null` when [tool] is exposed, otherwise a typed [ToolDenial] explaining
  /// the refusal. The `tool.invoke` primitive (step 6) turns a non-null
  /// result into `{ok: false, error}` (§ 21.10).
  ToolDenial? denialFor(BrainTool tool) {
    if (exposes(tool)) return null;
    return ToolDenial(tool.name, reason: 'profile ${profile.wire}');
  }

  /// Whether [name] matches any deny glob.
  bool _denied(String name) => deny.any((pattern) => _matchesGlob(pattern, name));

  /// Glob match where `*` stands for any run of characters; every other
  /// character is matched literally. Anchored at both ends.
  static bool _matchesGlob(String pattern, String name) {
    final buffer = StringBuffer('^');
    for (final unit in pattern.split('')) {
      if (unit == '*') {
        buffer.write('.*');
      } else {
        buffer.write(RegExp.escape(unit));
      }
    }
    buffer.write(r'$');
    return RegExp(buffer.toString()).hasMatch(name);
  }
}
