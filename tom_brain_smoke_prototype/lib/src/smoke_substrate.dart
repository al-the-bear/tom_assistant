// SmokeSubstrate — a stub `TomBrainSubstrateClient` for the end-to-end smoke
// (E.46).
//
// The smoke harness boots a real `BrainProcessBoot`, which binds the engine's
// `sub` bridge against a `TomBrainSubstrateClient`. For the prototype smoke we
// do not want a real provider call, so this stub stands in: it emits a canned
// chunked answer stream (whose concatenation is the answer text) and a fixed
// one-dimensional embedding. It records its open/close lifecycle so a test can
// assert the boot opened and the shutdown closed it.
//
// Modelled on the procedure prototype's `_AnsweringSubstrate`
// (`d44_brain_process_boot_test.dart`) — kept here as a library symbol (not a
// test fixture) so the harness and every E.10 smoke step share one stub.

import 'dart:typed_data';

import 'package:tom_brain_shared/tom_brain_shared.dart' show Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

/// A stub [TomBrainSubstrateClient] that answers with a canned chunked stream.
///
/// [answerChunks] is the ordered list of text fragments the next
/// [completeStream] emits; their concatenation is the answer. A test sets it
/// before driving a run (E.47+); for a pure stand-up smoke (E.46) the default
/// is enough. [openCount] / [closeCount] record the lifecycle the boot drives.
final class SmokeSubstrate implements TomBrainSubstrateClient {
  /// The ordered answer fragments the next [completeStream] emits.
  List<String> answerChunks = <String>['ok'];

  /// Number of times [open] has been called (boot opens at most once, and only
  /// when a `SubstrateConfig` is supplied).
  int openCount = 0;

  /// Number of times [close] has been called (shutdown closes exactly once).
  int closeCount = 0;

  @override
  Future<void> open(SubstrateConfig config) async {
    openCount++;
  }

  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    return Stream<LlmStreamEvent>.fromIterable(<LlmStreamEvent>[
      for (final String chunk in answerChunks)
        LlmStreamChunk(callId: 'smoke', text: chunk),
      const LlmStreamCompleted(
        callId: 'smoke',
        report: LlmCallReport(
          providerId: 'smoke',
          modelId: 'smoke',
          anchorHash: 'a',
          promptHash: 'p',
          tokensIn: 1,
          tokensOut: 1,
          retries: 0,
          wallClockMs: 1,
        ),
      ),
    ]);
  }

  @override
  Future<EmbeddingResult> embed(String text) async => EmbeddingResult(
        vec: Vec(Float32List.fromList(<double>[0.0])),
        modelIdentity: const EmbeddingModelIdentity(
          providerId: 'smoke',
          modelId: 'smoke',
          dims: 1,
          normalized: true,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
