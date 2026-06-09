// The observatory app shell. One [MaterialApp] over a [TraceApiClient] (Module 1
// — Prompt Tracing) and a [MemoryApiClient] (Module 2 — Memory Monitoring); the
// home is the prompt list (§ 4.1, PT-2.1), from which a toolbar action opens the
// memory home (§ 5, PT-6). Both clients are injected so tests drive stubs
// instead of a live brain; the production wiring (main.dart) injects the
// same-origin HTTP clients.

import 'package:flutter/material.dart';

import 'api/memory_api_client.dart';
import 'api/trace_api_client.dart';
import 'views/prompt_list_view.dart';

/// The root widget.
class ObservatoryApp extends StatelessWidget {
  final TraceApiClient client;
  final MemoryApiClient memoryClient;

  const ObservatoryApp({
    super.key,
    required this.client,
    required this.memoryClient,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tom Brain Observatory',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: PromptListView(client: client, memoryClient: memoryClient),
      );
}
