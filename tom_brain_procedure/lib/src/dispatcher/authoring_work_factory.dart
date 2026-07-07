// Authoring work factory — the § 5.3 "author" arm of the free-time
// scheduler's background routing (`tom_brain_definition.md` § 5.3;
// `tom_brain_procedure_specification.md` § 10.5; `procedure_specification.md`
// § 8.3).
//
// ── The gap this closes ─────────────────────────────────────────────
//
// `author_new_procedure_v1` (the authoring loop) is implemented and persists a
// real `Procedure` memory node, but *nothing routed an inbound to it*, so no
// `Procedure` node was ever created in practice. The `FreeTimeScheduler.tick()`
// path already pops a hot-stack entry and hands it to a [BackgroundWorkFactory]
// to build the background run; def § 5.3 names the four routing arms the
// factory owns — "research / triage / author / dream_*". The *author* arm was
// the one still `(_) => null`. This builder is that arm.
//
// ── What it routes ──────────────────────────────────────────────────
//
// An `AutomationIdea` node — "a candidate procedure to author"
// (`bootstrap_node_types.yaml` #14) — is the brain's own note that some
// intent recurs often enough to deserve a procedure. Those nodes live on the
// `automation_ideas` stack (a schedulable work stack, § 5.1). When the
// scheduler pops one, this factory reads the idea's salient text and submits an
// engine-backed `author_new_procedure_v1` run with that text as the `intent`
// input. The authoring loop then drafts, validates, critiques, and persists the
// new `Procedure` node (§ 8.3) — so the popped idea *becomes* a real, stored,
// deep-linkable procedure node.
//
// ── Why a factory builder, not an inline closure ────────────────────
//
// The same author arm is wired by the production free-time loop AND exercised
// by the routing test, so one tested unit is the single source of truth for
// "an automation idea becomes an authoring run" — mirroring
// `procedure_routing.dart`'s rationale for extracting the classify/select
// decision. The builder captures its collaborators ([engine], [memory]) once
// and returns the closure the scheduler calls per pick.
//
// ── Composition (single-arm by design) ──────────────────────────────
//
// This factory handles the `automation_ideas` stack only and declines every
// other pick (returns `null`, which the scheduler reports as an idle cycle).
// It is meant to be *composed* — a production free-time loop that schedules
// several stacks routes each stack to its own arm (research / triage / author /
// dream_*) and this is the author one. Used alone it is correct for a scheduler
// whose only schedulable stack is `automation_ideas`.

import 'package:tom_brain_memory/tom_brain_memory.dart'
    show Node, StackEntry, TomBrainMemoryClient, automationIdeasStackName;

import '../api/procedure_engine.dart' show ProcedureEngine;
import '../api/procedure_invocation.dart' show ProcedureInvocation;
import 'free_time_scheduler.dart'
    show BackgroundWorkFactory, ScheduledBackgroundWork;

/// The well-known id of the authoring loop this arm routes to
/// (`procedure_specification.md` § 8.3). Named here so the factory, its test,
/// and any production wiring share one spelling.
const String authorNewProcedureV1 = 'author_new_procedure_v1';

/// The `AutomationIdea` node value fields the arm reads the authoring `intent`
/// from, in priority order. `description` is the idea itself and `motivation`
/// its rationale (`bootstrap_node_types.yaml` #14); the remaining generic text
/// fields let a future idea-shaped node still yield an intent. The first
/// non-empty string wins.
const List<String> automationIdeaIntentFields = <String>[
  'description',
  'motivation',
  'title',
  'statement',
  'summary',
  'text',
  'name',
  'label',
];

/// The stable intent used when a popped `automation_ideas` entry resolves to no
/// salient text (a dangling entry, or an idea node carrying no readable text
/// field). Authoring still runs — around a traceable, node-scoped intent —
/// rather than being handed an empty string that would draft garbage. The
/// node id is appended by [_resolveIntent] so the run is traceable to its idea.
const String defaultAuthoringIntentPrefix =
    'author a procedure for automation idea';

/// Builds the § 5.3 *author* [BackgroundWorkFactory]: an `automation_ideas`
/// pick becomes an engine-backed `author_new_procedure_v1` run whose `intent`
/// is the popped idea's salient text.
///
/// [engine] runs the authoring procedure; [memory] resolves the popped entry's
/// node to read the idea text. [automationIdeasStack] is the stack this arm
/// claims (default [automationIdeasStackName]); [procedureId] / [version] name
/// the authoring procedure to invoke (defaults [authorNewProcedureV1] / 1). A
/// pick from any other stack is declined (`null`) so the arm composes with the
/// scheduler's other routing arms without stealing their picks.
BackgroundWorkFactory authoringWorkFactory({
  required ProcedureEngine engine,
  required TomBrainMemoryClient memory,
  String automationIdeasStack = automationIdeasStackName,
  String procedureId = authorNewProcedureV1,
  int version = 1,
}) {
  return (pick) {
    // Only the automation_ideas stack routes to authoring. Declining leaves the
    // pick to whatever arm owns its stack (or reports an idle cycle when this is
    // the only arm) — the factory never steals a pick it cannot author from.
    if (pick.stackName != automationIdeasStack) {
      return null;
    }
    return ScheduledBackgroundWork(
      body: () async {
        final intent = await _resolveIntent(memory, pick.entry);
        // The authoring loop persists the new Procedure node itself; the run's
        // outcome is awaited only to hold the background slot until it finishes
        // (the scheduler tracks the run through the coordinator).
        await engine
            .invoke(ProcedureInvocation(
              procedureId: procedureId,
              arguments: <String, Object?>{'intent': intent},
              version: version,
            ))
            .outcome;
      },
      procedureId: procedureId,
      version: version,
    );
  };
}

/// Resolves the authoring `intent` for a popped [entry]: the first non-empty
/// [automationIdeaIntentFields] value of its node, or a node-scoped default
/// when the node is missing or carries no salient text.
///
/// Best-effort: a store-read failure degrades to the default rather than
/// failing the schedule — a dangling idea should still trigger a (traceable)
/// authoring run, not crash the free-time cycle.
Future<String> _resolveIntent(
  TomBrainMemoryClient memory,
  StackEntry entry,
) async {
  Node? node;
  try {
    node = await memory.get(entry.nodeId);
  } on Object {
    node = null;
  }
  if (node != null) {
    for (final field in automationIdeaIntentFields) {
      final value = node.values[field];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
  }
  return '$defaultAuthoringIntentPrefix ${entry.nodeId.value}';
}
