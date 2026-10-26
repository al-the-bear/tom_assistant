// Plan-2 item 10 — `AnthropicLlmProvider` + `AnthropicHttpClient` seam.
//
// Mirrors the structure of `b15_openai_passthrough_provider_test.dart`
// (same black-box discipline against the wire-shape seam) for the
// Anthropic Messages API (`POST /v1/messages`, `x-api-key`,
// `anthropic-version`). Scope:
//
//   - Prove `AnthropicLlmProvider` honours every `LlmProvider` contract
//     point (id propagation, anchor-hash propagation, provenance stamp,
//     prompt-body preservation, the SSE-streaming `Started → Chunk* →
//     Completed` lifecycle shape).
//   - Prove the wire-shape seam (`AnthropicHttpClient`) receives the
//     correct request shape: model id, single-user-message list,
//     `max_tokens` (REQUIRED by the Messages API), generation knobs
//     (`temperature`, `stop_sequences`), `x-api-key` plumbing, the
//     `anthropic-version` header, extra-header forwarding.
//   - Prove the streaming path concatenates `content_block_delta`
//     text-deltas into one `LlmTextDelta` per non-empty delta and
//     stamps the `message_start` / `message_delta` usage counters onto
//     the terminal report.
//   - Prove failure-shape: an HTTP failure on the non-streaming path
//     surfaces as a thrown exception (router-catches contract); on the
//     streaming path it surfaces as a terminal [LlmRunFailed] with a
//     [LlmFailure] envelope (`classCode: 'unknown'`).
//   - Prove the router's failover taxonomy classifies an
//     `AnthropicHttpException` identically to the other wire families —
//     the 11-class mapping (`rate_limit`, `overloaded`, `auth`, …) is
//     driven purely off the HTTP status + body, so the Anthropic
//     exception "registers" in the taxonomy by being a
//     `WireHttpException` subtype.
//   - Prove the `DefaultAnthropicHttpClient` wire layer builds the
//     `x-api-key` + `anthropic-version` headers and decodes the
//     Messages API non-streaming + SSE shapes (via an injected
//     `MockClient`, no network).
//
// Scope this file is NOT for:
//
//   - No live Anthropic account. Every provider test uses
//     `_FakeAnthropicHttpClient`; the wire-layer tests use `MockClient`.
//   - No router behaviour (retry / rotate). The provider re-throws /
//     surfaces failures with `classCode: 'unknown'`; the classifier
//     test only asserts the *mapping*, not the routing action.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tom_basics/utilities.dart' show TomCancellationToken;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('P2.10 / AnthropicLlmProvider — interface conformance', () {
    test('id is propagated verbatim', () {
      final provider = _newProvider(id: 'anthropic:claude');
      expect(provider.id, 'anthropic:claude');
      expect(provider, isA<LlmProvider>());
    });

    test('callIdPrefix is "anthropic"', () {
      final provider = _newProvider();
      expect(provider.callIdPrefix, 'anthropic');
    });

    test(
      'complete stamps anchor + provider + template metadata onto report',
      () async {
        final fake = _FakeAnthropicHttpClient()
          ..messageResponse = const AnthropicChatResponse(
            model: 'claude-sonnet-4-20250514',
            content: 'hello back',
            inputTokens: 12,
            outputTokens: 5,
            stopReason: 'end_turn',
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

        expect(report.providerId, 'anthropic:passthrough');
        expect(report.modelId, 'claude-sonnet-4-20250514');
        expect(report.anchorHash, 'sha256:anchor-stamp');
        expect(report.templateSha, 'tpl-1');
        expect(report.tokensIn, 12);
        expect(report.tokensOut, 5);
        expect(report.retries, 0);
        expect(report.wallClockMs, greaterThanOrEqualTo(0));
        expect(report.promptHash, _sha256Stamp('anchor + body'));
      },
    );

    test('complete routes system to the top-level system field and user to the '
        'single user message', () async {
      final fake = _FakeAnthropicHttpClient()
        ..messageResponse = const AnthropicChatResponse(
          model: 'claude-sonnet-4-20250514',
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

      final call = fake.messageCalls.single;
      expect(call.model, 'claude-sonnet-4-20250514');
      // The anchor-first standing framing rides the Messages API
      // top-level `system` field, NOT a conversation message.
      expect(call.system, 'I am dedicated to this user.');
      // Only the call-specific user content becomes a `user` message.
      expect(call.messages, hasLength(1));
      expect(call.messages.single.role, 'user');
      expect(call.messages.single.content, 'user question');
    });

    test('options.model overrides the default model when provided', () async {
      final fake = _FakeAnthropicHttpClient()
        ..messageResponse = const AnthropicChatResponse(
          model: 'claude-opus-4-20250514',
          content: '',
        );
      final provider = _newProvider(
        httpClient: fake,
        defaultModel: 'claude-sonnet-4-20250514',
      );

      final report = await provider.complete(
        LlmRequest(
          prompt: const WirePrompt(
            system: 'x',
            anchorHash: 'sha256:y',
            roleId: 'analyser',
          ),
          options: const LlmOptions(model: 'claude-opus-4-20250514'),
        ),
      );

      expect(fake.messageCalls.single.model, 'claude-opus-4-20250514');
      expect(report.modelId, 'claude-opus-4-20250514');
    });

    test('max_tokens defaults to the provider default when unset', () async {
      final fake = _FakeAnthropicHttpClient()
        ..messageResponse = const AnthropicChatResponse(
          model: 'm',
          content: '',
        );
      final provider = _newProvider(
        httpClient: fake,
        defaultMaxOutputTokens: 2048,
      );

      await provider.complete(
        LlmRequest(
          prompt: const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
          options: const LlmOptions(),
        ),
      );

      // Messages API REQUIRES max_tokens; the provider supplies its
      // configured default when LlmOptions carries none.
      expect(fake.messageCalls.single.options.maxOutputTokens, 2048);
    });

    test(
      'options knobs translate onto the Anthropic generation fragment',
      () async {
        final fake = _FakeAnthropicHttpClient()
          ..messageResponse = const AnthropicChatResponse(
            model: 'm',
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

        final opts = fake.messageCalls.single.options;
        expect(opts.temperature, 0.42);
        expect(opts.maxOutputTokens, 256);
        expect(opts.stopSequences, <String>['STOP', 'END']);
      },
    );

    test(
      'x-api-key, anthropic-version + extra headers are forwarded',
      () async {
        final fake = _FakeAnthropicHttpClient()
          ..messageResponse = const AnthropicChatResponse(
            model: 'm',
            content: '',
          );
        final provider = _newProvider(
          httpClient: fake,
          apiKey: 'sk-ant-test',
          anthropicVersion: '2023-06-01',
          extraHeaders: const <String, String>{'anthropic-beta': 'x'},
        );

        await provider.complete(
          LlmRequest(
            prompt: const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
            options: const LlmOptions(),
          ),
        );

        final call = fake.messageCalls.single;
        expect(call.apiKey, 'sk-ant-test');
        expect(call.anthropicVersion, '2023-06-01');
        expect(call.extraHeaders['anthropic-beta'], 'x');
      },
    );

    test('missing usage counters surface as 0 + notes', () async {
      final fake = _FakeAnthropicHttpClient()
        ..messageResponse = const AnthropicChatResponse(
          model: 'm',
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
      expect(report.notes, contains('anthropic:input_tokens_missing'));
      expect(report.notes, contains('anthropic:output_tokens_missing'));
    });

    test('non-end_turn stop_reason is recorded as a note', () async {
      final fake = _FakeAnthropicHttpClient()
        ..messageResponse = const AnthropicChatResponse(
          model: 'm',
          content: 'truncated',
          inputTokens: 1,
          outputTokens: 1,
          stopReason: 'max_tokens',
        );
      final provider = _newProvider(httpClient: fake);

      final report = await provider.complete(
        LlmRequest(
          prompt: const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
          options: const LlmOptions(),
        ),
      );

      expect(report.notes, contains('anthropic:stop_reason=max_tokens'));
    });

    test(
      'end_turn / tool_use stop_reason does NOT pollute the notes',
      () async {
        final fake = _FakeAnthropicHttpClient()
          ..messageResponse = const AnthropicChatResponse(
            model: 'm',
            content: 'fine',
            inputTokens: 1,
            outputTokens: 1,
            stopReason: 'end_turn',
          );
        final provider = _newProvider(httpClient: fake);

        final report = await provider.complete(
          LlmRequest(
            prompt: const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
            options: const LlmOptions(),
          ),
        );

        expect(
          report.notes.where((n) => n.startsWith('anthropic:stop_reason')),
          isEmpty,
        );
      },
    );

    test(
      'responseFormat surfaces an unsupported note (no Messages field)',
      () async {
        final fake = _FakeAnthropicHttpClient()
          ..messageResponse = const AnthropicChatResponse(
            model: 'm',
            content: '',
            inputTokens: 1,
            outputTokens: 1,
            stopReason: 'end_turn',
          );
        final provider = _newProvider(httpClient: fake);

        final report = await provider.complete(
          LlmRequest(
            prompt: const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
            options: const LlmOptions(
              responseFormat: <String, Object?>{'type': 'json_object'},
            ),
          ),
        );

        expect(report.notes, contains('anthropic:response_format_unsupported'));
      },
    );

    test('complete re-throws transport failures unclassified', () async {
      final fake = _FakeAnthropicHttpClient()
        ..messageException = AnthropicHttpException(
          statusCode: 401,
          body: 'invalid api key',
          endpoint: Uri.parse('https://api.anthropic.com/v1/messages'),
        );
      final provider = _newProvider(httpClient: fake);

      await expectLater(
        provider.complete(
          LlmRequest(
            prompt: const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
            options: const LlmOptions(),
          ),
        ),
        throwsA(isA<AnthropicHttpException>()),
      );
    });
  });

  group('P2.10 / AnthropicLlmProvider — streaming path', () {
    test('emits Started → Chunk* → Completed with usage frame', () async {
      final fake = _FakeAnthropicHttpClient()
        ..streamFragments = const <AnthropicStreamFragment>[
          AnthropicStreamFragment(
            model: 'claude-sonnet-4-20250514',
            inputTokens: 7,
          ),
          AnthropicStreamFragment(textDelta: 'Hello '),
          AnthropicStreamFragment(textDelta: 'world'),
          AnthropicStreamFragment(outputTokens: 11, stopReason: 'end_turn'),
        ];
      final provider = _newProvider(httpClient: fake);

      final events = await provider
          .run(
            LlmRequest(
              prompt: const WirePrompt(
                system: 'streaming body',
                user: 'stream question',
                anchorHash: 'sha256:stream-anchor',
                roleId: 'assistant_to_user',
                templateSha: 'tpl-2',
              ),
              options: const LlmOptions(),
            ),
          )
          .toList();

      // The streaming path routes channels exactly like the
      // non-streaming path: system → top-level field, user → message.
      final streamCall = fake.messageCalls.single;
      expect(streamCall.system, 'streaming body');
      expect(streamCall.messages.single.role, 'user');
      expect(streamCall.messages.single.content, 'stream question');

      expect(events.first, isA<LlmRunStarted>());
      expect(events.last, isA<LlmRunCompleted>());

      final started = events.first as LlmRunStarted;
      expect(started.providerId, 'anthropic:passthrough');
      expect(started.modelId, 'claude-sonnet-4-20250514');
      expect(started.callId, isNotEmpty);

      final chunks = events.whereType<LlmTextDelta>().toList(growable: false);
      expect(chunks.map((c) => c.text).toList(), <String>['Hello ', 'world']);

      final completed = events.last as LlmRunCompleted;
      expect(completed.callId, started.callId);
      expect(completed.report.providerId, 'anthropic:passthrough');
      expect(completed.report.modelId, 'claude-sonnet-4-20250514');
      expect(completed.report.anchorHash, 'sha256:stream-anchor');
      expect(completed.report.templateSha, 'tpl-2');
      expect(completed.report.tokensIn, 7);
      expect(completed.report.tokensOut, 11);
      // promptHash is over WirePrompt.combined (system + "\n\n" + user).
      expect(
        completed.report.promptHash,
        _sha256Stamp('streaming body\n\nstream question'),
      );
    });

    test('empty-delta fragments do not emit a Chunk event', () async {
      final fake = _FakeAnthropicHttpClient()
        ..streamFragments = const <AnthropicStreamFragment>[
          AnthropicStreamFragment(model: 'm', inputTokens: 1),
          AnthropicStreamFragment(textDelta: ''),
          AnthropicStreamFragment(textDelta: 'first text'),
          AnthropicStreamFragment(outputTokens: 1, stopReason: 'end_turn'),
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
      'stream without usage frame still completes (tokens default to 0)',
      () async {
        final fake = _FakeAnthropicHttpClient()
          ..streamFragments = const <AnthropicStreamFragment>[
            AnthropicStreamFragment(model: 'm'),
            AnthropicStreamFragment(textDelta: 'partial'),
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
          contains('anthropic:input_tokens_missing'),
        );
        expect(
          completed.report.notes,
          contains('anthropic:output_tokens_missing'),
        );
      },
    );

    test(
      'non-end_turn stop_reason recorded in terminal report notes',
      () async {
        final fake = _FakeAnthropicHttpClient()
          ..streamFragments = const <AnthropicStreamFragment>[
            AnthropicStreamFragment(model: 'm', inputTokens: 1),
            AnthropicStreamFragment(textDelta: 'truncated'),
            AnthropicStreamFragment(outputTokens: 1, stopReason: 'max_tokens'),
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
        expect(
          completed.report.notes,
          contains('anthropic:stop_reason=max_tokens'),
        );
      },
    );

    test(
      'transport failure mid-stream surfaces as LlmRunFailed(unknown)',
      () async {
        final fake = _FakeAnthropicHttpClient()
          ..streamException = AnthropicHttpException(
            statusCode: 529,
            body: 'overloaded',
            endpoint: Uri.parse('https://api.anthropic.com/v1/messages'),
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
        expect(failed.failure.cause, isA<AnthropicHttpException>());
      },
    );
  });

  group('P2.10 / AnthropicLlmProvider — promptHash determinism', () {
    test('same prompt body → same promptHash', () async {
      final fake = _FakeAnthropicHttpClient()
        ..messageResponse = const AnthropicChatResponse(
          model: 'm',
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
      final fake = _FakeAnthropicHttpClient()
        ..messageResponse = const AnthropicChatResponse(
          model: 'm',
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

  group(
    'P2.10 / failover taxonomy — AnthropicHttpException classification',
    () {
      // The plan's "register it in the router's failover taxonomy" is
      // realised by `AnthropicHttpException` being a `WireHttpException`
      // subtype, which the centralised `LlmFailureClassifier` matches on
      // status + body. This drives all 11 status/exception-derived classes.
      const classifier = LlmFailureClassifier.shared;

      AnthropicHttpException ex(int status, [String body = '']) =>
          AnthropicHttpException(
            statusCode: status,
            body: body,
            endpoint: Uri.parse('https://api.anthropic.com/v1/messages'),
          );

      test('429 → rate_limit', () {
        expect(classifier.classify(ex(429)), LlmFailureClass.rateLimit);
      });
      test('503 → overloaded', () {
        expect(classifier.classify(ex(503)), LlmFailureClass.overloaded);
      });
      test('529 (Anthropic overloaded) → overloaded', () {
        expect(classifier.classify(ex(529)), LlmFailureClass.overloaded);
      });
      test('500 → overloaded', () {
        expect(classifier.classify(ex(500)), LlmFailureClass.overloaded);
      });
      test('402 → billing', () {
        expect(classifier.classify(ex(402)), LlmFailureClass.billing);
      });
      test('401 → auth', () {
        expect(classifier.classify(ex(401)), LlmFailureClass.auth);
      });
      test('403 → auth_permanent', () {
        expect(classifier.classify(ex(403)), LlmFailureClass.authPermanent);
      });
      test('404 → model_not_found', () {
        expect(classifier.classify(ex(404)), LlmFailureClass.modelNotFound);
      });
      test('408 → timeout', () {
        expect(classifier.classify(ex(408)), LlmFailureClass.timeout);
      });
      test('413 → context_overflow', () {
        expect(classifier.classify(ex(413)), LlmFailureClass.contextOverflow);
      });
      test('400 + context body → context_overflow', () {
        expect(
          classifier.classify(ex(400, 'maximum context length exceeded')),
          LlmFailureClass.contextOverflow,
        );
      });
      test('400 + format body → format', () {
        expect(
          classifier.classify(ex(400, 'invalid json in request')),
          LlmFailureClass.format,
        );
      });
      test('400 + unrecognised body → unknown', () {
        expect(
          classifier.classify(ex(400, 'something else')),
          LlmFailureClass.unknown,
        );
      });

      test(
        'wrap produces the resolved classCode for an Anthropic exception',
        () {
          final failure = classifier.wrap(ex(429));
          expect(failure.classCode, 'rate_limit');
          expect(failure.cause, isA<AnthropicHttpException>());
        },
      );
    },
  );

  group('P2.10 / DefaultAnthropicHttpClient — wire layer (MockClient)', () {
    test(
      'non-streaming: x-api-key + anthropic-version headers, body, decode',
      () async {
        late http.Request captured;
        final client = DefaultAnthropicHttpClient(
          client: MockClient((req) async {
            captured = req;
            return http.Response(
              jsonEncode(<String, Object?>{
                'id': 'msg_1',
                'type': 'message',
                'role': 'assistant',
                'model': 'claude-sonnet-4-20250514',
                'content': <Object?>[
                  <String, Object?>{'type': 'text', 'text': 'Hi there'},
                ],
                'stop_reason': 'end_turn',
                'usage': <String, Object?>{
                  'input_tokens': 9,
                  'output_tokens': 4,
                },
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
        );

        final resp = await client.message(
          baseUri: Uri.parse('https://api.anthropic.com/'),
          model: 'claude-sonnet-4-20250514',
          system: 'I am dedicated to this user.',
          messages: const <AnthropicMessage>[
            AnthropicMessage(role: 'user', content: 'hi'),
          ],
          options: const AnthropicGenerationOptions(maxOutputTokens: 64),
          apiKey: 'sk-ant-xyz',
          anthropicVersion: '2023-06-01',
        );

        expect(captured.url.path, '/v1/messages');
        expect(captured.headers['x-api-key'], 'sk-ant-xyz');
        expect(captured.headers['anthropic-version'], '2023-06-01');
        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(body['model'], 'claude-sonnet-4-20250514');
        expect(body['max_tokens'], 64);
        expect(body['stream'], false);
        // The system channel rides the Messages API top-level `system` field.
        expect(body['system'], 'I am dedicated to this user.');
        final messages = body['messages'] as List<Object?>;
        expect(messages, hasLength(1));

        expect(resp.model, 'claude-sonnet-4-20250514');
        expect(resp.content, 'Hi there');
        expect(resp.inputTokens, 9);
        expect(resp.outputTokens, 4);
        expect(resp.stopReason, 'end_turn');

        client.close();
      },
    );

    test(
      'non-streaming: empty system omits the top-level system field',
      () async {
        late http.Request captured;
        final client = DefaultAnthropicHttpClient(
          client: MockClient((req) async {
            captured = req;
            return http.Response(
              jsonEncode(<String, Object?>{
                'model': 'm',
                'content': <Object?>[],
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
        );

        await client.message(
          baseUri: Uri.parse('https://api.anthropic.com/'),
          model: 'm',
          messages: const <AnthropicMessage>[
            AnthropicMessage(role: 'user', content: 'hi'),
          ],
          options: const AnthropicGenerationOptions(maxOutputTokens: 8),
        );

        final body = jsonDecode(captured.body) as Map<String, Object?>;
        expect(body.containsKey('system'), isFalse);

        client.close();
      },
    );

    test(
      'non-2xx status throws AnthropicHttpException carrying status + body',
      () async {
        final client = DefaultAnthropicHttpClient(
          client: MockClient((req) async => http.Response('rate limited', 429)),
        );

        await expectLater(
          client.message(
            baseUri: Uri.parse('https://api.anthropic.com/'),
            model: 'm',
            messages: const <AnthropicMessage>[
              AnthropicMessage(role: 'user', content: 'hi'),
            ],
            options: const AnthropicGenerationOptions(maxOutputTokens: 8),
            apiKey: 'k',
          ),
          throwsA(
            isA<AnthropicHttpException>().having(
              (e) => e.statusCode,
              'statusCode',
              429,
            ),
          ),
        );
        client.close();
      },
    );

    test(
      'streaming: message_start → content_block_delta → message_stop SSE',
      () async {
        const sse =
            'event: message_start\n'
            'data: {"type":"message_start","message":{"id":"msg_1",'
            '"model":"claude-sonnet-4-20250514",'
            '"usage":{"input_tokens":7,"output_tokens":1}}}\n'
            '\n'
            'event: content_block_start\n'
            'data: {"type":"content_block_start","index":0,'
            '"content_block":{"type":"text","text":""}}\n'
            '\n'
            'event: content_block_delta\n'
            'data: {"type":"content_block_delta","index":0,'
            '"delta":{"type":"text_delta","text":"Hello "}}\n'
            '\n'
            'event: content_block_delta\n'
            'data: {"type":"content_block_delta","index":0,'
            '"delta":{"type":"text_delta","text":"world"}}\n'
            '\n'
            'event: content_block_stop\n'
            'data: {"type":"content_block_stop","index":0}\n'
            '\n'
            'event: message_delta\n'
            'data: {"type":"message_delta",'
            '"delta":{"stop_reason":"end_turn"},'
            '"usage":{"output_tokens":11}}\n'
            '\n'
            'event: message_stop\n'
            'data: {"type":"message_stop"}\n'
            '\n';

        final client = DefaultAnthropicHttpClient(
          client: MockClient.streaming((req, bodyStream) async {
            return http.StreamedResponse(
              Stream<List<int>>.value(utf8.encode(sse)),
              200,
              headers: <String, String>{'content-type': 'text/event-stream'},
            );
          }),
        );

        final fragments = await client
            .messageStream(
              baseUri: Uri.parse('https://api.anthropic.com/'),
              model: 'claude-sonnet-4-20250514',
              messages: const <AnthropicMessage>[
                AnthropicMessage(role: 'user', content: 'hi'),
              ],
              options: const AnthropicGenerationOptions(maxOutputTokens: 64),
              apiKey: 'k',
              anthropicVersion: '2023-06-01',
            )
            .toList();

        final texts = fragments
            .where((f) => f.textDelta.isNotEmpty)
            .map((f) => f.textDelta)
            .toList();
        expect(texts, <String>['Hello ', 'world']);

        final inputTokens = fragments
            .map((f) => f.inputTokens)
            .firstWhere((t) => t != null);
        expect(inputTokens, 7);
        final outputTokens = fragments
            .map((f) => f.outputTokens)
            .lastWhere((t) => t != null);
        expect(outputTokens, 11);
        final stop = fragments
            .map((f) => f.stopReason)
            .firstWhere((s) => s != null);
        expect(stop, 'end_turn');

        client.close();
      },
    );
  });

  group('P2.10 / barrel surface', () {
    test(
      'Anthropic provider + client + value classes import from barrel only',
      () {
        expect(AnthropicHttpClient, isNotNull);
        expect(DefaultAnthropicHttpClient, isNotNull);
        expect(AnthropicMessage, isNotNull);
        expect(AnthropicGenerationOptions, isNotNull);
        expect(AnthropicChatResponse, isNotNull);
        expect(AnthropicStreamFragment, isNotNull);
        expect(AnthropicHttpException, isNotNull);
        expect(AnthropicLlmProvider, isNotNull);
      },
    );
  });
}

// ─── Helpers ──────────────────────────────────────────────────────

AnthropicLlmProvider _newProvider({
  String id = 'anthropic:passthrough',
  String defaultModel = 'claude-sonnet-4-20250514',
  String? apiKey,
  String anthropicVersion = '2023-06-01',
  int defaultMaxOutputTokens = 4096,
  Map<String, String> extraHeaders = const <String, String>{},
  AnthropicHttpClient? httpClient,
}) {
  return AnthropicLlmProvider(
    id: id,
    baseUri: Uri.parse('https://api.anthropic.com/'),
    defaultModel: defaultModel,
    apiKey: apiKey,
    anthropicVersion: anthropicVersion,
    defaultMaxOutputTokens: defaultMaxOutputTokens,
    extraHeaders: extraHeaders,
    httpClient: httpClient ?? _FakeAnthropicHttpClient(),
  );
}

String _sha256Stamp(String body) {
  return 'sha256:${sha256.convert(utf8.encode(body))}';
}

// ─── Test double ──────────────────────────────────────────────────

final class _FakeAnthropicHttpClient implements AnthropicHttpClient {
  final List<_AnthropicMessageInvocation> messageCalls =
      <_AnthropicMessageInvocation>[];

  AnthropicChatResponse messageResponse = const AnthropicChatResponse(
    model: 'm',
    content: '',
  );
  Object? messageException;

  List<AnthropicStreamFragment> streamFragments =
      const <AnthropicStreamFragment>[];
  Object? streamException;

  bool closeCalled = false;

  @override
  Future<AnthropicChatResponse> message({
    required Uri baseUri,
    required String model,
    required List<AnthropicMessage> messages,
    required AnthropicGenerationOptions options,
    String system = '',
    String? apiKey,
    String anthropicVersion = '2023-06-01',
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
  }) async {
    messageCalls.add(
      _AnthropicMessageInvocation(
        baseUri: baseUri,
        model: model,
        system: system,
        messages: messages,
        options: options,
        apiKey: apiKey,
        anthropicVersion: anthropicVersion,
        extraHeaders: extraHeaders,
      ),
    );
    if (messageException != null) throw messageException!;
    return messageResponse;
  }

  @override
  Stream<AnthropicStreamFragment> messageStream({
    required Uri baseUri,
    required String model,
    required List<AnthropicMessage> messages,
    required AnthropicGenerationOptions options,
    String system = '',
    String? apiKey,
    String anthropicVersion = '2023-06-01',
    Map<String, String> extraHeaders = const <String, String>{},
    Duration? requestTimeout,
    TomCancellationToken? cancellationToken,
  }) async* {
    messageCalls.add(
      _AnthropicMessageInvocation(
        baseUri: baseUri,
        model: model,
        system: system,
        messages: messages,
        options: options,
        apiKey: apiKey,
        anthropicVersion: anthropicVersion,
        extraHeaders: extraHeaders,
      ),
    );
    if (streamException != null) throw streamException!;
    for (final frag in streamFragments) {
      yield frag;
    }
  }

  @override
  void close() {
    closeCalled = true;
  }
}

final class _AnthropicMessageInvocation {
  final Uri baseUri;
  final String model;
  final String system;
  final List<AnthropicMessage> messages;
  final AnthropicGenerationOptions options;
  final String? apiKey;
  final String anthropicVersion;
  final Map<String, String> extraHeaders;

  const _AnthropicMessageInvocation({
    required this.baseUri,
    required this.model,
    required this.system,
    required this.messages,
    required this.options,
    required this.apiKey,
    required this.anthropicVersion,
    required this.extraHeaders,
  });
}
