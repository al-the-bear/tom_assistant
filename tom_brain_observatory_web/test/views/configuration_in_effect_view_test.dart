// PT-2.2 (config) — the configuration-in-effect view (§ 4.3). Asserts the
// compact `role · provider/model · profile` chip, and that tapping it opens the
// read-only detail dialog carrying the §4.5 generation knobs (temperature, max
// output tokens, stop sequences) — `(default)` / `(none)` when a knob is unset.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/prompt_trace.dart';
import 'package:tom_brain_observatory_web/src/views/configuration_in_effect_view.dart';

Future<void> _pump(WidgetTester tester, Configuration configuration) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ConfigurationInEffectView(configuration: configuration),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('chip detail shows the generation knobs when the entry carries them',
      (tester) async {
    await _pump(
      tester,
      const Configuration(
        entries: <ConfigEntry>[
          ConfigEntry(
            role: 'recall_planner',
            provider: 'local',
            model: 'gemma3:27b',
            profile: 'default',
            temperature: 0.2,
            maxOutputTokens: 256,
            stopSequences: <String>['STOP'],
          ),
        ],
        memoryProfile: 'default',
      ),
    );

    // Compact chip label.
    expect(find.textContaining('local/gemma3:27b'), findsOneWidget);

    // Open the read-only detail dialog.
    await tester.tap(find.byType(ActionChip));
    await tester.pumpAndSettle();

    expect(find.textContaining('0.2'), findsWidgets);
    expect(find.textContaining('256 tok'), findsOneWidget);
    expect(find.textContaining('STOP'), findsWidgets);
  });

  testWidgets('chip detail reads (default) / (none) for unset knobs',
      (tester) async {
    await _pump(
      tester,
      const Configuration(
        entries: <ConfigEntry>[
          ConfigEntry(
            role: 'assistant_to_user',
            provider: 'local',
            model: 'gemma3:27b',
            profile: null,
          ),
        ],
        memoryProfile: null,
      ),
    );

    await tester.tap(find.byType(ActionChip));
    await tester.pumpAndSettle();

    expect(find.textContaining('(default)'), findsWidgets);
    expect(find.textContaining('(none)'), findsOneWidget);
  });
}
