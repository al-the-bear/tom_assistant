// LlmTrailWriter — the raw LLM-call trail + the `↳` drill-down link
// (`tom_brain_logging.md` §5.2 / §5.1; §10 build-order step #4).
//
// For **every** LLM call the brain issues — the user-facing
// `assistant_to_user` and every internal role (analyser, recaller, evaluator,
// dream agents, …) — this writer emits one
// `llm/<callType>/<turnId>__<callSeq>.raw.json` carrying the **full wire body**
// (the anchor scaffold the provider actually saw), the answer, and the call's
// provenance/metrics. That closes logging-spec "gap #3": the wire is captured,
// not merely hashed.
//
// It also emits one compact `brain.log` headline ending in `↳ <relative-path>`
// (§5.1), so an operator reading the high-level log can drill straight to the
// raw dump for any call. The headline goes through `SubstrateLog.llm` (tag
// `tom_brain.substrate.llm`), which the host's `FanoutLogOutput` routes to
// `brain.log` as a `status` headline (§5.1 routing) — the §5.1 example's
// `[substrate]` short form is illustrative of that same tag.
//
// Scope boundary (§10): this writer owns *only* the raw file + the link. The
// four versioned **summary** projections (session, all-sessions, by-role,
// by-llm — §5.4/§5.5/§5.8) fan out of this same call record in step #5; they
// are deliberately not built here.
//
// Best-effort and non-blocking (§9): a trail-write failure must never fail a
// turn, so every effect is guarded and a failure is swallowed.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show LlmTrailRecord, SubstrateBridge;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show CapturedWirePrompt, SubstrateLog;

import 'llm_raw_path.dart' show llmRawPathFromRoot;

/// Sink for the one compact `brain.log` headline the writer emits per call.
/// Defaults to `SubstrateLog.llm.status`; injectable so tests can capture the
/// line without standing up a `FanoutLogOutput`.
typedef LlmTrailHeadlineSink = void Function(String headline);

/// Writes the §5.2 raw LLM-call dump and the §5.1 `↳` link for each completed
/// LLM call (`tom_brain_logging.md` §10 step #4).
final class LlmTrailWriter {
  /// The trail tree root (`trail.root`). Raw dumps land under `<root>/llm/`.
  final Directory root;

  /// Whether the full anchor-scaffold wire body is serialised into the dump
  /// (`trail.capture.wireBody`, §8). When `false` the `wire` block is omitted;
  /// the metrics still land.
  final bool captureWireBody;

  /// Whether internal (non-user-facing) LLM calls are trailed at all
  /// (`trail.capture.internalRoles`, §8 / §11.1). When `false`, only the
  /// user-facing [SubstrateBridge.defaultRole] (`assistant_to_user`) is
  /// written; every other role is skipped silently.
  final bool captureInternalRoles;

  final LlmTrailHeadlineSink _headlineSink;

  /// Builds a writer rooted at [root]. [headlineSink] defaults to the
  /// `tom_brain.substrate.llm` status channel.
  LlmTrailWriter({
    required this.root,
    this.captureWireBody = true,
    this.captureInternalRoles = true,
    LlmTrailHeadlineSink? headlineSink,
  }) : _headlineSink = headlineSink ?? _defaultHeadlineSink;

  static void _defaultHeadlineSink(String headline) =>
      SubstrateLog.llm.status(headline);

  /// Writes the raw dump and emits the `↳` headline for [record]. Best-effort:
  /// any failure is swallowed so a trail write never breaks the turn (§9).
  void write(LlmTrailRecord record) {
    try {
      final obs = record.observation;
      // Internal-role gate (§11.1): when internal-role capture is off, only the
      // user-facing role is trailed.
      if (!captureInternalRoles && obs.callType != SubstrateBridge.defaultRole) {
        return;
      }

      final relativePath = llmRawPathFromRoot(record);
      final file = File('${root.path}/$relativePath');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(_rawJson(record)),
      );

      _headlineSink(_headline(record, relativePath));
    } catch (_) {
      // Trail writing is non-essential; never let it surface into the turn.
    }
  }

  /// Builds the §5.2 JSON map in the spec's field order.
  Map<String, Object?> _rawJson(LlmTrailRecord record) {
    final obs = record.observation;
    final report = obs.report;
    return <String, Object?>{
      'turnId': obs.turnId,
      'callSeq': obs.callSeq,
      'callType': obs.callType,
      'sessionId': record.sessionId,
      'profile': record.profile,
      'principalId': record.principalId,
      'runId': record.runId,
      'trailId': record.trailId,
      'provider': report.providerId,
      'model': report.modelId,
      'startedAt': obs.startedAt.toIso8601String(),
      'wallClockMs': report.wallClockMs,
      'tokensIn': report.tokensIn,
      'tokensOut': report.tokensOut,
      'retries': report.retries,
      'anchorHash': report.anchorHash,
      'promptHash': report.promptHash,
      if (captureWireBody && obs.wire != null) 'wire': _wireBlock(obs.wire!),
      'answer': obs.answer,
      'memoryProfile': record.profile,
    };
  }

  /// Serialises the captured wire as the §5.2 `wire.messages` block.
  ///
  /// Spec §5.2 reconciliation: the example shows a system + user message pair,
  /// but [CapturedWirePrompt.body] is the single, already-assembled
  /// anchor-first scaffold the provider received — so it serialises as **one**
  /// message carrying that whole body. The split into system/user is not
  /// available at this layer (and would be a lossy re-derivation).
  Map<String, Object?> _wireBlock(CapturedWirePrompt wire) => <String, Object?>{
        'messages': <Object?>[
          <String, Object?>{'role': 'user', 'content': wire.body},
        ],
      };

  /// The compact §5.1 headline, ending in the `↳ <relative-path>` link.
  String _headline(LlmTrailRecord record, String relativePath) {
    final obs = record.observation;
    final report = obs.report;
    return 'llm ${obs.callType} ${report.providerId}/${report.modelId} '
        '${report.tokensIn}→${report.tokensOut} tok ${report.wallClockMs}ms'
        '  ↳ $relativePath';
  }
}
