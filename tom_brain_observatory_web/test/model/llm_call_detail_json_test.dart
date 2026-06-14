// PT-2.4 (model) — `LlmCallDetail.fromJson` decodes the §3.7 raw LLM dump,
// including the §4.5 model-config knobs (temperature, maxOutputTokens,
// stopSequences) the brain's trail writer now emits beside provider/model.
// Pins that present knobs decode verbatim, that absent knobs decode to
// `null` / an empty stop set (never throw), and that an int temperature
// widens to a double.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/llm_call_detail.dart';

void main() {
  group('LlmCallDetail.fromJson (§3.7 raw dump)', () {
    test('decodes the generation settings when present', () {
      final detail = LlmCallDetail.fromJson(jsonDecode('''
        {
          "callType": "assistant_to_user",
          "provider": "local",
          "model": "gemma3:27b",
          "temperature": 0.35,
          "maxOutputTokens": 512,
          "stopSequences": ["STOP", "###"],
          "answer": "hi"
        }
      ''') as Map<String, dynamic>);

      expect(detail.temperature, 0.35);
      expect(detail.maxOutputTokens, 512);
      expect(detail.stopSequences, <String>['STOP', '###']);
    });

    test('absent knobs decode to null / empty stop set', () {
      final detail = LlmCallDetail.fromJson(jsonDecode('''
        {"callType": "analyser", "provider": "local", "model": "gemma3:27b"}
      ''') as Map<String, dynamic>);

      expect(detail.temperature, isNull);
      expect(detail.maxOutputTokens, isNull);
      expect(detail.stopSequences, isEmpty);
    });

    test('an integer temperature widens to a double', () {
      final detail = LlmCallDetail.fromJson(jsonDecode('''
        {"callType": "analyser", "temperature": 1}
      ''') as Map<String, dynamic>);

      expect(detail.temperature, 1.0);
    });
  });
}
