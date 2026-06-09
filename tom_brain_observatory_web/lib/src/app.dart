// The observatory app shell. One [MaterialApp] over a [TraceApiClient]; the home
// is the prompt list (§ 4.1, PT-2.1). The client is injected so tests drive a
// stub instead of a live brain; the production wiring (main.dart) injects the
// same-origin HttpTraceApiClient.

import 'package:flutter/material.dart';

import 'api/trace_api_client.dart';
import 'views/prompt_list_view.dart';

/// The root widget.
class ObservatoryApp extends StatelessWidget {
  final TraceApiClient client;

  const ObservatoryApp({super.key, required this.client});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Tom Brain Observatory',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: PromptListView(client: client),
      );
}
