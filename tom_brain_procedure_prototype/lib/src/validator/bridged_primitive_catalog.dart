// BridgedPrimitiveCatalog — the canonical set of bridged-API primitives a
// procedure may declare in its `requires` header and call from its body
// (Plan step C.29; `tom_brain_procedure_prototype_specification.md` § 5.1,
// § 7 row 5).
//
// The contract validator's requires-vs-actual check (C.29) needs two facts
// about every primitive: its canonical `requires` name (what the header
// lists) and the call-site spelling(s) a body uses to invoke it. This
// catalog is the single source of truth for both, so the validator never
// hard-codes a primitive name in two places.
//
// The names mirror the bridged surface assembled across C.12 (memory),
// C.13 (substrate), and C.19–C.21 (engine-native), plus the C.40 sugar
// aliases (`think` / `plan` / `create` / `critique` / `decide`) that
// resolve to `runProcedure`. The canonical name is the one used in the
// header `requires` list (e.g. `stack.push`, `propose_node_type`); the
// call-site tokens are derived from it (see [callTokensFor]) because the
// host-facing call spelling for dotted/snake names is still a wiring
// decision (Q-C.12.2). Accepting both the spec spelling and the camelCase
// Dart-method spelling keeps the validator correct whichever way C.16
// wires them.

/// The canonical, immutable catalog of bridged-API primitives.
///
/// Pure data + derivation — no state. [all] is the set of canonical
/// `requires` names; [isKnown] tests membership; [callTokensFor] yields the
/// call-site spellings the body scan accepts for a given canonical name.
final class BridgedPrimitiveCatalog {
  const BridgedPrimitiveCatalog._();

  /// Memory primitives (C.12). Mirrors `memory_specification`'s primitive
  /// set re-exposed by `MemoryBridge`.
  static const Set<String> memory = {
    'recall',
    'classify',
    'persist',
    'edge',
    'propose_node_type',
    'stack.list',
    'stack.create',
    'stack.push',
    'stack.peek',
    'stack.pop',
    'stack.update',
    'stack.remove',
    'demote',
    'updateCentroid',
    'findUncertain',
  };

  /// Substrate primitives (C.13), re-exposed by `SubstrateBridge`.
  static const Set<String> substrate = {'llm', 'embed', 'search', 'fetch'};

  /// Engine-native primitives (C.19–C.21).
  static const Set<String> engineNative = {
    'runProcedure',
    'note',
    'yield_if_foreground_waiting',
  };

  /// Sugar aliases over `runProcedure` (C.40). For the prototype only
  /// `think` is backed by a stub; the others throw `ProcedureNotFound` at
  /// runtime, but they are still part of the *callable* bridged surface, so
  /// a procedure that calls one of them must declare it in `requires`.
  static const Set<String> sugar = {
    'think',
    'plan',
    'create',
    'critique',
    'decide',
  };

  /// Tool-calling primitives (Extension F step 6), re-exposed by
  /// `ToolBridge`. `tool.list` enumerates the policy-narrowed tool set;
  /// `tool.invoke` runs one tool by name.
  static const Set<String> tools = {'tool.list', 'tool.invoke'};

  /// MCP-client primitives (Extension F step 8), re-exposed by `McpBridge`.
  /// `mcp.servers` enumerates the configured servers; `mcp.list` lists a
  /// server's advertised tools; `mcp.call` runs one MCP tool by name.
  static const Set<String> mcp = {'mcp.servers', 'mcp.list', 'mcp.call'};

  /// The high-level scripted-LLM sugar (Extension F step 9). `sub.llm` is an
  /// implicit nested `runProcedure(procedure ?? 'call_llm_v1', …)` call
  /// (§ 21.1); the body spells it `subLlm` (the dotted→camel call-token of
  /// the canonical `requires` name), which [callTokensFor] also accepts.
  static const Set<String> scriptedLlm = {'sub.llm'};

  /// VS Code scripting-API primitive (Extension F step 14), re-exposed by
  /// `VsCodeScriptingBridge`. `vscode.call` invokes one scripting-API method
  /// directly (§ 21.9) — distinct from the merged extension *tools* a
  /// procedure reaches through `tool.invoke` (§ 21.8). Callable only on a run
  /// colocated with the extension and with the `enableVsCodeIntegration`
  /// switch on (§ 6); the body spells it `vscodeCall` ([callTokensFor] accepts
  /// both).
  static const Set<String> vscodeScripting = {'vscode.call'};

  /// Every canonical `requires` name the prototype recognises.
  static const Set<String> all = {
    ...memory,
    ...substrate,
    ...engineNative,
    ...sugar,
    ...tools,
    ...mcp,
    ...scriptedLlm,
    ...vscodeScripting,
  };

  /// Whether [name] is a recognised bridged primitive.
  static bool isKnown(String name) => all.contains(name);

  /// The call-site spellings a procedure body may use to invoke the
  /// primitive whose canonical `requires` name is [name].
  ///
  /// The canonical name is always accepted. In addition:
  ///
  ///   - a dotted name (`stack.push`) also matches its camelCase flat form
  ///     (`stackPush`), because whether the host wires the stack ops under a
  ///     `stack.` namespace object or as flat methods is undecided
  ///     (Q-C.12.2);
  ///   - a snake_case name (`propose_node_type`,
  ///     `yield_if_foreground_waiting`) also matches its camelCase form
  ///     (`proposeNodeType`, `yieldIfForegroundWaiting`).
  ///
  /// A plain lowerCamel name (`recall`, `llm`, `runProcedure`) has exactly
  /// one spelling: itself.
  static Set<String> callTokensFor(String name) {
    final tokens = <String>{name};
    if (name.contains('.')) {
      tokens.add(_dottedToCamel(name));
    } else if (name.contains('_')) {
      tokens.add(_snakeToCamel(name));
    }
    return tokens;
  }

  /// `stack.push` → `stackPush`. Lower-cases nothing, just drops the dots
  /// and capitalises the first letter of each following segment.
  static String _dottedToCamel(String name) => _joinCamel(name.split('.'));

  /// `propose_node_type` → `proposeNodeType`.
  static String _snakeToCamel(String name) => _joinCamel(name.split('_'));

  static String _joinCamel(List<String> segments) {
    final buffer = StringBuffer(segments.first);
    for (final segment in segments.skip(1)) {
      if (segment.isEmpty) continue;
      buffer
        ..write(segment[0].toUpperCase())
        ..write(segment.substring(1));
    }
    return buffer.toString();
  }
}
