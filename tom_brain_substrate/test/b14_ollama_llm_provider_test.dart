// B.14 — `OllamaLlmProvider` + `OllamaHttpClient` seam conformance.
//
// Scope of this test file:
//
//   - Prove `OllamaLlmProvider` honours every `LlmProvider` contract
//     point that B.11 documented (id propagation, anchor-hash
//     propagation, provenance stamp, prompt-body preservation, the
//     non-streaming `completeStream` lifecycle shape).
//   - Prove the wire-shape seam (`OllamaHttpClient`) gets the right
//     request payload (model id, messages array, stream flag, options
//     map, format flag) for every documented input combination
//     (defaults vs. caller-overridden model, temperature / max tokens
//     / stop sequences, JSON response-format request).
//   - Prove the streaming path emits the documented
//     `Started → Chunk* → Completed` shape; the chunks line up with
//     the fragments the fake adapter produces; the terminal report
//     carries the eval counters and the prompt's anchor / template
//     metadata.
//   - Prove failure-shape: an HTTP failure on the non-streaming path
//     surfaces as a thrown exception (per spec § 4.1 "router catches"
//     contract); on the streaming path it surfaces as a terminal
//     [LlmStreamFailed] event with a typed [LlmFailure] envelope
//     (`classCode: 'unknown'` until B.18 wires the classifier).
//   - Prove the streaming path terminates with [LlmStreamFailed] when
//     the fake adapter ends the stream without emitting a `done: true`
//     fragment (protocol-shape failure, classCode `format`).
//   - Prove `embedRaw` / `listAvailableModels` (the off-interface
//     helpers landed at B.14 for B.18 / B.25 consumers) call through
//     to the seam unchanged.
//   - Prove the `LlmCallReport.promptHash` is sha256 over
//     `prompt.combined` (deterministic given the prompt body — same body
//     → same hash; different body → different hash).
//   - Prove the `OllamaHttpClient` and `OllamaLlmProvider` surfaces
//     are reachable from the top-level package barrel (the lints
//     rule that forbids `package:foo/src/...` imports).
//
// Scope this file is NOT for:
//
//   - No live Ollama daemon. Every test uses `_FakeOllamaHttpClient`.
//     The dependency-surface test (B.7) is the only place we touch
//     real wire types; this file binds against the seam.
//   - No router behaviour (retry / rotate / failure classification).
//     That is B.18+. The provider here re-throws / surfaces failures
//     with `classCode: 'unknown'` and that is the test's expectation.
//   - No anchor enforcement test. That is B.46's job and operates on
//     the whole `TomBrainSubstrateClient` surface.
//   - No cancellation-token mid-stream test against the production
//     `DefaultOllamaHttpClient`. B.14 honours cancellation on the
//     streaming path only and only by polling the token between
//     NDJSON lines; B.18 wires a cancellable HTTP client. The
//     contract here is "the provider forwards the token to the seam";
//     a separate fake-driven test exercises that wiring.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.14 / OllamaLlmProvider — interface conformance', () {
    test('id is propagated verbatim', () {
      final provider = _newProvider(id: 'ollama:local');
      expect(provider.id, 'ollama:local');
      expect(provider, isA<LlmProvider>());
    });

    test('complete stamps anchor + provider + template metadata onto the report',
        () async {
      final fake = _FakeOllamaHttpClient()
        ..chatResponse = const OllamaChatResponse(
          model: 'gemma3:27b',
          content: 'hello back',
          promptEvalCount: 12,
          evalCount: 5,
          totalDurationNs: 9000,
        );
      final provider = _newProvider(httpClient: fake);

      final report = await provider.complete(
        const WirePrompt(
          system: 'anchor + body',
          anchorHash: 'sha256:anchor-stamp',
          roleId: 'assistant_to_user',
          templateSha: 'tpl-1',
        ),
        const LlmOptions(),
      );

      expect(report.providerId, 'ollama:local');
      expect(report.modelId, 'gemma3:27b'); // echo from response
      expect(report.anchorHash, 'sha256:anchor-stamp');
      expect(report.templateSha, 'tpl-1');
      expect(report.tokensIn, 12);
      expect(report.tokensOut, 5);
      expect(report.retries, 0);
      expect(report.wallClockMs, greaterThanOrEqualTo(0));
      expect(report.promptHash, _sha256Stamp('anchor + body'));
    });

    test(
        'complete sends system + user as two messages '
        '([{role:system}, {role:user}])', () async {
      final fake = _FakeOllamaHttpClient()
        ..chatResponse = const OllamaChatResponse(
          model: 'gemma3:27b',
          content: '',
        );
      final provider = _newProvider(httpClient: fake);

      await provider.complete(
        const WirePrompt(
          system: 'I am dedicated to this user.',
          user: 'user question',
          anchorHash: 'sha256:x',
          roleId: 'assistant_to_user',
        ),
        const LlmOptions(),
      );

      final call = fake.chatCalls.single;
      expect(call.model, 'gemma3:27b');
      // Anchor-first system channel leads as a `system` message,
      // followed by the call-specific `user` message.
      expect(call.messages, hasLength(2));
      expect(call.messages[0].role, 'system');
      expect(call.messages[0].content, 'I am dedicated to this user.');
      expect(call.messages[1].role, 'user');
      expect(call.messages[1].content, 'user question');
    });

    test('complete omits the system message when system is empty', () async {
      final fake = _FakeOllamaHttpClient()
        ..chatResponse = const OllamaChatResponse(
          model: 'gemma3:27b',
          content: '',
        );
      final provider = _newProvider(httpClient: fake);

      await provider.complete(
        const WirePrompt(
          system: '',
          user: 'just the user turn',
          anchorHash: 'sha256:x',
          roleId: 'assistant_to_user',
        ),
        const LlmOptions(),
      );

      final call = fake.chatCalls.single;
      expect(call.messages, hasLength(1));
      expect(call.messages.single.role, 'user');
      expect(call.messages.single.content, 'just the user turn');
    });

    test('options.model overrides the default model when provided', () async {
      final fake = _FakeOllamaHttpClient()
        ..chatResponse = const OllamaChatResponse(
          model: 'llama3:8b',
          content: '',
        );
      final provider = _newProvider(httpClient: fake, defaultModel: 'gemma3:27b');

      final report = await provider.complete(
        const WirePrompt(
          system: 'x',
          anchorHash: 'sha256:y',
          roleId: 'analyser',
        ),
        const LlmOptions(model: 'llama3:8b'),
      );

      expect(fake.chatCalls.single.model, 'llama3:8b');
      expect(report.modelId, 'llama3:8b');
    });

    test('options knobs translate onto the Ollama generation map', () async {
      final fake = _FakeOllamaHttpClient()
        ..chatResponse =
            const OllamaChatResponse(model: 'gemma3:27b', content: '');
      final provider = _newProvider(httpClient: fake);

      await provider.complete(
        const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(
          temperature: 0.42,
          maxOutputTokens: 256,
          stopSequences: <String>['STOP', 'END'],
        ),
      );

      final opts = fake.chatCalls.single.options;
      expect(opts.temperature, 0.42);
      expect(opts.maxOutputTokens, 256);
      expect(opts.stopSequences, <String>['STOP', 'END']);
      expect(opts.jsonFormat, isFalse);
    });

    test('responseFormat non-null sets the Ollama format flag', () async {
      final fake = _FakeOllamaHttpClient()
        ..chatResponse =
            const OllamaChatResponse(model: 'gemma3:27b', content: '');
      final provider = _newProvider(httpClient: fake);

      await provider.complete(
        const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(responseFormat: <String, Object?>{'type': 'object'}),
      );

      expect(fake.chatCalls.single.options.jsonFormat, isTrue);
    });

    test('missing eval counters surface as 0 + a note (router classifies later)',
        () async {
      final fake = _FakeOllamaHttpClient()
        ..chatResponse = const OllamaChatResponse(
          model: 'gemma3:27b',
          content: '',
        ); // no counters
      final provider = _newProvider(httpClient: fake);

      final report = await provider.complete(
        const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );

      expect(report.tokensIn, 0);
      expect(report.tokensOut, 0);
      expect(report.notes, contains('ollama:prompt_eval_count_missing'));
      expect(report.notes, contains('ollama:eval_count_missing'));
    });

    test(
      'tool catalogue present surfaces a "not yet dispatched" note '
      '(spec § 4.1; tool dispatch lands at B.27)',
      () async {
        final fake = _FakeOllamaHttpClient()
          ..chatResponse = const OllamaChatResponse(
            model: 'gemma3:27b',
            content: '',
            promptEvalCount: 1,
            evalCount: 1,
          );
        final provider = _newProvider(httpClient: fake);

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
      },
    );

    test('complete re-throws transport failures unclassified (router classifies)',
        () async {
      final fake = _FakeOllamaHttpClient()
        ..chatException = OllamaHttpException(
          statusCode: 503,
          body: 'overloaded',
          endpoint: Uri.parse('http://localhost:11434/api/chat'),
        );
      final provider = _newProvider(httpClient: fake);

      await expectLater(
        provider.complete(
          const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
          const LlmOptions(),
        ),
        throwsA(isA<OllamaHttpException>()),
      );
    });
  });

  group('B.14 / OllamaLlmProvider — streaming path', () {
    test(
      'emits Started → Chunk* → Completed for a multi-fragment stream',
      () async {
        final fake = _FakeOllamaHttpClient()
          ..streamFragments = const <OllamaStreamFragment>[
            OllamaStreamFragment(
              model: 'gemma3:27b',
              contentDelta: 'Hello ',
              done: false,
            ),
            OllamaStreamFragment(
              model: 'gemma3:27b',
              contentDelta: 'world',
              done: false,
            ),
            OllamaStreamFragment(
              model: 'gemma3:27b',
              contentDelta: '',
              done: true,
              promptEvalCount: 7,
              evalCount: 11,
              totalDurationNs: 1000,
            ),
          ];
        final provider = _newProvider(httpClient: fake);

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

        final started = events.first as LlmStreamStarted;
        expect(started.providerId, 'ollama:local');
        expect(started.modelId, 'gemma3:27b');
        expect(started.callId, isNotEmpty);

        final chunks =
            events.whereType<LlmStreamChunk>().toList(growable: false);
        expect(chunks.map((c) => c.text).toList(), <String>['Hello ', 'world']);
        for (final chunk in chunks) {
          expect(chunk.callId, started.callId);
        }

        final completed = events.last as LlmStreamCompleted;
        expect(completed.callId, started.callId);
        expect(completed.report.providerId, 'ollama:local');
        expect(completed.report.modelId, 'gemma3:27b');
        expect(completed.report.anchorHash, 'sha256:stream-anchor');
        expect(completed.report.templateSha, 'tpl-2');
        expect(completed.report.tokensIn, 7);
        expect(completed.report.tokensOut, 11);
        expect(completed.report.promptHash, _sha256Stamp('streaming body'));
      },
    );

    test('empty-delta fragments do not emit a Chunk event', () async {
      final fake = _FakeOllamaHttpClient()
        ..streamFragments = const <OllamaStreamFragment>[
          OllamaStreamFragment(
            model: 'gemma3:27b',
            contentDelta: '',
            done: false,
          ),
          OllamaStreamFragment(
            model: 'gemma3:27b',
            contentDelta: 'first text',
            done: false,
          ),
          OllamaStreamFragment(
            model: 'gemma3:27b',
            contentDelta: '',
            done: true,
            promptEvalCount: 1,
            evalCount: 2,
          ),
        ];
      final provider = _newProvider(httpClient: fake);

      final events = await provider
          .completeStream(
            const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
            const LlmOptions(),
          )
          .toList();

      final chunks = events.whereType<LlmStreamChunk>().toList();
      expect(chunks, hasLength(1));
      expect(chunks.single.text, 'first text');
    });

    test(
      'no terminal done=true frame surfaces as LlmStreamFailed(format)',
      () async {
        final fake = _FakeOllamaHttpClient()
          ..streamFragments = const <OllamaStreamFragment>[
            OllamaStreamFragment(
              model: 'gemma3:27b',
              contentDelta: 'partial',
              done: false,
            ),
          ];
        final provider = _newProvider(httpClient: fake);

        final events = await provider
            .completeStream(
              const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
              const LlmOptions(),
            )
            .toList();

        expect(events.last, isA<LlmStreamFailed>());
        final failed = events.last as LlmStreamFailed;
        expect(failed.failure.classCode, 'format');
        expect(failed.report.anchorHash, 'a');
      },
    );

    test(
      'transport failure mid-stream surfaces as LlmStreamFailed(unknown) '
      '(B.18 will reclassify)',
      () async {
        final fake = _FakeOllamaHttpClient()
          ..streamException = OllamaHttpException(
            statusCode: 500,
            body: 'boom',
            endpoint: Uri.parse('http://localhost:11434/api/chat'),
          );
        final provider = _newProvider(httpClient: fake);

        final events = await provider
            .completeStream(
              const WirePrompt(system: 'x', anchorHash: 'a', roleId: 'r'),
              const LlmOptions(),
            )
            .toList();

        expect(events.first, isA<LlmStreamStarted>());
        expect(events.last, isA<LlmStreamFailed>());
        final failed = events.last as LlmStreamFailed;
        expect(failed.failure.classCode, 'unknown');
        expect(failed.failure.cause, isA<OllamaHttpException>());
      },
    );
  });

  group('B.14 / OllamaLlmProvider — promptHash determinism', () {
    test('same prompt body → same promptHash', () async {
      final fake = _FakeOllamaHttpClient()
        ..chatResponse =
            const OllamaChatResponse(model: 'gemma3:27b', content: '');
      final provider = _newProvider(httpClient: fake);

      final r1 = await provider.complete(
        const WirePrompt(system: 'deterministic', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );
      final r2 = await provider.complete(
        const WirePrompt(system: 'deterministic', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );
      expect(r1.promptHash, r2.promptHash);
      expect(r1.promptHash, startsWith('sha256:'));
    });

    test('different prompt body → different promptHash', () async {
      final fake = _FakeOllamaHttpClient()
        ..chatResponse =
            const OllamaChatResponse(model: 'gemma3:27b', content: '');
      final provider = _newProvider(httpClient: fake);

      final r1 = await provider.complete(
        const WirePrompt(system: 'first', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );
      final r2 = await provider.complete(
        const WirePrompt(system: 'second', anchorHash: 'a', roleId: 'r'),
        const LlmOptions(),
      );
      expect(r1.promptHash, isNot(equals(r2.promptHash)));
    });
  });

  group('B.14 / OllamaLlmProvider — off-interface helpers', () {
    test('embedRaw forwards model + prompt to the seam', () async {
      final fake = _FakeOllamaHttpClient()
        ..embedResponse = const <double>[0.1, 0.2, 0.3];
      final provider = _newProvider(httpClient: fake);

      final v = await provider.embedRaw(prompt: 'a body');
      expect(v, <double>[0.1, 0.2, 0.3]);

      final call = fake.embedCalls.single;
      expect(call.model, 'gemma3:27b'); // default model used
      expect(call.prompt, 'a body');
    });

    test('embedRaw honours an explicit model id', () async {
      final fake = _FakeOllamaHttpClient()
        ..embedResponse = const <double>[1.0];
      final provider = _newProvider(httpClient: fake);

      await provider.embedRaw(prompt: 'a', model: 'nomic-embed-text');
      expect(fake.embedCalls.single.model, 'nomic-embed-text');
    });

    test('listAvailableModels returns the seam tag list', () async {
      final fake = _FakeOllamaHttpClient()
        ..tagsResponse = const <OllamaTagEntry>[
          OllamaTagEntry(name: 'gemma3:27b'),
          OllamaTagEntry(name: 'llama3:8b'),
        ];
      final provider = _newProvider(httpClient: fake);

      final tags = await provider.listAvailableModels();
      expect(tags.map((t) => t.name).toList(), <String>['gemma3:27b', 'llama3:8b']);
    });
  });

  group('B.14 / barrel surface', () {
    test(
      'OllamaLlmProvider + OllamaHttpClient surfaces import from the '
      'top-level package barrel only (no `package:foo/src/...`)',
      () {
        // The single test-file import line is
        //   import 'package:tom_brain_substrate/tom_brain_substrate.dart';
        // — reaching every B.14-added symbol under that constraint is
        // the proof.
        expect(OllamaHttpClient, isNotNull);
        expect(DefaultOllamaHttpClient, isNotNull);
        expect(OllamaMessage, isNotNull);
        expect(OllamaGenerationOptions, isNotNull);
        expect(OllamaChatResponse, isNotNull);
        expect(OllamaStreamFragment, isNotNull);
        expect(OllamaTagEntry, isNotNull);
        expect(OllamaHttpException, isNotNull);
        expect(OllamaLlmProvider, isNotNull);
      },
    );
  });
}

// ─── Helpers ──────────────────────────────────────────────────────

OllamaLlmProvider _newProvider({
  String id = 'ollama:local',
  String defaultModel = 'gemma3:27b',
  OllamaHttpClient? httpClient,
}) {
  return OllamaLlmProvider(
    id: id,
    baseUri: Uri.parse('http://127.0.0.1:11434/'),
    defaultModel: defaultModel,
    httpClient: httpClient ?? _FakeOllamaHttpClient(),
  );
}

String _sha256Stamp(String body) {
  return 'sha256:${sha256.convert(utf8.encode(body))}';
}

// ─── Test double ──────────────────────────────────────────────────

/// Deterministic in-test [OllamaHttpClient]. Records what the provider
/// asked it to do and returns whatever the test set up as the response.
final class _FakeOllamaHttpClient implements OllamaHttpClient {
  /// Recorded `chat` invocations.
  final List<_ChatInvocation> chatCalls = <_ChatInvocation>[];

  /// Recorded `embed` invocations.
  final List<_EmbedInvocation> embedCalls = <_EmbedInvocation>[];

  /// Response for the next `chat` call.
  OllamaChatResponse chatResponse =
      const OllamaChatResponse(model: 'gemma3:27b', content: '');

  /// If set, the next `chat` call throws this instead of returning.
  Object? chatException;

  /// Fragments for the next `chatStream` call. Yielded in order.
  List<OllamaStreamFragment> streamFragments = const <OllamaStreamFragment>[];

  /// If set, the next `chatStream` call throws this after Started.
  Object? streamException;

  /// Response for the next `embed` call.
  List<double> embedResponse = const <double>[];

  /// Response for the next `listTags` call.
  List<OllamaTagEntry> tagsResponse = const <OllamaTagEntry>[];

  bool closeCalled = false;

  @override
  Future<OllamaChatResponse> chat({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
  }) async {
    chatCalls.add(_ChatInvocation(
      baseUri: baseUri,
      model: model,
      messages: messages,
      options: options,
    ));
    if (chatException != null) throw chatException!;
    return chatResponse;
  }

  @override
  Stream<OllamaStreamFragment> chatStream({
    required Uri baseUri,
    required String model,
    required List<OllamaMessage> messages,
    required OllamaGenerationOptions options,
    Duration? requestTimeout,
    CancellationToken? cancellationToken,
  }) async* {
    chatCalls.add(_ChatInvocation(
      baseUri: baseUri,
      model: model,
      messages: messages,
      options: options,
    ));
    if (streamException != null) throw streamException!;
    for (final frag in streamFragments) {
      yield frag;
    }
  }

  @override
  Future<List<double>> embed({
    required Uri baseUri,
    required String model,
    required String prompt,
    Duration? requestTimeout,
  }) async {
    embedCalls.add(_EmbedInvocation(
      baseUri: baseUri,
      model: model,
      prompt: prompt,
    ));
    return embedResponse;
  }

  @override
  Future<List<OllamaTagEntry>> listTags({
    required Uri baseUri,
    Duration? requestTimeout,
  }) async {
    return tagsResponse;
  }

  @override
  void close() {
    closeCalled = true;
  }
}

final class _ChatInvocation {
  final Uri baseUri;
  final String model;
  final List<OllamaMessage> messages;
  final OllamaGenerationOptions options;

  const _ChatInvocation({
    required this.baseUri,
    required this.model,
    required this.messages,
    required this.options,
  });
}

final class _EmbedInvocation {
  final Uri baseUri;
  final String model;
  final String prompt;

  const _EmbedInvocation({
    required this.baseUri,
    required this.model,
    required this.prompt,
  });
}
