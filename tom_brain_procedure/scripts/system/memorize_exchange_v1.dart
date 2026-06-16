/// @procedure
/// id: memorize_exchange_v1
/// version: 1
/// summary: Decide what of a finished exchange is worth committing to memory,
///   then check existing memory and store the worthwhile items.
/// successCriterion: For a prompt+answer exchange, the curator's worth-storing
///   items that are not already known are persisted (each embedded) and, when
///   the exchange Event id is supplied, edged derived_from it; the persisted
///   ids are returned.
/// budget: { wallClockMs: 86400000, tokenSpend: 100000000, toolCalls: 800, memoryWrites: 1000000 }
/// inputs:
///   - { name: prompt, type: String, required: true }
///   - { name: answer, type: String, required: true }
///   - { name: eventId, type: String, required: false }
/// outputs:
///   - { name: storedIds, type: List }
/// requires: [ recall, run, embed, persist, edge, stack.push, note, yield_if_foreground_waiting ]
//
// memorize_exchange_v1 — the memory curator (dream-subsystem redesign part f).
//
// The user asked for "an explicit step which asks the auxiliary LLM, for each
// prompt and answer, what of this should be memorized … under which angles
// 'worth storing' can be seen … and use the memory tools to store the
// information and check what is already in memory." This procedure is that
// step. It runs after an answer is produced, over the exchange's `prompt` and
// `answer`, and:
//
//   1. Recalls existing memory for the prompt, so the curator sees what is
//      already known and does not re-store it (the "check what is already in
//      memory" half).
//   2. Calls the substrate through the registered `dreaming.curator.worth_storing`
//      prompt + the `memory_curator` role — whose objective names the angles on
//      "worth storing" (durable user facts, stable preferences, reusable
//      conclusions, open questions, corrections; never ephemeral chit-chat or
//      already-known facts) — handing it the exchange and the recalled context.
//      The role returns a `TYPE :: statement` list (or `NONE`).
//   3. For each returned item, persists a node of its type (embedded) and links
//      it appropriately (the "store the information" half), within the bootstrap
//      schema's edge rules:
//        - a Claim (a durable fact) is, when the exchange Event id is supplied,
//          edged `derived_from` that Event — the provenance link back to the
//          exchange — and is a produced node of the run;
//        - a Question (an open question worth pursuing) is pushed onto the
//          `questions_open` stack, exactly as the Inquisitor queues its
//          questions. The bootstrap `Question` carries no outgoing
//          `derived_from`/`produced_by` edge, so it is neither edged to the
//          Event nor reported as a produced node (either would fail
//          `EdgeNotPermitted`).
//      "Use the memory tools" is realised through the bridged `mem.recall` /
//      `mem.persist` / `mem.edge` / `mem.stackPush` — the in-process equivalent
//      of the MCP memory tools a procedure body has access to.
//
// ── Scope (memory § 9 / part f) ─────────────────────────────────────
//
// The curator is a *scoped* agent: the engine binds its identity
// (`memorize_exchange_v1`) onto the memory bridge, so every write this body
// issues carries it and the store's `AgentRegistry` confines the run to its
// declared write scopes — `node:Claim`, `node:Question`, `edge:derived_from`,
// and `stack:questions_open`. A write to any other node type, edge kind, or
// stack, or under an unregistered identity, is rejected with
// `AgentScopeViolation` before the row is written. The curator never demotes or
// deletes — it only adds the worthwhile (principle 6: memory grows, it does not
// lose).
//
// ── Why each item is embedded here ──────────────────────────────────
//
// Claim (`statement`) and Question (`text`) both require an embedding over
// their statement and the store does not embed lazily — the writer supplies the
// vector. The body embeds each item's statement through `sub.embed` so it is
// immediately recallable by vector mode.
//
// ── The anchor invariant (PE-7 / principle 5) ───────────────────────
//
// `sub.run` names a registered prompt whose `memory_curator` role assembles
// persona + the assistant-dedication anchor at the substrate — the body never
// hands the substrate a raw wire prompt, so the curator is anchored exactly
// like every other dreaming role.
import 'package:tom_brain_procedure/src/api/procedure_inputs.dart';
import 'package:tom_brain_procedure/src/bridges/memory_bridge.dart';
import 'package:tom_brain_procedure/src/bridges/substrate_bridge.dart';
import 'package:tom_brain_procedure/src/primitives_native/primitives_native.dart';

/// The node types the curator is allowed to propose, mapped from the `TYPE`
/// token in each worth-storing line. A line naming any other type is skipped —
/// the store would refuse the write anyway (the curator's scope is exactly
/// these two node types), so dropping it early keeps the run clean. (Concept is
/// deliberately not curated here: its bootstrap schema needs a `name` +
/// `description` pair, not the single-sentence shape the curator emits — richer
/// Concepts are the Synthesiser's job.)
const Set<String> _allowedTypes = <String>{'Claim', 'Question'};

/// The single-line sentinel the curator emits when nothing is worth storing.
const String _nothingToStore = 'NONE';

Future<Map<String, Object?>> run(ProcedureInputs inputs) async {
  final prompt = inputs.get('prompt');
  final answer = inputs.get('answer');
  final eventId = inputs.has('eventId') ? inputs.get('eventId') : null;

  // 1. Check what is already in memory for this prompt, so the curator does not
  //    re-store known facts. Recall rides on BM25 + vector; the recalled node
  //    statements become the `known` context the curator is shown.
  final recall = await mem.recall(prompt, modes: ['bm25', 'vector'], k: 16);
  final known = _knownContext(recall);

  // 2. Ask the curator what — under the worth-storing angles — should be kept.
  //    The role objective carries the angles; this prompt carries the exchange
  //    and the already-known context. The verdict arrives under `answer` as a
  //    `TYPE :: statement` list, or the `NONE` sentinel.
  final completion = await sub.run(
    'dreaming.curator.worth_storing',
    inputs: <String, Object?>{
      'prompt': prompt,
      'answer': answer,
      'known': known,
    },
  );
  final verdict = completion['answer'];
  final items = _parseItems(verdict);

  // 3. Persist each worthwhile item (embedded) and link it per its type's
  //    bootstrap edge rules: a Claim is edged `derived_from` the exchange Event
  //    (when known) and is a produced node; a Question is queued on
  //    `questions_open` and is neither edged nor produced.
  const producer = 'memorize_exchange_v1';
  final storedIds = <String>[];
  final producedIds = <String>[];
  for (final item in items) {
    // Cooperative preemption checkpoint (PE-5): curation is background work, so
    // a foreground prompt parks the run here, between items, and resumes it once
    // the foreground drains — no item's work is lost or run twice.
    await yield_if_foreground_waiting();

    final embedding = await sub.embed(item.statement);
    final nodeId = await mem.persist(
      item.type,
      _valuesFor(item),
      producer: producer,
      embedding: embedding['vec'],
    );
    if (nodeId.isEmpty) continue;
    storedIds.add(nodeId);

    if (item.type == 'Question') {
      // A Question is the brain's backlog of what it noticed it does not know —
      // queued for the Researcher, exactly as the Inquisitor queues its
      // questions. It carries no outgoing derived_from/produced_by edge.
      await mem.stackPush('questions_open', nodeId, producer: producer);
    } else {
      // A Claim records its provenance back to the exchange it was distilled
      // from, when the caller supplied the exchange Event id.
      if (eventId is String && eventId.isNotEmpty) {
        await mem.edge(nodeId, 'derived_from', eventId, producer: producer);
      }
      producedIds.add(nodeId);
    }
  }

  // 4. Record the curation delta on the run trail.
  note('progress', {
    'agent': 'memorize_exchange_v1',
    'itemsConsidered': items.length,
    'itemsStored': storedIds.length,
  });

  // Only the Claims are this run's produced nodes (the engine threads them into
  // the run recorder's `produced_by` edges); Questions carry no such edge.
  // `storedIds` reports everything the curation persisted.
  return <String, Object?>{
    'storedIds': storedIds,
    'producedNodeIds': producedIds,
  };
}

/// A single worth-storing item: a node [type] and its [statement] sentence.
class _CuratedItem {
  const _CuratedItem(this.type, this.statement);
  final String type;
  final String statement;
}

/// Builds the property map for a curated item. A Claim carries a `statement`; a
/// Question carries `text` (each its bootstrap embedding source).
Map<String, Object?> _valuesFor(_CuratedItem item) {
  if (item.type == 'Question') {
    return <String, Object?>{'text': item.statement};
  }
  return <String, Object?>{'statement': item.statement};
}

/// Renders the recalled nodes into the `known` context block the curator sees —
/// one statement/text/summary per line. An empty recall yields the empty
/// string, which the prompt renders as "(nothing known yet)" framing implicitly.
String _knownContext(Object? recall) {
  if (recall is! Map) return '';
  final nodes = recall['nodes'];
  if (nodes is! List) return '';
  final lines = <String>[];
  for (final node in nodes) {
    if (node is! Map) continue;
    final values = node['values'];
    if (values is! Map) continue;
    final text = values['statement'] ?? values['text'] ?? values['summary'];
    if (text is String && text.trim().isNotEmpty) {
      lines.add('- ${text.trim()}');
    }
  }
  return lines.join('\n');
}

/// Parses the curator's `TYPE :: statement` list into typed items. Each
/// non-empty line is split on the first `::`; the type must be one of
/// [_allowedTypes] (case-insensitive, normalised to canonical casing) and the
/// statement non-empty. A leading `- ` bullet is tolerated. The `NONE` sentinel
/// (alone on a line, case-insensitive) yields no items, as does any unparseable
/// line — the curator never forces a store it did not clearly ask for. A
/// non-String verdict (e.g. a missing `answer`) yields no items.
List<_CuratedItem> _parseItems(Object? verdict) {
  final items = <_CuratedItem>[];
  if (verdict is! String) return items;
  for (final raw in verdict.split('\n')) {
    var line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('- ')) line = line.substring(2).trim();
    if (line.toUpperCase() == _nothingToStore) continue;
    final sep = line.indexOf('::');
    if (sep < 0) continue;
    final typeToken = line.substring(0, sep).trim();
    final statement = line.substring(sep + 2).trim();
    if (statement.isEmpty) continue;
    final type = _canonicalType(typeToken);
    if (type == null) continue;
    items.add(_CuratedItem(type, statement));
  }
  return items;
}

/// Maps a case-insensitive type token to its canonical node-type name, or null
/// when it names no allowed type.
String? _canonicalType(String token) {
  for (final type in _allowedTypes) {
    if (type.toLowerCase() == token.toLowerCase()) return type;
  }
  return null;
}
