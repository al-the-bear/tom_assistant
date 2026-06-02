// E.15 model-id → persona mapping contract test.
//
// Two layers (proto spec § 5.5's deliverable, AC-5):
//
//   1. `OpenAiPersonaMapping` as a pure unit — the three recognised
//      persona-as-model ids (`tom-assistant`, `:terse`, `:verbose`) each map
//      to a `Persona` carrying that id and the prototype substrate role
//      `assistant_to_user`; a `null` or unknown model falls back to
//      `Persona.assistant()` (an unknown model is *not* an error).
//   2. The mapping observed black-box through the adapter handler (Q-E.5.2: a
//      synthesised `shelf.Request` straight to `handler`, no socket): the
//      `model` field of the rendered `chat.completion` body is the resolved
//      persona's canonical id — a recognised id round-trips, an unknown id
//      normalises to `tom-assistant`.
//
// The test deliberately does not anticipate E.16+ (embeddings, models) or
// E.26 (`PersonaResolver` / the `Access.persona` field).

import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// Drives [adapter] with a synthesised request and returns the response.
Future<Response> _call(
  OpenAiHttpSseAdapter adapter,
  String method,
  String path, {
  String? body,
}) async {
  final Request request = Request(
    method,
    Uri.parse('http://localhost$path'),
    body: body,
  );
  return await adapter.handler(request);
}

/// A non-streaming chat body naming [model] (omitted when `null`).
String _chatBody({String? model}) {
  final Map<String, Object?> body = <String, Object?>{
    'stream': false,
    'messages': <Object?>[
      <String, Object?>{'role': 'user', 'content': 'hello'},
    ],
  };
  if (model != null) {
    body['model'] = model;
  }
  return jsonEncode(body);
}

/// An adapter wired with a trivial one-chunk answer source.
OpenAiHttpSseAdapter _adapter() => OpenAiHttpSseAdapter(
      answerStream: (_) => Stream<OutboundChunk>.fromIterable(
        <OutboundChunk>[OutboundChunk(textDelta: 'hi', isFinal: true)],
      ),
    );

/// The decoded `model` field of a rendered completion body.
Future<String?> _bodyModel(Response response) async {
  final Map<String, Object?> body =
      jsonDecode(await response.readAsString()) as Map<String, Object?>;
  return body['model'] as String?;
}

void main() {
  group('OpenAiPersonaMapping (E.15) — pure unit', () {
    test('recognised base model maps to the tom-assistant persona', () {
      final Persona persona = OpenAiPersonaMapping.resolve('tom-assistant');
      expect(persona.personaId, 'tom-assistant');
      expect(persona.substrateRole, Persona.defaultSubstrateRole);
    });

    test('terse variant keeps the variant id, default substrate role', () {
      final Persona persona =
          OpenAiPersonaMapping.resolve('tom-assistant:terse');
      expect(persona.personaId, 'tom-assistant:terse');
      expect(persona.substrateRole, 'assistant_to_user');
    });

    test('verbose variant keeps the variant id, default substrate role', () {
      final Persona persona =
          OpenAiPersonaMapping.resolve('tom-assistant:verbose');
      expect(persona.personaId, 'tom-assistant:verbose');
      expect(persona.substrateRole, 'assistant_to_user');
    });

    test('null model falls back to the default persona', () {
      expect(OpenAiPersonaMapping.resolve(null), Persona.assistant());
    });

    test('unknown model falls back to the default persona (not an error)', () {
      final Persona persona = OpenAiPersonaMapping.resolve('gpt-4o');
      expect(persona, Persona.assistant());
      expect(persona.personaId, Persona.defaultPersonaId);
    });

    test('empty model string falls back to the default persona', () {
      expect(OpenAiPersonaMapping.resolve(''), Persona.assistant());
    });

    test('knownModels lists exactly the three prototype persona ids', () {
      expect(OpenAiPersonaMapping.knownModels, <String>[
        'tom-assistant',
        'tom-assistant:terse',
        'tom-assistant:verbose',
      ]);
    });

    test('isKnown is true only for recognised ids', () {
      expect(OpenAiPersonaMapping.isKnown('tom-assistant'), isTrue);
      expect(OpenAiPersonaMapping.isKnown('tom-assistant:verbose'), isTrue);
      expect(OpenAiPersonaMapping.isKnown('gpt-4o'), isFalse);
      expect(OpenAiPersonaMapping.isKnown(null), isFalse);
    });
  });

  group('OpenAiHttpSseAdapter persona stamping (E.15)', () {
    test('a recognised variant model round-trips into the body model',
        () async {
      final Response response = await _call(
        _adapter(),
        'POST',
        '/v1/chat/completions',
        body: _chatBody(model: 'tom-assistant:verbose'),
      );
      expect(response.statusCode, 200);
      expect(await _bodyModel(response), 'tom-assistant:verbose');
    });

    test('an unknown model is normalised to tom-assistant in the body',
        () async {
      final Response response = await _call(
        _adapter(),
        'POST',
        '/v1/chat/completions',
        body: _chatBody(model: 'gpt-4o'),
      );
      expect(response.statusCode, 200);
      expect(await _bodyModel(response), 'tom-assistant');
    });

    test('an absent model defaults to tom-assistant in the body', () async {
      final Response response = await _call(
        _adapter(),
        'POST',
        '/v1/chat/completions',
        body: _chatBody(),
      );
      expect(response.statusCode, 200);
      expect(await _bodyModel(response), 'tom-assistant');
    });
  });
}
