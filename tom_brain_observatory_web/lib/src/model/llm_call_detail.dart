// The client DTO for one substrate call's full detail (§ 3.7), decoded from the
// verbatim raw dump served by `GET /api/llm` (PT-2.4). The run-tree's
// [LlmCallNode] carries only the link + token counts; this is the body behind
// it: provider/model/profile/role, the anchor + prompt hashes (verbatim, so two
// identical scaffolds are visibly identical, § 4.5), retries, wall-clock, the
// full wire prompt body, and the returned answer.

import 'dart:convert';

class LlmCallDetail {
  final String callType;
  final String? provider;
  final String? model;
  final String? profile;
  final String? anchorHash;
  final String? promptHash;
  final int? tokensIn;
  final int? tokensOut;
  final int? retries;
  final int? wallClockMs;
  final Object? wire;
  final String? answer;

  const LlmCallDetail({
    required this.callType,
    required this.provider,
    required this.model,
    required this.profile,
    required this.anchorHash,
    required this.promptHash,
    required this.tokensIn,
    required this.tokensOut,
    required this.retries,
    required this.wallClockMs,
    required this.wire,
    required this.answer,
  });

  factory LlmCallDetail.fromJson(Map<String, dynamic> json) => LlmCallDetail(
        callType: json['callType'] as String? ?? '(unknown)',
        provider: json['provider'] as String?,
        model: json['model'] as String?,
        profile: (json['profile'] ?? json['memoryProfile']) as String?,
        anchorHash: json['anchorHash'] as String?,
        promptHash: json['promptHash'] as String?,
        tokensIn: json['tokensIn'] as int?,
        tokensOut: json['tokensOut'] as int?,
        retries: json['retries'] as int?,
        wallClockMs: json['wallClockMs'] as int?,
        wire: json['wire'],
        answer: json['answer'] as String?,
      );

  /// The wire body as indented JSON for the scrollable/copyable block (§ 4.5).
  String get wirePretty =>
      wire == null ? '(no wire body captured)' : const JsonEncoder.withIndent('  ').convert(wire);
}
