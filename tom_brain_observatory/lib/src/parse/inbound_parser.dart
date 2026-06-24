// Parser for the §5.3 raw incoming-prompt file
// (`incoming/<channel>/<turnId>.raw.json`) into an [Inbound]
// (`prompt_tracing.md` § 3.3). The on-disk shape is owned by `tom_brain_run`'s
// `IncomingTrailWriter._rawJson` (read read-only as the contract).

import 'dart:convert';

import '../model/prompt_trace.dart';

/// Parses [jsonText] (the contents of one `incoming/…raw.json`) into an
/// [Inbound], or `null` when it is not a JSON object.
Inbound? parseInbound(String jsonText) {
  final decoded = jsonDecode(jsonText);
  if (decoded is! Map<String, Object?>) return null;
  return _fromMap(decoded);
}

Inbound _fromMap(Map<String, Object?> json) => Inbound(
      channel: json['channel'] as String? ?? 'unknown',
      principalId: json['principalId'] as String? ?? '',
      sessionId: json['sessionId'] as String? ?? '',
      conversationId: json['conversationId'] as String?,
      profile: json['profile'] as String?,
      // The processing-profile axis (§7.2 item 6). Older dumps predate these
      // fields → degrade to the SC-5 byte-compatible default (cognitive,
      // anchored).
      processingProfile: json['processingProfile'] as String? ?? 'default',
      processingMode: json['processingMode'] as String? ?? 'cognitive',
      anchored: json['anchored'] as bool? ?? true,
      persona: json['persona'] as String? ?? '',
      receivedAt:
          DateTime.tryParse(json['receivedAt'] as String? ?? '')?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      text: json['text'] as String? ?? '',
      attachments: (json['attachments'] as List?)?.cast<Object?>() ??
          const <Object?>[],
      rawEnvelope:
          (json['rawEnvelope'] as Map?)?.cast<String, Object?>() ??
              const <String, Object?>{},
    );
