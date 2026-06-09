// E.53 — OpenAI API conformance suite (black-box, over the socket).
//
// Plan step E.53 (verbatim): "API conformance tests — OpenAI: a black-box test
// suite using a real HTTP client (`tom_core_kernel`'s `HttpClient`) against the
// running process. Cover the streaming + non-streaming + embeddings + models
// routes. Compare wire formats against captured fixtures from the real OpenAI
// API (where format-compatible)."
//
// First substep of `## E.11 — Phase-end review and extraction` that asserts
// *behaviour* over the wire. Where E.18 (`openai_wire_format_conformance_test`)
// proves the in-process adapter contract by driving its `handler` directly,
// E.53 proves the *running process*: it stands the whole cognition up
// (`standUpSmokeProcess`), then drives it over a real TCP socket with
// `tom_core_kernel`'s HTTP client (`TomServerChannel` / `TomServerCall`) — the
// same path a real OpenAI client takes. The two guard AC-6 ("OpenAI wire-format
// fidelity") at two layers; E.53 is the over-the-socket one.
//
// ── The captured-fixture conformance contract ────────────────────────────
//
// `test/fixtures/openai/*.json` are canonical response shapes from the real
// OpenAI API (the OpenAI API reference). The prototype emits a documented
// *subset* of those shapes (E.51 / Q-E.51.2: it omits `system_fingerprint`,
// `logprobs`, the streaming first-chunk `delta.role`, the models `permission`/
// `root`/`parent`, …). So the comparison is "format-compatible subset", encoded
// in [conformanceDivergences]:
//
//   * every key the prototype emits MUST exist in the captured fixture (the
//     prototype must never invent a field foreign to the OpenAI wire format);
//   * a shared key's value must have the same JSON type as the fixture's;
//   * the `object` discriminator must match the fixture value exactly;
//   * a `null` fixture value is a type wildcard (OpenAI's nullable fields:
//     `logprobs`, `finish_reason`, `param`, `refusal`, …);
//   * keys present in the fixture but absent from the prototype's body are
//     allowed — that is the documented subset.
//
// This makes "compare wire formats against captured fixtures" a real check (a
// foreign field, a wrong type, or a wrong discriminator trips it) while
// honouring the prototype's deliberate omissions. The omissions themselves are
// pinned as explicit *absence* assertions so a future addition is a deliberate,
// test-tripping change.
//
// `embeddings` is the plan's explicit "where format-compatible" carve-out: the
// running cognition edge returns `501 not_implemented` for `POST /v1/embeddings`
// (embeddings are a substrate passthrough, not a cognition — Q-E.2.2 /
// Q-E.51.1). So the embeddings *success* fixture is not comparable against the
// live edge; E.53 instead proves the route is covered (the `501` + an OpenAI
// error envelope that DOES conform to the captured error fixture) and documents
// the carve-out.

import 'dart:convert';
import 'dart:io';

import 'package:tom_basics/tom_basics.dart' show TomPlatformUtils;
import 'package:tom_basics_console/tom_basics_console.dart'
    show TomStandalonePlatformUtils;
import 'package:tom_brain_access/tom_brain_access.dart'
    show OpenAiPersonaMapping;
import 'package:tom_brain_smoke_prototype/tom_brain_smoke_prototype.dart';
import 'package:tom_core_kernel/tom_core_kernel.dart'
    show TomServerCall, TomServerCallLoad, TomServerCallSpecs, TomServerChannel;
import 'package:test/test.dart';

// --- The real-HTTP-client transport (tom_core_kernel) --------------------

/// The raw result of one over-the-socket call: status, the `content-type`
/// header, and the raw (undecoded) body. SSE is a text wire, JSON a structured
/// one, so the body is returned verbatim and parsed per-test.
typedef _HttpResult = ({int statusCode, String? contentType, String body});

/// Issues a `GET` against the running process through `tom_core_kernel`'s HTTP
/// client and returns the status, `content-type`, and raw body.
Future<_HttpResult> _get(int port, String path) async {
  final TomServerChannel channel = TomServerChannel('127.0.0.1', port);
  try {
    final TomServerCall call = channel.prepareCall(
      TomServerCallSpecs(
        'GET',
        Uri.parse('http://127.0.0.1:$port$path'),
        includeBearerAuthentication: false,
      ),
    );
    call.send(TomServerCallLoad());
    final String body = await call.readAsString(utf8);
    return (
      statusCode: await call.getResponseStatusCode(),
      contentType: (await call.getResponseHeaders())['content-type'],
      body: body,
    );
  } finally {
    channel.close();
  }
}

/// Issues a `POST` of [jsonBody] against the running process through
/// `tom_core_kernel`'s HTTP client, carrying the bearer [token], and returns the
/// status, `content-type`, and raw body.
Future<_HttpResult> _postJson(
  int port,
  String path,
  Object jsonBody, {
  required String token,
}) async {
  final TomServerChannel channel = TomServerChannel('127.0.0.1', port);
  try {
    final TomServerCall call = channel.prepareCall(
      TomServerCallSpecs(
        'POST',
        Uri.parse('http://127.0.0.1:$port$path'),
        includeBearerAuthentication: false,
        headers: <String, String>{
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      ),
    );
    call.send(
      TomServerCallLoad(
        stringBody: jsonEncode(jsonBody),
        contentType: 'application/json',
        encoding: utf8,
      ),
    );
    final String body = await call.readAsString(utf8);
    return (
      statusCode: await call.getResponseStatusCode(),
      contentType: (await call.getResponseHeaders())['content-type'],
      body: body,
    );
  } finally {
    channel.close();
  }
}

// --- Captured-fixture loading + the conformance comparator ---------------

/// Loads and decodes a captured OpenAI fixture from `test/fixtures/openai/`.
Map<String, Object?> _loadFixture(String name) {
  final File file = File('test/fixtures/openai/$name');
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

/// Records every way [actual] diverges from the captured OpenAI [fixture] under
/// the format-compatible-subset contract (see the file header). Returns an empty
/// list when [actual] is a conformant subset of [fixture].
List<String> conformanceDivergences(
  Object? actual,
  Object? fixture, [
  String path = r'$',
]) {
  // A null fixture value is a type wildcard (OpenAI nullable fields).
  if (fixture == null) return const <String>[];

  if (fixture is Map<String, Object?>) {
    if (actual is! Map<String, Object?>) {
      return <String>['$path: expected an object, got ${actual.runtimeType}'];
    }
    final List<String> divergences = <String>[];
    for (final MapEntry<String, Object?> entry in actual.entries) {
      final String key = entry.key;
      final String childPath = '$path.$key';
      if (!fixture.containsKey(key)) {
        divergences.add(
          '$childPath: key is not part of the captured OpenAI wire format',
        );
        continue;
      }
      // The `object` discriminator must match the captured value exactly.
      if (key == 'object' &&
          entry.value is String &&
          fixture[key] is String &&
          entry.value != fixture[key]) {
        divergences.add(
          '$childPath: object discriminator "${entry.value}" != '
          'captured "${fixture[key]}"',
        );
        continue;
      }
      divergences.addAll(
        conformanceDivergences(entry.value, fixture[key], childPath),
      );
    }
    return divergences;
  }

  if (fixture is List<Object?>) {
    if (actual is! List<Object?>) {
      return <String>['$path: expected a list, got ${actual.runtimeType}'];
    }
    if (fixture.isEmpty) return const <String>[];
    // The fixture's first element is the per-item schema.
    final Object? schema = fixture.first;
    final List<String> divergences = <String>[];
    for (int i = 0; i < actual.length; i++) {
      divergences.addAll(
        conformanceDivergences(actual[i], schema, '$path[$i]'),
      );
    }
    return divergences;
  }

  // Scalars: the JSON types must be compatible (num covers int + double).
  final bool compatible = switch (fixture) {
    String() => actual is String,
    bool() => actual is bool,
    num() => actual is num,
    _ => false,
  };
  return compatible
      ? const <String>[]
      : <String>['$path: type ${actual.runtimeType} != ${fixture.runtimeType}'];
}

// --- Request bodies + the canned answer ----------------------------------

/// The chunked answer the stub substrate streams; its concatenation is the
/// answer text every chat body must carry.
const List<String> _answerChunks = <String>['Back up by ', 'rsyncing nightly.'];
const String _answerText = 'Back up by rsyncing nightly.';

Map<String, Object?> _chatBody(String prompt, {required bool stream}) =>
    <String, Object?>{
      'model': 'tom-assistant',
      'messages': <Object?>[
        <String, Object?>{'role': 'user', 'content': prompt},
      ],
      'stream': stream,
    };

/// Splits an SSE body into its ordered, non-empty frame lines.
List<String> _frames(String body) => body
    .split('\n\n')
    .map((String s) => s.trim())
    .where((String s) => s.isNotEmpty)
    .toList();

/// Decodes one `data: {…}` frame's JSON payload, or `null` for `data: [DONE]`.
Map<String, Object?>? _payload(String frame) {
  if (!frame.startsWith('data:')) return null;
  final String data = frame.substring('data:'.length).trim();
  if (data == '[DONE]') return null;
  return jsonDecode(data) as Map<String, Object?>;
}

void main() {
  // `tom_core_kernel`'s HTTP client (`TomServerChannel`) resolves its socket
  // implementation through `TomPlatformUtils.current.httpClient()`. The default
  // in a bare test process is the fallback that throws `UnimplementedError`, so
  // register the standalone (`dart:io` / `IOClient`) platform before any call.
  setUpAll(() {
    TomPlatformUtils.setCurrentPlatform(TomStandalonePlatformUtils());
  });

  // --- The conformance comparator's own contract -------------------------
  //
  // The comparator is the load-bearing assertion of this suite, so it is unit
  // tested before it is trusted against the live process.
  group('E.53 conformance comparator', () {
    test('a strict subset of the fixture conforms', () {
      final Map<String, Object?> fixture = <String, Object?>{
        'object': 'chat.completion',
        'id': 'x',
        'system_fingerprint': 'fp',
        'choices': <Object?>[
          <String, Object?>{'index': 0, 'logprobs': null}
        ],
      };
      final Map<String, Object?> actual = <String, Object?>{
        'object': 'chat.completion',
        'id': 'chatcmpl-1',
        'choices': <Object?>[
          <String, Object?>{'index': 0}
        ],
      };
      expect(conformanceDivergences(actual, fixture), isEmpty);
    });

    test('a foreign field trips the comparator', () {
      expect(
        conformanceDivergences(
          <String, Object?>{'object': 'list', 'not_openai': 1},
          <String, Object?>{'object': 'list'},
        ),
        isNotEmpty,
      );
    });

    test('a wrong object discriminator trips the comparator', () {
      expect(
        conformanceDivergences(
          <String, Object?>{'object': 'chat.completion'},
          <String, Object?>{'object': 'text_completion'},
        ),
        isNotEmpty,
      );
    });

    test('a wrong scalar type trips the comparator', () {
      expect(
        conformanceDivergences(
          <String, Object?>{'created': 'not-an-int'},
          <String, Object?>{'created': 1741570283},
        ),
        isNotEmpty,
      );
    });

    test('a null fixture value is a type wildcard', () {
      expect(
        conformanceDivergences(
          <String, Object?>{'finish_reason': 'stop'},
          <String, Object?>{'finish_reason': null},
        ),
        isEmpty,
      );
    });
  });

  // --- POST /v1/chat/completions (non-streaming) -------------------------
  group('E.53 non-streaming chat.completion vs the captured fixture', () {
    late SmokeProcess smoke;
    late Map<String, Object?> fixture;

    setUp(() async {
      fixture = _loadFixture('chat_completion.json');
      smoke = await standUpSmokeProcess(
        substrate: SmokeSubstrate()
          ..answerChunks = List<String>.of(_answerChunks),
      );
    });

    tearDown(() async {
      await smoke.stop();
    });

    test('the live body is a format-compatible subset of the OpenAI shape',
        () async {
      final _HttpResult result = await _postJson(
        smoke.port,
        '/v1/chat/completions',
        _chatBody('how do I automate backups?', stream: false),
        token: smokeBearerToken,
      );

      expect(result.statusCode, 200);
      expect(result.contentType, isNotNull);
      expect(result.contentType!.startsWith('application/json'), isTrue);

      final Map<String, Object?> body =
          jsonDecode(result.body) as Map<String, Object?>;

      // The captured-fixture conformance check (the heart of E.53).
      expect(
        conformanceDivergences(body, fixture),
        isEmpty,
        reason: 'the live chat.completion body must be a format-compatible '
            'subset of the captured OpenAI fixture',
      );

      // Discriminator + the carried answer.
      expect(body['object'], 'chat.completion');
      final Map<String, Object?> choice =
          (body['choices'] as List<Object?>).first as Map<String, Object?>;
      final Map<String, Object?> message =
          choice['message'] as Map<String, Object?>;
      expect(message['role'], 'assistant');
      expect(message['content'], _answerText);
      expect(choice['finish_reason'], 'stop');
    });

    test('the documented OpenAI gaps stay absent (E.51 / Q-E.51.2)', () async {
      final _HttpResult result = await _postJson(
        smoke.port,
        '/v1/chat/completions',
        _chatBody('how do I automate backups?', stream: false),
        token: smokeBearerToken,
      );
      final Map<String, Object?> body =
          jsonDecode(result.body) as Map<String, Object?>;

      // The fixture carries these; the prototype deliberately does not. Pinned
      // so a future addition is a deliberate, test-tripping change.
      expect(body.containsKey('system_fingerprint'), isFalse);
      final Map<String, Object?> choice =
          (body['choices'] as List<Object?>).first as Map<String, Object?>;
      expect(choice.containsKey('logprobs'), isFalse);
    });
  });

  // --- POST /v1/chat/completions (streaming) -----------------------------
  group('E.53 streaming chat.completion.chunk vs the captured fixture', () {
    late SmokeProcess smoke;
    late Map<String, Object?> chunkFixture;

    setUp(() async {
      chunkFixture = _loadFixture('chat_completion_chunk.json');
      smoke = await standUpSmokeProcess(
        substrate: SmokeSubstrate()
          ..answerChunks = List<String>.of(_answerChunks),
      );
    });

    tearDown(() async {
      await smoke.stop();
    });

    test('every data frame is a format-compatible chat.completion.chunk in '
        'order, terminated by [DONE]', () async {
      final _HttpResult result = await _postJson(
        smoke.port,
        '/v1/chat/completions',
        _chatBody('how do I automate backups?', stream: true),
        token: smokeBearerToken,
      );

      expect(result.statusCode, 200);
      expect(result.contentType, isNotNull);
      expect(result.contentType!.startsWith('text/event-stream'), isTrue);

      final List<String> frames = _frames(result.body);
      expect(frames.length, greaterThanOrEqualTo(2));
      expect(frames.last, 'data: [DONE]');

      final StringBuffer content = StringBuffer();
      final List<Map<String, Object?>> chunks = <Map<String, Object?>>[];
      for (final String frame in frames) {
        final Map<String, Object?>? payload = _payload(frame);
        if (payload == null) continue;
        chunks.add(payload);
        // Each chunk conforms to the captured streaming-chunk fixture.
        expect(
          conformanceDivergences(payload, chunkFixture),
          isEmpty,
          reason: 'each SSE chunk must be a format-compatible subset of the '
              'captured chat.completion.chunk fixture',
        );
        expect(payload['object'], 'chat.completion.chunk');
        final Map<String, Object?> delta =
            (payload['choices'] as List<Object?>).first
                as Map<String, Object?>;
        final Object? deltaContent =
            (delta['delta'] as Map<String, Object?>)['content'];
        if (deltaContent is String) content.write(deltaContent);
      }
      expect(chunks, isNotEmpty);
      // Ordering: the deltas concatenate (in arrival order) to the answer.
      expect(content.toString(), _answerText);
      // One stable completion id across every chunk.
      expect(
        chunks.map((Map<String, Object?> c) => c['id'] as String).toSet(),
        hasLength(1),
      );
    });

    test('the documented streaming gaps stay absent (E.51 / Q-E.51.2)',
        () async {
      final _HttpResult result = await _postJson(
        smoke.port,
        '/v1/chat/completions',
        _chatBody('how do I automate backups?', stream: true),
        token: smokeBearerToken,
      );
      final Map<String, Object?> firstChunk = _frames(result.body)
          .map(_payload)
          .firstWhere((Map<String, Object?>? p) => p != null)!;

      expect(firstChunk.containsKey('system_fingerprint'), isFalse);
      final Map<String, Object?> choice =
          (firstChunk['choices'] as List<Object?>).first
              as Map<String, Object?>;
      expect(choice.containsKey('logprobs'), isFalse);
      // The first-chunk `delta.role` gap is *closed* (Q-E.51.2 / current_todos
      // #33): the opening frame announces `role:"assistant"` like the real
      // OpenAI stream. (Later frames omit it — pinned by the access-package
      // sentinel `e51_spec_section_attestation_test.dart`.)
      expect((choice['delta'] as Map<String, Object?>)['role'], 'assistant');
    });
  });

  // --- GET /v1/models ----------------------------------------------------
  group('E.53 models list vs the captured fixture', () {
    late SmokeProcess smoke;
    late Map<String, Object?> fixture;

    setUp(() async {
      fixture = _loadFixture('models_list.json');
      smoke = await standUpSmokeProcess();
    });

    tearDown(() async {
      await smoke.stop();
    });

    test('the live models list is a format-compatible subset of the OpenAI '
        'shape', () async {
      final _HttpResult result = await _get(smoke.port, '/v1/models');

      expect(result.statusCode, 200);
      final Map<String, Object?> body =
          jsonDecode(result.body) as Map<String, Object?>;

      expect(
        conformanceDivergences(body, fixture),
        isEmpty,
        reason: 'the live models list must be a format-compatible subset of '
            'the captured OpenAI models-list fixture',
      );

      expect(body['object'], 'list');
      // The listed ids are exactly the prototype's persona vocabulary.
      final List<Object?> data = body['data'] as List<Object?>;
      expect(
        data.map((Object? e) => (e as Map<String, Object?>)['id']).toList(),
        OpenAiPersonaMapping.knownModels,
      );
    });

    test('the documented models gaps stay absent (E.51 / Q-E.51.2)', () async {
      final _HttpResult result = await _get(smoke.port, '/v1/models');
      final Map<String, Object?> body =
          jsonDecode(result.body) as Map<String, Object?>;
      final Map<String, Object?> item =
          (body['data'] as List<Object?>).first as Map<String, Object?>;
      // OpenAI model items carry these; the prototype's do not.
      expect(item.containsKey('permission'), isFalse);
      expect(item.containsKey('root'), isFalse);
      expect(item.containsKey('parent'), isFalse);
    });
  });

  // --- POST /v1/embeddings (the "where format-compatible" carve-out) ------
  group('E.53 embeddings route — the not-format-compatible carve-out', () {
    late SmokeProcess smoke;
    late Map<String, Object?> errorFixture;

    setUp(() async {
      errorFixture = _loadFixture('error_envelope.json');
      smoke = await standUpSmokeProcess();
    });

    tearDown(() async {
      await smoke.stop();
    });

    test('the live cognition edge does not serve embeddings — 501 with an '
        'OpenAI error envelope', () async {
      // The captured embeddings *success* fixture (embedding_list.json) is the
      // shape a substrate-backed passthrough emits; the running cognition edge
      // deliberately does not serve it (embeddings go direct to substrate —
      // Q-E.2.2 / Q-E.51.1). So this route is the plan's "where format-
      // compatible" carve-out: it is covered by proving the 501 + a conformant
      // OpenAI error envelope, not by comparing a success body.
      final _HttpResult result = await _postJson(
        smoke.port,
        '/v1/embeddings',
        <String, Object?>{
          'input': <Object?>['alpha', 'beta'],
          'model': 'text-embedding-3-small',
        },
        token: smokeBearerToken,
      );

      expect(result.statusCode, 501);
      final Map<String, Object?> body =
          jsonDecode(result.body) as Map<String, Object?>;

      // The error envelope IS format-compatible — it conforms to the captured
      // OpenAI error fixture.
      expect(conformanceDivergences(body, errorFixture), isEmpty);
      final Map<String, Object?> error = body['error'] as Map<String, Object?>;
      expect(error['type'], 'not_implemented');
      expect(error['code'], 'not_implemented');
    });

    test('the captured embeddings success fixture is a well-formed OpenAI '
        'list (reference only)', () {
      // Documents the substrate-passthrough format the live edge does not serve.
      final Map<String, Object?> embeddingFixture =
          _loadFixture('embedding_list.json');
      expect(embeddingFixture['object'], 'list');
      final Map<String, Object?> item =
          (embeddingFixture['data'] as List<Object?>).first
              as Map<String, Object?>;
      expect(item['object'], 'embedding');
      expect(item['embedding'], isA<List<Object?>>());
    });
  });

  // --- The OpenAI error envelope (401) -----------------------------------
  group('E.53 error envelope vs the captured fixture', () {
    late SmokeProcess smoke;
    late Map<String, Object?> errorFixture;

    setUp(() async {
      errorFixture = _loadFixture('error_envelope.json');
      smoke = await standUpSmokeProcess(
        substrate: SmokeSubstrate()
          ..answerChunks = List<String>.of(_answerChunks),
      );
    });

    tearDown(() async {
      await smoke.stop();
    });

    test('an unbound bearer token is a 401 whose envelope conforms to the '
        'captured OpenAI error fixture', () async {
      final _HttpResult result = await _postJson(
        smoke.port,
        '/v1/chat/completions',
        _chatBody('how do I automate backups?', stream: false),
        token: 'not-the-smoke-token',
      );

      expect(result.statusCode, 401);
      expect(result.contentType, isNotNull);
      expect(result.contentType!.startsWith('application/json'), isTrue);

      final Map<String, Object?> body =
          jsonDecode(result.body) as Map<String, Object?>;
      expect(conformanceDivergences(body, errorFixture), isEmpty);

      final Map<String, Object?> error = body['error'] as Map<String, Object?>;
      // The OpenAI error envelope carries exactly message/type/param/code.
      expect(error.keys.toSet(), <String>{'message', 'type', 'param', 'code'});
      expect(error['type'], 'invalid_request_error');
      expect(error['code'], 'identity_unresolved');
    });
  });
}
