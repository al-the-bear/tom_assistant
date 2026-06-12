// C.13 — SubstrateBridge unit tests.
//
// Drives `SubstrateBridge` against an in-memory fake of
// `TomBrainSubstrateClient` (the interface boundary, PE-10). Each test
// asserts two things: (a) the primitive d4rt-facing arguments are
// converted into the correct substrate domain types on the way in, and
// (b) the domain results are flattened into the correct primitive
// maps/lists on the way out.
//
// These are *native* Dart tests — they do NOT run the d4rt generator.
// The generator-output round-trip smoke is C.15. This step (C.13) proves
// the source class behaves before it is bridged.

import 'dart:typed_data';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

void main() {
  late _FakeSubstrateClient client;
  late SubstrateBridge bridge;

  setUp(() {
    client = _FakeSubstrateClient();
    bridge = SubstrateBridge(client);
  });

  group('C.13 SubstrateBridge — construction', () {
    test('wraps the injected client (PE-10 interface boundary)', () {
      expect(bridge.client, same(client));
    });
  });

  group('C.13 SubstrateBridge.llm', () {
    test('builds an LlmCall, concatenates chunk text, flattens report',
        () async {
      client.streamEvents = <LlmStreamEvent>[
        const LlmStreamStarted(
          callId: 'c1',
          providerId: 'ollama:local',
          modelId: 'gemma3:27b',
        ),
        const LlmStreamChunk(callId: 'c1', text: 'Hello, '),
        const LlmStreamChunk(callId: 'c1', text: 'world.'),
        const LlmStreamCompleted(
          callId: 'c1',
          report: LlmCallReport(
            providerId: 'ollama:local',
            modelId: 'gemma3:27b',
            anchorHash: 'a1',
            promptHash: 'p1',
            tokensIn: 12,
            tokensOut: 7,
            retries: 1,
            wallClockMs: 340,
            cost: 0.0,
            templateSha: 'sha1',
            notes: <String>['note'],
          ),
        ),
      ];

      final out = await bridge.llm('what is X?');

      // (a) Inbound conversion — role default + prompt input + budget.
      final call = client.lastCall!;
      expect(call.roleId, SubstrateBridge.defaultRole);
      expect(call.inputs, <String, Object?>{'prompt': 'what is X?'});
      expect(call.budget.wallClockMs, 86400000);
      expect(call.budget.tokenSpend, 100000000);

      // (b) Outbound flattening — concatenated text + report map.
      expect(out['text'], 'Hello, world.');
      final report = out['report']! as Map<String, Object?>;
      expect(report['providerId'], 'ollama:local');
      expect(report['modelId'], 'gemma3:27b');
      expect(report['anchorHash'], 'a1');
      expect(report['promptHash'], 'p1');
      expect(report['tokensIn'], 12);
      expect(report['tokensOut'], 7);
      expect(report['retries'], 1);
      expect(report['wallClockMs'], 340);
      expect(report['cost'], 0.0);
      expect(report['templateSha'], 'sha1');
      expect(report['notes'], <String>['note']);
    });

    test('passes the caller-supplied role through', () async {
      client.streamEvents = _completedStream('ok');
      await bridge.llm('q', role: 'analyser');
      expect(client.lastCall!.roleId, 'analyser');
    });

    test('builds the budget from a primitive map, falling back per field',
        () async {
      client.streamEvents = _completedStream('ok');
      await bridge.llm('q', budget: const <String, Object?>{
        'wallClockMs': 5000,
        'tokenSpend': 200,
        // toolCalls + memoryWrites omitted → default fallback.
      });
      final b = client.lastCall!.budget;
      expect(b.wallClockMs, 5000);
      expect(b.tokenSpend, 200);
      expect(b.toolCalls, 800); // default
      expect(b.memoryWrites, 1000000); // default
    });

    test('rejects a non-numeric budget field with a FormatException (E.3.3)',
        () async {
      client.streamEvents = _completedStream('ok');
      await expectLater(
        bridge.llm('q', budget: const <String, Object?>{'wallClockMs': 'lots'}),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('budget.wallClockMs must be a number (got'),
        )),
      );
    });

    test('omits null cost / templateSha from the report map', () async {
      client.streamEvents = <LlmStreamEvent>[
        const LlmStreamCompleted(
          callId: 'c1',
          report: LlmCallReport(
            providerId: 'p',
            modelId: 'm',
            anchorHash: 'a',
            promptHash: 'pr',
            tokensIn: 1,
            tokensOut: 1,
            retries: 0,
            wallClockMs: 1,
          ),
        ),
      ];
      final out = await bridge.llm('q');
      final report = out['report']! as Map<String, Object?>;
      expect(report.containsKey('cost'), isFalse);
      expect(report.containsKey('templateSha'), isFalse);
      expect(report['notes'], isEmpty);
    });

    test('throws LlmCompletionFailure on a failed stream', () async {
      client.streamEvents = <LlmStreamEvent>[
        const LlmStreamChunk(callId: 'c1', text: 'partial'),
        const LlmStreamFailed(
          callId: 'c1',
          failure: LlmFailure(classCode: 'timeout', message: 'too slow'),
          report: LlmCallReport(
            providerId: 'p',
            modelId: 'm',
            anchorHash: 'a',
            promptHash: 'pr',
            tokensIn: 3,
            tokensOut: 0,
            retries: 2,
            wallClockMs: 9000,
          ),
        ),
      ];

      await expectLater(
        bridge.llm('q'),
        throwsA(
          isA<LlmCompletionFailure>()
              .having((e) => e.classCode, 'classCode', 'timeout')
              .having((e) => e.message, 'message', 'too slow')
              .having((e) => e.report['retries'], 'report.retries', 2),
        ),
      );
    });

    test('throws StateError when the stream closes with no terminal event',
        () async {
      client.streamEvents = <LlmStreamEvent>[
        const LlmStreamChunk(callId: 'c1', text: 'orphan'),
      ];
      await expectLater(bridge.llm('q'), throwsA(isA<StateError>()));
    });
  });

  group('C.13 SubstrateBridge.llm — streaming token sink (P1.3 #7)', () {
    test('forwards each chunk to the bound sink as it arrives, still '
        'returning the concatenated text', () async {
      final tokens = <String>[];
      final streaming = SubstrateBridge(client, onToken: (delta) async {
        tokens.add(delta);
      });
      client.streamEvents = <LlmStreamEvent>[
        const LlmStreamStarted(
          callId: 'c1',
          providerId: 'ollama:local',
          modelId: 'gemma3:27b',
        ),
        const LlmStreamChunk(callId: 'c1', text: 'Hello, '),
        const LlmStreamChunk(callId: 'c1', text: 'world.'),
        const LlmStreamCompleted(
          callId: 'c1',
          report: LlmCallReport(
            providerId: 'ollama:local',
            modelId: 'gemma3:27b',
            anchorHash: 'a1',
            promptHash: 'p1',
            tokensIn: 12,
            tokensOut: 7,
            retries: 0,
            wallClockMs: 340,
          ),
        ),
      ];

      final out = await streaming.llm('what is X?');

      // The sink saw each token delta in order — the external path streams
      // instead of only buffering.
      expect(tokens, <String>['Hello, ', 'world.']);
      // The concatenated text is still returned (persist + late-failure
      // status depend on it).
      expect(out['text'], 'Hello, world.');
    });

    test('forwards the partial deltas before a stream failure', () async {
      final tokens = <String>[];
      final streaming = SubstrateBridge(client, onToken: (delta) async {
        tokens.add(delta);
      });
      client.streamEvents = <LlmStreamEvent>[
        const LlmStreamChunk(callId: 'c1', text: 'par'),
        const LlmStreamChunk(callId: 'c1', text: 'tial'),
        const LlmStreamFailed(
          callId: 'c1',
          failure: LlmFailure(classCode: 'timeout', message: 'too slow'),
          report: LlmCallReport(
            providerId: 'p',
            modelId: 'm',
            anchorHash: 'a',
            promptHash: 'pr',
            tokensIn: 3,
            tokensOut: 0,
            retries: 2,
            wallClockMs: 9000,
          ),
        ),
      ];

      await expectLater(
        streaming.llm('q'),
        throwsA(isA<LlmCompletionFailure>()),
      );
      expect(tokens, <String>['par', 'tial']);
    });

    test('with no sink bound the chunks are only buffered (internal path)',
        () async {
      // The default bridge (no onToken) must behave exactly as before — the
      // internal/free-time path stays non-streaming. Proven by the existing
      // llm tests; this asserts the construction default explicitly.
      client.streamEvents = _completedStream('ok');
      final out = await bridge.llm('q');
      expect(out['text'], 'ok');
    });
  });

  group('C.13 SubstrateBridge.llm — labeled thinking stages (§ 9.2 Todo 7)', () {
    // When a deliberation turn streams on the thinking channel, the notice the
    // user follows is prefixed with a short stage label keyed on the turn's
    // role, so the live process reads as `🧠 analysing… <text>` rather than a
    // bare text dump. The label rides only on the *notice* — the text the
    // bridge returns to the procedure (which feeds persist / transcript) stays
    // unlabeled.

    test('an analyser turn is labeled 🧠 analysing…', () async {
      final notices = <String>[];
      final thinking =
          SubstrateBridge(client, onThinking: (text) => notices.add(text));
      client.streamEvents = _completedStream('the analysis');

      final out = await thinking.llm('q', role: 'analyser');

      expect(notices, hasLength(1));
      expect(notices.single, startsWith('🧠 analysing…'));
      expect(notices.single, contains('the analysis'));
      // The procedure-facing text carries no label.
      expect(out['text'], 'the analysis');
    });

    test('a sub_thinker turn is labeled 🧩 reasoning…', () async {
      final notices = <String>[];
      final thinking =
          SubstrateBridge(client, onThinking: (text) => notices.add(text));
      client.streamEvents = _completedStream('a sub-answer');

      await thinking.llm('q', role: 'sub_thinker');

      expect(notices.single, startsWith('🧩 reasoning…'));
      expect(notices.single, contains('a sub-answer'));
    });

    test('an evaluator turn is labeled 🔎 critiquing…', () async {
      final notices = <String>[];
      final thinking =
          SubstrateBridge(client, onThinking: (text) => notices.add(text));
      client.streamEvents = _completedStream('the critique');

      await thinking.llm('q', role: 'evaluator');

      expect(notices.single, startsWith('🔎 critiquing…'));
      expect(notices.single, contains('the critique'));
    });

    test('a thinking-channel turn with no stage role falls back to 🤔 thinking…',
        () async {
      final notices = <String>[];
      final thinking =
          SubstrateBridge(client, onThinking: (text) => notices.add(text));
      client.streamEvents = _completedStream('working it out');

      // `assistant_to_user` is not a deliberation stage; routed to thinking by
      // an explicit channel, it gets the generic fallback label.
      final out = await thinking.llm(
        'q',
        role: 'assistant_to_user',
        channel: 'thinking',
      );

      expect(notices.single, startsWith('🤔 thinking…'));
      expect(notices.single, contains('working it out'));
      expect(out['text'], 'working it out');
    });
  });

  group('C.13 SubstrateBridge.embed', () {
    test('flattens the vector + model identity', () async {
      client.embedResult = EmbeddingResult(
        vec: Vec(Float32List.fromList(<double>[0.1, 0.2, 0.3])),
        modelIdentity: const EmbeddingModelIdentity(
          providerId: 'ollama:local',
          modelId: 'nomic-embed-text',
          dims: 3,
          normalized: true,
        ),
      );

      final out = await bridge.embed('embed me');

      expect(client.lastEmbedText, 'embed me');
      final vec = out['vec']! as List<Object?>;
      expect(vec, hasLength(3));
      expect((vec[0]! as double), closeTo(0.1, 1e-6));
      final identity = out['modelIdentity']! as Map<String, Object?>;
      expect(identity['providerId'], 'ollama:local');
      expect(identity['modelId'], 'nomic-embed-text');
      expect(identity['dims'], 3);
      expect(identity['normalized'], true);
    });
  });

  group('C.13 SubstrateBridge.search', () {
    test('converts provider + k and flattens hits', () async {
      client.searchResult = WebSearchResult(
        provider: 'brave',
        query: 'dart streams',
        hits: <SearchHit>[
          SearchHit(
            title: 'Streams',
            url: Uri.parse('https://dart.dev/streams'),
            snippet: 'about streams',
            rank: 1,
          ),
        ],
      );

      final out = await bridge.search('dart streams', provider: 'brave', k: 5);

      expect(client.lastSearchQuery, 'dart streams');
      expect(client.lastSearchOptions!.provider, 'brave');
      expect(client.lastSearchOptions!.k, 5);

      expect(out['provider'], 'brave');
      expect(out['query'], 'dart streams');
      final hits = out['hits']! as List<Object?>;
      expect(hits, hasLength(1));
      final h0 = hits.first! as Map<String, Object?>;
      expect(h0['title'], 'Streams');
      expect(h0['url'], 'https://dart.dev/streams');
      expect(h0['snippet'], 'about streams');
      expect(h0['rank'], 1);
    });

    test('defaults provider to null and k to 10', () async {
      client.searchResult = const WebSearchResult(
        provider: 'duckduckgo',
        query: 'q',
        hits: <SearchHit>[],
      );
      await bridge.search('q');
      expect(client.lastSearchOptions!.provider, isNull);
      expect(client.lastSearchOptions!.k, 10);
    });
  });

  group('C.13 SubstrateBridge.fetch', () {
    test('parses the url, passes the budget, flattens a text result',
        () async {
      client.fetchResult = WebFetchResult(
        url: Uri.parse('https://example.com/page'),
        status: 200,
        contentType: 'text/html',
        text: 'extracted prose',
      );

      final out =
          await bridge.fetch('https://example.com/page', budgetBytes: 1024);

      expect(client.lastFetchUrl, Uri.parse('https://example.com/page'));
      expect(client.lastFetchOptions!.budgetBytes, 1024);

      expect(out['url'], 'https://example.com/page');
      expect(out['status'], 200);
      expect(out['contentType'], 'text/html');
      expect(out['truncated'], false);
      expect(out['text'], 'extracted prose');
      expect(out.containsKey('json'), isFalse);
      expect(out.containsKey('binaryMeta'), isFalse);
    });

    test('flattens a json result', () async {
      client.fetchResult = WebFetchResult(
        url: Uri.parse('https://api.example.com/x'),
        status: 200,
        contentType: 'application/json',
        json: const <String, Object?>{'a': 1},
      );
      final out = await bridge.fetch('https://api.example.com/x');
      expect(out['json'], <String, Object?>{'a': 1});
      expect(out.containsKey('text'), isFalse);
    });

    test('flattens a binary result with truncation', () async {
      client.fetchResult = WebFetchResult(
        url: Uri.parse('https://example.com/blob'),
        status: 200,
        contentType: 'application/octet-stream',
        binaryMeta: const BinaryFetchMeta(
          contentType: 'application/octet-stream',
          contentLength: 4096,
        ),
        truncated: true,
      );
      final out = await bridge.fetch('https://example.com/blob');
      expect(out['truncated'], true);
      final meta = out['binaryMeta']! as Map<String, Object?>;
      expect(meta['contentType'], 'application/octet-stream');
      expect(meta['contentLength'], 4096);
      expect(out.containsKey('text'), isFalse);
      expect(out.containsKey('json'), isFalse);
    });
  });
}

/// Builds a minimal Started→Chunk→Completed stream emitting [text].
List<LlmStreamEvent> _completedStream(String text) => <LlmStreamEvent>[
      LlmStreamChunk(callId: 'c', text: text),
      const LlmStreamCompleted(
        callId: 'c',
        report: LlmCallReport(
          providerId: 'p',
          modelId: 'm',
          anchorHash: 'a',
          promptHash: 'pr',
          tokensIn: 1,
          tokensOut: 1,
          retries: 0,
          wallClockMs: 1,
        ),
      ),
    ];

/// Fake `TomBrainSubstrateClient` capturing the subset of calls
/// `SubstrateBridge` makes. Unused members fall through to
/// `noSuchMethod`.
class _FakeSubstrateClient implements TomBrainSubstrateClient {
  LlmCall? lastCall;
  List<LlmStreamEvent> streamEvents = const <LlmStreamEvent>[];

  String? lastEmbedText;
  EmbeddingResult embedResult = EmbeddingResult(
    vec: Vec(Float32List.fromList(<double>[0.0])),
    modelIdentity: const EmbeddingModelIdentity(
      providerId: 'p',
      modelId: 'm',
      dims: 1,
      normalized: true,
    ),
  );

  String? lastSearchQuery;
  WebSearchOptions? lastSearchOptions;
  WebSearchResult searchResult = const WebSearchResult(
    provider: 'p',
    query: 'q',
    hits: <SearchHit>[],
  );

  Uri? lastFetchUrl;
  WebFetchOptions? lastFetchOptions;
  WebFetchResult fetchResult = WebFetchResult(
    url: Uri.parse('https://example.com'),
    status: 200,
    contentType: 'text/plain',
    text: '',
  );

  @override
  Stream<LlmStreamEvent> completeStream(LlmCall call) {
    lastCall = call;
    return Stream<LlmStreamEvent>.fromIterable(streamEvents);
  }

  @override
  Future<EmbeddingResult> embed(String text) async {
    lastEmbedText = text;
    return embedResult;
  }

  @override
  Future<WebSearchResult> webSearch(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async {
    lastSearchQuery = query;
    lastSearchOptions = options;
    return searchResult;
  }

  @override
  Future<WebFetchResult> webFetch(
    Uri url, {
    WebFetchOptions options = WebFetchOptions.empty,
  }) async {
    lastFetchUrl = url;
    lastFetchOptions = options;
    return fetchResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
