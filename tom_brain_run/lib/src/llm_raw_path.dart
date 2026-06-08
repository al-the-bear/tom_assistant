// The §5.2 raw-LLM-dump path — the single place that names where one
// `LlmTrailRecord` is dumped (`tom_brain_logging.md` §5.2 / §5.1).
//
// The raw writer (`LlmTrailWriter`) writes the dump *here*, and the §5.4 / §5.5
// / §5.8 summary surfaces all *link* here. They must agree byte-for-byte on the
// stem and the relative path, so the rule lives once in this file and both
// consumers call it — never re-derive it.

import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show LlmTrailRecord;

/// The file stem identifying one call's raw dump: `<turnId>__<callSeq>` for a
/// turn-bound call (`callSeq` zero-padded to two digits, matching the §5.1
/// `__01` form), falling back to `<runId>__<callId>` for a turn-less internal /
/// dream call.
String llmRawStem(LlmTrailRecord record) {
  final obs = record.observation;
  final turnId = obs.turnId;
  final callSeq = obs.callSeq;
  if (turnId != null && callSeq != null) {
    return '${turnId}__${callSeq.toString().padLeft(2, '0')}';
  }
  return '${record.runId ?? 'run'}__${obs.callId}';
}

/// The raw dump's path **relative to the trail root** —
/// `llm/<callType>/<stem>.raw.json` (§5.2). The raw writer writes to it; the
/// summary surfaces prefix it with the `../` / `../../` hop from their own
/// directory to build the markdown link.
String llmRawPathFromRoot(LlmTrailRecord record) =>
    'llm/${record.observation.callType}/${llmRawStem(record)}.raw.json';
