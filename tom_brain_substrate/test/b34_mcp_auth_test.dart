// B.34 — Bearer-token auth plumbing tests.
//
// The B.8 / B.35 tests in `b08_mcp_client_test.dart` already prove
// the wire-level behaviour (HTTP transport attaches `Authorization:
// Bearer <token>`, 401 surfaces as `McpAuthFailed`, omitted credential
// emits no header). What B.34 adds is the *plumbing layer* between
// `SubstrateConfig` and that wire behaviour:
//
//   1. `McpAuthConfig.none` resolves to a `null` credential — no
//      header path.
//   2. `McpAuthConfig.bearer(token: ...)` resolves to a credential
//      with the exact token. Inline tokens skip disk I/O entirely.
//   3. `McpAuthConfig.bearer(secretRef: '_ai/secrets/mcp.bearer')`
//      reads the file, trims surrounding whitespace, and surfaces
//      the result as the credential's token. Trailing newlines must
//      NOT survive into the Authorization header.
//   4. Bearer config with neither / both of `token` and `secretRef`
//      throws `McpAuthConfigInvalid` at construction time.
//   5. Bearer config on a stdio endpoint throws `McpAuthConfigInvalid`
//      at resolve time (policy override 2: stdio is never
//      authenticated).
//   6. Missing secret file → `McpAuthConfigInvalid` (operator error),
//      not `McpAuthFailed` (which is reserved for runtime 401/403).
//   7. Empty / whitespace-only secret file → `McpAuthConfigInvalid`.
//   8. `McpBearerCredential.toString()` never includes the raw token;
//      a fingerprint substring is the only token-identifying field.
//   9. The fingerprint is deterministic for the same token and
//      different for different tokens.
//  10. Equality and hashCode reflect token identity (so the dispatcher
//      can deduplicate credentials by value).

import 'dart:io' as io;

import 'package:test/test.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  group('B.34 — McpAuthConfig construction invariants', () {
    test('none is a const singleton', () {
      expect(identical(McpAuthConfig.none, McpAuthConfig.none), isTrue);
    });

    test('bearer with neither token nor secretRef throws', () {
      expect(
        () => McpAuthConfig.bearer(),
        throwsA(isA<McpAuthConfigInvalid>()),
      );
    });

    test('bearer with both token and secretRef throws', () {
      expect(
        () => McpAuthConfig.bearer(
          token: 'abc',
          secretRef: '_ai/secrets/mcp.bearer',
        ),
        throwsA(isA<McpAuthConfigInvalid>()),
      );
    });

    test('bearer with empty inline token throws', () {
      expect(
        () => McpAuthConfig.bearer(token: ''),
        throwsA(isA<McpAuthConfigInvalid>()),
      );
    });

    test('bearer with empty secretRef path throws', () {
      expect(
        () => McpAuthConfig.bearer(secretRef: ''),
        throwsA(isA<McpAuthConfigInvalid>()),
      );
    });
  });

  group('B.34 — McpAuthResolver', () {
    late io.Directory tempRoot;

    setUp(() async {
      tempRoot = await io.Directory.systemTemp.createTemp('b34_mcp_auth_');
    });

    tearDown(() async {
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('none resolves to null credential on http transport', () async {
      final resolver = McpAuthResolver(secretsRoot: tempRoot);
      final credential = await resolver.resolve(
        endpointId: 'memory_remote',
        transport: 'http',
        config: McpAuthConfig.none,
      );
      expect(credential, isNull);
    });

    test('none resolves to null credential on stdio transport', () async {
      // Stdio with `none` must succeed — only stdio + bearer is the
      // rejected pair.
      final resolver = McpAuthResolver(secretsRoot: tempRoot);
      final credential = await resolver.resolve(
        endpointId: 'memory',
        transport: 'stdio',
        config: McpAuthConfig.none,
      );
      expect(credential, isNull);
    });

    test('inline bearer token resolves to a credential with exact token',
        () async {
      final resolver = McpAuthResolver(secretsRoot: tempRoot);
      final credential = await resolver.resolve(
        endpointId: 'memory_remote',
        transport: 'http',
        config: McpAuthConfig.bearer(token: 'secret-token-XYZ'),
      );
      expect(credential, isNotNull);
      expect(credential!.token, 'secret-token-XYZ');
    });

    test('secretRef bearer reads token from file and trims whitespace',
        () async {
      final secretsDir =
          io.Directory('${tempRoot.path}/_ai/secrets')..createSync(recursive: true);
      final secretFile = io.File('${secretsDir.path}/mcp.bearer');
      // Deliberately include surrounding whitespace + trailing newline
      // so the trim invariant is actually exercised.
      await secretFile.writeAsString('   secret-from-file-ABC\n');

      final resolver = McpAuthResolver(secretsRoot: tempRoot);
      final credential = await resolver.resolve(
        endpointId: 'memory_remote',
        transport: 'http',
        config: McpAuthConfig.bearer(secretRef: '_ai/secrets/mcp.bearer'),
      );

      expect(credential, isNotNull);
      expect(credential!.token, 'secret-from-file-ABC');
    });

    test('stdio endpoint with bearer config is rejected as invalid',
        () async {
      final resolver = McpAuthResolver(secretsRoot: tempRoot);

      Object? captured;
      try {
        await resolver.resolve(
          endpointId: 'memory',
          transport: 'stdio',
          config: McpAuthConfig.bearer(token: 'whatever'),
        );
      } on McpAuthConfigInvalid catch (error) {
        captured = error;
      }

      expect(captured, isA<McpAuthConfigInvalid>());
      expect((captured as McpAuthConfigInvalid).endpointId, 'memory');
      expect(
        captured.message,
        contains('Auth is HTTP-only'),
      );
    });

    test('channel endpoint with bearer config is rejected as invalid',
        () async {
      // Channel transport is the in-isolate fixture seam (B.8). It is
      // even more clearly "no auth" than stdio — make sure the
      // resolver agrees.
      final resolver = McpAuthResolver(secretsRoot: tempRoot);
      expect(
        () => resolver.resolve(
          endpointId: 'memory_channel',
          transport: 'channel',
          config: McpAuthConfig.bearer(token: 'whatever'),
        ),
        throwsA(isA<McpAuthConfigInvalid>()),
      );
    });

    test('missing secret file surfaces as McpAuthConfigInvalid', () async {
      final resolver = McpAuthResolver(secretsRoot: tempRoot);

      Object? captured;
      try {
        await resolver.resolve(
          endpointId: 'memory_remote',
          transport: 'http',
          config: McpAuthConfig.bearer(
            secretRef: '_ai/secrets/does-not-exist.bearer',
          ),
        );
      } on Object catch (error) {
        captured = error;
      }

      expect(captured, isA<McpAuthConfigInvalid>());
      expect((captured as McpAuthConfigInvalid).endpointId, 'memory_remote');
      expect(captured.message, contains('could not be read'));
    });

    test('empty (whitespace-only) secret file is rejected', () async {
      final secretsDir =
          io.Directory('${tempRoot.path}/_ai/secrets')..createSync(recursive: true);
      final secretFile = io.File('${secretsDir.path}/empty.bearer');
      await secretFile.writeAsString('   \n\n  \n');

      final resolver = McpAuthResolver(secretsRoot: tempRoot);

      Object? captured;
      try {
        await resolver.resolve(
          endpointId: 'memory_remote',
          transport: 'http',
          config: McpAuthConfig.bearer(secretRef: '_ai/secrets/empty.bearer'),
        );
      } on Object catch (error) {
        captured = error;
      }

      expect(captured, isA<McpAuthConfigInvalid>());
      expect(
        (captured as McpAuthConfigInvalid).message,
        contains('empty token'),
      );
    });

    test('absolute secretRef paths bypass secretsRoot', () async {
      final absDir = await tempRoot.createTemp('abs_');
      final absFile = io.File('${absDir.path}/abs.bearer');
      await absFile.writeAsString('absolute-token-DEF\n');

      // Construct a resolver whose secretsRoot is NOT the directory
      // holding the absolute file, to prove the absolute path is
      // honoured as-is.
      final unrelatedRoot =
          await io.Directory.systemTemp.createTemp('b34_unrelated_');
      addTearDown(() async {
        if (unrelatedRoot.existsSync()) {
          await unrelatedRoot.delete(recursive: true);
        }
      });
      final resolver = McpAuthResolver(secretsRoot: unrelatedRoot);

      final credential = await resolver.resolve(
        endpointId: 'memory_remote',
        transport: 'http',
        config: McpAuthConfig.bearer(secretRef: absFile.path),
      );

      expect(credential, isNotNull);
      expect(credential!.token, 'absolute-token-DEF');
    });

    test('custom readFile hook is honoured (hermetic resolver)', () async {
      // The hermetic-loader hook is what later tests / config loaders
      // will use to keep the resolver off real disk during unit tests.
      final resolver = McpAuthResolver(
        secretsRoot: tempRoot,
        readFile: (file) async => 'injected-token-GHI\n',
      );

      final credential = await resolver.resolve(
        endpointId: 'memory_remote',
        transport: 'http',
        config: McpAuthConfig.bearer(secretRef: '_ai/secrets/anything'),
      );

      expect(credential, isNotNull);
      expect(credential!.token, 'injected-token-GHI');
    });
  });

  group('B.34 — McpBearerCredential redaction & identity', () {
    test('toString does not include the raw token', () {
      const credential = McpBearerCredential('VERY-SECRET-TOKEN-12345');
      final rendered = credential.toString();
      expect(rendered, isNot(contains('VERY-SECRET-TOKEN-12345')));
      expect(rendered, startsWith('McpBearerCredential('));
      expect(rendered, contains('fingerprint:'));
    });

    test('fingerprint is deterministic for the same token', () {
      const a = McpBearerCredential('stable-token');
      const b = McpBearerCredential('stable-token');
      expect(a.fingerprint, equals(b.fingerprint));
      // Sanity: 8 hex characters.
      expect(a.fingerprint, hasLength(8));
      expect(RegExp(r'^[0-9a-f]{8}$').hasMatch(a.fingerprint), isTrue);
    });

    test('different tokens have different fingerprints', () {
      const a = McpBearerCredential('token-one');
      const b = McpBearerCredential('token-two');
      expect(a.fingerprint, isNot(equals(b.fingerprint)));
    });

    test('equality is by token, hashCode follows token', () {
      const a = McpBearerCredential('matching-token');
      const b = McpBearerCredential('matching-token');
      const c = McpBearerCredential('different');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('fingerprint never returns the token even for short tokens', () {
      // Edge case: a token shorter than the fingerprint must still
      // be redacted by the hash (no "if token short, print it" path).
      const credential = McpBearerCredential('a');
      expect(credential.toString(), isNot(contains(': a')));
      expect(credential.fingerprint, hasLength(8));
    });
  });
}
