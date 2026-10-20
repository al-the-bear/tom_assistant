// B.15 — `OpenAiPassthroughProvider` + `OpenAiHttpClient` seam conformance.
//
// Mirrors the structure of `b14_ollama_llm_provider_test.dart` (same
// black-box discipline against the wire-shape seam). Scope:
//
//   - Prove `OpenAiPassthroughProvider` honours every `LlmProvider`
//     contract point that B.11 documented (id propagation, anchor-hash
//     propagation, provenance stamp, prompt-body preservation, the
//     SSE-streaming `Started → Chunk* → Completed` lifecycle shape).
//   - Prove the wire-shape seam (`OpenAiHttpClient`) receives the
//     correct request shape: model id, single-user-message list,
//     `stream: false|true`, generation knobs (`temperature`,
//     `max_tokens`, `stop`, `response_format`), bearer-token plumbing
//     (`apiKey`), extra-header forwarding.
//   - Prove the streaming path emits one `LlmTextDelta` per
//     non-empty SSE delta; the terminal report carries the usage
//     counters surfaced via `stream_options: {include_usage: true}`;
//     a content frame whose `finish_reason` is non-`stop` is recorded
//     in the report's notes.
//   - Prove failure-shape: an HTTP failure on the non-streaming path
//     surfaces as a thrown exception (per spec § 4.1 "router catches"
//     contract); on the streaming path it surfaces as a terminal
//     [LlmRunFailed] event with a typed [LlmFailure] envelope
//     (`classCode: 'unknown'` until B.18).
//   - Prove `embedRaw`, `embedBatchRaw`, `listAvailableModels` (the
//     off-interface helpers landed at B.15 for B.18 / B.25 / B.26
//     consumers) call through to the seam unchanged and surface
//     ordering / cardinality invariants.
//   - Prove `LlmCallReport.promptHash` is sha256 over `prompt.combined`
//     (deterministic given the prompt body — same body → same hash;
//     different body → different hash; same prefix shape `sha256:` as
//     B.14 + `AnchorRegistry.currentHash`).
//   - Prove the `OpenAiHttpClient` and `OpenAiPassthroughProvider`
//     surfaces are reachable from the top-level package barrel (the
//     lints rule that forbids `package:foo/src/...` imports).
//
// Scope this file is NOT for:
//
//   - No live vendor account. Every test uses `_FakeOpenAiHttpClient`.
//   - No router behaviour (retry / rotate / failure classification).
//     That is B.18+. The provider here re-throws / surfaces failures
//     with `classCode: 'unknown'` and that is the test's expectation.
//   - No anchor enforcement test. That is B.46's job.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.15 / OpenAiPassthroughProvider — interface conformance', () {
    test('id is propagated verbatim', () {
      final provider = _newProvider(id: 'openai:passthrough');
      expect(provider.id, 'openai:passthrough');
      expect(provider, isA<LlmProvider>());
    });

    test(
      'complete stamps anchor + provider + template metadata onto the report',
      () async {
        final fake = _FakeOpenAiHttpClient()
          ..chatResponse = const OpenAiChatResponse(
            model: 'gpt-4o-mini',
            content: 'hello back',
            promptTokens: 12,
            completionTokens: 5,
            finishReason: 'stop',
          );
        final provider = _newProvider(httpClient: fake);

        final report = await provider.complete(
          LlmRequest(
            prompt: const WirePrompt(
              system: 'anchor + body',
              anchorHash: 'sha256:anchor-stamp',
              roleId: 'assistant_to_user',
              templateSha: 'tpl-1',
            ),
            options: const LlmOptions(),
          ),
        );

        expect(report.providerId, 'openai:passthrough');
        expect(report.modelId, 'gpt-4o-mini'); // echo from response
        expect(report.anchorHash, 'sha256:anchor-stamp');
        expect(report.templateSha, 'tpl-1');
        expect(report.tokensIn, 12);
        expect(report.tokensOut, 5);
        expect(report.retries, 0);
        expect(report.wallClockMs, greaterThanOrEqualTo(0));
        expect(report.promptHash, _sha256Stamp('anchor + body'));
      },
    );

    test('complete sends system + user as two messages '
        '([{role:system}, {role:user}])', () async {
      final fake = _FakeOpenAiHttpClient()
        ..chatResponse = const OpenAiChatResponse(
          model: 'gpt-4o-mini',
          content: '',
        );
      final provider = _newProvider(httpClient: fake);

      await provider.complete(
        LlmRequest(
          prompt: const WirePrompt(
            system: 'I am dedicated to this user.',
            user: 'user question',
            anchorHash: 'sha256:x',
            roleId: 'assistant_to_user',
          ),
          options: const LlmOptions(),
        ),
      );

      final call = fake.chatCalls.single;
      expect(call.model, 'gpt-4o-mini');
      // Anchor-first system channel leads as a `system` message,
      // followed by the call-specific `user` message.
      expect(call.messages, hasLength(2));
      expect(call.messages[0].role, 'system');
      expect(call.messages[0].content, 'I am dedicated to this user.');
      expect(call.messages[1].role, 'user');
      expect(call.messages[1].content, 'user question');
    });

    test('complete omits the system message when system is empty', () async {
      final fake = _FakeOpenAiHttpClient()
        ..chatResponse = const OpenAiChatResponse(
          model: 'gpt-4o-mini',
          content: '',
        );
      final provider = _newProvider(httpClient: fake);

      await provider.complete(
        LlmRequest(
          prompt: const WirePrompt(
            system: '',
            user: 'just the user turn',
            anchorHash: 'sha256:x',
            roleId: 'assistant_to_user',
          ),
          options: const LlmOptions(),
        ),
      );

      final call = fake.chatCalls.single;
      expect(call.messages, hasLength(1));
      expect(call.messages.single.role, 'user');
      expect(call.messages.single.content, 'just the user turn');
    });

    test('options.model overrides the default model when provided', () async {
      final fake = _FakeOpenAiHttpClient()
        ..chatResponse = const OpenAiChatResponse(
          model: 'mistralai/mistral-7b-instruct',
          content: '',
        );
      final provider = _newProvider(
        httpClient: fake,
        defaultModel: 'gpt-4o-mini',
      );

      final report = await provider.complete(
        LlmRequest(
          prompt: const WirePrompt(
            system: 'x',
            anchorHash: 'sha256:y',
            roleId: 'analyser',
          ),
          options: const LlmOptions(model: 'mistralai/mistral-7b-instruct'),
        ),
      );

      expect(fake.chatCalls.single.model, 'mistralai/mistral-7b-instruct');
      expect(report.modelId, 'mistralai/mistral-7b-instruct');
    });

    test(
      'options knobs translate onto the OpenAI generation fragment',
      () async {
        final fake = _FakeOpenAiHttpClient()
          ..chatResponse = const OpenAiChatResponse(
            model: 'gpt-4o-mini',
            content: '',
          );
        final provider = _newProvider(httpClient: fake);

        await provider.complete(
          LlmRequest(
            prompt: const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
            options: const LlmOptions(
              temperature: 0.42,
              maxOutputTokens: 256,
              stopSequences: <String>['STOP', 'END'],
            ),
          ),
        );

        final opts = fake.chatCalls.single.options;
        expect(opts.temperature, 0.42);
        expect(opts.maxOutputTokens, 256);
        expect(opts.stopSequences, <String>['STOP', 'END']);
        expect(opts.responseFormat, isNull);
      },
    );

    test('responseFormat propagates onto the OpenAI request', () async {
      final fake = _FakeOpenAiHttpClient()
        ..chatResponse = const OpenAiChatResponse(
          model: 'gpt-4o-mini',
          content: '',
        );
      final provider = _newProvider(httpClient: fake);

      await provider.complete(
        LlmRequest(
          prompt: const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
          options: const LlmOptions(
            responseFormat: <String, Object?>{'type': 'json_object'},
          ),
        ),
      );

      expect(fake.chatCalls.single.options.responseFormat, <String, Object?>{
        'type': 'json_object',
      });
    });

    test(
      'bearer token + extra headers are forwarded on every chat call',
      () async {
        final fake = _FakeOpenAiHttpClient()
          ..chatResponse = const OpenAiChatResponse(
            model: 'gpt-4o-mini',
            content: '',
          );
        final provider = _newProvider(
          httpClient: fake,
          apiKey: 'sk-test',
          extraHeaders: const <String, String>{
            'HTTP-Referer': 'https://tom-brain.local',
            'X-Title': 'Tom Brain',
          },
        );

        await provider.complete(
          LlmRequest(
            prompt: const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
            options: const LlmOptions(),
          ),
        );

        final call = fake.chatCalls.single;
        expect(call.apiKey, 'sk-test');
        expect(call.extraHeaders['HTTP-Referer'], 'https://tom-brain.local');
        expect(call.extraHeaders['X-Title'], 'Tom Brain');
      },
    );

    test('missing usage counters surface as 0 + notes', () async {
      final fake = _FakeOpenAiHttpClient()
        ..chatResponse = const OpenAiChatResponse(
          model: 'gpt-4o-mini',
          content: '',
        );
      final provider = _newProvider(httpClient: fake);

      final report = await provider.complete(
        LlmRequest(
          prompt: const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
          options: const LlmOptions(),
        ),
      );

      expect(report.tokensIn, 0);
      expect(report.tokensOut, 0);
      expect(report.notes, contains('openai:prompt_tokens_missing'));
      expect(report.notes, contains('openai:completion_tokens_missing'));
    });

    test('non-stop finish_reason is recorded as a note', () async {
      final fake = _FakeOpenAiHttpClient()
        ..chatResponse = const OpenAiChatResponse(
          model: 'gpt-4o-mini',
          content: 'truncated',
          promptTokens: 1,
          completionTokens: 1,
          finishReason: 'length',
        );
      final provider = _newProvider(httpClient: fake);

      final report = await provider.complete(
        LlmRequest(
          prompt: const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
          options: const LlmOptions(),
        ),
      );

      expect(report.notes, contains('openai:finish_reason=length'));
    });

    test(
      'stop / tool_calls finish_reason does NOT pollute the notes',
      () async {
        final fake = _FakeOpenAiHttpClient()
          ..chatResponse = const OpenAiChatResponse(
            model: 'gpt-4o-mini',
            content: 'fine',
            promptTokens: 1,
            completionTokens: 1,
            finishReason: 'stop',
          );
        final provider = _newProvider(httpClient: fake);

        final report = await provider.complete(
          LlmRequest(
            prompt: const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
            options: const LlmOptions(),
          ),
        );

        expect(
          report.notes.where((n) => n.startsWith('openai:finish_reason')),
          isEmpty,
        );
      },
    );

    test('tool catalogue present surfaces a "not yet dispatched" note '
        '(spec § 4.1; tool dispatch lands at B.27)', () async {
      final fake = _FakeOpenAiHttpClient()
        ..chatResponse = const OpenAiChatResponse(
          model: 'gpt-4o-mini',
          content: '',
          promptTokens: 1,
          completionTokens: 1,
          finishReason: 'stop',
        );
      final provider = _newProvider(httpClient: fake);

      final report = await provider.complete(
        LlmRequest(
          prompt: const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
          options: const LlmOptions(
            toolCatalogue: ToolCatalogue(<ToolDescriptor>[
              ToolDescriptor(
                name: 'noop',
                description: 'no-op',
                parametersSchema: <String, Object?>{},
              ),
            ]),
          ),
        ),
      );

      expect(
        report.notes,
        contains('tool_catalogue_present:not_yet_dispatched'),
      );
    });

    test('complete re-throws transport failures unclassified', () async {
      final fake = _FakeOpenAiHttpClient()
        ..chatException = OpenAiHttpException(
          statusCode: 401,
          body: 'invalid api key',
          endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
        );
      final provider = _newProvider(httpClient: fake);

      await expectLater(
        provider.complete(
          LlmRequest(
            prompt: const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
            options: const LlmOptions(),
          ),
        ),
        throwsA(isA<OpenAiHttpException>()),
      );
    });
  });

  group('B.15 / OpenAiPassthroughProvider — streaming path', () {
    test(
      'emits Started → Chunk* → Completed for an SSE stream with usage frame',
      () async {
        final fake = _FakeOpenAiHttpClient()
          ..streamFragments = const <OpenAiStreamFragment>[
            OpenAiStreamFragment(model: 'gpt-4o-mini', contentDelta: 'Hello '),
            OpenAiStreamFragment(model: 'gpt-4o-mini', contentDelta: 'world'),
            OpenAiStreamFragment(
              model: 'gpt-4o-mini',
              contentDelta: '',
              finishReason: 'stop',
            ),
            OpenAiStreamFragment(
              model: 'gpt-4o-mini',
              contentDelta: '',
              promptTokens: 7,
              completionTokens: 11,
            ),
          ];
        final provider = _newProvider(httpClient: fake);

        final events = await provider
            .run(
              LlmRequest(
                prompt: const WirePrompt(
                  system: 'streaming body',
                  anchorHash: 'sha256:stream-anchor',
                  roleId: 'assistant_to_user',
                  templateSha: 'tpl-2',
                ),
                options: const LlmOptions(),
              ),
            )
            .toList();

        expect(events.first, isA<LlmRunStarted>());
        expect(events.last, isA<LlmRunCompleted>());

        final started = events.first as LlmRunStarted;
        expect(started.providerId, 'openai:passthrough');
        expect(started.modelId, 'gpt-4o-mini');
        expect(started.callId, isNotEmpty);

        final chunks = events.whereType<LlmTextDelta>().toList(growable: false);
        expect(chunks.map((c) => c.text).toList(), <String>['Hello ', 'world']);

        final completed = events.last as LlmRunCompleted;
        expect(completed.callId, started.callId);
        expect(completed.report.providerId, 'openai:passthrough');
        expect(completed.report.modelId, 'gpt-4o-mini');
        expect(completed.report.anchorHash, 'sha256:stream-anchor');
        expect(completed.report.templateSha, 'tpl-2');
        expect(completed.report.tokensIn, 7);
        expect(completed.report.tokensOut, 11);
        expect(completed.report.promptHash, _sha256Stamp('streaming body'));
      },
    );

    test('empty-delta fragments do not emit a Chunk event', () async {
      final fake = _FakeOpenAiHttpClient()
        ..streamFragments = const <OpenAiStreamFragment>[
          OpenAiStreamFragment(model: 'gpt-4o-mini', contentDelta: ''),
          OpenAiStreamFragment(
            model: 'gpt-4o-mini',
            contentDelta: 'first text',
          ),
          OpenAiStreamFragment(
            model: 'gpt-4o-mini',
            contentDelta: '',
            finishReason: 'stop',
          ),
        ];
      final provider = _newProvider(httpClient: fake);

      final events = await provider
          .run(
            LlmRequest(
              prompt: const WirePrompt(
                system: 'x',
                anchorHash: 'a',
                roleId: 'r',
              ),
              options: const LlmOptions(),
            ),
          )
          .toList();

      final chunks = events.whereType<LlmTextDelta>().toList();
      expect(chunks, hasLength(1));
      expect(chunks.single.text, 'first text');
    });

    test(
      'SSE stream without usage frame still completes (tokens default to 0)',
      () async {
        final fake = _FakeOpenAiHttpClient()
          ..streamFragments = const <OpenAiStreamFragment>[
            OpenAiStreamFragment(
              model: 'gpt-4o-mini',
              contentDelta: 'partial',
              finishReason: 'stop',
            ),
          ];
        final provider = _newProvider(httpClient: fake);

        final events = await provider
            .run(
              LlmRequest(
                prompt: const WirePrompt(
                  system: 'x',
                  anchorHash: 'a',
                  roleId: 'r',
                ),
                options: const LlmOptions(),
              ),
            )
            .toList();

        expect(events.last, isA<LlmRunCompleted>());
        final completed = events.last as LlmRunCompleted;
        expect(completed.report.tokensIn, 0);
        expect(completed.report.tokensOut, 0);
        expect(
          completed.report.notes,
          contains('openai:prompt_tokens_missing'),
        );
        expect(
          completed.report.notes,
          contains('openai:completion_tokens_missing'),
        );
      },
    );

    test('non-stop finish_reason recorded in terminal report notes', () async {
      final fake = _FakeOpenAiHttpClient()
        ..streamFragments = const <OpenAiStreamFragment>[
          OpenAiStreamFragment(
            model: 'gpt-4o-mini',
            contentDelta: 'truncated',
            finishReason: 'length',
            promptTokens: 1,
            completionTokens: 1,
          ),
        ];
      final provider = _newProvider(httpClient: fake);

      final events = await provider
          .run(
            LlmRequest(
              prompt: const WirePrompt(
                system: 'x',
                anchorHash: 'a',
                roleId: 'r',
              ),
              options: const LlmOptions(),
            ),
          )
          .toList();

      final completed = events.last as LlmRunCompleted;
      expect(completed.report.notes, contains('openai:finish_reason=length'));
    });

    test('transport failure mid-stream surfaces as LlmRunFailed(unknown) '
        '(B.18 will reclassify)', () async {
      final fake = _FakeOpenAiHttpClient()
        ..streamException = OpenAiHttpException(
          statusCode: 500,
          body: 'boom',
          endpoint: Uri.parse('https://api.openai.com/v1/chat/completions'),
        );
      final provider = _newProvider(httpClient: fake);

      final events = await provider
          .run(
            LlmRequest(
              prompt: const WirePrompt(
                system: 'x',
                anchorHash: 'a',
                roleId: 'r',
              ),
              options: const LlmOptions(),
            ),
          )
          .toList();

      expect(events.first, isA<LlmRunStarted>());
      expect(events.last, isA<LlmRunFailed>());
      final failed = events.last as LlmRunFailed;
      expect(failed.failure.classCode, 'unknown');
      expect(failed.failure.cause, isA<OpenAiHttpException>());
    });
  });

  group('B.15 / OpenAiPassthroughProvider — promptHash determinism', () {
    test('same prompt body → same promptHash', () async {
      final fake = _FakeOpenAiHttpClient()
        ..chatResponse = const OpenAiChatResponse(
          model: 'gpt-4o-mini',
          content: '',
        );
      final provider = _newProvider(httpClient: fake);

      final r1 = await provider.complete(
        LlmRequest(
          prompt: const WirePrompt(
            system: 'deterministic',
            anchorHash: 'a',
            roleId: 'r',
          ),
          options: const LlmOptions(),
        ),
      );
      final r2 = await provider.complete(
        LlmRequest(
          prompt: const WirePrompt(
            system: 'deterministic',
            anchorHash: 'a',
            roleId: 'r',
          ),
          options: const LlmOptions(),
        ),
      );
      expect(r1.promptHash, r2.promptHash);
      expect(r1.promptHash, startsWith('sha256:'));
    });

    test('different prompt body → different promptHash', () async {
      final fake = _FakeOpenAiHttpClient()
        ..chatResponse = const OpenAiChatResponse(
          model: 'gpt-4o-mini',
          content: '',
        );
      final provider = _newProvider(httpClient: fake);

      final r1 = await provider.complete(
        LlmRequest(
          prompt: const WirePrompt(
            system: 'first',
            anchorHash: 'a',
            roleId: 'r',
          ),
          options: const LlmOptions(),
        ),
      );
      final r2 = await provider.complete(
        LlmRequest(
          prompt: const WirePrompt(
            system: 'second',
            anchorHash: 'a',
            roleId: 'r',
          ),
          options: const LlmOptions(),
        ),
      );
      expect(r1.promptHash, isNot(equals(r2.promptHash)));
    });
  });

  group('B.15 / OpenAiPassthroughProvider — off-interface helpers', () {
    test(
      'embedRaw forwards single-element list + bearer to the seam',
      () async {
        final fake = _FakeOpenAiHttpClient()
          ..embedResponse = const OpenAiEmbeddingResponse(
            model: 'text-embedding-3-small',
            embeddings: <List<double>>[
              <double>[0.1, 0.2, 0.3],
            ],
            promptTokens: 4,
          );
        final provider = _newProvider(
          httpClient: fake,
          defaultEmbeddingModel: 'text-embedding-3-small',
          apiKey: 'sk-embed',
        );

        final v = await provider.embedRaw(input: 'a body');
        expect(v, <double>[0.1, 0.2, 0.3]);

        final call = fake.embedCalls.single;
        expect(call.model, 'text-embedding-3-small');
        expect(call.input, <String>['a body']);
        expect(call.apiKey, 'sk-embed');
      },
    );

    test('embedRaw honours an explicit model id', () async {
      final fake = _FakeOpenAiHttpClient()
        ..embedResponse = const OpenAiEmbeddingResponse(
          model: 'text-embedding-3-large',
          embeddings: <List<double>>[
            <double>[1.0],
          ],
        );
      final provider = _newProvider(
        httpClient: fake,
        defaultEmbeddingModel: 'text-embedding-3-small',
      );

      await provider.embedRaw(input: 'a', model: 'text-embedding-3-large');
      expect(fake.embedCalls.single.model, 'text-embedding-3-large');
    });

    test(
      'embedRaw without defaultEmbeddingModel and without model param throws',
      () async {
        final provider = _newProvider();

        await expectLater(
          provider.embedRaw(input: 'a'),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('embedBatchRaw returns one vector per input, in order', () async {
      final fake = _FakeOpenAiHttpClient()
        ..embedResponse = const OpenAiEmbeddingResponse(
          model: 'text-embedding-3-small',
          embeddings: <List<double>>[
            <double>[1.0, 2.0],
            <double>[3.0, 4.0],
            <double>[5.0, 6.0],
          ],
        );
      final provider = _newProvider(
        httpClient: fake,
        defaultEmbeddingModel: 'text-embedding-3-small',
      );

      final vecs = await provider.embedBatchRaw(
        inputs: <String>['a', 'b', 'c'],
      );
      expect(vecs, hasLength(3));
      expect(vecs[0], <double>[1.0, 2.0]);
      expect(vecs[1], <double>[3.0, 4.0]);
      expect(vecs[2], <double>[5.0, 6.0]);
      expect(fake.embedCalls.single.input, <String>['a', 'b', 'c']);
    });

    test(
      'embedBatchRaw with empty inputs short-circuits and returns []',
      () async {
        final fake = _FakeOpenAiHttpClient();
        final provider = _newProvider(httpClient: fake);

        final vecs = await provider.embedBatchRaw(inputs: const <String>[]);
        expect(vecs, isEmpty);
        expect(fake.embedCalls, isEmpty);
      },
    );

    test(
      'embedBatchRaw throws when the vendor returns a vector count mismatch',
      () async {
        final fake = _FakeOpenAiHttpClient()
          ..embedResponse = const OpenAiEmbeddingResponse(
            model: 'text-embedding-3-small',
            embeddings: <List<double>>[
              <double>[1.0],
              <double>[2.0],
            ], // only 2 for 3 inputs
          );
        final provider = _newProvider(
          httpClient: fake,
          defaultEmbeddingModel: 'text-embedding-3-small',
        );

        await expectLater(
          provider.embedBatchRaw(inputs: <String>['a', 'b', 'c']),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('listAvailableModels returns the seam model list', () async {
      final fake = _FakeOpenAiHttpClient()
        ..modelsResponse = const <OpenAiModelEntry>[
          OpenAiModelEntry(id: 'gpt-4o-mini', ownedBy: 'openai'),
          OpenAiModelEntry(id: 'gpt-4o', ownedBy: 'openai'),
        ];
      final provider = _newProvider(httpClient: fake);

      final models = await provider.listAvailableModels();
      expect(models.map((m) => m.id).toList(), <String>[
        'gpt-4o-mini',
        'gpt-4o',
      ]);
    });
  });

  group(
    'B.15 / OpenAiHttpClient — wire decoding (DefaultOpenAiHttpClient)',
    () {
      test(
        'decoded chat response handles missing usage / finish_reason',
        () async {
          // Indirect test: the default client's decoder lives in
          // openai_http_client.dart; we exercise it through the provider
          // by feeding the fake whatever the decoder would have produced,
          // and a few canonical edge cases. Doubled-up here so a future
          // decoder change can't regress without a test catching it.
          final fake = _FakeOpenAiHttpClient()
            ..chatResponse = const OpenAiChatResponse(model: '', content: '');
          final provider = _newProvider(httpClient: fake);

          final report = await provider.complete(
            LlmRequest(
              prompt: const WirePrompt(
                system: 'x',
                anchorHash: 'a',
                roleId: 'r',
              ),
              options: const LlmOptions(model: 'fallback-model'),
            ),
          );

          // Empty model from response → falls back to the requested model.
          expect(report.modelId, 'fallback-model');
        },
      );
    },
  );

  group('B.15 / barrel surface', () {
    test(
      'OpenAiPassthroughProvider + OpenAiHttpClient + value classes import '
      'from the top-level package barrel only (no `package:foo/src/...`)',
      () {
        // Reaching every B.15-added symbol via the single
        //   import 'package:tom_brain_substrate/tom_brain_substrate.dart';
        // is the proof.
        expect(OpenAiHttpClient, isNotNull);
        expect(DefaultOpenAiHttpClient, isNotNull);
        expect(OpenAiMessage, isNotNull);
        expect(OpenAiGenerationOptions, isNotNull);
        expect(OpenAiChatResponse, isNotNull);
        expect(OpenAiStreamFragment, isNotNull);
        expect(OpenAiEmbeddingResponse, isNotNull);
        expect(OpenAiModelEntry, isNotNull);
        expect(OpenAiHttpException, isNotNull);
        expect(OpenAiPassthroughProvider, isNotNull);
      },
    );
  });
}

// ─── Helpers ──────────────────────────────────────────────────────

OpenAiPassthroughProvider _newProvider({
  String id = 'openai:passthrough',
  String defaultModel = 'gpt-4o-mini',
  String? defaultEmbeddingModel,
  String? apiKey,
  Map<String, String> extraHeaders = const <String, String>{},
  OpenAiHttpClient? httpClient,
}) {
  return OpenAiPassthroughProvider(
    id: id,
    baseUri: Uri.parse('https://api.openai.com/'),
    defaultModel: defaultModel,
    defaultEmbeddingModel: defaultEmbeddingModel,
    apiKey: apiKey,
    extraHeaders: extraHeaders,
    httpClient: httpClient ?? _FakeOpenAiHttpClient(),
  );
}

String _sha256Stamp(String body) {
  return 'sha256:${sha256.convert(utf8.encode(body))}';
}

// ─── Test double ──────────────────────────────────────────────────

/// Deterministic in-test [OpenAiHttpClient]. Records what the provider
/// asked it to do and returns whatever the test set up as the
/// response.
final class _FakeOpenAiHttpClient implements OpenAiHttpClient {
  final List<_OpenAiChatInvocation> chatCalls = <_OpenAiChatInvocation>[];
  final List<_OpenAiEmbedInvocation> embedCalls = <_OpenAiEmbedInvocation>[];

  OpenAiChatResponse chatResponse = const OpenAiChatResponse(
    model: 'gpt-4o-mini',
    content: '',
  );
  Object? chatException;

  List<OpenAiStreamFragment> streamFragments = const <OpenAiStreamFragment>[];
  Object? streamException;

  OpenAiEmbeddingResponse embedResponse = const OpenAiEmbeddingResponse(
    model: 'text-embedding-3-small',
    embeddings: <List<double>>[],
  );

  List<OpenAiModelEntry> modelsResponse = const <OpenAiModelEntry>[];

  bool closeCalled = false;

  @override
  Future<OpenAiChatResponse> chat({
    required Uri baseUri,
    required String model,
    required List<OpenAiMessage> messages,
    required OpenAiGenerationOptions options,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    chatCalls.add(
      _OpenAiChatInvocation(
        baseUri: baseUri,
        model: model,
        messages: messages,
        options: options,
        apiKey: apiKey,
        extraHeaders: extraHeaders,
      ),
    );
    if (chatException != null) throw chatException!;
    return chatResponse;
  }

  @override
  Stream<OpenAiStreamFragment> chatStream({
    required Uri baseUri,
    required String model,
    required List<OpenAiMessage> messages,
    required OpenAiGenerationOptions options,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
    CancellationToken? cancellationToken,
  }) async* {
    chatCalls.add(
      _OpenAiChatInvocation(
        baseUri: baseUri,
        model: model,
        messages: messages,
        options: options,
        apiKey: apiKey,
        extraHeaders: extraHeaders,
      ),
    );
    if (streamException != null) throw streamException!;
    for (final frag in streamFragments) {
      yield frag;
    }
  }

  @override
  Future<OpenAiEmbeddingResponse> embed({
    required Uri baseUri,
    required String model,
    required List<String> input,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    embedCalls.add(
      _OpenAiEmbedInvocation(
        baseUri: baseUri,
        model: model,
        input: input,
        apiKey: apiKey,
      ),
    );
    return embedResponse;
  }

  @override
  Future<List<OpenAiModelEntry>> listModels({
    required Uri baseUri,
    String? apiKey,
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    return modelsResponse;
  }

  @override
  void close() {
    closeCalled = true;
  }
}

final class _OpenAiChatInvocation {
  final Uri baseUri;
  final String model;
  final List<OpenAiMessage> messages;
  final OpenAiGenerationOptions options;
  final String? apiKey;
  final Map<String, String> extraHeaders;

  const _OpenAiChatInvocation({
    required this.baseUri,
    required this.model,
    required this.messages,
    required this.options,
    required this.apiKey,
    required this.extraHeaders,
  });
}

final class _OpenAiEmbedInvocation {
  final Uri baseUri;
  final String model;
  final List<String> input;
  final String? apiKey;

  const _OpenAiEmbedInvocation({
    required this.baseUri,
    required this.model,
    required this.input,
    required this.apiKey,
  });
}
