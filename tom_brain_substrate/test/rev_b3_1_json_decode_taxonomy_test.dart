// Review fix B.3.1 — unwrapped `jsonDecode` must not escape the closed
// failure taxonomy.
//
// `prototype_review_result.md` § B.3.1 flagged that the wire HTTP
// clients called `jsonDecode` on a raw 2xx response body with no guard.
// A backend (or an intermediary proxy) that answers `200` with a
// non-JSON body — a proxy error page, a truncated stream — made
// `jsonDecode` throw a bare `FormatException` that carried no
// provider/url context and was *not* one of the classes
// `LlmFailureClassifier` recognises (§ 5.4), so it escaped the router's
// route-walk uncaught.
//
// These tests assert the decode failure now surfaces as the provider's
// typed wire exception (`OllamaHttpException` / `OpenAiHttpException`,
// both of which the classifier maps) carrying the endpoint, and that
// the web JSON helper surfaces a `WebHttpTransportException` carrying
// the URL. They drive the production `Default…HttpClient`s through a
// `MockClient` so no network is touched.

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.3.1 / Ollama wire client — malformed JSON joins the taxonomy', () {
    test('chat() on a 200 with a non-JSON body throws OllamaHttpException',
        () async {
      final client = DefaultOllamaHttpClient(
        client: MockClient((_) async => http.Response('<html>oops</html>', 200)),
      );
      await expectLater(
        () => client.chat(
          baseUri: Uri.parse('http://localhost:11434'),
          model: 'gemma3:27b',
          messages: const [OllamaMessage(role: 'user', content: 'hi')],
          options: const OllamaGenerationOptions(),
        ),
        throwsA(
          isA<OllamaHttpException>()
              .having((e) => e.endpoint.path, 'endpoint', contains('/api/chat'))
              .having((e) => e.body, 'body', contains('Malformed JSON')),
        ),
      );
      client.close();
    });

    test('embed() on a 200 with a non-JSON body throws OllamaHttpException',
        () async {
      final client = DefaultOllamaHttpClient(
        client: MockClient((_) async => http.Response('not json', 200)),
      );
      await expectLater(
        () => client.embed(
          baseUri: Uri.parse('http://localhost:11434'),
          model: 'nomic-embed-text',
          prompt: 'hi',
        ),
        throwsA(isA<OllamaHttpException>()),
      );
      client.close();
    });

    test('listTags() on a 200 with a non-JSON body throws OllamaHttpException',
        () async {
      final client = DefaultOllamaHttpClient(
        client: MockClient((_) async => http.Response('{bad', 200)),
      );
      await expectLater(
        () => client.listTags(baseUri: Uri.parse('http://localhost:11434')),
        throwsA(isA<OllamaHttpException>()),
      );
      client.close();
    });
  });

  group('B.3.1 / OpenAI wire client — malformed JSON joins the taxonomy', () {
    test('chat() on a 200 with a non-JSON body throws OpenAiHttpException',
        () async {
      final client = DefaultOpenAiHttpClient(
        client: MockClient((_) async => http.Response('<html>oops</html>', 200)),
      );
      await expectLater(
        () => client.chat(
          baseUri: Uri.parse('https://api.openai.com/'),
          model: 'gpt-4o-mini',
          messages: const [OpenAiMessage(role: 'user', content: 'hi')],
          options: const OpenAiGenerationOptions(),
          apiKey: 'sk-test',
        ),
        throwsA(
          isA<OpenAiHttpException>()
              .having((e) => e.body, 'body', contains('Malformed JSON')),
        ),
      );
      client.close();
    });

    test('embed() on a 200 with a non-JSON body throws OpenAiHttpException',
        () async {
      final client = DefaultOpenAiHttpClient(
        client: MockClient((_) async => http.Response('nope', 200)),
      );
      await expectLater(
        () => client.embed(
          baseUri: Uri.parse('https://api.openai.com/'),
          model: 'text-embedding-3-small',
          input: const ['hi'],
          apiKey: 'sk-test',
        ),
        throwsA(isA<OpenAiHttpException>()),
      );
      client.close();
    });

    test('listModels() on a 200 with a non-JSON body throws OpenAiHttpException',
        () async {
      final client = DefaultOpenAiHttpClient(
        client: MockClient((_) async => http.Response('}{', 200)),
      );
      await expectLater(
        () => client.listModels(
          baseUri: Uri.parse('https://api.openai.com/'),
          apiKey: 'sk-test',
        ),
        throwsA(isA<OpenAiHttpException>()),
      );
      client.close();
    });
  });

  group('B.3.1 / classifier recognises the wrapped decode failure', () {
    test('a malformed-JSON OllamaHttpException classifies (not unhandled)', () {
      const classifier = LlmFailureClassifier();
      final cls = classifier.classify(
        OllamaHttpException(
          statusCode: 200,
          body: 'Malformed JSON (JSON object expected): ...',
          endpoint: Uri.parse('http://localhost:11434/api/chat'),
        ),
      );
      // A 200 with a malformed body is conservatively `unknown`, which
      // the router treats as overloaded-for-routing (retry once, rotate)
      // — the point is that it is *classified*, not escaping uncaught.
      expect(cls, LlmFailureClass.unknown);
    });
  });

  group('B.3.1 / web JSON helper carries URL context', () {
    test('decodeJsonBody on a malformed body throws WebHttpTransportException',
        () {
      final response = WebHttpResponse(
        statusCode: 200,
        body: '<html>not json</html>',
        headers: const {},
        url: Uri.parse('https://search.example/api'),
      );
      expect(
        () => decodeJsonBody(response),
        throwsA(
          isA<WebHttpTransportException>()
              .having((e) => e.url.host, 'url', 'search.example'),
        ),
      );
    });
  });
}
