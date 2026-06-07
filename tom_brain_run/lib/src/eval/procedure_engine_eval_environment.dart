// ProcedureEngineEvalEnvironment — the production [RetrievalEvalEnvironment]
// (Plan-2 extension step #33; spec § 23.8).
//
// Runs the harness's five phases over a *real* `ProcedureEngine` + memory
// store: it provisions a throwaway profile through a `MemoryProfileRegistry`,
// seeds the labelled corpus through the normal `persist` path, queries each
// prompt by invoking the `retrieve_for_prompt_v1` conductor (passing the
// resolved `MemoryRetrievalConfig.toConductorMap()` as the conductor's
// `retrievalConfig` input), recovers the seeded `evalId` from each recalled
// node, and drops the profile.
//
// ── The injected per-profile binding ─────────────────────────────────
//
// A retrieval eval is store-stateful: the nodes seeded in `seed` must survive
// into `query`, so the same memory client + engine pair is reused across both
// phases for a given profile. How that pair is built (open an isolate-hosted
// `SqliteTomBrainMemory` for `<root>/profiles/<name>`, register the retrieval
// node types, build the conductor engine over the real bridges) is the
// production caller's concern — it is injected as [bind] so this environment
// stays free of substrate/transport wiring and is unit-testable with a fake
// binding. The binding is cached per profile and discarded on `drop`.
//
// The seed `kind` → node `typeName` mapping capitalises the first letter
// (`event` → `Event`), and the logical `evalId` is carried in
// `values['evalId']` so `query` can recover it from a recalled node's values.

import 'package:tom_brain_memory/tom_brain_memory.dart' show TomBrainMemory;
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show MemoryRetrievalConfig, ProcedureEngine, ProcedureInvocation;
import 'package:tom_brain_shared/tom_brain_shared.dart' show NodeDraft, Scope;

import 'retrieval_eval_environment.dart';

/// The per-profile memory + engine pair the environment reuses across phases.
final class EvalProfileBinding {
  const EvalProfileBinding({required this.memory, required this.engine});

  /// The store the corpus is seeded into and the conductor recalls from.
  final TomBrainMemory memory;

  /// The engine that runs the `retrieve_for_prompt_v1` conductor.
  final ProcedureEngine engine;
}

/// Builds the [EvalProfileBinding] for a freshly-provisioned profile.
typedef EvalProfileBinder = Future<EvalProfileBinding> Function(String profile);

/// The production [RetrievalEvalEnvironment] over a real engine + store.
final class ProcedureEngineEvalEnvironment implements RetrievalEvalEnvironment {
  ProcedureEngineEvalEnvironment({
    required this.bind,
    String conductorId = 'retrieve_for_prompt_v1',
    Scope seedScope = const Scope(producer: 'eval:retrieval_eval:seed'),
  })  : _conductorId = conductorId,
        _seedScope = seedScope;

  /// Builds the per-profile memory + engine binding.
  final EvalProfileBinder bind;

  final String _conductorId;
  final Scope _seedScope;
  final Map<String, EvalProfileBinding> _bindings =
      <String, EvalProfileBinding>{};

  Future<EvalProfileBinding> _bindingFor(String profile) async =>
      _bindings[profile] ??= await bind(profile);

  @override
  Future<void> provision(String profile) async {
    // Build (and cache) the binding, then create the profile through the
    // binding's own registry surface — the binding owns the store handle.
    final binding = await _bindingFor(profile);
    final exists = await binding.memory.profiles.exists(profile);
    if (!exists) await binding.memory.profiles.createProfile(profile);
  }

  @override
  Future<void> seed(String profile, List<EvalSeedDoc> docs) async {
    final binding = await _bindingFor(profile);
    for (final doc in docs) {
      await binding.memory.persist(
        evalDocToDraft(doc),
        scope: Scope(
          producer: _seedScope.producer,
          idempotencyKey: 'eval:${doc.evalId}',
        ),
      );
    }
  }

  @override
  Future<List<String>> query(
    String profile,
    String prompt,
    MemoryRetrievalConfig config,
  ) async {
    final binding = await _bindingFor(profile);
    final outcome = await binding.engine
        .invoke(ProcedureInvocation(
          procedureId: _conductorId,
          arguments: <String, Object?>{
            'text': prompt,
            'retrievalConfig': config.toConductorMap(),
          },
        ))
        .outcome;
    return evalIdsFromRecall(outcome.result?.outputs['recall']);
  }

  @override
  Future<void> drop(String profile) async {
    final binding = _bindings.remove(profile);
    if (binding != null) {
      await binding.memory.profiles.dropProfile(profile);
    }
  }
}

/// Maps an [EvalSeedDoc] to the [NodeDraft] the seed phase persists.
///
/// Carries the logical [EvalSeedDoc.evalId] in `values['evalId']` (so
/// [evalIdsFromRecall] can recover it from a recalled node) and projects the
/// lower-case corpus `kind` to a capitalised `typeName` (`event` → `Event`).
NodeDraft evalDocToDraft(EvalSeedDoc doc) => NodeDraft(
      typeName: _capitalise(doc.kind),
      values: <String, Object?>{
        'evalId': doc.evalId,
        'text': doc.text,
        if (doc.at != null) 'at': doc.at,
        if (doc.about.isNotEmpty) 'about': doc.about,
      },
    );

/// Pulls the ordered `evalId`s out of the conductor's `recall` map output
/// (`{'nodes': [{'values': {'evalId': …}}, …]}`), best-first, skipping any
/// node that does not carry a string `evalId`. Tolerant of a missing /
/// malformed shape (returns an empty list) — the conductor's PE-6 degrade
/// path can return a sparse result.
List<String> evalIdsFromRecall(Object? recall) {
  if (recall is! Map) return const <String>[];
  final nodes = recall['nodes'];
  if (nodes is! List) return const <String>[];
  final ids = <String>[];
  for (final node in nodes) {
    if (node is! Map) continue;
    final values = node['values'];
    if (values is! Map) continue;
    final evalId = values['evalId'];
    if (evalId is String) ids.add(evalId);
  }
  return ids;
}

String _capitalise(String kind) =>
    kind.isEmpty ? kind : '${kind[0].toUpperCase()}${kind.substring(1)}';
