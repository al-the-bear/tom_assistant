// Trail config block + mode resolution + startup banner — §10 build-order
// step #1 of `tom_brain_logging.md`.
//
// Logging-spec §4.1 defines two operating modes and a startup banner:
//
//   * Full trailing   — a `trail:` block whose `root` is configured: the whole
//     tree under `trail.root` is written.
//   * Unconfigured    — no `trail:` block at all: only `brain.log` +
//     `components/*.log` in the CWD; every other surface disabled.
//
// §8 defines the `trail:` block fields and their defaults (count/size caps +
// the `capture` sub-block). This step lands the typed `TrailConfig`, the
// `TrailMode` switch on `BrainRunConfig`, the `TrailConfigLoader` (canonical
// plain-map loader — no `YamlMap`/`YamlList` leak), and the pure
// `TrailBanner.forStartup` text, before any surface writes a byte.
//
// Interpretation (surfaced before coding): §8's "shipped config sets it;
// default value …" describes what the *shipped config file* writes, not a
// loader-computed default. The loader stays pure and deterministic — it does
// not probe hostname / workspace to synthesise a root. A present `trail:`
// block therefore *requires* `root`; its absence is unconfigured mode.
//
// ── What this suite proves ───────────────────────────────────────────
//
//   Group A — TrailConfigLoader.parse (pure): an absent block → null
//   (unconfigured); a full block → a fully-populated `TrailConfig`; `${ENV}`
//   expansion of `root`; the §8 defaults when caps/capture are omitted; and a
//   located error for each malformed shape (missing root, non-positive cap,
//   unknown key under `trail:` / `trail.capture`, undefined env var, non-map
//   block, wrong-typed cap).
//
//   Group B — mode resolution: `BrainRunConfig.trailMode` is `unconfigured`
//   when `trail` is null and `full` otherwise; `BrainRunConfigLoader.parse`
//   threads the `trail:` section through (and, by tolerating it as a top-level
//   section, proves the access loader's allow-list now admits `trail`).
//
//   Group C — TrailBanner.forStartup (pure): the §4.1 banner text for both
//   modes — the enabled banner names the root and the six full-tree surfaces;
//   the unconfigured banner names the CWD, the disabled surfaces, and the
//   "set `trail.root`" hint.

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';

/// The `substrate:` section in the prototype's real deployment shape (mirrors
/// `r31_run_config_test.dart`) — needed only so `BrainRunConfigLoader.parse`
/// can assemble a whole `BrainRunConfig` in Group B.
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
    analyser:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
    assistant_to_user:
      - providerId: omlx
        model: gemma-4-26b-a4b-it-4bit
  embedding:
    providerId: ollama
    model: nomic-embed-text
    dims: 768
    normalize: true''';

/// A `memory:` section (parse is pure — paths are never touched on disk).
const String _memorySection = '''
memory:
  root: "/var/tmp/brain-mem"
  sqliteVec:
    binariesRoot: "/var/tmp/sqlite-vec"''';

/// The `access:` section: one OpenAI port + one bearer-bound user + the
/// required rate-limit / quota blocks (mirrors `r31_run_config_test.dart`).
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

/// A fully-specified `trail:` section (every §8 field set).
const String _fullTrailSection = '''
trail:
  root: /srv/brain/_ai/tom_brain_trail/bomber
  compactLogCap: 1200
  liveTrailTurns: 25
  llmPerRoleCap: 400
  incomingPerChannelCap: 350
  proceduresPerKindCap: 360
  rawAggregateSizeMb: 2048
  capture:
    wireBody: false
    internalRoles: false''';

void main() {
  group('A · TrailConfigLoader.parse (pure)', () {
    test('absent trail: block → null (unconfigured mode)', () {
      final TrailConfig? trail = TrailConfigLoader.parse(_memorySection);
      expect(trail, isNull);
    });

    test('full trail: block → fully-populated TrailConfig', () {
      final TrailConfig? trail = TrailConfigLoader.parse(_fullTrailSection);
      expect(trail, isNotNull);
      expect(trail!.root, '/srv/brain/_ai/tom_brain_trail/bomber');
      expect(trail.compactLogCap, 1200);
      expect(trail.liveTrailTurns, 25);
      expect(trail.llmPerRoleCap, 400);
      expect(trail.incomingPerChannelCap, 350);
      expect(trail.proceduresPerKindCap, 360);
      expect(trail.rawAggregateSizeMb, 2048);
      expect(trail.captureWireBody, isFalse);
      expect(trail.captureInternalRoles, isFalse);
    });

    test('§8 defaults apply when caps / capture omitted', () {
      final TrailConfig? trail =
          TrailConfigLoader.parse('trail:\n  root: /x/trail');
      expect(trail, isNotNull);
      expect(trail!.root, '/x/trail');
      expect(trail.compactLogCap, 1000);
      expect(trail.liveTrailTurns, 20);
      expect(trail.llmPerRoleCap, 300);
      expect(trail.incomingPerChannelCap, 300);
      expect(trail.proceduresPerKindCap, 300);
      expect(trail.rawAggregateSizeMb, 1024);
      expect(trail.captureWireBody, isTrue);
      expect(trail.captureInternalRoles, isTrue);
    });

    test('\${ENV} in root is expanded from envVars', () {
      final TrailConfig? trail = TrailConfigLoader.parse(
        'trail:\n  root: \${TOM_BRAIN_TRAIL_ROOT}',
        envVars: const {'TOM_BRAIN_TRAIL_ROOT': '/env/trail/root'},
      );
      expect(trail, isNotNull);
      expect(trail!.root, '/env/trail/root');
    });

    test('present block missing root → located error', () {
      expect(
        () => TrailConfigLoader.parse('trail:\n  compactLogCap: 100'),
        throwsA(
          isA<TrailConfigException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('trail.root'), contains('Missing required')),
          ),
        ),
      );
    });

    test('non-positive cap → located error', () {
      expect(
        () => TrailConfigLoader.parse(
            'trail:\n  root: /x\n  compactLogCap: 0'),
        throwsA(
          isA<TrailConfigException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('trail.compactLogCap'), contains('positive')),
          ),
        ),
      );
    });

    test('unknown key under trail: → located error', () {
      expect(
        () => TrailConfigLoader.parse('trail:\n  root: /x\n  bogus: 1'),
        throwsA(
          isA<TrailConfigException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('Unknown'), contains('bogus'), contains('trail')),
          ),
        ),
      );
    });

    test('unknown key under trail.capture → located error', () {
      expect(
        () => TrailConfigLoader.parse(
            'trail:\n  root: /x\n  capture:\n    bogus: true'),
        throwsA(
          isA<TrailConfigException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('Unknown'), contains('bogus'),
                contains('trail.capture')),
          ),
        ),
      );
    });

    test('undefined env var in root → located error', () {
      expect(
        () => TrailConfigLoader.parse('trail:\n  root: \${NOPE}'),
        throwsA(
          isA<TrailConfigException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('trail.root'), contains('NOPE')),
          ),
        ),
      );
    });

    test('non-map trail: → located error', () {
      expect(
        () => TrailConfigLoader.parse('trail: nope'),
        throwsA(
          isA<TrailConfigException>().having(
            (e) => e.toString(),
            'message',
            contains('trail'),
          ),
        ),
      );
    });

    test('wrong-typed cap → located error', () {
      expect(
        () => TrailConfigLoader.parse(
            'trail:\n  root: /x\n  compactLogCap: nope'),
        throwsA(
          isA<TrailConfigException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('trail.compactLogCap'), contains('number')),
          ),
        ),
      );
    });
  });

  group('B · mode resolution', () {
    test('BrainRunConfig.trailMode is unconfigured when trail is null', () {
      final TrailConfig? trail = TrailConfigLoader.parse(_memorySection);
      final BrainRunConfig config = BrainRunConfigLoader.parse(
        '$_substrateSection\n$_memorySection\n$_accessSection\n',
      );
      expect(trail, isNull);
      expect(config.trail, isNull);
      expect(config.trailMode, TrailMode.unconfigured);
    });

    test('BrainRunConfigLoader threads a trail: section → full mode', () {
      final BrainRunConfig config = BrainRunConfigLoader.parse(
        '$_substrateSection\n$_memorySection\n$_accessSection\n'
        '$_fullTrailSection\n',
      );
      expect(config.trail, isNotNull);
      expect(config.trail!.root, '/srv/brain/_ai/tom_brain_trail/bomber');
      expect(config.trailMode, TrailMode.full);
    });
  });

  group('C · TrailBanner.forStartup (pure)', () {
    test('enabled banner names the root and the six full-tree surfaces', () {
      final TrailConfig trail =
          TrailConfigLoader.parse('trail:\n  root: /srv/brain/trail')!;
      final String banner =
          TrailBanner.forStartup(trail, cwd: '/srv/run/cwd');
      expect(banner, contains('[tom_brain.trail]'));
      expect(banner, contains('ENABLED'));
      expect(banner, contains('/srv/brain/trail'));
      for (final surface in const [
        'llm',
        'incoming',
        'procedures',
        'memory',
        'sessions',
        'summary',
      ]) {
        expect(banner, contains(surface), reason: 'missing surface $surface');
      }
    });

    test('unconfigured banner names the CWD, disabled surfaces, and the hint',
        () {
      final String banner =
          TrailBanner.forStartup(null, cwd: '/srv/run/cwd');
      expect(banner, contains('[tom_brain.trail]'));
      expect(banner, contains('NOT CONFIGURED'));
      expect(banner, contains('component logs only'));
      expect(banner, contains('/srv/run/cwd'));
      expect(banner, contains('DISABLED'));
      expect(banner, contains('trail.root'));
    });
  });
}
