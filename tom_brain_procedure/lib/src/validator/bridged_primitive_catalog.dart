// BridgedPrimitiveCatalog — the canonical set of bridged-API primitives a
// procedure may declare in its `requires` header and call from its body
// (Plan step C.29; `tom_brain_procedure_specification.md` § 5.1,
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
    'recallMulti',
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
    'updateProcedureMetrics',
  };

  /// Substrate primitives (C.13), re-exposed by `SubstrateBridge`.
  ///
  /// `send` (prompt_configuration.md §7.4) is the low-level explicit-route
  /// completion: it routes over the chain a named route resolves to, while the
  /// role still assembles the wire prompt. It is a substrate method on the
  /// `sub` global (`sub.send`) and a procedure that calls it declares `send` in
  /// `requires`. With the low-level `llm` method retired (Phase 5, step 12),
  /// `send` and `run` are the only substrate completion entry points.
  ///
  /// `run` (prompt_configuration.md §7.1 / §7.4) is the high-level, ID-driven
  /// entry point: it resolves a registered prompt by id (settings + loaded,
  /// placeholder-resolved template), renders `${tools.catalogue}`, assembles the
  /// transcript, and delegates the send→parse→execute→re-send loop to
  /// `tool_loop_v1`. A procedure that calls `sub.run(...)` declares `run` in
  /// `requires`. It is distinct from the engine-native `runProcedure`: `run`
  /// resolves a *prompt*, `runProcedure` resolves a *procedure*.
  ///
  /// `render` (prompt_configuration.md §7.1) is the LLM-free sibling of `run`:
  /// it resolves + renders a registered prompt without issuing a completion.
  static const Set<String> substrate = {
    'send',
    'run',
    'render',
    'embed',
    'search',
    'fetch',
    'retrievalRole',
  };

  /// Engine-native primitives (C.19–C.21, plus `notImplemented` at Todo 4).
  /// `notImplemented` is the single build site for the clear-error stub
  /// message — the four stub verbs (`plan_v1` / `create_v1` / `critique_v1` /
  /// `decide_v1`) declare it in `requires` and call it once each (§ 5.2.1).
  static const Set<String> engineNative = {
    'runProcedure',
    'note',
    'yield_if_foreground_waiting',
    'notImplemented',
    // The LLM-free `validate(source)` dry-run the authoring loop calls between
    // drafts (Todo 7 / G-PR2, § 8.3). A procedure that calls it — chiefly
    // `author_new_procedure_v1` — must declare `validate` in `requires`.
    'validate',
  };

  /// Sugar aliases over `runProcedure` (C.40). All five verbs now resolve to a
  /// shipped `<verb>_v1` target: `think` is a no-op stub, while `plan` /
  /// `create` / `critique` / `decide` resolve to clear-error stubs that throw
  /// `ProcedureNotImplemented` until their real loops land (Todo 4, § 5.2.1).
  /// They are part of the *callable* bridged surface, so a procedure that calls
  /// one must declare it in `requires`.
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

  /// The high-level scripted-LLM sugar (Extension F step 9). Its canonical
  /// `requires` name is `sub.llm`, an implicit nested
  /// `runProcedure(procedure ?? 'call_llm_v1', …)` call (§ 21.1); the body
  /// spells it `subLlm` (the dotted→camel call-token of the canonical name),
  /// which is the *only* call spelling [callTokensFor] accepts for it. With the
  /// low-level substrate `llm` method retired (Phase 5, step 12), the dotted
  /// `sub.llm(...)` spelling is no longer a callable substrate primitive — only
  /// the bare `subLlm(...)` sugar reaches this nested-procedure path.
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

  /// The d4rt global the memory bridge is bound to: memory primitives are
  /// invoked as `mem.recall(...)` (`d4rt_dcli_host.dart` —
  /// `D4rtDcliHost.memoryGlobal`).
  static const String memoryReceiver = 'mem';

  /// The d4rt global the substrate bridge is bound to: substrate primitives
  /// are invoked as `sub.send(...)` (`D4rtDcliHost.substrateGlobal`).
  static const String substrateReceiver = 'sub';

  /// The call-site spellings a procedure body may use to invoke the
  /// primitive whose canonical `requires` name is [name].
  ///
  /// The spelling tracks how the host actually binds each family
  /// (`d4rt_dcli_host.dart` / `native_primitives_installer.dart`):
  ///
  ///   - **memory** primitives are methods on the bound `mem` global, so the
  ///     accepted call is `mem.<flatMethod>` (`recall` → `mem.recall`,
  ///     `stack.push` → `mem.stackPush`, `propose_node_type` →
  ///     `mem.proposeNodeType`). The stack surface is flat on `mem`
  ///     (Q-C.12.2), so there is no dotted `stack.` spelling at the call site.
  ///   - **substrate** primitives are methods on the bound `sub` global, so
  ///     the accepted call is `sub.<flatMethod>` (`send` → `sub.send`,
  ///     `retrievalRole` → `sub.retrievalRole`).
  ///   - the **scripted-LLM sugar** `sub.llm` is the bare top-level `subLlm`
  ///     (§ 21.1): its canonical `requires` name resolves *only* to the
  ///     camelCase `subLlm` spelling — the dotted `sub.llm(...)` is no longer a
  ///     callable substrate primitive (the low-level `llm` method was retired
  ///     in Phase 5, step 12), so there is nothing for the sugar to collide
  ///     with.
  ///   - **engine-native** primitives and **sugar** verbs are bare top-level
  ///     functions (`note`, `runProcedure`, `validate`, `think`), so the
  ///     canonical name is itself the spelling.
  ///   - **tool / mcp / vscode** primitives are dotted calls on their own
  ///     bound namespace global (`tool.list(...)`), so the canonical dotted
  ///     name is the spelling (its camelCase form is also accepted in case the
  ///     host wires them flat).
  static Set<String> callTokensFor(String name) {
    if (memory.contains(name)) {
      return {'$memoryReceiver.${_flatMethod(name)}'};
    }
    if (substrate.contains(name)) {
      return {'$substrateReceiver.${_flatMethod(name)}'};
    }
    if (scriptedLlm.contains(name)) {
      return {_dottedToCamel(name)};
    }
    final tokens = <String>{name};
    if (name.contains('.')) {
      tokens.add(_dottedToCamel(name));
    } else if (name.contains('_')) {
      tokens.add(_snakeToCamel(name));
    }
    return tokens;
  }

  /// The camelCase method spelled on a `mem`/`sub` receiver for the canonical
  /// memory/substrate name [name]: `recall` → `recall`, `stack.push` →
  /// `stackPush`, `propose_node_type` → `proposeNodeType`.
  static String _flatMethod(String name) {
    if (name.contains('.')) return _dottedToCamel(name);
    if (name.contains('_')) return _snakeToCamel(name);
    return name;
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
