// The embedding backend is a separate service from the chat LLM, and on a
// split deployment it can be down while chat is up. Nothing downstream noticed
// until the first embedding-dependent work crashed with `Connection refused` —
// a wall of errored dream lanes with no boot-time hint. `probeEmbeddingReachable
// AtBoot` closes that gap: one real embed round-trip at boot, reported once and
// clearly, non-fatally.
//
// ── What this suite proves ──────────────────────────────────────────────
//
//   1. When the backend answers, the probe returns true and reports the
//      resolved model identity via `info` (never `warn`).
//   2. When the backend throws (Connection refused), the probe returns false,
//      does NOT rethrow (boot is non-fatal), and the `warn` message is
//      actionable: it carries the cause, the degraded surfaces, and the
//      recovery hint.

import 'package:test/test.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart' show Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show EmbeddingModelIdentity, EmbeddingResult, TomBrainSubstrateClient;

import 'package:tom_brain_run/tom_brain_run.dart'
    show probeEmbeddingReachableAtBoot;

void main() {
  test('a reachable backend returns true and reports identity via info',
      () async {
    final warnings = <String>[];
    final infos = <String>[];

    final reachable = await probeEmbeddingReachableAtBoot(
      _ReachableSubstrate(),
      warn: warnings.add,
      info: infos.add,
    );

    expect(reachable, isTrue);
    expect(warnings, isEmpty, reason: 'a reachable backend never warns');
    expect(infos, hasLength(1));
    expect(infos.single, contains('provider=ollama:local'));
    expect(infos.single, contains('model=nomic-embed-text'));
    expect(infos.single, contains('dims=768'));
  });

  test(
      'an unreachable backend returns false, does not throw, and warns '
      'actionably', () async {
    final warnings = <String>[];

    final reachable = await probeEmbeddingReachableAtBoot(
      _UnreachableSubstrate(),
      warn: warnings.add,
    );

    expect(reachable, isFalse, reason: 'boot is non-fatal on a dead backend');
    expect(warnings, hasLength(1));
    final warning = warnings.single;
    expect(warning, contains('UNREACHABLE'));
    // The cause is threaded through so the operator sees the endpoint.
    expect(warning, contains('Connection refused'));
    expect(warning, contains('11434'));
    // The degraded surfaces and the recovery hint are both present.
    expect(warning, contains('dream_recentroid_v1'));
    expect(warning, contains('ollama serve'));
    expect(warning, contains('Chat answers are unaffected'));
  });
}

/// A substrate double whose `embed` succeeds with a fixed identity.
class _ReachableSubstrate implements TomBrainSubstrateClient {
  @override
  Future<EmbeddingResult> embed(String text) async => EmbeddingResult(
        vec: Vec.fromList(List<double>.filled(768, 0.0)),
        modelIdentity: const EmbeddingModelIdentity(
          providerId: 'ollama:local',
          modelId: 'nomic-embed-text',
          dims: 768,
          normalized: true,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// A substrate double whose `embed` throws the same shape that crashed the live
/// dream lanes — a connection-refused to the Ollama embeddings endpoint.
class _UnreachableSubstrate implements TomBrainSubstrateClient {
  @override
  Future<EmbeddingResult> embed(String text) async => throw Exception(
        'ClientException with SocketException: Connection refused '
        '(OS Error: Connection refused, errno = 111), '
        'uri=http://127.0.0.1:11434/api/embeddings',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
