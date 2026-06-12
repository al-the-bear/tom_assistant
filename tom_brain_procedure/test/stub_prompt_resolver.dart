// A minimal host-prompt resolver double for the increment-8 procedure suites.
//
// `prompt_configuration.md` §12 increments 6–8 migrate every system procedure
// off inline `sub.llm(promptText, role:)` builders onto `sub.run('<id>')`. A
// migrated procedure no longer carries its own prompt text — the host
// `PromptResolver` resolves the registered id into a `ResolvedPrompt` (role +
// route + tool set + assembled body). The procedure-side acceptance suites do
// not assert on the assembled prompt *text* (the substrate doubles return
// canned text keyed off the role, not the body); they assert on the *memory
// effect* and *which roles were called*. So this resolver stands in for the
// real config-backed host resolver with the minimum a `sub.run` call needs:
//
//   * any id resolves (an unregistered id still returns `null`, preserving the
//     §7.3 unregistered-prompt-is-fatal contract for tests that want it);
//   * the resolved [role] drives the substrate double (mapped per id via
//     [roleForId] when a suite needs distinct roles, e.g. the thinking stages);
//   * the resolved tool set is [tools] (empty `none` profile by default, so the
//     shared `tool_loop_v1` runs a single send and returns the plain answer);
//   * the body echoes the inputs so a body that *is* asserted on (rare) still
//     carries the bindings the procedure passed.
//
// Suites that key the substrate off role set [role] / [roleForId]; suites that
// want the substrate to see a catalogue set [tools]. Every resolved id and its
// inputs are captured in [requests] in dispatch order.

import 'package:tom_brain_substrate/tom_brain_substrate.dart' show RouteEntry;

import 'package:tom_brain_procedure/tom_brain_procedure.dart'
    show PromptResolver, ResolvedPrompt, RouteChainResolver;

/// A configurable stand-in for the host `PromptResolver` + `RouteChainResolver`
/// the `SubstrateBridge` is wired with at boot. Construct one per test, mutate
/// [tools] / [role] / [roleForId] before invoking, and pass [resolver] +
/// [routeChainOf] to `SubstrateBridge(...)`.
class StubPromptResolver {
  StubPromptResolver({
    this.role = 'assistant_to_user',
    this.tools = const <Object?>[],
    this.roleForId,
  });

  /// The role every resolved prompt assumes unless [roleForId] overrides it.
  String role;

  /// The resolved tool descriptor list (the `tool.list` wire shape) every
  /// prompt offers — empty means the `none` profile (the loop runs one send).
  List<Object?> tools;

  /// An optional per-id role override: a migrated multi-prompt procedure whose
  /// stages run under distinct personas (analyser / planner / tester …) maps
  /// each prompt id to its role here so the role-keyed substrate double can
  /// distinguish the stages.
  String Function(String id)? roleForId;

  /// Every `(id, inputs)` pair the resolver was asked for, in dispatch order.
  final List<({String id, Map<String, Object?> inputs})> requests =
      <({String id, Map<String, Object?> inputs})>[];

  /// The `PromptResolver` seam: resolves any id to a `ResolvedPrompt`.
  PromptResolver get resolver =>
      (String promptId, Map<String, Object?> inputs) async {
        requests.add((id: promptId, inputs: Map<String, Object?>.of(inputs)));
        return ResolvedPrompt(
          role: roleForId?.call(promptId) ?? role,
          llmRoute: 'stub',
          templateBody: _echo(inputs),
          tools: tools,
          maxToolLoops: 8,
        );
      };

  /// The `RouteChainResolver` seam: every route resolves to an empty chain —
  /// the substrate doubles route over their own canned stream regardless.
  RouteChainResolver get routeChainOf =>
      (String routeName) => const <RouteEntry>[];

  /// Renders the inputs as a stable body so a rare body assertion still sees the
  /// bindings; the `${tools.catalogue}` marker is left for `SubstrateBridge.run`.
  static String _echo(Map<String, Object?> inputs) {
    final buffer = StringBuffer(r'${tools.catalogue}');
    for (final entry in inputs.entries) {
      buffer.writeln('${entry.key}: ${entry.value}');
    }
    return buffer.toString();
  }
}
