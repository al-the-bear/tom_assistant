// ToolPolicyConfig — the global tool-permission default plus the shared
// deny / enabled-groups / allow lists
// (`tom_brain_procedure_prototype_specification.md` § 21.8, § 21.10).
//
// A prompt type may name its own `toolPolicy:` profile (step 3); when it does
// not, the brain falls back to [defaultProfile] here. Either way the shared
// [deny] / [enabledGroups] / [allow] lists apply, so the motivating
// `deny: [vscode.todo.*]` rule is configured once and honoured by every
// allow-all prompt type. [policyFor] resolves a (possibly null) per-prompt
// profile into a concrete [ToolPolicy].
//
// This is the in-memory shape only; the YAML loader that reads it from
// configuration lands in a later Extension F step (§ 21.10 wiring).

import '../config/prompt_template_config.dart' show ToolPolicyProfile;
import 'tool_group.dart';
import 'tool_policy.dart';

/// The global tool-policy configuration: a default profile plus the deny /
/// enabled-groups / allow lists shared across prompt types. Const-constructible.
final class ToolPolicyConfig {
  /// The profile used when a prompt type does not name its own.
  final ToolPolicyProfile defaultProfile;

  /// Deny globs honoured under the allow-all profiles.
  final List<String> deny;

  /// Groups exposed under the `groups` profile.
  final Set<ToolGroup> enabledGroups;

  /// Tool names exposed under the `explicit` profile.
  final List<String> allow;

  /// Builds the configuration, defaulting to profile `all` with empty lists.
  const ToolPolicyConfig({
    this.defaultProfile = ToolPolicyProfile.all,
    this.deny = const <String>[],
    this.enabledGroups = const <ToolGroup>{},
    this.allow = const <String>[],
  });

  /// Resolves [templateProfile] (a prompt type's `toolPolicy:`, or `null` to
  /// fall back to [defaultProfile]) into a concrete [ToolPolicy] carrying the
  /// shared deny / enabled-groups / allow lists.
  ToolPolicy policyFor(ToolPolicyProfile? templateProfile) => ToolPolicy(
        templateProfile ?? defaultProfile,
        deny: deny,
        enabledGroups: enabledGroups,
        allow: allow,
      );
}
