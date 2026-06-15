// Host-side seam value types for `SubstrateBridge.run` (§7.4).
//
// These types are part of the **host wiring** of `sub.run`, not the
// d4rt-facing primitive API. A procedure script never constructs a
// `ResolvedPrompt` or catches an `UnregisteredPromptException` as a bridged
// value — it calls `sub.run('<id>')` and the host resolves the id through the
// injected `PromptResolver` seam. By principle 7 (the bridged primitive API is
// the only surface a procedure can touch), these must therefore **not** be
// bridged.
//
// `tom_d4rt_generator` bridges every public class defined in a `buildkit.yaml`
// `barrelFiles` source. `SubstrateBridge` and its substrate failure carrier
// `LlmCompletionFailure` are intentionally bridged from
// `substrate_bridge.dart` (a barrelFile). The two seam value types below were
// originally defined alongside them and so were swept into the bridged set,
// violating principle 7 and tripping `generated_bridges_test`'s closed
// seven-class guard. Defining them here — a file that is *not* a `buildkit.yaml`
// barrelFile, only imported by `substrate_bridge.dart` — keeps them referenced
// (the generated `SubstrateBridge` constructor wrapper still resolves
// `ResolvedPrompt` for its `promptResolver` param) without bridging them.

/// The inherited settings + loaded, placeholder-resolved template a
/// `PromptResolver` yields for a registered prompt id (§7.1 / §7.4).
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
    this.channel,
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

  /// The delivery channel the loop's `sub.send` streams over (§9.2): `thinking`
  /// keeps tokens off the user channel, the default (`null`) routes by role. A
  /// `tools: none`, answer-role completion turn (the DONE/CONTINUE confirmation)
  /// sets `thinking` so its verdict does not leak to the user stream.
  final String? channel;
}

/// Thrown by `SubstrateBridge.run` when its prompt id is not registered
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
