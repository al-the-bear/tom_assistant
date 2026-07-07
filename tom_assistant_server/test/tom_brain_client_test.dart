// TomBrainClient — wire-format unit tests (UB6).
//
// These pin the OpenAI request/response contract the client speaks against a
// `package:http` MockClient — no socket, no brain, always reproducible. The
// companion `tom_brain_gateway_e2e_test.dart` proves the same client against a
// REAL stood-up brain gateway.
//
// Pins: the buffered request shape (model + messages + stream=false, bearer
// header, /v1/chat/completions route) and its parse; the ask() single-message
// convenience; the SSE streaming parse (delta concatenation, [DONE] terminator);
// the non-2xx → TomBrainClientException boundary; the apiPrefix normalisation.

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tom_assistant_server/tom_assistant_server.dart';
import 'package:test/test.dart';

void main() {
  group('TomBrainClient buffered complete', () {
    test('builds the OpenAI request and parses choices[0].message', () async {
      late http.Request seen;
      final client = TomBrainClient(
        baseUrl: Uri.parse('http://brain.test:8080'),
        bearerToken: 'tok-1',
        model: 'tom-assistant',
        httpClient: MockClient((http.Request request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'object': 'chat.completion',
              'id': 'chatcmpl-abc',
              'model': 'tom-assistant',
              'choices': <Object?>[
                <String, Object?>{
                  'index': 0,
                  'message': <String, Object?>{
                    'role': 'assistant',
                    'content': 'hello from the brain',
                  },
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
            headers: <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      );
      addTearDown(client.close);

      final completion = await client.ask('hi');

      // Request contract.
      expect(seen.method, 'POST');
      expect(seen.url.toString(),
          'http://brain.test:8080/v1/chat/completions');
      expect(seen.headers['authorization'], 'Bearer tok-1');
      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['model'], 'tom-assistant');
      expect(body['stream'], isFalse);
      expect(body['messages'], <Object?>[
        <String, Object?>{'role': 'user', 'content': 'hi'},
      ]);

      // Parsed answer.
      expect(completion.content, 'hello from the brain');
      expect(completion.finishReason, 'stop');
      expect(completion.model, 'tom-assistant');
      expect(completion.id, 'chatcmpl-abc');
    });

    test('sends a multi-message conversation verbatim', () async {
      late http.Request seen;
      final client = TomBrainClient(
        baseUrl: Uri.parse('http://brain.test:8080'),
        bearerToken: 'tok-1',
        httpClient: MockClient((http.Request request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'message': <String, Object?>{
                    'role': 'assistant',
                    'content': 'ok',
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);

      await client.complete(<TomBrainMessage>[
        const TomBrainMessage.system('be terse'),
        const TomBrainMessage.user('ping'),
      ]);

      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['messages'], <Object?>[
        <String, Object?>{'role': 'system', 'content': 'be terse'},
        <String, Object?>{'role': 'user', 'content': 'ping'},
      ]);
    });

    test('a non-2xx status surfaces a TomBrainClientException', () async {
      final client = TomBrainClient(
        baseUrl: Uri.parse('http://brain.test:8080'),
        bearerToken: 'bad',
        httpClient: MockClient((http.Request request) async => http.Response(
              jsonEncode(<String, Object?>{
                'error': <String, Object?>{'code': 'identity_unresolved'},
              }),
              401,
            )),
      );
      addTearDown(client.close);

      await expectLater(
        client.ask('hi'),
        throwsA(isA<TomBrainClientException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.body, 'body', contains('identity_unresolved'))),
      );
    });
  });

  group('TomBrainClient streaming', () {
    test('concatenates SSE delta content and stops at [DONE]', () async {
      final client = TomBrainClient(
        baseUrl: Uri.parse('http://brain.test:8080'),
        bearerToken: 'tok-1',
        httpClient: MockClient.streaming(
            (http.BaseRequest request, http.ByteStream body) async {
          const String sse = 'data: {"choices":[{"delta":{"content":"Back up "}}]}\n\n'
              'data: {"choices":[{"delta":{"content":"nightly."},"finish_reason":"stop"}]}\n\n'
              'data: [DONE]\n\n';
          return http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode(sse)),
            200,
            headers: <String, String>{
              'content-type': 'text/event-stream; charset=utf-8',
            },
          );
        }),
      );
      addTearDown(client.close);

      final deltas = await client.askStream('how do I back up?').toList();
      expect(deltas, <String>['Back up ', 'nightly.']);
      expect(deltas.join(), 'Back up nightly.');
    });

    test('a non-2xx status surfaces a TomBrainClientException before deltas',
        () async {
      final client = TomBrainClient(
        baseUrl: Uri.parse('http://brain.test:8080'),
        bearerToken: 'bad',
        httpClient: MockClient.streaming(
            (http.BaseRequest request, http.ByteStream body) async =>
                http.StreamedResponse(
                  Stream<List<int>>.value(
                      utf8.encode('{"error":{"code":"identity_unresolved"}}')),
                  401,
                )),
      );
      addTearDown(client.close);

      await expectLater(
        client.askStream('hi').toList(),
        throwsA(isA<TomBrainClientException>()
            .having((e) => e.statusCode, 'statusCode', 401)),
      );
    });
  });

  group('TomBrainClient endpoint building', () {
    test('normalises a trailing-slash baseUrl and a bare apiPrefix', () async {
      late Uri seenUrl;
      final client = TomBrainClient(
        baseUrl: Uri.parse('http://brain.test:8080/'),
        bearerToken: 'tok-1',
        apiPrefix: 'v2/',
        httpClient: MockClient((http.Request request) async {
          seenUrl = request.url;
          return http.Response(
            jsonEncode(<String, Object?>{
              'choices': <Object?>[
                <String, Object?>{
                  'message': <String, Object?>{'content': 'ok'},
                },
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);

      await client.ask('hi');
      expect(seenUrl.toString(), 'http://brain.test:8080/v2/chat/completions');
    });
  });
}
