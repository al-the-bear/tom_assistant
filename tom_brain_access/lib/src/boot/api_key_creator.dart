// ApiKeyCreator — the access-side orchestration behind `/create_api_key`
// (memory_session_profiles.md § 7 / § 13, MSP-7, decision MSPP-42…47).
//
// ── Why this lives in access, over an injected persist closure ───────
//
// MSP-7 has two halves: a runtime-created key must be live *immediately* (the
// next request bearing it authenticates and scopes) and durable (it survives a
// restart). The live half is purely an access-layer concern — it mutates the
// `AccessAssembler`'s identity registry + namespace index, which this package
// owns ([ApiKeyRegistrar]). Only the durable half needs the run layer, because
// only it knows the run-config path on disk.
//
// So unlike the other configuration controllers (`/switch_model`,
// `/cli_server_port`) there is no run-layer *implementation* of the seam — the
// orchestration is here, and the run layer supplies just the one thing it owns:
// an [ApiKeyPersist] closure that appends the key to the run config. That keeps
// the both-or-neither parsing, the mint, the live admission, and the §13
// rollback all in one unit-testable place, with the run dependency reduced to a
// single closure.
//
// ── The order is admit-then-persist, rollback-on-failure (§ 13) ──────
//
// The key is admitted live first, then persisted. If the persist throws (a YAML
// write failure), the live admission is rolled back via [ApiKeyRegistrar.revoke]
// so the running process never authenticates a key that did not survive to disk
// — live == disk is restored, and the caller is told it failed. We admit before
// persisting (rather than the reverse) so that the unit under test exercises the
// rollback path; a persisted-but-not-admitted key would be a worse failure (it
// authenticates only after a restart, silently).

import '../config/api_key_config.dart';
import '../identity/uuid_v4.dart';
import 'api_key_registrar.dart';
import 'telegram_inspectors.dart';

/// Persists a freshly created [ApiKeyConfig] durably (MSP-7) — implemented by
/// the run layer, which owns the run-config path.
///
/// **Must throw on failure.** [ApiKeyCreator] relies on a thrown exception to
/// trigger the §13 rollback; a silent failure would leave a key live but not on
/// disk. The natural `File.writeAsStringSync` / `YamlEditor` failure already
/// throws, so the closure needs no extra error wrapping.
typedef ApiKeyPersist = void Function(ApiKeyConfig config);

/// Mints a fresh key value. Defaults to [uuidV4] (D-6: a `_`-free v4 UUID);
/// injectable so a test can pin the value.
typedef ApiKeyGenerator = String Function();

/// Orchestrates `/create_api_key`: mint → admit live → persist → rollback on
/// failure (MSP-7 / § 13).
///
/// Implements [TelegramApiKeyCreator] so the Telegram edge drives it directly.
/// Holds the live [ApiKeyRegistrar] (the `AccessAssembler`) for the live half
/// and an injected [ApiKeyPersist] for the durable half.
final class ApiKeyCreator implements TelegramApiKeyCreator {
  /// The live-admission seam — admits the new key into the running process's
  /// identity registry + namespace index, and reverses it on a failed persist.
  final ApiKeyRegistrar registrar;

  /// The durable-persist closure the run layer supplies. Must throw on failure.
  final ApiKeyPersist persist;

  /// Mints the key value. Defaults to [uuidV4].
  final ApiKeyGenerator generateKey;

  /// Builds the creator over its live [registrar] and durable [persist].
  ApiKeyCreator({
    required this.registrar,
    required this.persist,
    ApiKeyGenerator? generateKey,
  }) : generateKey = generateKey ?? uuidV4;

  @override
  Future<String> createApiKey({
    String? sessionPrefix,
    String? memoryPrefix,
    String? defaultProfile,
  }) async {
    final String key = generateKey();

    // No prefixes ⇒ the key value itself (plus a trailing `_`) is both the
    // session and the memory prefix (§ 7). Explicit prefixes are used verbatim.
    // The both-or-neither rule is enforced at the edge (MSPP-45); by the time we
    // are called the pair is consistent.
    final String effectiveSession = sessionPrefix ?? '${key}_';
    final String effectiveMemory = memoryPrefix ?? '${key}_';

    final ApiKeyConfig config = ApiKeyConfig(
      key: key,
      sessionPrefix: effectiveSession,
      memoryPrefix: effectiveMemory,
      defaultProfile: defaultProfile,
    );

    // Admit live first so the rollback path is the one exercised on a persist
    // failure (a persisted-but-unadmitted key would authenticate only after a
    // restart — a silent, worse failure).
    registrar.admit(config);

    try {
      persist(config);
    } catch (error) {
      // Durable write failed — roll the live admission back so live == disk
      // (§ 13) and tell the caller it did not stick.
      registrar.revoke(config);
      return 'Could not create the API key: persisting it failed and the '
          'live change was rolled back.\nReason: $error';
    }

    return _successMessage(
      key: key,
      sessionPrefix: effectiveSession,
      memoryPrefix: effectiveMemory,
      defaultProfile: defaultProfile,
    );
  }

  /// Renders the success reply, echoing the secret [key] once (it is never
  /// re-derivable, § 7).
  String _successMessage({
    required String key,
    required String sessionPrefix,
    required String memoryPrefix,
    String? defaultProfile,
  }) {
    final StringBuffer buffer = StringBuffer()
      ..writeln('Created a new API key. It is live now and will survive a '
          'restart. This is the only time the key is shown:')
      ..writeln()
      ..writeln(key)
      ..writeln()
      ..writeln('session prefix: $sessionPrefix')
      ..write('memory prefix: $memoryPrefix');
    if (defaultProfile != null) {
      buffer.write('\ndefault profile: $defaultProfile');
    }
    return buffer.toString();
  }
}
