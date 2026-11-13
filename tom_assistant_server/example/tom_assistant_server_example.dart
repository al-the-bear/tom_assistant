// Ask a running Tom Brain through its OpenAI-format gateway.
//
// Run it against a stood-up brain:
//   TOM_BRAIN_URL=http://127.0.0.1:8080 TOM_BRAIN_TOKEN=... dart run example/tom_assistant_server_example.dart
import 'dart:io';

import 'package:tom_assistant_server/tom_assistant_server.dart';

Future<void> main() async {
  final client = TomBrainClient(
    baseUrl: Uri.parse(Platform.environment['TOM_BRAIN_URL'] ?? 'http://127.0.0.1:8080'),
    bearerToken: Platform.environment['TOM_BRAIN_TOKEN'] ?? '',
  );
  try {
    // One question, the whole answer at once.
    final answer = await client.ask('What is on my list for today?');
    print('${answer.model ?? 'tom-brain'}: ${answer.content}');

    // The same, streamed as it is written.
    await for (final chunk in client.askStream('And tomorrow?')) {
      stdout.write(chunk);
    }
    stdout.writeln();
  } on TomBrainClientException catch (e) {
    stderr.writeln('The gateway refused: $e');
  } finally {
    client.close();
  }
}
