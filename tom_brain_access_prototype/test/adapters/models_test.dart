// E.17 OpenAI `GET /v1/models` listing — the models-list renderer and the
// adapter route.
//
// Two layers, mirroring the E.14 / E.15 / E.16 tests:
//   1. Pure unit cases over `ModelsResponseRenderer` — no socket, no adapter.
//   2. Black-box cases through the adapter handler (Q-E.5.2: a synthesised
//      `shelf.Request` straight to `handler`, no socket). Unlike chat /
//      embeddings the models route needs no injected source, so a bare
//      adapter answers a real `200` (never `501`).

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:test/test.dart';

/// Drives [adapter] with a synthesised GET and returns the response.
Future<Response> _get(OpenAiHttpSseAdapter adapter, String path) async {
  final Request request = Request('GET', Uri.parse('http://localhost$path'));
  return await adapter.handler(request);
}

void main() {
  group('ModelsResponseRenderer (E.17 — pure)', () {
    test('defaults to the recognised persona vocabulary in order', () {
      const renderer = ModelsResponseRenderer();
      final Map<String, Object?> body = renderer.bodyMap();
      expect(body['object'], 'list');
      final List<Object?> data = body['data'] as List<Object?>;
      final List<Object?> ids = <Object?>[
        for (final Object? item in data)
          (item as Map<String, Object?>)['id'],
      ];
      expect(ids, OpenAiPersonaMapping.knownModels);
      expect(ids, <String>[
        'tom-assistant',
        'tom-assistant:terse',
        'tom-assistant:verbose',
      ]);
    });

    test('each item carries the OpenAI model shape', () {
      const renderer = ModelsResponseRenderer();
      final List<Object?> data =
          renderer.bodyMap()['data'] as List<Object?>;
      for (final Object? item in data) {
        final Map<String, Object?> model = item as Map<String, Object?>;
        expect(model['object'], 'model');
        expect(model['owned_by'], 'tom-brain');
        expect(model['created'], ModelsResponseRenderer.created);
        expect(model['id'], isA<String>());
      }
    });

    test('created is a fixed deterministic constant (no wall-clock read)', () {
      const renderer = ModelsResponseRenderer();
      final String first = renderer.bodyJson();
      final String second = renderer.bodyJson();
      // Same bytes on every call — important for the wire-format fixtures.
      expect(first, second);
    });

    test('an explicit model list is rendered as given', () {
      const renderer = ModelsResponseRenderer();
      final List<Object?> data = (renderer.bodyMap(
        models: <String>['only-one'],
      )['data'] as List<Object?>);
      expect(data.length, 1);
      expect((data[0] as Map<String, Object?>)['id'], 'only-one');
    });
  });

  group('OpenAiHttpSseAdapter /v1/models (E.17 — black-box)', () {
    test('GET /v1/models → 200 OpenAI models-list body (no source needed)',
        () async {
      // A bare adapter — no chat / embedding source — still answers 200,
      // because the persona vocabulary is static and adapter-owned.
      final OpenAiHttpSseAdapter adapter = OpenAiHttpSseAdapter();
      final Response response = await _get(adapter, '/v1/models');

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));
      final Map<String, Object?> body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect(body['object'], 'list');
      final List<Object?> data = body['data'] as List<Object?>;
      expect(data.length, OpenAiPersonaMapping.knownModels.length);
      final List<Object?> ids = <Object?>[
        for (final Object? item in data)
          (item as Map<String, Object?>)['id'],
      ];
      expect(ids, OpenAiPersonaMapping.knownModels);
      expect((data.first as Map<String, Object?>)['object'], 'model');
      expect((data.first as Map<String, Object?>)['owned_by'], 'tom-brain');
    });
  });
}
