// EffortAccountant — maps one bridged-primitive call to its
// `EffortMetrics` delta (Plan step C.32;
// `tom_brain_procedure_prototype_specification.md` § 8;
// `tom_brain_definition.md` § 7.4).
//
// ── What C.32 owns ──────────────────────────────────────────────────
//
// C.31 defined the *shape* of the effort record (`EffortMetrics`) and
// persisted whatever total it was handed. C.32 owns the *accumulation*:
// the rule that turns a single bridged call — by name, and by what its
// result reports — into the counters that call contributed. The
// `RunRecorder` folds these deltas with `EffortMetrics.plus` as each
// call is recorded, so the final `ProcedureRun` carries an authoritative
// tally the engine never has to assemble by hand.
//
// ── Classification (definition § 7.4) ───────────────────────────────
//
//   - `llm`                       → +1 llmCall, +tokensIn inputTokens,
//                                    +tokensOut outputTokens (read from
//                                    the call's `report`).
//   - `embed` / `search` / `fetch`→ +1 toolCall (substrate tool callouts
//                                    other than `llm`).
//   - `recall` / `classify` /
//     `stack.list` / `stack.peek` /
//     `findUncertain`             → +1 memoryRead (`classify` and
//                                    `findUncertain` read the centroid
//                                    table; neither writes).
//   - `persist` / `edge` /
//     `propose_node_type` /
//     `stack.create` / `.push` /
//     `.pop` / `.update` /
//     `.remove` / `demote` /
//     `updateCentroid`            → +1 memoryWrite (any call that
//                                    mutates the store; `pop` mutates by
//                                    removing the top entry, `demote` by
//                                    changing lifecycle status,
//                                    `updateCentroid` by replacing a
//                                    centroid row).
//   - `runProcedure` / `note` /
//     `yield_if_foreground_waiting`→ zero (engine-native control flow has
//                                    no direct substrate/memory cost; a
//                                    nested `runProcedure`'s cost is
//                                    tallied on the child run, never
//                                    double-counted on the parent).
//   - anything else               → zero (a primitive the accountant does
//                                    not recognise contributes no
//                                    counters; the call is still recorded
//                                    on the trail by the recorder).
//
// `wallClockMs` is deliberately never set here — it is the *run's*
// elapsed time, stamped once by `RunRecorder.complete`, not the sum of
// per-call latencies (which overlap and double-count under concurrency).

import 'package:tom_brain_shared/tom_brain_shared.dart' show EffortMetrics;

/// Classifies a single bridged-primitive call into the [EffortMetrics]
/// delta it contributed.
///
/// Pure and stateless: [classify] depends only on its arguments, so the
/// recorder can fold deltas in any order and tests can assert each rule
/// in isolation. The primitive name may arrive in either the spec's
/// dotted form (`stack.push`) or the bridge's camelCase form
/// (`stackPush`); both normalise to the same bucket.
final class EffortAccountant {
  /// Builds the (stateless) accountant.
  const EffortAccountant();

  /// Memory-read primitives — each contributes one `memoryReads`.
  static const Set<String> _readPrimitives = <String>{
    'recall',
    'classify',
    'stack.list',
    'stack.peek',
    'stackList',
    'stackPeek',
    // `findUncertain` reads the centroid table to surface borderline nodes
    // (§ 7.4); it writes nothing.
    'findUncertain',
  };

  /// Store-mutating primitives — each contributes one `memoryWrites`.
  static const Set<String> _writePrimitives = <String>{
    'persist',
    'edge',
    'propose_node_type',
    'proposeNodeType',
    'stack.create',
    'stack.push',
    'stack.pop',
    'stack.update',
    'stack.remove',
    'stackCreate',
    'stackPush',
    'stackPop',
    'stackUpdate',
    'stackRemove',
    // `demote` mutates a node's lifecycle status (§ 9.5); `updateCentroid`
    // replaces a centroid row (§ 7.3). Both change the store, so each charges
    // one memoryWrite.
    'demote',
    'updateCentroid',
  };

  /// Tool callouts — each contributes one `toolCalls`. The substrate tool
  /// callouts other than `llm` (`embed` / `search` / `fetch`), plus
  /// `tool.invoke` (Extension F step 6), `mcp.call` (Extension F step 8), and
  /// `vscode.call` (Extension F step 14): invoking a registered tool, an MCP
  /// tool, or a VS Code scripting-API method is one tool call, so the budget
  /// ledger can pre-charge it (PE-8). `tool.list` / `mcp.servers` / `mcp.list`
  /// only enumerate and are deliberately absent — they score zero.
  static const Set<String> _toolPrimitives = <String>{
    'embed',
    'search',
    'fetch',
    'tool.invoke',
    'toolInvoke',
    'mcp.call',
    'mcpCall',
    'vscode.call',
    'vscodeCall',
  };

  /// The metric delta the [primitive] call contributed.
  ///
  /// [result] is the call's JSON-encodable return map (the same map the
  /// recorder writes to the trail). Only `llm` reads it — for token
  /// counts off the embedded `report`; every other primitive's delta is a
  /// fixed unit determined by name alone.
  EffortMetrics classify(
    String primitive, {
    Map<String, Object?> result = const <String, Object?>{},
  }) {
    if (primitive == 'llm') {
      return EffortMetrics(
        llmCalls: 1,
        inputTokens: _reportToken(result, 'tokensIn'),
        outputTokens: _reportToken(result, 'tokensOut'),
      );
    }
    if (_toolPrimitives.contains(primitive)) {
      return EffortMetrics(toolCalls: 1);
    }
    if (_readPrimitives.contains(primitive)) {
      return EffortMetrics(memoryReads: 1);
    }
    if (_writePrimitives.contains(primitive)) {
      return EffortMetrics(memoryWrites: 1);
    }
    // Everything else contributes nothing. This covers two cases that the
    // current metric set scores identically:
    //   - engine-native control flow (`runProcedure`, `note`,
    //     `yield_if_foreground_waiting`) — a nested `runProcedure`'s cost is
    //     tallied on the child run, so the parent charges zero, and the
    //     other two have no substrate/memory cost;
    //   - an unrecognised primitive — scored zero rather than guessed, while
    //     the recorder still writes the call to the trail.
    // There is no separate "free" branch because there is no separate
    // metric to assign: until a control-flow primitive carries a real cost,
    // collapsing both cases here keeps the classifier honest about the fact
    // that they are indistinguishable in this metric set.
    return EffortMetrics.zero;
  }

  /// Reads a non-negative token count from `result['report'][key]`,
  /// defaulting to zero when the report or field is missing or malformed.
  /// The `llm` bridge returns `{'text': …, 'report': {tokensIn, tokensOut,
  /// …}}` (see `SubstrateBridge.llm`); a substrate that reports negative
  /// or non-numeric tokens degrades to zero rather than corrupting the
  /// run's tally.
  static int _reportToken(Map<String, Object?> result, String key) {
    final report = result['report'];
    if (report is! Map) return 0;
    final value = report[key];
    if (value is! num) return 0;
    final tokens = value.toInt();
    return tokens < 0 ? 0 : tokens;
  }
}
