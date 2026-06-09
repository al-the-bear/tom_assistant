// Typed planning queries (`planning_specification.md` § 7.4, § 10, G-P5).
//
// Memory exposes a small set of *primitive* read operations — `recall`,
// `edgesOf`, `get`, `getMany`. The planning subsystem needs four *named* reads
// on top of them:
//
//   * `OpenPlansFor` — the still-pursued plans (`draft` / `active`) for a goal,
//     so a re-planner or a Forge inspector can pick up live work. Symbolic when
//     no goal text is given; bm25 + vector relevance when it is.
//   * `StepsBlockedBy` — the steps that depend on a given step. A `depends-on`
//     relationship is a `part_of` edge carrying `attrs.kind = depends_on`
//     (§ 5.3 — no new edge label), oriented `dependent → dependency`; so the
//     steps blocked by a dependency are the incoming dependency edges' `from`s.
//   * `PlanStepsInOrder` — a plan's steps in a dependency-respecting order, via
//     the domain-free `orderPlanSteps` (Kahn). A dependency cycle is surfaced
//     in `cyclic` rather than silently dropped.
//   * `SupersededHistoryOf` — the full `superseded_by` revision chain a Plan
//     belongs to, oldest → newest. Revisions are structural and never deleted
//     (hard principle 6), so the chain walk is how the live tip and the full
//     audit history are read back. Delegates to the shared `walkSupersededByChain`.
//
// Each query is a small immutable value describing *what* to read; `execute`
// composes the client primitives to *do* the read and returns typed
// `PlanView` / `PlanStepView`s. They live here in `tom_brain_memory` (not in
// shared) because they compose the memory client contract; the *shapes* they
// return (`PlanView`, `PlanStepView`) and the *ordering* they apply
// (`orderPlanSteps`) are the shared / domain-free pieces, owned elsewhere.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart'
    show PlanStepOrdering, orderPlanSteps;

import '../graph/revision_chain.dart' show walkSupersededByChain;

/// The still-pursued plans for a goal (`planning_specification.md` § 7.4).
///
/// With no [goalText] (and no [embedding]) this is a symbolic scan over `Plan`
/// nodes; with goal text it recalls over BM25 (+ vector) for relevance. Either
/// way the result is filtered to open plans (`draft` / `active` per
/// [PlanView.isOpen]) and capped at [limit].
final class OpenPlansFor {
  /// Goal text to rank plans by. When null, all `Plan` nodes are scanned.
  final String? goalText;

  /// Pre-computed goal embedding for vector relevance. Ignored when [goalText]
  /// is also null (a pure symbolic scan needs neither).
  final Vec? embedding;

  /// How many plan nodes to pull before the open-filter and [limit].
  final int poolSize;

  /// How many open plans to return.
  final int limit;

  const OpenPlansFor({
    this.goalText,
    this.embedding,
    this.poolSize = 32,
    this.limit = 16,
  });

  /// Runs the query against [client]. Returns the open plans, recall order
  /// preserved, capped at [limit].
  Future<List<PlanView>> execute(TomBrainMemoryClient client) async {
    final modes = <RecallMode>{
      if (goalText != null) RecallMode.bm25,
      if (embedding != null || goalText != null) RecallMode.vector,
    };
    final query = modes.isEmpty
        ? const RecallQuery(
            modes: <RecallMode>{RecallMode.symbolic},
            filter: SymbolicFilter(typeNames: <String>{planNodeTypeName}),
            k: 32,
          )
        : RecallQuery(
            modes: modes,
            text: goalText,
            embedding: embedding,
            filter:
                const SymbolicFilter(typeNames: <String>{planNodeTypeName}),
            k: poolSize,
          );

    final result = await client.recall(query);
    final open = <PlanView>[
      for (final node in result.nodes)
        if (PlanView.fromNode(node) case final v when v.isOpen) v,
    ];
    return open.length > limit ? open.sublist(0, limit) : open;
  }
}

/// The steps that depend on [step] (`planning_specification.md` § 5.3, § 7.4).
///
/// A `depends-on` relationship is modelled as a `part_of` edge
/// `dependent —part_of[kind=depends_on]→ dependency`. So the steps *blocked by*
/// [step] are the `from` ends of the incoming `part_of` edges to [step] that
/// carry the [dependsOnEdgeKind] marker.
final class StepsBlockedBy {
  /// The dependency step whose dependents to find.
  final NodeId step;

  const StepsBlockedBy(this.step);

  /// Runs the query against [client]. Returns the dependent steps in edge
  /// order; an unknown or leaf step yields an empty list.
  Future<List<PlanStepView>> execute(TomBrainMemoryClient client) async {
    final edges = await client.edgesOf(
      step,
      direction: EdgeDirection.incoming,
      types: const <EdgeType>{EdgeType.partOf},
    );
    final dependentIds = <NodeId>[
      for (final edge in edges)
        if (edge.attrs['kind'] == dependsOnEdgeKind) edge.from,
    ];
    if (dependentIds.isEmpty) return const <PlanStepView>[];
    final nodes = await client.getMany(dependentIds);
    return <PlanStepView>[for (final n in nodes) PlanStepView.fromNode(n)];
  }
}

/// A plan's steps in a dependency-respecting order, plus any cyclic remainder
/// (`planning_specification.md` § 7.4).
final class OrderedPlanSteps {
  /// The steps in dependency-first order (dependencies before dependents).
  final List<PlanStepView> ordered;

  /// Steps trapped in a dependency cycle — surfaced rather than dropped, so a
  /// caller can report the malformed plan instead of silently losing steps.
  final List<PlanStepView> cyclic;

  const OrderedPlanSteps({required this.ordered, required this.cyclic});

  /// Whether the plan's step dependencies contain a cycle.
  bool get hasCycle => cyclic.isNotEmpty;
}

/// Orders a plan's steps deps-first via the domain-free Kahn sort
/// (`planning_specification.md` § 7.4).
final class PlanStepsInOrder {
  /// The plan whose steps to order. Steps are matched by their `plan_id` field.
  final NodeId planId;

  /// Maximum number of step nodes to pull from the symbolic scan.
  final int scanLimit;

  const PlanStepsInOrder(this.planId, {this.scanLimit = 256});

  /// Runs the query against [client]. Reads the plan's steps, builds the
  /// dependency adjacency from each step's outgoing `part_of[kind=depends_on]`
  /// edges (restricted to steps within this plan), topo-sorts, and projects the
  /// result into views.
  Future<OrderedPlanSteps> execute(TomBrainMemoryClient client) async {
    final result = await client.recall(RecallQuery(
      modes: const <RecallMode>{RecallMode.symbolic},
      filter: SymbolicFilter(
        typeNames: const <String>{planStepNodeTypeName},
        attributes: <AttrClause>[
          AttrClause('plan_id', SymbolicOp.eq, planId.value),
        ],
      ),
      k: scanLimit,
    ));

    final byId = <String, PlanStepView>{
      for (final node in result.nodes)
        node.id.value: PlanStepView.fromNode(node),
    };

    final dependencies = <String, List<String>>{};
    for (final node in result.nodes) {
      final edges = await client.edgesOf(
        node.id,
        direction: EdgeDirection.outgoing,
        types: const <EdgeType>{EdgeType.partOf},
      );
      dependencies[node.id.value] = <String>[
        for (final edge in edges)
          if (edge.attrs['kind'] == dependsOnEdgeKind &&
              byId.containsKey(edge.to.value))
            edge.to.value,
      ];
    }

    final PlanStepOrdering ordering = orderPlanSteps(dependencies);
    return OrderedPlanSteps(
      ordered: <PlanStepView>[for (final id in ordering.order) byId[id]!],
      cyclic: <PlanStepView>[for (final id in ordering.cyclic) byId[id]!],
    );
  }
}

/// The full `superseded_by` revision chain a Plan belongs to, oldest → newest
/// (`planning_specification.md` § 7.4, hard principle 6).
final class SupersededHistoryOf {
  /// Any plan node in the chain — the walk finds the whole chain from it.
  final NodeId anchor;

  const SupersededHistoryOf(this.anchor);

  /// Runs the query against [client]. Returns the chain oldest → newest, or an
  /// empty list when [anchor] does not resolve to a live node. Delegates the
  /// graph walk to the shared [walkSupersededByChain] and projects each node
  /// into a `PlanView`.
  Future<List<PlanView>> execute(TomBrainMemoryClient client) async {
    final nodes = await walkSupersededByChain(client, anchor);
    return <PlanView>[for (final n in nodes) PlanView.fromNode(n)];
  }
}
