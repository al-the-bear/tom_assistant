// probeEmbeddingReachableAtBoot — the boot-time reachability check for the
// embedding substrate.
//
// The embedding backend (Ollama by default, `nomic-embed-text` on
// `127.0.0.1:11434`) is a *separate* service from the chat LLM. On a split
// deployment (bomber: chat = omlx on :8000, embeddings = ollama on :11434) the
// chat provider can be up while the embedding backend is down — and nothing
// downstream notices until the first embedding-dependent work runs (a vector
// recall, or a dreaming lane that re-embeds) and crashes with `Connection
// refused`. Live, that surfaced only as a wall of errored dream lanes with no
// boot-time hint that the backend was unreachable — exactly the gap flagged as
// "the reachability of some service should have been verified at startup, but
// hasn't."
//
// This probe does ONE real embed round-trip at boot — the *same* wire path the
// steady state uses (`substrate.embed`), so it cannot pass while real embeds
// fail — and reports the outcome once, clearly, at startup. It is **non-fatal**:
// chat answers need no embeddings, so an unreachable backend produces an
// actionable WARN and a `false` return rather than aborting boot. The brain
// still serves chat; only the embedding-dependent surfaces are degraded, and
// the operator now knows why from line one of the log instead of inferring it
// from a flood of errored dream lanes.

import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show TomBrainSubstrateClient;

/// The embedding-dependent surfaces named in the unreachable warning, so the
/// operator sees *what* degrades — not just that "embeddings" are down.
const String _degradedSurfaces =
    'vector-mode recall and every dreaming lane that re-embeds '
    '(dream_extract_v1, dream_connect_v1, dream_repetition_detect_v1, '
    'dream_recentroid_v1, research_v1, …)';

/// Probes the embedding substrate for reachability at boot by performing one
/// real [TomBrainSubstrateClient.embed] round-trip with [probeText].
///
/// Returns `true` when the backend answered (calling [info] with the resolved
/// model identity), `false` when it did not (calling [warn] with an actionable
/// message that names the failure, the degraded surfaces, and how to recover).
/// Never throws — a failed probe is reported, not propagated, because the chat
/// path does not depend on embeddings and must still boot.
Future<bool> probeEmbeddingReachableAtBoot(
  TomBrainSubstrateClient substrate, {
  required void Function(String message) warn,
  void Function(String message)? info,
  String probeText = 'tom-brain embedding reachability probe',
}) async {
  try {
    final result = await substrate.embed(probeText);
    final identity = result.modelIdentity;
    info?.call(
      '[embedding] reachable — provider=${identity.providerId} '
      'model=${identity.modelId} dims=${identity.dims}',
    );
    return true;
  } on Object catch (error) {
    warn(
      '[embedding] UNREACHABLE — the embedding backend did not answer a boot '
      'probe: $error\n'
      '        Embedding-dependent work will fail until it is reachable: '
      '$_degradedSurfaces.\n'
      '        Chat answers are unaffected. Bring the embedding backend up '
      '(e.g. `ollama serve`) or repoint `substrate.embedding` at a reachable '
      'endpoint.',
    );
    return false;
  }
}
