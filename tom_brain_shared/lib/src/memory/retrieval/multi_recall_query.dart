// MultiRecallQuery + RecallSeed — input to
// `TomBrainMemory.recallMulti` (memory_specification.md § 6.5,
// Extension H).
//
// `recall` (recall_query.dart) runs the four modes over **one**
// payload. Extension H needs many payloads at once — the prompt, the
// LLM's questions, hypothetical answers, key phrases, type filters,
// Concept seeds — each a separate seed possibly in a different mode.
// `recallMulti` is that surface: it runs every seed (re-using the
// § 6.1 mode implementations), fuses the per-seed ranked lists with
// RRF honouring each seed's `weight`, applies MMR, and returns one
// `RecallResult` whose `provenance` records which seeds surfaced each
// node and the fused score.
//
// Like every memory surface, `recallMulti` instantiates **no LLM**
// (Q-H.1). Text seeds are embedded by the storage-stack embedding
// model exactly as `recall(text)` already does; LLM-derived seeds are
// computed by the procedure layer and passed in as ordinary seeds —
// memory cannot tell an LLM-derived seed from a non-LLM one.
//
// These types live in `tom_brain_shared` (alongside `RecallQuery`)
// because every component that constructs a multi-seed recall — the
// procedure layer's retrieval orchestration, the `memory.recall.multi`
// MCP tool's argument parser — needs them without a runtime dependency
// on `tom_brain_memory`.

import '../../embedding/embedding.dart' show Vec;
import '../../ids/ids.dart' show NodeId;
import '../../symbolic/symbolic.dart' show SymbolicFilter;

import 'recall_query.dart'
    show DiversityPolicy, FusionPolicy, RecallBudget, RecallMode;

/// One seed in a [MultiRecallQuery] (§ 6.5).
///
/// A seed is a single-mode recall payload plus a fusion [weight] and a
/// per-seed result cap [k]. The fields a given mode reads mirror the
/// single-payload `RecallQuery`:
///
///   * [RecallMode.bm25] — [text] or [terms].
///   * [RecallMode.vector] — [embedding] (preferred, skips the embed
///     callout) or [text] (embedded by the storage-stack model).
///   * [RecallMode.graphWalk] — [startNodes] (+ optional [filter] for
///     the edge / depth scope).
///   * [RecallMode.symbolic] — [filter].
///
/// Fields irrelevant to [mode] are ignored. A seed whose required
/// payload for its mode is absent contributes an empty ranked list
/// (it degrades exactly as the equivalent single-mode `recall` would).
final class RecallSeed {
  /// Which one of the four retrieval modes this seed runs.
  final RecallMode mode;

  /// Query text for BM25 / vector seeds. For a vector seed it is
  /// embedded by the storage-stack model when [embedding] is null.
  final String? text;

  /// Pre-computed vector seed (skips the embed callout). Vector mode
  /// only.
  final Vec? embedding;

  /// Explicit BM25 query terms. BM25 mode only; when present they are
  /// joined into the BM25 query in place of [text].
  final List<String>? terms;

  /// Seed node set for a graph-walk seed.
  final Set<NodeId>? startNodes;

  /// Symbolic filter — the `WHERE` for a symbolic seed, or the
  /// edge/depth scope for a graph-walk seed.
  final SymbolicFilter? filter;

  /// Fusion weight. The fused score of a node is the weighted sum of
  /// its reciprocal-rank contributions across the seeds that surfaced
  /// it (§ 6.5). Must be `>= 0`; defaults to `1.0`.
  final double weight;

  /// Per-seed candidate cap, before fusion. Defaults to 64 — the same
  /// per-mode default `RecallBudget.perModeK` carries.
  final int k;

  const RecallSeed({
    required this.mode,
    this.text,
    this.embedding,
    this.terms,
    this.startNodes,
    this.filter,
    this.weight = 1.0,
    this.k = 64,
  });
}

/// Input record for `TomBrainMemory.recallMulti` (§ 6.5).
///
/// Carries the seed array plus the always-on [scope] constraint, the
/// post-fusion result cap [k], and the budget / fusion / diversity
/// policies. The fusion policy's per-mode `weights` are not consulted
/// for multi-seed fusion — weighting is per **seed** (each
/// [RecallSeed.weight]) rather than per mode; [FusionPolicy] is carried
/// for its `rrfK` smoothing constant and strategy selector.
final class MultiRecallQuery {
  /// The seeds to fan out over. An empty list yields an empty result.
  final List<RecallSeed> seeds;

  /// Always-on constraint applied to every seed (e.g. a
  /// principal / profile filter). `null` = no extra constraint.
  final SymbolicFilter? scope;

  /// Post-fusion cap on the total result list.
  final int k;

  /// Wall-clock + per-mode caps shared across the seeds.
  final RecallBudget budget;

  /// Fusion policy. RRF (default) with per-seed `weight` respected;
  /// `rrfK` is taken from here.
  final FusionPolicy fusion;

  /// Diversity policy (MMR by default), applied to the fused list.
  final DiversityPolicy diversity;

  const MultiRecallQuery({
    required this.seeds,
    this.scope,
    this.k = 20,
    this.budget = const RecallBudget(),
    this.fusion = FusionPolicy.defaultRrf,
    this.diversity = DiversityPolicy.defaultMmr,
  });
}
