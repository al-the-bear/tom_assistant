// Extension F step 5 — the four-profile `ToolPolicy`
// (`tom_brain_procedure_specification.md` § 21.8, § 21.10;
// `prototype_tools_mcp_extension_plan.md` step 5).
//
// The policy narrows a registry's tools to the set a prompt type may see,
// following the Anthropic-template permission logic (Q-F.6):
//
//   all        every tool; the deny list is honoured.
//   read_only  every `readOnly` tool; the deny list is honoured.
//   groups     every tool whose `group` is in the enabled-groups set
//              (the deny list is *not* used — group membership is the gate).
//   explicit   only the allow-listed names (the deny list is *not* used —
//              the allow list is the gate).
//
// What this suite locks:
//
//   F.5-1 — `all` exposes everything; deny removes named tools (incl. the
//           motivating `vscode.todo.*` glob so in-process `todo.*` wins).
//   F.5-2 — `read_only` exposes only read-only tools; deny honoured.
//   F.5-3 — `groups` exposes only enabled groups; deny is ignored here.
//   F.5-4 — `explicit` exposes only allow-listed names; deny ignored.
//   F.5-5 — `denialFor` returns null when exposed and a typed `ToolDenial`
//           (code `tool.denied`) when not — the refusal `tool.invoke`
//           surfaces as `{ok: false, error}`.
//   F.5-6 — `ToolPolicyConfig.policyFor` lets a per-prompt-type profile
//           override the global default, keeping the shared deny/groups/
//           allow lists.

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:test/test.dart';

/// The shared fixture tool set spanning groups and read/write.
final _memoryRead = _StubTool('memory.read', ToolGroup.memory, readOnly: true);
final _memoryWrite =
    _StubTool('memory.write', ToolGroup.memory, readOnly: false);
final _fileRead = _StubTool('file.read', ToolGroup.file, readOnly: true);
final _todoAdd = _StubTool('todo.add', ToolGroup.todo, readOnly: false);
final _vscodeTodoAdd =
    _StubTool('vscode.todo.add', ToolGroup.vscode, readOnly: false);

final _allTools = <BrainTool>[
  _memoryRead,
  _memoryWrite,
  _fileRead,
  _todoAdd,
  _vscodeTodoAdd,
];

Set<String> _exposedNames(ToolPolicy policy) =>
    policy.narrow(_allTools).map((t) => t.name).toSet();

void main() {
  group('F.5-1 profile `all`', () {
    test('exposes every registered tool when no deny list', () {
      final policy = ToolPolicy(ToolPolicyProfile.all);
      expect(_exposedNames(policy), <String>{
        'memory.read',
        'memory.write',
        'file.read',
        'todo.add',
        'vscode.todo.add',
      });
    });

    test('the deny list removes named tools (exact name)', () {
      final policy =
          ToolPolicy(ToolPolicyProfile.all, deny: const <String>['memory.write']);
      expect(_exposedNames(policy), isNot(contains('memory.write')));
      expect(_exposedNames(policy), contains('memory.read'));
    });

    test('motivating case: deny [vscode.todo.*] so in-process todo.* wins', () {
      // The § 21.8 example — profile `all` plus a glob deny so the brain
      // prefers its own `todo.*` over the editor's `vscode.todo.*`.
      final policy = ToolPolicy(
        ToolPolicyProfile.all,
        deny: const <String>['vscode.todo.*'],
      );
      final exposed = _exposedNames(policy);
      expect(exposed, isNot(contains('vscode.todo.add')),
          reason: 'the glob removes the editor todo tool');
      expect(exposed, contains('todo.add'),
          reason: 'the in-process todo tool survives');
    });
  });

  group('F.5-2 profile `read_only`', () {
    test('exposes only read-only tools', () {
      final policy = ToolPolicy(ToolPolicyProfile.readOnly);
      expect(_exposedNames(policy), <String>{'memory.read', 'file.read'});
    });

    test('a write tool is never exposed', () {
      final policy = ToolPolicy(ToolPolicyProfile.readOnly);
      expect(_exposedNames(policy), isNot(contains('memory.write')));
    });

    test('the deny list removes a named read-only tool', () {
      final policy = ToolPolicy(
        ToolPolicyProfile.readOnly,
        deny: const <String>['file.read'],
      );
      expect(_exposedNames(policy), <String>{'memory.read'});
    });
  });

  group('F.5-3 profile `groups`', () {
    test('exposes only tools in the enabled-groups set', () {
      final policy = ToolPolicy(
        ToolPolicyProfile.groups,
        enabledGroups: const <ToolGroup>{ToolGroup.memory, ToolGroup.todo},
      );
      expect(_exposedNames(policy),
          <String>{'memory.read', 'memory.write', 'todo.add'});
    });

    test('the deny list is ignored — group membership is the only gate', () {
      final policy = ToolPolicy(
        ToolPolicyProfile.groups,
        enabledGroups: const <ToolGroup>{ToolGroup.memory},
        deny: const <String>['memory.write'],
      );
      expect(_exposedNames(policy), contains('memory.write'),
          reason: 'deny does not apply under the `groups` profile');
    });

    test('no enabled groups exposes nothing', () {
      final policy = ToolPolicy(ToolPolicyProfile.groups);
      expect(_exposedNames(policy), isEmpty);
    });
  });

  group('F.5-4 profile `explicit`', () {
    test('exposes only the allow-listed names', () {
      final policy = ToolPolicy(
        ToolPolicyProfile.explicit,
        allow: const <String>['memory.read', 'todo.add'],
      );
      expect(_exposedNames(policy), <String>{'memory.read', 'todo.add'});
    });

    test('the deny list is ignored — the allow list is the only gate', () {
      final policy = ToolPolicy(
        ToolPolicyProfile.explicit,
        allow: const <String>['memory.write'],
        deny: const <String>['memory.write'],
      );
      expect(_exposedNames(policy), contains('memory.write'),
          reason: 'deny does not apply under the `explicit` profile');
    });

    test('an empty allow list exposes nothing', () {
      final policy = ToolPolicy(ToolPolicyProfile.explicit);
      expect(_exposedNames(policy), isEmpty);
    });
  });

  group('F.5-5 denialFor — the typed refusal on invoke', () {
    test('returns null for an exposed tool', () {
      final policy = ToolPolicy(ToolPolicyProfile.all);
      expect(policy.denialFor(_memoryRead), isNull);
      expect(policy.exposes(_memoryRead), isTrue);
    });

    test('returns a typed ToolDenial for a denied tool', () {
      final policy = ToolPolicy(
        ToolPolicyProfile.all,
        deny: const <String>['memory.write'],
      );
      final denial = policy.denialFor(_memoryWrite);
      expect(denial, isNotNull);
      expect(denial!.name, 'memory.write');
      expect(denial.code, toolDeniedCode);
      expect(denial.toString(), contains(toolDeniedCode));
      expect(policy.exposes(_memoryWrite), isFalse);
    });

    test('returns a typed ToolDenial for a tool outside read_only', () {
      final policy = ToolPolicy(ToolPolicyProfile.readOnly);
      expect(policy.denialFor(_memoryWrite), isNotNull);
    });
  });

  group('F.5-6 ToolPolicyConfig — global default + per-type override', () {
    test('policyFor(null) uses the configured default profile', () {
      const config = ToolPolicyConfig(
        defaultProfile: ToolPolicyProfile.readOnly,
      );
      expect(config.policyFor(null).profile, ToolPolicyProfile.readOnly);
    });

    test('policyFor(profile) overrides the default but keeps the lists', () {
      const config = ToolPolicyConfig(
        defaultProfile: ToolPolicyProfile.all,
        deny: <String>['vscode.todo.*'],
      );
      final policy = config.policyFor(ToolPolicyProfile.readOnly);
      expect(policy.profile, ToolPolicyProfile.readOnly,
          reason: 'the per-prompt-type profile wins');
      // The shared deny list still applies under read_only.
      expect(policy.deny, contains('vscode.todo.*'));
    });

    test('the default ToolPolicyConfig is profile `all` with empty lists', () {
      const config = ToolPolicyConfig();
      expect(config.defaultProfile, ToolPolicyProfile.all);
      expect(config.deny, isEmpty);
      expect(config.enabledGroups, isEmpty);
      expect(config.allow, isEmpty);
    });
  });
}

/// A minimal concrete [BrainTool] for policy fixtures — its [run] is never
/// called by these tests (the policy reasons over `name` / `group` /
/// `readOnly` only).
final class _StubTool extends BrainTool {
  _StubTool(this.name, this.group, {required this.readOnly});

  @override
  final String name;

  @override
  final ToolGroup group;

  @override
  final bool readOnly;

  @override
  String get description => '$name stub';

  @override
  Map<String, Object?> get inputSchema => const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
      };

  @override
  Future<Object?> run(Map<String, Object?> args, ToolContext ctx) async => null;
}
