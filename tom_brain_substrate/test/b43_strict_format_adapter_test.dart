// B.43 — strict-format response adapter (spec § 5.4, Q-B.43.2).
//
// `substrate_specification.md` § 5.4 row for `format`:
//
//   | `format` | HTTP 400 + format body | Re-emit with strict-format
//   |          |                        | adapter; single retry. |
//
// Before this step the router treated `format` as a generic
// `retryThenRotate`: it re-sent the *identical* prompt, which is pointless
// for a format failure — the same model handed the same prompt produces
// the same malformed output. This suite pins the real spec behaviour:
//
//   1. The [StrictFormatAdapter] appends a strict-format reinforcement
//      block to a [WirePrompt] body while preserving the anchor block
//      (first paragraph) and every provenance field.
//   2. On a `format`-class failure the router re-emits the *adapted*
//      prompt exactly once (single retry, independent of
//      `retriesPerClass`), then rotates if the adapted retry also fails.
//   3. The role's structured-output schema (`LlmOptions.responseFormat`)
//      flows into the reinforcement block when present.

import 'dart:convert';

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('StrictFormatAdapter — pure prompt transform', () {
    final adapter = StrictFormatAdapter.shared;

    test('appends the reinforcement marker after the original body', () {
      final original = _prompt('anchor-block\n\nrole body text');
      final reinforced = adapter.reinforce(original);

      // The original body is preserved verbatim and stays first (so the
      // anchor paragraph remains the prompt's opening).
      expect(reinforced.combined, startsWith('anchor-block\n\nrole body text'));
      expect(
        reinforced.combined,
        contains(StrictFormatAdapter.reinforcementMarker),
      );
    });

    test('preserves anchorHash, roleId and templateSha', () {
      final original = _prompt('body');
      final reinforced = adapter.reinforce(original);

      expect(reinforced.anchorHash, original.anchorHash);
      expect(reinforced.roleId, original.roleId);
      expect(reinforced.templateSha, original.templateSha);
    });

    test('without a schema, embeds only the generic strict-format text', () {
      final reinforced = adapter.reinforce(_prompt('body'));

      expect(reinforced.combined, contains('did not match the required'));
      // No JSON schema fragment when none was supplied.
      expect(reinforced.combined, isNot(contains('"type"')));
      expect(reinforced.combined, isNot(contains('conforming to this schema')));
    });

    test('with a schema, embeds the JSON-encoded schema', () {
      final schema = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'answer': <String, Object?>{'type': 'string'},
        },
      };
      final reinforced = adapter.reinforce(
        _prompt('body'),
        responseFormat: schema,
      );

      expect(reinforced.combined, contains('conforming to this schema'));
      expect(reinforced.combined, contains(jsonEncode(schema)));
    });
  });

  group('LlmRouter — format failover re-emits the adapted prompt', () {
    test('format failure → single re-emit with the reinforced prompt, '
        'then success, no rotation', () async {
      final failing = _RecordingFailureProvider(
        id: 'p',
        defaultModel: 'm',
        exceptions: <Object>[
          OpenAiHttpException(
            statusCode: 400,
            body: 'response_format JSON schema invalid',
            endpoint: Uri.parse('http://x/y'),
          ),
        ],
        fallthrough: () => 'ok',
      );
      final fallback = _RecordingFailureProvider(
        id: 'fb',
        defaultModel: 'fbm',
        exceptions: const <Object>[],
        fallthrough: () => 'fb-ok',
      );
      final router = LlmRouter(
        providers: <String, LlmProvider>{'p': failing, 'fb': fallback},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'r': <RouteEntry>[
              const RouteEntry(providerId: 'p', model: 'm'),
              const RouteEntry(providerId: 'fb', model: 'fbm'),
            ],
          },
          // High generic retry budget — `format` must still retry exactly
          // once (single), not `retriesPerClass` times.
          retriesPerClass: 5,
        ),
      );

      final report = await router.dispatch(
        roleId: 'r',
        prompt: _prompt('original body'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );

      // Won on the same route after a single re-emit; never rotated.
      expect(report.providerId, 'p');
      expect(report.retries, 1);
      expect(failing.callCount, 2);
      expect(fallback.callCount, 0);

      // First attempt: original prompt. Second attempt: the adapted prompt.
      expect(failing.bodies[0], 'original body');
      expect(
        failing.bodies[1],
        contains(StrictFormatAdapter.reinforcementMarker),
      );
    });

    test('responseFormat schema flows into the re-emitted prompt', () async {
      final schema = <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'answer': <String, Object?>{'type': 'string'},
        },
      };
      final failing = _RecordingFailureProvider(
        id: 'p',
        defaultModel: 'm',
        exceptions: <Object>[
          OpenAiHttpException(
            statusCode: 400,
            body: 'invalid format',
            endpoint: Uri.parse('http://x/y'),
          ),
        ],
        fallthrough: () => 'ok',
      );
      final router = LlmRouter(
        providers: <String, LlmProvider>{'p': failing},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'r': <RouteEntry>[const RouteEntry(providerId: 'p', model: 'm')],
          },
        ),
      );

      await router.dispatch(
        roleId: 'r',
        prompt: _prompt('original body'),
        options: const LlmOptions(
          responseFormat: <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'answer': <String, Object?>{'type': 'string'},
            },
          },
        ),
        budget: _bigBudget,
      );

      expect(failing.bodies[1], contains(jsonEncode(schema)));
    });

    test('format persists after the single re-emit → rotate to next route, '
        'no cooldown applied', () async {
      final failing = _RecordingFailureProvider(
        id: 'p',
        defaultModel: 'm',
        exceptions: <Object>[
          OpenAiHttpException(
            statusCode: 400,
            body: 'format error',
            endpoint: Uri.parse('http://x/y'),
          ),
          OpenAiHttpException(
            statusCode: 400,
            body: 'format error again',
            endpoint: Uri.parse('http://x/y'),
          ),
        ],
        fallthrough: () => 'never',
      );
      final fallback = _RecordingFailureProvider(
        id: 'fb',
        defaultModel: 'fbm',
        exceptions: const <Object>[],
        fallthrough: () => 'fb-ok',
      );
      final router = LlmRouter(
        providers: <String, LlmProvider>{'p': failing, 'fb': fallback},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'r': <RouteEntry>[
              const RouteEntry(providerId: 'p', model: 'm'),
              const RouteEntry(providerId: 'fb', model: 'fbm'),
            ],
          },
        ),
      );

      final report = await router.dispatch(
        roleId: 'r',
        prompt: _prompt('original'),
        options: LlmOptions.empty,
        budget: _bigBudget,
      );

      // Two attempts on `p` (original + one adapted re-emit), then rotated.
      expect(failing.callCount, 2);
      expect(report.providerId, 'fb');
      // `format` carries no cooldown — the route stays dispatchable.
      expect(router.isInCooldown(providerId: 'p', modelId: 'm'), isFalse);
      expect(router.cooldownsActive, 0);
    });

    test('streaming: format failure re-emits the adapted prompt once then '
        'forwards the successful stream', () async {
      final failing = _RecordingFailureProvider(
        id: 'p',
        defaultModel: 'm',
        exceptions: <Object>[
          OpenAiHttpException(
            statusCode: 400,
            body: 'schema mismatch',
            endpoint: Uri.parse('http://x/y'),
          ),
        ],
        fallthrough: () => 'streamed',
      );
      final router = LlmRouter(
        providers: <String, LlmProvider>{'p': failing},
        policy: RouterPolicy(
          roleRoutes: <String, List<RouteEntry>>{
            'r': <RouteEntry>[const RouteEntry(providerId: 'p', model: 'm')],
          },
        ),
      );

      final events = await router
          .dispatchStream(
            roleId: 'r',
            prompt: _prompt('original body'),
            options: LlmOptions.empty,
            budget: _bigBudget,
          )
          .toList();

      expect(events.last, isA<LlmRunCompleted>());
      expect(failing.streamCallCount, 2);
      expect(failing.bodies[0], 'original body');
      expect(
        failing.bodies[1],
        contains(StrictFormatAdapter.reinforcementMarker),
      );
    });
  });
}

// ─── Test helpers ────────────────────────────────────────────────

WirePrompt _prompt(String body) => WirePrompt(
  system: body,
  anchorHash: 'sha256:anchor',
  roleId: 'analyser',
  templateSha: 'sha-abc',
);

final Budget _bigBudget = Budget(
  wallClockMs: 60000,
  tokenSpend: 100000,
  toolCalls: 0,
  memoryWrites: 0,
);

/// LlmProvider that records every prompt body it is handed and drains a
/// scripted list of exceptions on successive calls, then falls through to
/// a successful response built from [fallthrough].
///
/// Recording the bodies lets the format-adapter tests prove that the
/// *second* attempt carried the reinforcement block while the *first*
/// carried the verbatim prompt.
class _RecordingFailureProvider extends LlmProvider {
  @override
  final String id;
  final String defaultModel;
  final List<Object> _exceptions;
  final String Function() fallthrough;

  /// Bodies received, in call order (covers both `complete` and
  /// `completeStream`).
  final List<String> bodies = <String>[];
  int callCount = 0;
  int streamCallCount = 0;

  _RecordingFailureProvider({
    required this.id,
    required this.defaultModel,
    required List<Object> exceptions,
    required this.fallthrough,
  }) : _exceptions = List<Object>.of(exceptions);

  @override
  Future<LlmCallReport> complete(LlmRequest request) async {
    final prompt = request.prompt;
    final options = request.options;
    callCount++;
    bodies.add(prompt.combined);
    if (_exceptions.isNotEmpty) {
      throw _exceptions.removeAt(0);
    }
    final r = fallthrough();
    return LlmCallReport(
      providerId: id,
      modelId: options.model ?? defaultModel,
      anchorHash: prompt.anchorHash,
      promptHash: 'sha256:body',
      tokensIn: prompt.combined.length,
      tokensOut: r.length,
      retries: 0,
      wallClockMs: 0,
      templateSha: prompt.templateSha,
    );
  }

  @override
  Stream<LlmEvent> run(LlmRequest request) async* {
    final prompt = request.prompt;
    final options = request.options;
    streamCallCount++;
    bodies.add(prompt.combined);
    final callId = 'rfp-$id-$streamCallCount';
    yield LlmRunStarted(
      callId: callId,
      providerId: id,
      modelId: options.model ?? defaultModel,
    );
    if (_exceptions.isNotEmpty) {
      final ex = _exceptions.removeAt(0);
      yield LlmRunFailed(
        callId: callId,
        failure: LlmFailure(
          classCode: 'unknown',
          message: ex.toString(),
          cause: ex,
        ),
        report: LlmCallReport(
          providerId: id,
          modelId: options.model ?? defaultModel,
          anchorHash: prompt.anchorHash,
          promptHash: '',
          tokensIn: 0,
          tokensOut: 0,
          retries: 0,
          wallClockMs: 0,
        ),
      );
      return;
    }
    yield LlmRunCompleted(
      callId: callId,
      report: LlmCallReport(
        providerId: id,
        modelId: options.model ?? defaultModel,
        anchorHash: prompt.anchorHash,
        promptHash: '',
        tokensIn: 0,
        tokensOut: 0,
        retries: 0,
        wallClockMs: 0,
      ),
    );
  }
}
