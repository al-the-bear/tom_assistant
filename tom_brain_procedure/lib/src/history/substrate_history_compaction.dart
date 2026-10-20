// SubstrateHistoryCompaction — the production [HistoryCompactionSubstrate]
// (open-ends step 4; hub spec § 22.4, PE-7 / PE-8).
//
// `HistoryCompactor` issues its compaction completion through a single
// injectable seam ([HistoryCompactionSubstrate]); the G.21 tests stub it with a
// one-line `(_) async => summary`. This is the real seam: it routes the
// assembled compaction prompt through the substrate's registered, anchored
// `sub.llm` path — exactly the way the `SubstrateBridge.llm` primitive does —
// so the compaction LLM call carries:
//
//   * the assistant-dedication anchor (PE-7). The anchor is **not** a parameter
//     this seam passes; it is applied structurally by `RoleTemplate.assemble`
//     when the substrate resolves [roleId] (substrate § 6.3). There is no path
//     to issue an un-anchored completion, so this seam cannot bypass it.
//   * a budget (PE-8). The [budget] rides onto the [LlmCall]; a compaction call
//     that would exceed it raises `ProcedureBudgetExceeded` at the bridge, never
//     here.
//
// Why the role path takes the whole assembled prompt as one `prompt` input:
// the `sub.llm` convention puts the entire caller prompt into the user channel
// (`inputs: {'prompt': …}`) while the role supplies the anchor-first system
// channel (`RoleTemplate.assemble`). The compactor already resolves its own
// `compact_history_v1` scaffolds (the `${history.compacted}` / `${history.batch}`
// instruction + content) into [HistoryCompactionPrompt.system] /
// [HistoryCompactionPrompt.user]; this seam folds those two into the single
// `prompt` input, matching every other `sub.llm` call shape.
//
// Role choice: the compaction call routes under the dedicated first-class
// `history_compactor` role — its own roster entry (the substrate's `history`
// roster group), its own `roleRoutes` route, and its own
// `history_compactor.persona.md` / `.objective.md` prose. The role's objective —
// "fold the new turns into the running summary faithfully; preserve every
// decision, commitment, named entity, and open thread; add nothing the turns do
// not state" — is purpose-written for compaction (it replaced the earlier
// `recaller` stopgap, HC-81). [roleId] is still a parameter so a richer assembly
// can override it without touching this class.

import 'package:tom_brain_shared/tom_brain_shared.dart' show Budget;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show LlmCall, LlmTextDelta, LlmRunFailed, TomBrainSubstrateClient;

import 'history_compactor.dart' show HistoryCompactionPrompt;

/// The registered role the compaction completion routes under by default.
///
/// The dedicated first-class `history_compactor` role (substrate `history`
/// roster group; see the file header) — purpose-written for faithful summary
/// folding, replacing the earlier `recaller` stopgap (HC-81).
const String historyCompactionRoleId = 'history_compactor';

/// The default budget for one compaction completion.
///
/// Compaction issues a single chat completion that reads neither tools nor
/// memory, so [Budget.toolCalls] / [Budget.memoryWrites] are zero; the token and
/// wall-clock allowances are generous bounds, not tuning knobs (the real cap on
/// the produced summary is `HistorySizing.maxCompactedChars`, enforced by the
/// compactor). A caller with a run-level envelope passes its own [Budget] in.
final Budget _defaultCompactionBudget = Budget(
  wallClockMs: 60000,
  tokenSpend: 16000,
  toolCalls: 0,
  memoryWrites: 0,
);

/// Thrown when the substrate stream terminates in an [LlmRunFailed] event.
///
/// `HistoryCompactor._run` catches every throw from the seam and turns it into a
/// failed run (the prior summary kept, `pending` retried — never silent data
/// loss, hub § 22.10), so this surfaces the provider failure as that signal.
final class HistoryCompactionSubstrateFailure implements Exception {
  /// The substrate failure's class code (e.g. `provider.timeout`).
  final String classCode;

  /// The substrate failure's human-readable message.
  final String message;

  /// Records a compaction completion failure.
  const HistoryCompactionSubstrateFailure(this.classCode, this.message);

  @override
  String toString() =>
      'HistoryCompactionSubstrateFailure($classCode): $message';
}

/// The production [HistoryCompactionSubstrate]: routes the assembled compaction
/// prompt through the substrate's anchored, budgeted `sub.llm` path.
///
/// Construct one over a [TomBrainSubstrateClient] and hand [call] to a
/// [HistoryCompactor] as its `substrate` seam.
final class SubstrateHistoryCompaction {
  /// The substrate the compaction completion is issued through.
  final TomBrainSubstrateClient client;

  /// The registered role the completion routes under (anchor source).
  final String roleId;

  /// The budget the compaction completion runs under (PE-8).
  final Budget budget;

  /// Builds a production compaction seam over [client].
  ///
  /// [roleId] defaults to [historyCompactionRoleId]; [budget] to a generous
  /// single-completion envelope. Both are seams a richer assembly overrides.
  SubstrateHistoryCompaction({
    required this.client,
    this.roleId = historyCompactionRoleId,
    Budget? budget,
  }) : budget = budget ?? _defaultCompactionBudget;

  /// Issues one compaction completion for [prompt] and returns the model's
  /// rewritten summary text.
  ///
  /// Drains the role-routed completion stream and concatenates its chunks — the
  /// `complete` (buffered) surface returns only an `LlmCallReport`, so the text
  /// is recovered from the stream, exactly as `SubstrateBridge.llm` does.
  /// A terminal [LlmRunFailed] throws [HistoryCompactionSubstrateFailure],
  /// which the [HistoryCompactor] turns into a failed run.
  Future<String> call(HistoryCompactionPrompt prompt) async {
    final llmCall = LlmCall(
      roleId: roleId,
      inputs: <String, Object?>{'prompt': _wire(prompt)},
      budget: budget,
    );
    final buffer = StringBuffer();
    await for (final event in client.completeStream(llmCall)) {
      switch (event) {
        case LlmTextDelta(:final text):
          buffer.write(text);
        case LlmRunFailed(:final failure):
          throw HistoryCompactionSubstrateFailure(
            failure.classCode,
            failure.message,
          );
        default:
          // Started / tool-call / completed events carry no summary text for the
          // compactor; the rewritten summary is the concatenation of the chunks.
          break;
      }
    }
    return buffer.toString();
  }

  /// Folds the two assembled scaffolds into the single `prompt` input the role
  /// path expects: the system scaffold (instruction + current summary) followed
  /// by the user scaffold (the pending batch). An empty user half degrades to
  /// the system scaffold alone.
  static String _wire(HistoryCompactionPrompt prompt) => prompt.user.isEmpty
      ? prompt.system
      : '${prompt.system}\n\n${prompt.user}';
}
