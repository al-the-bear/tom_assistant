// B.16 — `StubLlmProvider` conformance suite.
//
// Scope of this test file:
//
//   - Prove `StubLlmProvider` honours every `LlmProvider` contract
//     point that B.11 documented (id propagation, anchor-hash
//     propagation, provenance stamp, prompt-body preservation, the
//     `Started → Chunk* → Completed` lifecycle on the streaming
//     path, the `Completed` carrying the same provenance as a paired
//     `complete()` call would).
//
//   - Prove every determinism guarantee the file-level header makes:
//       * `wallClockMs == 0` on every emitted report.
//       * `tokensIn == prompt.combined.length`.
//       * `tokensOut == response.length`.
//       * `retries == 0`, `cost == null`.
//       * `callId` shape and monotonic counter advance.
//       * `notes` always contains `stub:deterministic`.
//       * Repeat calls with identical prompts return identical reports
//         apart from the `callId` (counter advances) — same anchor /
//         model / hashes / token counts / wall-clock.
//
//   - Prove the three response-generation modes:
//       * **Script** drains in FIFO order; exhausting an
//         `loopScript: false` queue throws `StateError` on the next
//         call; `loopScript: true` cycles; `enqueueScripted` extends.
//       * **Responder** callback receives the prompt + options and its
//         return value is the response. A `throw` inside the responder
//         re-throws from `complete` and surfaces as `LlmStreamFailed`
//         (`classCode: 'unknown'`) from `completeStream`.
//       * **Default echo** (`'STUB:' + prompt.combined`) is the fallback
//         when neither script nor responder is configured.
//
//   - Prove the chunk-splitter contract:
//       * `singleChunk` default emits exactly one `LlmStreamChunk` per
//         non-empty response, zero for an empty response.
//       * `splitByWord` emits one chunk per whitespace-separated
//         non-empty segment.
//       * A custom callback can shape multi-chunk streams arbitrarily.
//       * Empty strings in the splitter's output are suppressed by
//         the stream emitter (no zero-length `LlmStreamChunk`).
//
//   - Prove the `alwaysFails` factory:
//       * `complete` re-throws the failure's `cause` (or a
//         `StateError(failure.message)` when `cause` is null).
//       * `completeStream` emits `LlmStreamStarted` then
//         `LlmStreamFailed` — never a `LlmStreamCompleted`, never a
//         `LlmStreamChunk`.
//       * The terminal `LlmStreamFailed` carries the supplied
//         `LlmFailure` verbatim and a `LlmCallReport` honouring the
//         anchor / provenance / determinism guarantees.
//
//   - Prove the `tool_catalogue_present:not_yet_dispatched` note is
//     surfaced when `options.toolCatalogue` is non-empty, matching
//     B.14 / B.15.
//
//   - Prove the barrel surface reaches the test through
//     `package:tom_brain_substrate/tom_brain_substrate.dart` only
//     (no `package:foo/src/...` deep imports).
//
// Scope this file is NOT for:
//
//   - No router behaviour (retry / rotate / failure classification).
//     B.18+. This file's `alwaysFails` factory deliberately emits
//     `classCode: 'unknown'` because the stub does not classify.
//   - No anchor enforcement test (B.46). The stub propagates the
//     anchor it receives; it does not validate.
//   - No cross-provider conformance run. That is B.17. This file is
//     the per-provider test; B.17 runs every provider against the
//     same `LlmProvider` contract.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.16 / StubLlmProvider — interface conformance', () {
    test('default id and model are stub / stub-model', () {
      final provider = StubLlmProvider();
      expect(provider.id, 'stub');
      expect(provider.defaultModel, 'stub-model');
      expect(provider, isA<LlmProvider>());
    });

    test('id and defaultModel are constructor-overridable', () {
      final provider = StubLlmProvider(
        id: 'stub:test',
        defaultModel: 'sized-medium',
      );
      expect(provider.id, 'stub:test');
      expect(provider.defaultModel, 'sized-medium');
    });

    test(
      'complete stamps anchor + provider + template metadata onto the report',
      () async {
        final provider = StubLlmProvider(id: 'stub:test');

        final report = await provider.complete(
          const WirePrompt(
            system: 'I am dedicated to this user.\n\nask',
            anchorHash: 'sha256:anchor-stamp',
            roleId: 'assistant_to_user',
            templateSha: 'tpl-1',
          ),
          const LlmOptions(),
        );

        expect(report.providerId, 'stub:test');
        expect(report.modelId, 'stub-model');
        expect(report.anchorHash, 'sha256:anchor-stamp');
        expect(report.templateSha, 'tpl-1');
        expect(report.promptHash,
            _sha256Stamp('I am dedicated to this user.\n\nask'));
      },
    );

    test('options.model overrides defaultModel on the report', () async {
      final provider = StubLlmProvider(defaultModel: 'fallback');
      final report = await provider.complete(
        const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(model: 'caller-picked'),
      );
      expect(report.modelId, 'caller-picked');
    });

    test('the stub does not mutate the prompt body before emitting it',
        () async {
      final captured = <String>[];
      final provider = StubLlmProvider(
        responder: (prompt, options) {
          captured.add(prompt.combined);
          return 'ok';
        },
      );

      await provider.complete(
        const WirePrompt(
          system: 'I am dedicated to this user.\n\nverbatim body',
          anchorHash: 'a',
          roleId: 'r',
        ),
        const LlmOptions(),
      );

      expect(captured.single, 'I am dedicated to this user.\n\nverbatim body');
    });

    test(
      'completeStream emits Started → Chunk → Completed for a non-empty response',
      () async {
        final provider = StubLlmProvider(
          responder: (_, _) => 'one big chunk',
        );

        final events = await provider
            .completeStream(
              const WirePrompt(
                system: 'streaming body',
                anchorHash: 'sha256:stream-anchor',
                roleId: 'assistant_to_user',
                templateSha: 'tpl-2',
              ),
              const LlmOptions(),
            )
            .toList();

        expect(events.first, isA<LlmStreamStarted>());
        expect(events.last, isA<LlmStreamCompleted>());

        final middle = events.sublist(1, events.length - 1);
        expect(middle, hasLength(1));
        expect(middle.single, isA<LlmStreamChunk>());

        final chunk = middle.single as LlmStreamChunk;
        expect(chunk.text, 'one big chunk');

        final started = events.first as LlmStreamStarted;
        final completed = events.last as LlmStreamCompleted;
        expect(started.providerId, 'stub');
        expect(completed.callId, started.callId);
        expect(chunk.callId, started.callId);
        expect(completed.report.anchorHash, 'sha256:stream-anchor');
        expect(completed.report.providerId, 'stub');
        expect(completed.report.templateSha, 'tpl-2');
      },
    );

    test(
      'completeStream emits only Started + Completed for an empty response '
      '(no zero-length Chunk events per spec § 4.3 / B.14 convention)',
      () async {
        final provider = StubLlmProvider(responder: (_, _) => '');

        final events = await provider
            .completeStream(
              const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
              const LlmOptions(),
            )
            .toList();

        expect(events, hasLength(2));
        expect(events.first, isA<LlmStreamStarted>());
        expect(events.last, isA<LlmStreamCompleted>());
        expect(events.whereType<LlmStreamChunk>(), isEmpty);
      },
    );

    test(
      'tool catalogue present surfaces a "not yet dispatched" note '
      '(matches B.14 / B.15)',
      () async {
        final provider = StubLlmProvider();
        final report = await provider.complete(
          const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
          const LlmOptions(
            toolCatalogue: ToolCatalogue(<ToolDescriptor>[
              ToolDescriptor(
                name: 'noop',
                description: 'no-op',
                parametersSchema: <String, Object?>{},
              ),
            ]),
          ),
        );
        expect(
          report.notes,
          contains('tool_catalogue_present:not_yet_dispatched'),
        );
        expect(report.notes, contains('stub:deterministic'));
      },
    );
  });

  group('B.16 / StubLlmProvider — determinism guarantees', () {
    test('wallClockMs is always 0; retries is always 0; cost is always null',
        () async {
      final provider = StubLlmProvider();
      final r1 = await provider.complete(
        const WirePrompt(system: 'a', anchorHash: 'h', roleId: 'r'),
        const LlmOptions(),
      );
      final r2 = await provider.complete(
        const WirePrompt(system: 'a longer body', anchorHash: 'h', roleId: 'r'),
        const LlmOptions(),
      );
      for (final r in <LlmCallReport>[r1, r2]) {
        expect(r.wallClockMs, 0);
        expect(r.retries, 0);
        expect(r.cost, isNull);
      }
    });

    test('tokensIn == prompt.combined.length, tokensOut == response.length',
        () async {
      final provider = StubLlmProvider(
        responder: (prompt, _) => 'ECHO:${prompt.combined}',
      );
      final report = await provider.complete(
        const WirePrompt(system: 'twelve chars', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );
      expect(report.tokensIn, 'twelve chars'.length);
      expect(report.tokensOut, 'ECHO:twelve chars'.length);
    });

    test(
      'two calls with identical prompts produce identical reports except for callId',
      () async {
        final provider = StubLlmProvider(loopScript: true, script: const <String>[
          'fixed response',
        ]);

        final firstReport = await provider.complete(
          const WirePrompt(system: 'same', anchorHash: 'h', roleId: 'r'),
          const LlmOptions(),
        );
        final secondReport = await provider.complete(
          const WirePrompt(system: 'same', anchorHash: 'h', roleId: 'r'),
          const LlmOptions(),
        );

        expect(secondReport.providerId, firstReport.providerId);
        expect(secondReport.modelId, firstReport.modelId);
        expect(secondReport.anchorHash, firstReport.anchorHash);
        expect(secondReport.promptHash, firstReport.promptHash);
        expect(secondReport.tokensIn, firstReport.tokensIn);
        expect(secondReport.tokensOut, firstReport.tokensOut);
        expect(secondReport.wallClockMs, firstReport.wallClockMs);
      },
    );

    test('promptHash is sha256(body) and is stable across calls', () async {
      final provider = StubLlmProvider();
      final r1 = await provider.complete(
        const WirePrompt(system: 'deterministic', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );
      final r2 = await provider.complete(
        const WirePrompt(system: 'deterministic', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );
      expect(r1.promptHash, _sha256Stamp('deterministic'));
      expect(r2.promptHash, r1.promptHash);
    });

    test('different prompt bodies hash differently', () async {
      final provider = StubLlmProvider();
      final r1 = await provider.complete(
        const WirePrompt(system: 'first', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );
      final r2 = await provider.complete(
        const WirePrompt(system: 'second', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );
      expect(r1.promptHash, isNot(r2.promptHash));
    });

    test('notes always contains stub:deterministic', () async {
      final provider = StubLlmProvider();
      final report = await provider.complete(
        const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );
      expect(report.notes, contains('stub:deterministic'));
    });
  });

  group('B.16 / StubLlmProvider — callId monotonic counter', () {
    test('callCount starts at 0 and increments per call', () async {
      final provider = StubLlmProvider();
      expect(provider.callCount, 0);

      await provider.complete(
        const WirePrompt(system: 'a', anchorHash: 'h', roleId: 'r'),
        const LlmOptions(),
      );
      expect(provider.callCount, 1);

      await provider.complete(
        const WirePrompt(system: 'b', anchorHash: 'h', roleId: 'r'),
        const LlmOptions(),
      );
      expect(provider.callCount, 2);

      await provider
          .completeStream(
            const WirePrompt(system: 'c', anchorHash: 'h', roleId: 'r'),
            const LlmOptions(),
          )
          .toList();
      expect(provider.callCount, 3);
    });

    test('callId follows the stub-<id>-<counter>-<hexBodyHash> shape',
        () async {
      final provider = StubLlmProvider(id: 'stub:shape');
      final events = await provider
          .completeStream(
            const WirePrompt(system: 'shape-test', anchorHash: 'a', roleId: 'r'),
            const LlmOptions(),
          )
          .toList();

      final started = events.first as LlmStreamStarted;
      // Counter incremented from 0 to 1 at the start of completeStream.
      expect(started.callId, startsWith('stub-stub:shape-1-'));
    });

    test('successive callIds differ (counter advances)', () async {
      final provider = StubLlmProvider();
      final s1 = await provider
          .completeStream(
            const WirePrompt(system: 'same', anchorHash: 'a', roleId: 'r'),
            const LlmOptions(),
          )
          .toList();
      final s2 = await provider
          .completeStream(
            const WirePrompt(system: 'same', anchorHash: 'a', roleId: 'r'),
            const LlmOptions(),
          )
          .toList();
      final id1 = (s1.first as LlmStreamStarted).callId;
      final id2 = (s2.first as LlmStreamStarted).callId;
      expect(id1, isNot(id2));
    });
  });

  group('B.16 / StubLlmProvider — script mode', () {
    test('drains FIFO across complete calls', () async {
      final provider = StubLlmProvider(
        script: const <String>['first', 'second', 'third'],
      );
      expect(provider.scriptRemaining, 3);

      final r1 = await provider.complete(
        const WirePrompt(system: 'a', anchorHash: 'h', roleId: 'r'),
        const LlmOptions(),
      );
      final r2 = await provider.complete(
        const WirePrompt(system: 'a', anchorHash: 'h', roleId: 'r'),
        const LlmOptions(),
      );

      expect(r1.tokensOut, 'first'.length);
      expect(r2.tokensOut, 'second'.length);
      expect(provider.scriptRemaining, 1);
    });

    test('exhausted (loopScript: false) throws StateError on the next call',
        () async {
      final provider = StubLlmProvider(script: const <String>['only one']);
      await provider.complete(
        const WirePrompt(system: 'x', anchorHash: 'h', roleId: 'r'),
        const LlmOptions(),
      );
      expect(provider.scriptRemaining, 0);

      await expectLater(
        provider.complete(
          const WirePrompt(system: 'x', anchorHash: 'h', roleId: 'r'),
          const LlmOptions(),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('scripted responses exhausted'),
          ),
        ),
      );
    });

    test('loopScript: true cycles the queue indefinitely', () async {
      final provider = StubLlmProvider(
        loopScript: true,
        script: const <String>['alpha', 'beta'],
      );

      // Run 5 calls; queue is length 2; we expect alpha/beta/alpha/beta/alpha.
      final outs = <int>[];
      for (var i = 0; i < 5; i++) {
        final r = await provider.complete(
          const WirePrompt(system: 'x', anchorHash: 'h', roleId: 'r'),
          const LlmOptions(),
        );
        outs.add(r.tokensOut);
      }
      expect(outs, <int>[
        'alpha'.length,
        'beta'.length,
        'alpha'.length,
        'beta'.length,
        'alpha'.length,
      ]);
      expect(provider.scriptRemaining, 2);
    });

    test('enqueueScripted extends a draining queue at runtime', () async {
      final provider = StubLlmProvider(script: const <String>['first']);
      await provider.complete(
        const WirePrompt(system: 'x', anchorHash: 'h', roleId: 'r'),
        const LlmOptions(),
      );
      expect(provider.scriptRemaining, 0);

      provider.enqueueScripted('extension');
      expect(provider.scriptRemaining, 1);

      final r = await provider.complete(
        const WirePrompt(system: 'x', anchorHash: 'h', roleId: 'r'),
        const LlmOptions(),
      );
      expect(r.tokensOut, 'extension'.length);
    });
  });

  group('B.16 / StubLlmProvider — responder mode', () {
    test('responder receives the prompt + options and its return value wins',
        () async {
      LlmOptions? capturedOptions;
      WirePrompt? capturedPrompt;

      final provider = StubLlmProvider(
        responder: (prompt, options) {
          capturedPrompt = prompt;
          capturedOptions = options;
          return 'response derived from ${prompt.roleId}';
        },
      );

      final report = await provider.complete(
        const WirePrompt(
          system: 'body',
          anchorHash: 'a',
          roleId: 'analyser',
        ),
        const LlmOptions(temperature: 0.5),
      );

      expect(capturedPrompt!.roleId, 'analyser');
      expect(capturedOptions!.temperature, 0.5);
      expect(report.tokensOut, 'response derived from analyser'.length);
    });

    test('responder throws → complete re-throws verbatim', () async {
      final provider = StubLlmProvider(
        responder: (_, _) => throw FormatException('responder boom'),
      );

      await expectLater(
        provider.complete(
          const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
          const LlmOptions(),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'responder throws → completeStream emits Started + Failed(unknown) '
      'with the original error as cause',
      () async {
        final provider = StubLlmProvider(
          responder: (_, _) => throw FormatException('responder boom'),
        );

        final events = await provider
            .completeStream(
              const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
              const LlmOptions(),
            )
            .toList();

        expect(events, hasLength(2));
        expect(events.first, isA<LlmStreamStarted>());
        expect(events.last, isA<LlmStreamFailed>());

        final failed = events.last as LlmStreamFailed;
        expect(failed.failure.classCode, 'unknown');
        expect(failed.failure.cause, isA<FormatException>());
        expect(failed.report.anchorHash, 'a');
        expect(failed.report.tokensIn, 'x'.length);
        expect(failed.report.tokensOut, 0); // no successful response
        expect(failed.report.wallClockMs, 0);
      },
    );
  });

  group('B.16 / StubLlmProvider — default echo mode', () {
    test('default echo is "STUB:" + body when no script and no responder',
        () async {
      final provider = StubLlmProvider();
      final report = await provider.complete(
        const WirePrompt(system: 'hi', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );
      expect(report.tokensOut, 'STUB:hi'.length);
    });

    test('default echo is exposed as a static helper', () {
      const wp = WirePrompt(system: 'data', anchorHash: 'a', roleId: 'r');
      expect(
        StubLlmProvider.defaultEcho(wp, const LlmOptions()),
        'STUB:data',
      );
    });

    test(
        'default echo concatenates the two channels as system + "\\n\\n" + user '
        '(the no-system-channel fallback)', () {
      const wp = WirePrompt(
        system: 'I am dedicated to this user.',
        user: 'user question',
        anchorHash: 'a',
        roleId: 'r',
      );
      // The stub has no native system channel, so it echoes
      // `WirePrompt.combined` — the documented `system + "\n\n" + user`
      // concatenation, anchor-first.
      expect(
        StubLlmProvider.defaultEcho(wp, const LlmOptions()),
        'STUB:I am dedicated to this user.\n\nuser question',
      );
    });

    test('responder, when present, wins over the default echo', () async {
      final provider = StubLlmProvider(
        responder: (_, _) => 'CUSTOM',
      );
      final report = await provider.complete(
        const WirePrompt(system: 'body', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );
      expect(report.tokensOut, 'CUSTOM'.length);
    });

    test('script, when non-empty, wins over the responder', () async {
      final provider = StubLlmProvider(
        script: const <String>['scripted'],
        responder: (_, _) => 'fallback',
      );
      final report = await provider.complete(
        const WirePrompt(system: 'body', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );
      expect(report.tokensOut, 'scripted'.length);

      // Once the script is drained, the responder takes over.
      final next = await provider.complete(
        const WirePrompt(system: 'body', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );
      expect(next.tokensOut, 'fallback'.length);
    });
  });

  group('B.16 / StubLlmProvider — chunk splitter', () {
    test('singleChunk returns one element for non-empty, empty list for empty',
        () {
      expect(StubLlmProvider.singleChunk('hello'), <String>['hello']);
      expect(StubLlmProvider.singleChunk(''), <String>[]);
    });

    test('splitByWord splits on whitespace and drops empties', () {
      expect(
        StubLlmProvider.splitByWord('  one   two\nthree '),
        <String>['one', 'two', 'three'],
      );
      expect(StubLlmProvider.splitByWord(''), <String>[]);
      expect(StubLlmProvider.splitByWord('   '), <String>[]);
    });

    test(
      'completeStream with splitByWord emits one Chunk per non-empty segment',
      () async {
        final provider = StubLlmProvider(
          responder: (_, _) => 'alpha beta gamma',
          chunkSplitter: StubLlmProvider.splitByWord,
        );
        final events = await provider
            .completeStream(
              const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
              const LlmOptions(),
            )
            .toList();

        final chunks = events.whereType<LlmStreamChunk>().toList();
        expect(chunks.map((c) => c.text).toList(),
            <String>['alpha', 'beta', 'gamma']);
        // Started + 3 Chunks + Completed.
        expect(events, hasLength(5));
      },
    );

    test('custom splitter shape: char-by-char', () async {
      final provider = StubLlmProvider(
        responder: (_, _) => 'abc',
        chunkSplitter: (response) => response.split(''),
      );
      final events = await provider
          .completeStream(
            const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
            const LlmOptions(),
          )
          .toList();

      final chunks = events.whereType<LlmStreamChunk>().toList();
      expect(chunks.map((c) => c.text).toList(), <String>['a', 'b', 'c']);
    });

    test('empty strings in splitter output are suppressed by the emitter',
        () async {
      final provider = StubLlmProvider(
        responder: (_, _) => 'kept',
        chunkSplitter: (response) => <String>['', response, ''],
      );
      final events = await provider
          .completeStream(
            const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
            const LlmOptions(),
          )
          .toList();

      final chunks = events.whereType<LlmStreamChunk>().toList();
      expect(chunks, hasLength(1));
      expect(chunks.single.text, 'kept');
    });
  });

  group('B.16 / StubLlmProvider.alwaysFails', () {
    test('complete re-throws the supplied cause', () async {
      final boom = StateError('boom');
      final provider = StubLlmProvider.alwaysFails(
        failure: LlmFailure(
          classCode: 'rate_limit',
          message: 'simulated 429',
          cause: boom,
        ),
      );
      await expectLater(
        provider.complete(
          const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
          const LlmOptions(),
        ),
        throwsA(same(boom)),
      );
    });

    test(
      'complete throws StateError(failure.message) when cause is null',
      () async {
        final provider = StubLlmProvider.alwaysFails(
          failure: const LlmFailure(
            classCode: 'auth',
            message: 'no key configured',
          ),
        );
        await expectLater(
          provider.complete(
            const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
            const LlmOptions(),
          ),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            'no key configured',
          )),
        );
      },
    );

    test('completeStream emits Started + Failed only — never Completed',
        () async {
      final provider = StubLlmProvider.alwaysFails(
        failure: const LlmFailure(
          classCode: 'overloaded',
          message: 'capacity gone',
        ),
      );
      final events = await provider
          .completeStream(
            const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
            const LlmOptions(),
          )
          .toList();

      expect(events, hasLength(2));
      expect(events.first, isA<LlmStreamStarted>());
      expect(events.last, isA<LlmStreamFailed>());
      expect(events.whereType<LlmStreamCompleted>(), isEmpty);
      expect(events.whereType<LlmStreamChunk>(), isEmpty);

      final failed = events.last as LlmStreamFailed;
      expect(failed.failure.classCode, 'overloaded');
      expect(failed.failure.message, 'capacity gone');
      // Report honours anchor + provenance + determinism.
      expect(failed.report.anchorHash, 'a');
      expect(failed.report.providerId, 'stub:fail');
      expect(failed.report.wallClockMs, 0);
      expect(failed.report.tokensOut, 0);
    });

    test('alwaysFails respects custom id and defaultModel', () async {
      final provider = StubLlmProvider.alwaysFails(
        id: 'stub:rate-limited',
        defaultModel: 'fakemodel-1',
        failure: const LlmFailure(
          classCode: 'rate_limit',
          message: 'simulated',
        ),
      );
      final events = await provider
          .completeStream(
            const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
            const LlmOptions(),
          )
          .toList();

      final started = events.first as LlmStreamStarted;
      expect(started.providerId, 'stub:rate-limited');
      expect(started.modelId, 'fakemodel-1');
    });
  });

  group('B.16 / barrel surface', () {
    test(
      'StubLlmProvider + typedefs reach the test through the top-level '
      'package barrel only (no `package:foo/src/...`)',
      () {
        // The single test-file import line is
        //   import 'package:tom_brain_substrate/tom_brain_substrate.dart';
        // — reaching every B.16-added symbol under that constraint is
        // the proof.
        expect(StubLlmProvider, isNotNull);
        // typedefs cannot be referenced as values; instead instantiate
        // a stub that uses one as a parameter type.
        StubResponder responder = StubLlmProvider.defaultEcho;
        StubChunkSplitter splitter = StubLlmProvider.singleChunk;
        final provider = StubLlmProvider(
          responder: responder,
          chunkSplitter: splitter,
        );
        expect(provider, isA<LlmProvider>());
      },
    );
  });
}

// ─── Helpers ──────────────────────────────────────────────────────

String _sha256Stamp(String body) {
  return 'sha256:${sha256.convert(utf8.encode(body))}';
}
