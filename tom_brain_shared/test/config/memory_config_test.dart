// Tests for the § 12 usage-decay / ranking config value types
// (memory_optimization_plan.md § 12; memory_specification.md § 6.6,
// § 9.7, § 14).
//
// Surface under test (pure value types in `tom_brain_shared`):
//   * `RankingConfig` — the post-fusion re-score tunables
//     (`defaultRanking`, `recencyWeight`) and their defaults.
//   * `DecayConfig` — the per-type half-life map, its typed `default`
//     fallback, and the `halfLifeDaysFor` lookup that owns the fallback.
//   * `DecayDemoteConfig` — the `dream_decay_v1` demotion knobs and
//     their defaults.
//   * `MemoryConfig.decay` defaulting + `withProfile` preservation.
//
// The YAML→object parsing + validation is covered separately in
// `tom_brain_memory/test/a83_memory_config_loader_test.dart`.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  group('RankingConfig', () {
    test('defaults to relevance + recencyWeight 1.0', () {
      const cfg = RankingConfig();
      expect(cfg.defaultRanking, RecallRanking.relevance);
      expect(cfg.recencyWeight, 1.0);
    });

    test('carries explicit values', () {
      const cfg = RankingConfig(
        defaultRanking: RecallRanking.recencyBoosted,
        recencyWeight: 2.5,
      );
      expect(cfg.defaultRanking, RecallRanking.recencyBoosted);
      expect(cfg.recencyWeight, 2.5);
    });

    test('RetrievalConfig embeds a default RankingConfig', () {
      const cfg = RetrievalConfig();
      expect(cfg.ranking.defaultRanking, RecallRanking.relevance);
      expect(cfg.ranking.recencyWeight, 1.0);
    });
  });

  group('DecayDemoteConfig', () {
    test('defaults match the § 14 example', () {
      const cfg = DecayDemoteConfig();
      expect(cfg.maxPerPass, 200);
      expect(cfg.minAccessCount, 1);
      expect(cfg.coldnessFloorDays, 30);
    });
  });

  group('DecayConfig.halfLifeDaysFor', () {
    test('returns the per-type override when present', () {
      const cfg = DecayConfig(
        halfLifeDays: {'Event': 14, 'Concept': 365},
        defaultHalfLifeDays: 90,
      );
      expect(cfg.halfLifeDaysFor('Event'), 14);
      expect(cfg.halfLifeDaysFor('Concept'), 365);
    });

    test('falls back to defaultHalfLifeDays for an unlisted type', () {
      const cfg = DecayConfig(
        halfLifeDays: {'Event': 14},
        defaultHalfLifeDays: 60,
      );
      expect(cfg.halfLifeDaysFor('Claim'), 60);
      expect(cfg.halfLifeDaysFor('AnythingUnseen'), 60);
    });

    test('an empty map always yields the typed default (90)', () {
      const cfg = DecayConfig();
      expect(cfg.halfLifeDays, isEmpty);
      expect(cfg.defaultHalfLifeDays, 90);
      expect(cfg.halfLifeDaysFor('Event'), 90);
    });

    test('default demote knobs are present on a default DecayConfig', () {
      const cfg = DecayConfig();
      expect(cfg.demote.maxPerPass, 200);
      expect(cfg.demote.minAccessCount, 1);
      expect(cfg.demote.coldnessFloorDays, 30);
    });
  });

  group('MemoryConfig.decay', () {
    test('defaults to a DecayConfig with the 90-day fallback', () {
      final cfg = MemoryConfig.forTesting(
        root: '/tmp/x',
        extensionPath: '/opt/vec0.so',
      );
      expect(cfg.decay.halfLifeDaysFor('Event'), 90);
      expect(cfg.retrieval.ranking.defaultRanking, RecallRanking.relevance);
    });

    test('withProfile preserves the decay + ranking config verbatim', () {
      const decay = DecayConfig(
        halfLifeDays: {'Event': 14},
        defaultHalfLifeDays: 60,
        demote: DecayDemoteConfig(maxPerPass: 50),
      );
      const retrieval = RetrievalConfig(
        ranking: RankingConfig(
          defaultRanking: RecallRanking.recencyBoosted,
          recencyWeight: 3.0,
        ),
      );
      final base = MemoryConfig(
        root: '/tmp/x',
        sqliteVec: const SqliteVecConfig(extensionPath: '/opt/vec0.so'),
        retrieval: retrieval,
        decay: decay,
      );

      final bound = base.withProfile('alice');
      expect(bound.profile, 'alice');
      expect(bound.decay.halfLifeDaysFor('Event'), 14);
      expect(bound.decay.defaultHalfLifeDays, 60);
      expect(bound.decay.demote.maxPerPass, 50);
      expect(
        bound.retrieval.ranking.defaultRanking,
        RecallRanking.recencyBoosted,
      );
      expect(bound.retrieval.ranking.recencyWeight, 3.0);
    });
  });
}
