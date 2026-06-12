// The host-side prompt-resolution seam for `SubstrateBridge.run`
// (prompt_configuration.md §7.1 / §7.4).
//
// These types are deliberately **host-only**: they are the contract between the
// engine's `run` entry point and the cognition config's prompt registry, never
// a d4rt-facing surface. A procedure reaches the answering path through the
// bridged `sub.run(...)` *method*, not by constructing a [ResolvedPrompt] or
// catching an [UnregisteredPromptException] in script. They therefore live here
// — in `api/`, alongside `ProcedureInputs` / `ProcedureResult` — rather than in
// `substrate_bridge.dart`, whose every public class the d4rt bridge generator
// auto-bridges (build.yaml lists it as a barrel file). Keeping them out of the
// barrel keeps the d4rt surface minimal (principle 7: the primitive API is the
// only surface for procedures).

import 'procedure_inputs.dart';
import 'procedure_result.dart';

/// The inherited settings + loaded, placeholder-resolved template a
/// [PromptResolver] yields for a registered prompt id (§7.1 / §7.4).
///
/// Every placeholder in [templateBody] is already resolved **except**
/// `${tools.catalogue}`, which `SubstrateBridge.run` renders from [tools] (it
/// alone depends on the tool set `run` resolves). [tools] is the prompt's
/// resolved tool descriptor list (the `tool.list` wire shape) — already expanded
/// from the prompt's tool policy (`all` / `readonly` / explicit / `none`) by the
/// resolver, which is where the tool registry lives — and is empty for the
/// `none` profile.
final class ResolvedPrompt {
  /// Builds a resolved prompt. [maxToolLoops] defaults to 6 (the §5 inherited
  /// default); [tools] defaults to empty (the `none` profile).
  const ResolvedPrompt({
    required this.role,
    required this.llmRoute,
    required this.templateBody,
    this.tools = const <Object?>[],
    this.maxToolLoops = 6,
    this.temperature,
    this.responseFormat,
  });

  /// The role the prompt assumes — assembles persona + the assistant-dedication
  /// anchor on every `sub.send` the loop issues.
  final String role;

  /// The named LLM route the loop's `sub.send` dispatches over (§8).
  final String llmRoute;

  /// The loaded template body, all placeholders resolved except
  /// `${tools.catalogue}` (which `run` renders).
  final String templateBody;

  /// The resolved tool descriptor list (`tool.list` wire shape); empty for the
  /// `none` profile.
  final List<Object?> tools;

  /// The cap on the loop's tool iterations (§7.2) — the §5 `max_tool_loops`.
  final int maxToolLoops;

  /// The decoding temperature, or `null` to leave it at provider/role default.
  final double? temperature;

  /// The structured-output `response_format`, or `null` for free-form text.
  final Map<String, Object?>? responseFormat;
}

/// Resolves a registered prompt *id* to its [ResolvedPrompt] (§7.1 / §7.4).
///
/// The host backs it with the cognition config's prompt registry: the seam
/// performs the registry lookup, inheritance resolution, template load, and
/// placeholder resolution (against [inputs] + the §6 built-ins), and yields the
/// inherited settings + resolved template body. Returns `null` when [promptId]
/// is not registered — `SubstrateBridge.run` turns that into an
/// [UnregisteredPromptException]. The bridge stays config-unaware — it is handed
/// the id→settings function, the `RouteChainResolver` pattern applied to prompt
/// resolution.
typedef PromptResolver = Future<ResolvedPrompt?> Function(
  String promptId,
  Map<String, Object?> inputs,
);

/// Runs another procedure by id on behalf of `SubstrateBridge.run` (§7.2).
///
/// The engine binds it per run over that run's depth-capped
/// `RunProcedurePrimitive`, so the delegated `tool_loop_v1` run gets correct
/// depth bookkeeping and its own trail — exactly the path a scripted nested
/// `runProcedure` takes. `run` is the only caller; it always targets the latest
/// version, so the seam takes no `version`.
typedef ProcedureRunner = Future<ProcedureResult> Function(
  String procedureId,
  ProcedureInputs inputs,
);

/// Thrown by `SubstrateBridge.run` when its `promptId` is not registered
/// (§7.3 — fatal to the run).
///
/// A run names a prompt by id; an id with no registered prompt is a contract
/// error at the call site, not a recoverable miss, so it surfaces loudly rather
/// than running an empty or guessed prompt.
final class UnregisteredPromptException implements Exception {
  /// Records that no prompt is registered under [promptId].
  const UnregisteredPromptException(this.promptId);

  /// The unregistered prompt id `run` was asked for.
  final String promptId;

  @override
  String toString() =>
      'UnregisteredPromptException: no prompt registered for id "$promptId"';
}
