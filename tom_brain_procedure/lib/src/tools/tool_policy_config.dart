// ToolPolicyConfig — the global tool-permission default plus the shared
// deny / enabled-groups / allow lists
// (`tom_brain_procedure_specification.md` § 21.8, § 21.10).
//
// A prompt type may name its own `toolPolicy:` profile (step 3); when it does
// not, the brain falls back to [defaultProfile] here. Either way the shared
// [deny] / [enabledGroups] / [allow] lists apply, so the motivating
// `deny: [vscode.todo.*]` rule is configured once and honoured by every
// allow-all prompt type. [policyFor] resolves a (possibly null) per-prompt
// profile into a concrete [ToolPolicy].
//
// The [ToolPolicyConfig.fromYamlMap] loader (Extension F step 15) reads this
// shape from a plain `toolPolicy:` map through the canonical plain-map loader,
// reusing the shared typed [LlmConfigInvalid] for a malformed block (the same
// direction `tools → config` the [ToolPolicyProfile] import already follows).

import 'package:tom_core_agentic/tom_core_agentic.dart';

import '../config/llm_config_errors.dart' show LlmConfigInvalid;
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

  /// Parses a `toolPolicy:` block from an already-loaded plain [map]
  /// (Extension F step 15; § 21.8, § 21.10).
  ///
  /// [map] is the nested block as returned by the canonical plain-map loader
  /// (`loadYamlAsMap` / `optionalMap`) — never a `YamlMap`. Shape:
  ///
  /// ```yaml
  /// default: read_only      # all | read_only | groups | explicit (absent ⇒ all)
  /// deny:   [ vscode.todo.* ]
  /// groups: [ memory, web ] # ToolGroup names
  /// allow:  [ memory.read ]
  /// ```
  ///
  /// An absent `default` falls back to [ToolPolicyProfile.all]. An unknown
  /// profile, an unknown group name, or a non-string list entry each throw a
  /// located [LlmConfigInvalid] under [path].
  static ToolPolicyConfig fromYamlMap(
    Map<Object?, Object?> map, {
    String path = 'toolPolicy',
  }) {
    const reader = YamlConfigReader(
      env: <String, String>{},
      errorFactory: LlmConfigInvalid.new,
    );

    final rawDefault = reader.optionalString(map, 'default', '$path.default');
    final defaultProfile = rawDefault == null
        ? ToolPolicyProfile.all
        : ToolPolicyProfile.parse(rawDefault, '$path.default');

    final deny = _stringList(reader, map, 'deny', '$path.deny');
    final allow = _stringList(reader, map, 'allow', '$path.allow');
    final enabledGroups = _groupSet(reader, map, 'groups', '$path.groups');

    return ToolPolicyConfig(
      defaultProfile: defaultProfile,
      deny: deny,
      enabledGroups: enabledGroups,
      allow: allow,
    );
  }

  /// Reads an optional string list at [key], rejecting a non-string entry
  /// through a located [LlmConfigInvalid]. Absent ⇒ an empty list.
  static List<String> _stringList(
    YamlConfigReader reader,
    Map<Object?, Object?> map,
    String key,
    String path,
  ) {
    final raw = reader.optionalList(map, key, path);
    if (raw == null) return const <String>[];
    final out = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final value = raw[i];
      if (value is! String) {
        throw LlmConfigInvalid(
          'must be a string (got ${value.runtimeType})',
          path: '$path[$i]',
        );
      }
      out.add(value);
    }
    return out;
  }

  /// Reads the `groups` list and maps each entry to a [ToolGroup], rejecting an
  /// unknown group name through a located [LlmConfigInvalid]. Absent ⇒ empty.
  static Set<ToolGroup> _groupSet(
    YamlConfigReader reader,
    Map<Object?, Object?> map,
    String key,
    String path,
  ) {
    final raw = reader.optionalList(map, key, path);
    if (raw == null) return const <ToolGroup>{};
    final out = <ToolGroup>{};
    for (var i = 0; i < raw.length; i++) {
      final value = raw[i];
      if (value is! String) {
        throw LlmConfigInvalid(
          'group must be a string (got ${value.runtimeType})',
          path: '$path[$i]',
        );
      }
      out.add(_parseGroup(value, '$path[$i]'));
    }
    return out;
  }

  static ToolGroup _parseGroup(String value, String path) {
    for (final group in ToolGroup.values) {
      if (group.name == value) return group;
    }
    final known = ToolGroup.values.map((g) => g.name).join(', ');
    throw LlmConfigInvalid(
      'unknown tool group "$value" (expected one of: $known)',
      path: path,
    );
  }
}
