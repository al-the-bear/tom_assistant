// Built-in placeholder binding set — increment 2 of `prompt_configuration.md`
// (§6 *Realisation* + §12 step 2).
//
// `tom_brain_run` binds the six boot-time built-ins the whole brain stack reads
// — `${hostname}`, `${trail_folder}`, `${config_folder}`, `${memory_root}`,
// `${scripts_folder}`, `${role.anchor}` — into every resolver it hands down.
// `BrainBuiltins` is that binding set: derived from the parsed `BrainRunConfig`
// plus the two boot-resolved folders the config does not carry (the cognition
// root and the resolved `scripts/system` dir), with the dedication anchor as a
// compile-time constant.
//
// ── What this suite proves ───────────────────────────────────────────
//
//   Group A — the binding set: all six built-ins, `${role.anchor}` is the
//   canonical `AssistantDedicationAnchor.text`, and `bindInto` seeds a stack.
//
//   Group B — each built-in resolves in a *config value* (`resolveSync`, the
//   env-only/binding-only path) and in a *template* (`resolve`, the async path
//   with the d4rt expression backing), including a `${{ hostname }}` expression
//   over a simple-identifier built-in. The `${role.anchor}` dot-key is reachable
//   only via the simple `${role.anchor}` lookup, never as a `${{ … }}` local.
//
//   Group C — `fromRunConfig` derivation: `${memory_root}` from
//   `config.memory.root`, `${trail_folder}` from `config.trail?.root` (empty in
//   unconfigured mode), the explicit `configFolder` / `scriptsFolder`, and the
//   `hostname` override.

import 'package:test/test.dart';

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show D4rtExpressionContext;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;

/// A representative built-in set with distinct, recognisable values.
BrainBuiltins _builtins() => const BrainBuiltins(
      hostname: 'bomber',
      trailFolder: '/srv/brain/trail',
      configFolder: '/srv/brain/config/cognition',
      memoryRoot: '/srv/brain/memory',
      scriptsFolder: '/srv/brain/scripts/system',
    );

void main() {
  group('BrainBuiltins — the binding set', () {
    test('exposes all six §6 built-ins with the anchor as a constant', () {
      final bindings = _builtins().bindings;
      expect(bindings, <String, Object?>{
        'hostname': 'bomber',
        'trail_folder': '/srv/brain/trail',
        'config_folder': '/srv/brain/config/cognition',
        'memory_root': '/srv/brain/memory',
        'scripts_folder': '/srv/brain/scripts/system',
        'role.anchor': AssistantDedicationAnchor.text,
      });
    });

    test('bindInto seeds the six built-ins into a stack', () {
      final stack = PlaceholderStack();
      _builtins().bindInto(stack);
      expect(stack.lookup('hostname'), 'bomber');
      expect(stack.lookup('memory_root'), '/srv/brain/memory');
      expect(stack.lookup('role.anchor'), AssistantDedicationAnchor.text);
    });
  });

  group('BrainBuiltins — resolves in a config value and a template', () {
    test('each built-in resolves in a config value (resolveSync)', () {
      final resolver = _builtins().resolver();
      expect(resolver.resolveSync(r'${hostname}'), 'bomber');
      expect(resolver.resolveSync(r'${trail_folder}'), '/srv/brain/trail');
      expect(
        resolver.resolveSync(r'${config_folder}'),
        '/srv/brain/config/cognition',
      );
      expect(resolver.resolveSync(r'${memory_root}'), '/srv/brain/memory');
      expect(
        resolver.resolveSync(r'${scripts_folder}'),
        '/srv/brain/scripts/system',
      );
      expect(
        resolver.resolveSync(r'${role.anchor}'),
        AssistantDedicationAnchor.text,
      );
      // A composed config value reads several built-ins at once.
      expect(
        resolver.resolveSync(r'${memory_root}/memory.db'),
        '/srv/brain/memory/memory.db',
      );
    });

    test('each built-in resolves in a template (async resolve)', () async {
      final resolver = _builtins().resolver(expressions: D4rtExpressionContext());
      expect(await resolver.resolve(r'host=${hostname}'), 'host=bomber');
      expect(
        await resolver.resolve(r'${scripts_folder}/answer_with_memory_v1.dart'),
        '/srv/brain/scripts/system/answer_with_memory_v1.dart',
      );
      expect(
        await resolver.resolve(r'${role.anchor}'),
        AssistantDedicationAnchor.text,
      );
    });

    test(r'a simple-identifier built-in is readable from a ${{ … }} expression',
        () async {
      final resolver = _builtins().resolver(expressions: D4rtExpressionContext());
      expect(await resolver.resolve(r'${{ hostname }}'), 'bomber');
      expect(
        await resolver.resolve(r"${{ hostname == 'bomber' ? 'yes' : 'no' }}"),
        'yes',
      );
    });
  });

  group('BrainBuiltins.fromRunConfig — derivation', () {
    test('derives memory_root / trail_folder and takes explicit folders', () {
      final config = BrainRunConfigLoader.parse(_runYaml(withTrail: true));
      final builtins = BrainBuiltins.fromRunConfig(
        config,
        configFolder: '/srv/cfg/cognition',
        scriptsFolder: '/srv/scripts/system',
        hostname: 'bigbeast',
      );
      expect(builtins.memoryRoot, '/var/lib/tom_brain/memory');
      expect(builtins.trailFolder, '/var/log/tom_brain/trail');
      expect(builtins.configFolder, '/srv/cfg/cognition');
      expect(builtins.scriptsFolder, '/srv/scripts/system');
      expect(builtins.hostname, 'bigbeast');
    });

    test('trail_folder is empty in unconfigured mode (no trail block)', () {
      final config = BrainRunConfigLoader.parse(_runYaml(withTrail: false));
      final builtins = BrainBuiltins.fromRunConfig(
        config,
        configFolder: '/c',
        scriptsFolder: '/s',
        hostname: 'h',
      );
      expect(builtins.trailFolder, '');
    });
  });
}

/// A minimal whole-process YAML: the three required sections, optionally a
/// `trail:` block, with recognisable `memory.root` / `trail.root` values.
String _runYaml({required bool withTrail}) =>
    '$_substrateSection\n'
    'memory:\n'
    '  root: "/var/lib/tom_brain/memory"\n'
    '  sqliteVec:\n'
    '    binariesRoot: "/opt/tom_binaries/sqlite_vec"\n'
    '$_accessSection\n'
    '${withTrail ? _trailSection : ''}';

const String _substrateSection = '''
substrate:
  providers:
    - id: omlx
      kind: openai
      baseUrl: http://10.8.0.7:8000/v1/
      models:
        - gemma-4-26b-a4b-it-4bit
    - id: ollama
      kind: ollama
      baseUrl: http://10.8.0.9:11434
      models:
        - nomic-embed-text
  roleRoutes:
    assistant_to_user:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
  embedding:
    providerId: ollama
    model: nomic-embed-text
    dims: 768
    normalize: true''';

const String _accessSection = '''
access:
  openai:
    port: 8080
    basePath: /v1
  users:
    - id: owner
      displayName: Owner
      openaiBearerTokens:
        - run-token
  rateLimit:
    capacity: 1000000
    refillTokens: 1000000
    refillPeriodSeconds: 1
  quota:
    dailyCap: 1000000''';

const String _trailSection = '''
trail:
  root: "/var/log/tom_brain/trail"
''';
