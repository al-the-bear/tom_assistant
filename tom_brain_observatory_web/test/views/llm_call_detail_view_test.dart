// PT-2.4 (widget) — the LLM-call detail view over a stubbed client. Asserts the
// §4.5 detail renders from the fetched §3.7 dump: provider·model·profile·
// callType header, anchor + prompt hashes verbatim, tokens in/out, retries,
// wall-clock, the wire body, and the answer. Also asserts the not-found state
// (the host has no dump for the link).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/llm_call_detail.dart';
import 'package:tom_brain_observatory_web/src/model/llm_call_source.dart';
import 'package:tom_brain_observatory_web/src/model/prompt_trace.dart';
import 'package:tom_brain_observatory_web/src/views/llm_call_detail_view.dart';

import '../support/stub_api_client.dart';

const _turnId = '260101-120000.000001';
const _rawPath = '../../llm/assistant_to_user/260101-120000.000001__02.raw.json';

const _node = LlmCallNode(
  callType: 'assistant_to_user',
  tokensIn: 1200,
  tokensOut: 340,
  rawPath: _rawPath,
);

LlmCallDetail _detail({
  String? roleId,
  double? temperature,
  int? maxOutputTokens,
  List<String> stopSequences = const <String>[],
}) =>
    LlmCallDetail(
      callType: 'assistant_to_user',
      provider: 'local',
      model: 'gemma3:27b',
      profile: 'default',
      roleId: roleId,
      anchorHash: 'sha256:aaaa1111',
      promptHash: 'sha256:bbbb2222',
      tokensIn: 1200,
      tokensOut: 340,
      retries: 1,
      wallClockMs: 1850,
      temperature: temperature,
      maxOutputTokens: maxOutputTokens,
      stopSequences: stopSequences,
      wire: <String, Object?>{
        'messages': <Object?>[
          <String, Object?>{'role': 'system', 'content': 'You are Tom.'},
          <String, Object?>{'role': 'user', 'content': 'hello'},
        ],
      },
      answer: 'Hi — how can I help?',
    );

Future<void> _pump(WidgetTester tester, StubApiClient client) async {
  await tester.pumpWidget(MaterialApp(
    home: LlmCallDetailView(
        client: client, source: LlmCallSource.turn(_turnId), node: _node),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the §4.5 detail from the fetched dump', (tester) async {
    await _pump(
      tester,
      StubApiClient(llmCalls: <String, LlmCallDetail>{_rawPath: _detail()}),
    );

    // provider·model·profile·callType header.
    expect(find.textContaining('local'), findsWidgets);
    expect(find.textContaining('gemma3:27b'), findsOneWidget);
    expect(find.textContaining('assistant_to_user'), findsWidgets);

    // Hashes verbatim.
    expect(find.textContaining('sha256:aaaa1111'), findsOneWidget);
    expect(find.textContaining('sha256:bbbb2222'), findsOneWidget);

    // Metrics.
    expect(find.textContaining('in 1200 tok'), findsOneWidget);
    expect(find.textContaining('out 340 tok'), findsOneWidget);
    expect(find.textContaining('retries 1'), findsOneWidget);
    expect(find.textContaining('wall 1.9s'), findsOneWidget);

    // Wire body (pretty JSON) and answer.
    expect(find.textContaining('"role": "system"'), findsOneWidget);
    expect(find.text('Hi — how can I help?'), findsOneWidget);
  });

  testWidgets('renders the generation settings (§4.5 model-config detail)',
      (tester) async {
    await _pump(
      tester,
      StubApiClient(llmCalls: <String, LlmCallDetail>{
        _rawPath: _detail(
          temperature: 0.35,
          maxOutputTokens: 512,
          stopSequences: <String>['STOP', '###'],
        ),
      }),
    );

    expect(find.textContaining('temp 0.35'), findsOneWidget);
    expect(find.textContaining('max out 512 tok'), findsOneWidget);
    expect(find.textContaining('STOP'), findsWidgets);
    expect(find.textContaining('###'), findsWidgets);
  });

  testWidgets('shows (default) for unset knobs and hides empty stops',
      (tester) async {
    await _pump(
      tester,
      StubApiClient(llmCalls: <String, LlmCallDetail>{_rawPath: _detail()}),
    );

    expect(find.textContaining('temp (default)'), findsOneWidget);
    expect(find.textContaining('max out (default)'), findsOneWidget);
    expect(find.textContaining('stops'), findsNothing);
  });

  testWidgets('shows a not-found state when the host has no dump', (tester) async {
    await _pump(tester, StubApiClient());
    expect(find.text('No raw dump for this LLM call.'), findsOneWidget);
  });

  testWidgets('offers the edit-prompt affordance and opens the editor for a role',
      (tester) async {
    await _pump(
      tester,
      StubApiClient(
        llmCalls: <String, LlmCallDetail>{_rawPath: _detail(roleId: 'analyser')},
        prompts: <String, String>{'analyser/persona': 'persona prose'},
      ),
    );

    expect(find.text('role analyser'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'edit persona'));
    await tester.pumpAndSettle();

    // The prompt-file editor page is now on top, seeded with the override.
    expect(find.text('prompt · analyser.persona'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('offers no edit-prompt affordance when the call carries no role',
      (tester) async {
    await _pump(
      tester,
      StubApiClient(llmCalls: <String, LlmCallDetail>{_rawPath: _detail()}),
    );
    expect(find.textContaining('edit persona'), findsNothing);
  });
}
