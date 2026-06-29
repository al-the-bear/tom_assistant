// ProfileRegistry — config parse + boot resolution + boot validation
// (session_configuration_plan.md step 3; spec § 3).
//
// Covers the four faces of the step-3 deliverable:
//   * the `Profile` config DTO (defaults, unmodifiable lists,
//     `effectiveEntryProcedure`);
//   * `ProfileRegistry.fromYamlString` — the `profiles:` parser, the synthesised
//     built-in `default` (SC-5), and the parse-time `mode`/`entryProcedure`
//     conflict (SCP-13);
//   * `resolve` — mode→entry mapping, the offered-MCP set (§ 3.6 / SCP-15), the
//     budget/rate-limit clamp (SC-8 / SCP-12), advisory cross-axis defaults, and
//     the unknown-name error;
//   * `validateAtBoot` — unknown role (`profile.unknown_role`), missing overlay
//     (`profile.overlay_missing`), and the clamp warning;
//   * `namespacedDefinedServers` — `<profileId>/<serverName>` rewriting.

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show McpServerConfig, McpTransport;
import 'package:tom_brain_run/tom_brain_run.dart'
    show
        Profile,
        ProfileAuthoringContext,
        ProfileConfigException,
        ProfileRegistry,
        UnknownProfileException;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show ProfileBudget, ProfileMode, ProfileRateLimits, ResolvedProfile;
import 'package:test/test.dart';

void main() {
  group('Profile (config DTO)', () {
    test('PRO-01: defaults — cognitive, anchored, empty unmodifiable lists', () {
      final p = Profile(id: 'x');
      expect(p.id, 'x');
      expect(p.mode, ProfileMode.cognitive);
      expect(p.anchored, isTrue);
      expect(p.entryProcedure, isNull);
      expect(p.role, isNull);
      expect(p.templateOverlay, isNull);
      expect(p.mcpServers, isEmpty);
      expect(p.defineMcpServers, isEmpty);
      expect(p.budget, isNull);
      expect(p.rateLimits, isNull);
      expect(p.defaultSession, isNull);
      expect(p.defaultMemory, isNull);
      expect(() => p.mcpServers.add('y'), throwsUnsupportedError);
      expect(() => p.defineMcpServers.add(
            const McpServerConfig(id: 'z', transport: McpTransport.stdio),
          ), throwsUnsupportedError);
    });

    test('PRO-02: effectiveEntryProcedure falls back to the mode default', () {
      expect(Profile(id: 'a').effectiveEntryProcedure, 'prompt_analyzer_v1');
      expect(Profile(id: 'b', mode: ProfileMode.answer).effectiveEntryProcedure,
          'answer_with_memory_v1');
      expect(
          Profile(id: 'c', mode: ProfileMode.passthrough).effectiveEntryProcedure,
          'passthrough_v1');
    });

    test('PRO-03: explicit entryProcedure overrides the mode default', () {
      final p = Profile(id: 'd', entryProcedure: 'answer_with_thinking_v1');
      expect(p.effectiveEntryProcedure, 'answer_with_thinking_v1');
    });
  });

  group('ProfileRegistry.fromYamlString — parse', () {
    test('REG-01: no profiles: block → registry has only the built-in default',
        () {
      final r = ProfileRegistry.fromYamlString('memory:\n  root: /tmp/x\n');
      expect(r.contains('default'), isTrue);
      expect(r.names, ['default']);
      final resolved = r.resolve('default');
      expect(resolved, const ResolvedProfile.cognitiveDefault());
    });

    test('REG-02: empty profiles: map → still only the built-in default', () {
      final r = ProfileRegistry.fromYamlString('profiles: {}\n');
      expect(r.names, ['default']);
    });

    test('REG-03: parses research/quick/relay with their fields', () {
      const yaml = '''
profiles:
  research:
    mode: cognitive
    role: researcher
    templateOverlay: research
    mcpServers: [web]
    defineMcpServers:
      - id: docs
        transport: stdio
        command: mcp-docs
        args: [--root, ./corpus]
        exposeToLlms: true
    budget:
      maxLlmCalls: 24
      wallClockSeconds: 180
    defaultMemory: research
  quick:
    mode: answer
    role: assistant_to_user
    rateLimits:
      requestsPerMinute: 30
  relay:
    mode: passthrough
    anchored: false
''';
      final r = ProfileRegistry.fromYamlString(yaml);
      expect(r.names, containsAll(<String>['default', 'research', 'quick', 'relay']));

      final research = r.profile('research')!;
      expect(research.mode, ProfileMode.cognitive);
      expect(research.role, 'researcher');
      expect(research.templateOverlay, 'research');
      expect(research.mcpServers, ['web']);
      expect(research.defineMcpServers.single.id, 'docs');
      expect(research.defineMcpServers.single.transport, McpTransport.stdio);
      expect(research.defineMcpServers.single.command, 'mcp-docs');
      expect(research.defineMcpServers.single.args, ['--root', './corpus']);
      expect(research.defineMcpServers.single.exposeToLlms, isTrue);
      expect(research.budget!.maxLlmCalls, 24);
      expect(research.budget!.wallClock, const Duration(seconds: 180));
      expect(research.defaultMemory, 'research');

      final quick = r.profile('quick')!;
      expect(quick.mode, ProfileMode.answer);
      expect(quick.role, 'assistant_to_user');
      expect(quick.rateLimits!.requestsPerMinute, 30);

      final relay = r.profile('relay')!;
      expect(relay.mode, ProfileMode.passthrough);
      expect(relay.anchored, isFalse);
    });

    test('REG-04: a redefined default replaces the built-in', () {
      const yaml = '''
profiles:
  default:
    mode: answer
    role: assistant_to_user
''';
      final r = ProfileRegistry.fromYamlString(yaml);
      expect(r.profile('default')!.mode, ProfileMode.answer);
      expect(r.resolve('default').entryProcedure, 'answer_with_memory_v1');
    });

    test('REG-05: mode + conflicting entryProcedure → ProfileConfigException', () {
      const yaml = '''
profiles:
  bad:
    mode: answer
    entryProcedure: passthrough_v1
''';
      expect(
        () => ProfileRegistry.fromYamlString(yaml),
        throwsA(isA<ProfileConfigException>()
            .having((e) => e.code, 'code', 'profile.mode_entry_conflict')),
      );
    });

    test('REG-06: entryProcedure without mode is a power-user override, not a '
        'conflict', () {
      const yaml = '''
profiles:
  power:
    entryProcedure: answer_with_thinking_v1
''';
      final r = ProfileRegistry.fromYamlString(yaml);
      expect(r.profile('power')!.effectiveEntryProcedure,
          'answer_with_thinking_v1');
    });

    test('REG-07: mode + matching entryProcedure is allowed (redundant)', () {
      const yaml = '''
profiles:
  ok:
    mode: answer
    entryProcedure: answer_with_memory_v1
''';
      final r = ProfileRegistry.fromYamlString(yaml);
      expect(r.profile('ok')!.effectiveEntryProcedure, 'answer_with_memory_v1');
    });

    test('REG-08: unknown mode token → ProfileConfigException', () {
      const yaml = '''
profiles:
  bad:
    mode: turbo
''';
      expect(() => ProfileRegistry.fromYamlString(yaml),
          throwsA(isA<ProfileConfigException>()));
    });
  });

  group('ProfileRegistry.resolve', () {
    test('RES-01: unknown name → UnknownProfileException', () {
      final r = ProfileRegistry.fromYamlString('profiles: {}\n');
      expect(() => r.resolve('nope'), throwsA(isA<UnknownProfileException>()));
    });

    test('RES-02: each mode maps to its entry procedure', () {
      const yaml = '''
profiles:
  c: {mode: cognitive}
  a: {mode: answer}
  p: {mode: passthrough}
''';
      final r = ProfileRegistry.fromYamlString(yaml);
      expect(r.resolve('c').entryProcedure, 'prompt_analyzer_v1');
      expect(r.resolve('a').entryProcedure, 'answer_with_memory_v1');
      expect(r.resolve('p').entryProcedure, 'passthrough_v1');
    });

    test('RES-03: explicit entryProcedure rides onto the resolved bundle', () {
      const yaml = '''
profiles:
  t: {entryProcedure: answer_with_thinking_v1}
''';
      final r = ProfileRegistry.fromYamlString(yaml);
      expect(r.resolve('t').entryProcedure, 'answer_with_thinking_v1');
    });

    test('RES-04: role/anchored/overlay/defaults carry through', () {
      const yaml = '''
profiles:
  s:
    role: researcher
    anchored: false
    templateOverlay: research
    defaultSession: work
    defaultMemory: research
''';
      final resolved = ProfileRegistry.fromYamlString(yaml).resolve('s');
      expect(resolved.role, 'researcher');
      expect(resolved.anchored, isFalse);
      expect(resolved.templateOverlay, 'research');
      expect(resolved.defaultSession, 'work');
      expect(resolved.defaultMemory, 'research');
    });

    group('offeredMcpServers (§ 3.6 / SCP-15)', () {
      test('RES-05: no allowlist + no defines → empty sentinel (all '
          'globally-exposed)', () {
        final r = ProfileRegistry.fromYamlString('profiles:\n  x: {}\n');
        final resolved = r.resolve('x', globalExposedIds: const ['web', 'fs']);
        expect(resolved.offeredMcpServers, isEmpty);
      });

      test('RES-06: allowlist intersects the global-exposed set; '
          'listed-but-unexposed dropped', () {
        const yaml = '''
profiles:
  x: {mcpServers: [web, secret]}
''';
        final r = ProfileRegistry.fromYamlString(yaml);
        final resolved = r.resolve('x', globalExposedIds: const ['web', 'fs']);
        expect(resolved.offeredMcpServers, ['web']);
      });

      test('RES-07: empty allowlist + exposed define → materialise globals ∪ '
          'namespaced define', () {
        const yaml = '''
profiles:
  x:
    defineMcpServers:
      - {id: docs, transport: stdio, command: d, exposeToLlms: true}
''';
        final r = ProfileRegistry.fromYamlString(yaml);
        final resolved = r.resolve('x', globalExposedIds: const ['web']);
        expect(resolved.offeredMcpServers, ['web', 'x/docs']);
      });

      test('RES-08: a non-exposed define is excluded from the offered set', () {
        const yaml = '''
profiles:
  x:
    mcpServers: [web]
    defineMcpServers:
      - {id: docs, transport: stdio, command: d, exposeToLlms: false}
''';
        final r = ProfileRegistry.fromYamlString(yaml);
        final resolved = r.resolve('x', globalExposedIds: const ['web']);
        expect(resolved.offeredMcpServers, ['web']);
      });
    });

    group('budget/rateLimits clamp (SC-8 / SCP-12)', () {
      test('RES-09: a looser budget is clamped to the ceiling', () {
        const yaml = '''
profiles:
  big: {budget: {maxLlmCalls: 100}}
''';
        final r = ProfileRegistry.fromYamlString(yaml);
        final resolved = r.resolve('big',
            budgetCeiling: const ProfileBudget(maxLlmCalls: 10));
        expect(resolved.budget!.maxLlmCalls, 10);
      });

      test('RES-10: a tighter budget is left untouched', () {
        const yaml = '''
profiles:
  small: {budget: {maxLlmCalls: 3}}
''';
        final r = ProfileRegistry.fromYamlString(yaml);
        final resolved = r.resolve('small',
            budgetCeiling: const ProfileBudget(maxLlmCalls: 10));
        expect(resolved.budget!.maxLlmCalls, 3);
      });

      test('RES-11: no ceiling → budget passes through unchanged', () {
        const yaml = '''
profiles:
  free: {budget: {maxLlmCalls: 100}}
''';
        final r = ProfileRegistry.fromYamlString(yaml);
        expect(r.resolve('free').budget!.maxLlmCalls, 100);
      });

      test('RES-12: a looser rate-limit is clamped to the ceiling', () {
        const yaml = '''
profiles:
  fast: {rateLimits: {requestsPerMinute: 600}}
''';
        final r = ProfileRegistry.fromYamlString(yaml);
        final resolved = r.resolve('fast',
            rateLimitCeiling: const ProfileRateLimits(requestsPerMinute: 60));
        expect(resolved.rateLimits!.requestsPerMinute, 60);
      });
    });
  });

  group('ProfileRegistry.validateAtBoot', () {
    ProfileRegistry registryFor(String body) =>
        ProfileRegistry.fromYamlString('profiles:\n$body');

    test('VAL-01: an unknown role → profile.unknown_role', () {
      final r = registryFor('  s: {role: ghost}\n');
      expect(
        () => r.validateAtBoot(
          knownRoles: const {'researcher'},
          overlayDirExists: (_) => true,
        ),
        throwsA(isA<ProfileConfigException>()
            .having((e) => e.code, 'code', 'profile.unknown_role')),
      );
    });

    test('VAL-02: a known role passes', () {
      final r = registryFor('  s: {role: researcher}\n');
      expect(
        () => r.validateAtBoot(
          knownRoles: const {'researcher'},
          overlayDirExists: (_) => true,
        ),
        returnsNormally,
      );
    });

    test('VAL-03: a missing overlay dir → profile.overlay_missing', () {
      final r = registryFor('  s: {templateOverlay: research}\n');
      expect(
        () => r.validateAtBoot(
          knownRoles: const {},
          overlayDirExists: (_) => false,
        ),
        throwsA(isA<ProfileConfigException>()
            .having((e) => e.code, 'code', 'profile.overlay_missing')),
      );
    });

    test('VAL-04: a present overlay dir passes', () {
      final r = registryFor('  s: {templateOverlay: research}\n');
      expect(
        () => r.validateAtBoot(
          knownRoles: const {},
          overlayDirExists: (name) => name == 'research',
        ),
        returnsNormally,
      );
    });

    test('VAL-05: a looser budget logs a warning, does not throw', () {
      final r = registryFor('  big: {budget: {maxLlmCalls: 100}}\n');
      final warnings = <String>[];
      r.validateAtBoot(
        knownRoles: const {},
        overlayDirExists: (_) => true,
        budgetCeiling: const ProfileBudget(maxLlmCalls: 10),
        warn: warnings.add,
      );
      expect(warnings, isNotEmpty);
      expect(warnings.first, contains('big'));
    });

    test('VAL-06: a within-ceiling budget logs nothing', () {
      final r = registryFor('  small: {budget: {maxLlmCalls: 3}}\n');
      final warnings = <String>[];
      r.validateAtBoot(
        knownRoles: const {},
        overlayDirExists: (_) => true,
        budgetCeiling: const ProfileBudget(maxLlmCalls: 10),
        warn: warnings.add,
      );
      expect(warnings, isEmpty);
    });
  });

  group('ProfileRegistry.namespacedDefinedServers', () {
    test('NS-01: define ids are rewritten to <profileId>/<serverName>', () {
      const yaml = '''
profiles:
  research:
    defineMcpServers:
      - {id: docs, transport: stdio, command: d, exposeToLlms: true}
      - {id: notes, transport: stdio, command: n, exposeToLlms: false}
''';
      final r = ProfileRegistry.fromYamlString(yaml);
      final ids = r.namespacedDefinedServers.map((s) => s.id).toList();
      expect(ids, containsAll(<String>['research/docs', 'research/notes']));
    });

    test('NS-02: no defines anywhere → empty list', () {
      final r = ProfileRegistry.fromYamlString('profiles:\n  x: {}\n');
      expect(r.namespacedDefinedServers, isEmpty);
    });
  });

  // Runtime authoring engine (I-6, Phase 1) — `author` upserts a profile and
  // `remove` deletes one, both with boot-identical environmental validation and
  // the SC-5 guarantee that `default` always exists. The persisted write
  // surface (Observatory PUT + on-disk yaml_edit) is the deferred Phase 2.
  group('ProfileRegistry runtime authoring (I-6)', () {
    ProfileAuthoringContext ctx({
      Set<String> knownRoles = const <String>{},
      bool Function(String)? overlayDirExists,
      ProfileBudget? budgetCeiling,
      void Function(String)? warn,
    }) =>
        ProfileAuthoringContext(
          knownRoles: knownRoles,
          overlayDirExists: overlayDirExists ?? (_) => true,
          budgetCeiling: budgetCeiling,
          warn: warn,
        );

    test('AUTH-01: author a new profile → resolvable like a configured one', () {
      final r = ProfileRegistry.fromYamlString('profiles: {}\n');
      expect(r.contains('research'), isFalse);
      r.author(Profile(id: 'research', mode: ProfileMode.answer), ctx());
      expect(r.contains('research'), isTrue);
      expect(r.names, containsAll(<String>['default', 'research']));
      expect(r.resolve('research').entryProcedure, 'answer_with_memory_v1');
    });

    test('AUTH-02: author replaces an existing profile by id', () {
      final r = ProfileRegistry.fromYamlString(
          'profiles:\n  s: {mode: answer}\n');
      expect(r.profile('s')!.mode, ProfileMode.answer);
      r.author(Profile(id: 's', mode: ProfileMode.passthrough), ctx());
      expect(r.profile('s')!.mode, ProfileMode.passthrough);
    });

    test('AUTH-03: author may redefine the built-in default', () {
      final r = ProfileRegistry.fromYamlString('profiles: {}\n');
      r.author(Profile(id: 'default', mode: ProfileMode.answer), ctx());
      expect(r.resolve('default').entryProcedure, 'answer_with_memory_v1');
    });

    test('AUTH-04: an unknown role rejects with profile.unknown_role and leaves '
        'the registry unchanged', () {
      final r = ProfileRegistry.fromYamlString('profiles: {}\n');
      expect(
        () => r.author(
          Profile(id: 'ghosted', role: 'ghost'),
          ctx(knownRoles: const {'researcher'}),
        ),
        throwsA(isA<ProfileConfigException>()
            .having((e) => e.code, 'code', 'profile.unknown_role')),
      );
      expect(r.contains('ghosted'), isFalse);
    });

    test('AUTH-05: a missing overlay dir rejects with profile.overlay_missing '
        'and leaves the registry unchanged', () {
      final r = ProfileRegistry.fromYamlString('profiles: {}\n');
      expect(
        () => r.author(
          Profile(id: 'over', templateOverlay: 'nope'),
          ctx(overlayDirExists: (_) => false),
        ),
        throwsA(isA<ProfileConfigException>()
            .having((e) => e.code, 'code', 'profile.overlay_missing')),
      );
      expect(r.contains('over'), isFalse);
    });

    test('AUTH-06: a looser budget warns (does not throw); stored raw, clamped '
        'at resolve', () {
      final r = ProfileRegistry.fromYamlString('profiles: {}\n');
      final warnings = <String>[];
      r.author(
        Profile(id: 'big', budget: const ProfileBudget(maxLlmCalls: 100)),
        ctx(
          budgetCeiling: const ProfileBudget(maxLlmCalls: 10),
          warn: warnings.add,
        ),
      );
      expect(warnings, isNotEmpty);
      expect(warnings.first, contains('big'));
      expect(r.profile('big')!.budget!.maxLlmCalls, 100);
      final resolved = r.resolve('big',
          budgetCeiling: const ProfileBudget(maxLlmCalls: 10));
      expect(resolved.budget!.maxLlmCalls, 10);
    });

    test('REM-01: remove an authored profile → gone, returns true', () {
      final r = ProfileRegistry.fromYamlString('profiles: {}\n');
      r.author(Profile(id: 'temp'), ctx());
      expect(r.remove('temp'), isTrue);
      expect(r.contains('temp'), isFalse);
    });

    test('REM-02: removing an absent profile returns false', () {
      final r = ProfileRegistry.fromYamlString('profiles: {}\n');
      expect(r.remove('never'), isFalse);
    });

    test('REM-03: removing the built-in default is refused (SC-5)', () {
      final r = ProfileRegistry.fromYamlString('profiles: {}\n');
      expect(
        () => r.remove('default'),
        throwsA(isA<ProfileConfigException>()
            .having((e) => e.code, 'code', 'profile.default_immutable')),
      );
      expect(r.contains('default'), isTrue);
    });
  });
}
