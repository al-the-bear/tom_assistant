// IncomingTrailWriter — the §5.3 raw incoming-prompt trail
// (`tom_brain_logging.md` §10 build-order step #7).
//
// For every admitted inbound request the access layer hands one
// `IncomingTrailRecord` (built at the admission seam where channel + turnId +
// the full envelope + the resolved identity/session/persona all coexist,
// pre-dispatch). This writer turns each into one
// `incoming/<channel>/<turnId>.raw.json` carrying the §5.3 fields (turnId,
// channel, receivedAt, principalId, sessionId, conversationId, profile,
// persona, text, attachments, rawEnvelope).
//
// Secret handling (§5.3 "rawEnvelope redacted of secrets"): the bearer / bot
// credential never reaches the record — it is a separate admission argument,
// never a field of `InboundRequest` — so this writer's redaction of
// secret-looking `rawEnvelope` keys is a defence-in-depth net over the
// channel-specific metadata, not the primary guard.
//
// Scope boundary (§10): this writer owns *only* the raw file. The
// `incomingPerChannelCap` count cap (§8) is enforced by the step #10
// `TrailJanitor`, not here — consistent with `LlmTrailWriter`, which likewise
// does not prune its own tree.
//
// Best-effort and non-blocking (§9): a trail-write failure must never fail a
// turn, so every effect is guarded and a failure is swallowed.

import 'dart:convert';
import 'dart:io';

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart'
    show IncomingTrailRecord;

/// Substrings (matched case-insensitively) that mark a `rawEnvelope` key as
/// carrying a secret. A matching key's value is replaced with [_redactedMarker]
/// before serialisation (§5.3).
const List<String> _secretKeyMarkers = <String>[
  'authorization',
  'token',
  'bearer',
  'secret',
  'password',
  'cookie',
  'api-key',
  'api_key',
  'apikey',
];

const String _redactedMarker = '[redacted]';

/// Writes the §5.3 raw incoming-prompt dump for each admitted inbound request
/// (`tom_brain_logging.md` §10 step #7).
final class IncomingTrailWriter {
  /// The trail tree root (`trail.root`). Raw dumps land under
  /// `<root>/incoming/`.
  final Directory root;

  /// Builds a writer rooted at [root].
  IncomingTrailWriter({required this.root});

  /// Writes the §5.3 raw dump for [record]. Best-effort: any failure is
  /// swallowed so a trail write never breaks the turn (§9).
  void write(IncomingTrailRecord record) {
    try {
      final file = File(
        '${root.path}/incoming/${record.channel.wireName}/'
        '${record.turnId.value}.raw.json',
      );
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(_rawJson(record)),
      );
    } catch (_) {
      // Trail writing is non-essential; never let it surface into the turn.
    }
  }

  /// Builds the §5.3 JSON map in the spec's field order. Optional fields
  /// (`conversationId`, `profile`) are omitted when absent.
  Map<String, Object?> _rawJson(IncomingTrailRecord record) => <String, Object?>{
        'turnId': record.turnId.value,
        'channel': record.channel.wireName,
        'receivedAt': record.receivedAt.toIso8601String(),
        'principalId': record.principalId,
        'sessionId': record.sessionId,
        if (record.conversationId != null)
          'conversationId': record.conversationId,
        if (record.profile != null) 'profile': record.profile,
        'persona': record.persona,
        'text': record.text,
        'attachments': record.attachments,
        'rawEnvelope': _redact(record.rawEnvelope),
      };

  /// Returns a copy of [envelope] with every secret-looking key's value
  /// replaced by [_redactedMarker] (§5.3). Non-secret keys are preserved
  /// verbatim.
  Map<String, Object?> _redact(Map<String, Object?> envelope) =>
      envelope.map((key, value) =>
          MapEntry(key, _isSecretKey(key) ? _redactedMarker : value));

  bool _isSecretKey(String key) {
    final lower = key.toLowerCase();
    return _secretKeyMarkers.any(lower.contains);
  }
}
