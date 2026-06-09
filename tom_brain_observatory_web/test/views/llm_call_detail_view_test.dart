// PT-2.4 (widget) — the LLM-call detail view over a stubbed client. Asserts the
// §4.5 detail renders from the fetched §3.7 dump: provider·model·profile·
// callType header, anchor + prompt hashes verbatim, tokens in/out, retries,
// wall-clock, the wire body, and the answer. Also asserts the not-found state
// (the host has no dump for the link).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tom_brain_observatory_web/src/model/llm_call_detail.dart';
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

LlmCallDetail _detail() => const LlmCallDetail(
      callType: 'assistant_to_user',
      provider: 'local',
      model: 'gemma3:27b',
      profile: 'default',
      anchorHash: 'sha256:aaaa1111',
      promptHash: 'sha256:bbbb2222',
      tokensIn: 1200,
      tokensOut: 340,
      retries: 1,
      wallClockMs: 1850,
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
    home: LlmCallDetailView(client: client, turnId: _turnId, node: _node),
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

  testWidgets('shows a not-found state when the host has no dump', (tester) async {
    await _pump(tester, const StubApiClient());
    expect(find.text('No raw dump for this LLM call.'), findsOneWidget);
  });
}
