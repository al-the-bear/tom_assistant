// A.76 — Bearer-token authentication conformance tests.
//
// What this file locks:
//
//   1. Anonymous mode is the default: a server constructed without an
//      `authenticator` parameter accepts `initialize` with no bearer
//      token, and exposes `principal == null` afterwards.
//   2. When an authenticator is supplied, `initialize` rejects a
//      request that carries no `_meta.tomBrainBearerToken`. The
//      rejection arrives as a JSON-RPC error so the client cannot
//      proceed to call tools.
//   3. When an authenticator is supplied, a wrong / unknown token
//      rejects the handshake. The error message exposes the failure
//      *reason tag* but not the token itself or the internal
//      [BearerAuthFailure.message] (defence-in-depth against
//      token-introspection side channels).
//   4. A valid token accepts the handshake and caches the resolved
//      [TomPrincipal] on `server.principal` for A.77 tool handlers to
//      read.
//   5. The bearer-auth surface is exported through the package
//      barrel — consumers do not need to reach into
//      `src/mcp_server/bearer_auth.dart` directly.
//   6. The two shipped [BearerTokenAuthenticator] implementations
//      behave per their contract in isolation:
//        - [StaticBearerTokenAuthenticator] accepts members of the
//          fixed map and rejects everything else.
//        - [JwtBearerTokenAuthenticator] rejects empty tokens and
//          malformed JWTs with the right reason tag. (A full
//          happy-path JWT test would require a signing-key fixture
//          the prototype does not yet ship; the JWT path is
//          exercised indirectly via the server integration tests
//          using `StaticBearerTokenAuthenticator` for the
//          accepted-token shape.)
//
// What this file does NOT lock:
//
//   - JWT signing-key configuration. The crypto layer is out of
//     scope for A.76; the JWT authenticator is wired through the
//     spec-canonical path (`TomBearerAuthentication.convert…`) but
//     a real signed-JWT happy path needs key setup that lands in a
//     later step.
//   - Per-tool authorisation. A.77 will add role / entitlement
//     checks against `server.principal`.
//
// Test driving pattern mirrors `a75_mcp_server_skeleton_test.dart`'s
// in-memory channel pair (mirrors dart_mcp's own `TestEnvironment`
// helper). For the bearer-aware cases we extend the `_TestEnv`
// constructor with an optional authenticator and accept an optional
// `bearerToken` on the handshake helper.

import 'dart:async';

import 'package:dart_mcp/client.dart' as mcp_client;
import 'package:dart_mcp/server.dart' as mcp_server;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:tom_core_kernel/tom_core_kernel.dart'
    show TomPrincipal, TomUser;

void main() {
  group('A.76 bearer-auth — anonymous mode (no authenticator)', () {
    test('default constructor leaves the server in anonymous mode', () async {
      final env = _TestEnv();
      addTearDown(env.shutdown);

      final result = await env.initializeHandshake();
      // Successful handshake reuses the A.75 invariants.
      expect(result.serverInfo.name, equals('tom_brain_memory'));
      // Anonymous mode: no principal cached.
      expect(env.server.principal, isNull);
      expect(env.server.authenticator, isNull);
    });

    test('handshake succeeds even when the client passes a bearer token', () async {
      // No authenticator => the token is simply ignored. This prevents a
      // misconfigured deployment from silently rejecting a client that
      // tries to authenticate against an anonymous server.
      final env = _TestEnv();
      addTearDown(env.shutdown);

      final result = await env.initializeHandshake(bearerToken: 'ignored');
      expect(result.serverInfo.name, equals('tom_brain_memory'));
      expect(env.server.principal, isNull);
    });
  });

  group('A.76 bearer-auth — required-token mode', () {
    test('initialize without a token is rejected', () async {
      final env = _TestEnv(
        authenticator: StaticBearerTokenAuthenticator({
          'valid-token': _testPrincipal('alice'),
        }),
      );
      addTearDown(env.shutdown);

      await expectLater(
        env.initializeHandshake(),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'toString',
            allOf(
              contains('Bearer authentication failed'),
              contains(BearerAuthFailureReason.missing.name),
              // The internal `BearerAuthFailure.message` text must not
              // leak — only the stable reason tag is on the wire.
              isNot(contains('initialize _meta')),
            ),
          ),
        ),
      );
      expect(env.server.principal, isNull);
    });

    test('initialize with an unknown token is rejected', () async {
      final env = _TestEnv(
        authenticator: StaticBearerTokenAuthenticator({
          'valid-token': _testPrincipal('alice'),
        }),
      );
      addTearDown(env.shutdown);

      await expectLater(
        env.initializeHandshake(bearerToken: 'wrong-token'),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'toString',
            allOf(
              contains('Bearer authentication failed'),
              contains(BearerAuthFailureReason.rejected.name),
              // No token-introspection side channel: the rejected
              // token string itself must not appear in the wire
              // error.
              isNot(contains('wrong-token')),
              isNot(contains('shared-secret set')),
            ),
          ),
        ),
      );
      expect(env.server.principal, isNull);
    });

    test('initialize with a valid token caches the principal', () async {
      final principal = _testPrincipal('alice');
      final env = _TestEnv(
        authenticator: StaticBearerTokenAuthenticator({
          'valid-token': principal,
        }),
      );
      addTearDown(env.shutdown);

      final result = await env.initializeHandshake(bearerToken: 'valid-token');
      expect(result.serverInfo.name, equals('tom_brain_memory'));
      // Principal cached for A.77 tool handlers.
      expect(env.server.principal, same(principal));
      expect(env.server.principal!.user.username, equals('alice'));
      expect(env.server.principal!.authenticated, isTrue);
    });
  });

  group('A.76 bearer-auth — barrel exports', () {
    test('BearerTokenAuthenticator + failure types reach via the package barrel', () {
      // Identifier-existence check: importing only
      // `package:tom_brain_memory/tom_brain_memory.dart` must be
      // sufficient to reference every public symbol the operator
      // needs to wire authentication.
      expect(BearerTokenAuthenticator, isNotNull);
      expect(BearerAuthFailure, isNotNull);
      expect(BearerAuthFailureReason.values, hasLength(3));
      expect(StaticBearerTokenAuthenticator, isNotNull);
      expect(JwtBearerTokenAuthenticator, isNotNull);
      expect(bearerTokenMetaKey, equals('tomBrainBearerToken'));
    });
  });

  group('A.76 bearer-auth — authenticator implementations', () {
    test('StaticBearerTokenAuthenticator accepts known tokens', () {
      final principal = _testPrincipal('bob');
      final auth = StaticBearerTokenAuthenticator({
        'a-known-token': principal,
      });
      expect(auth.authenticate('a-known-token'), same(principal));
    });

    test('StaticBearerTokenAuthenticator rejects empty tokens as missing', () {
      final auth = StaticBearerTokenAuthenticator({'token': _testPrincipal('x')});
      expect(
        () => auth.authenticate(''),
        throwsA(
          isA<BearerAuthFailure>().having(
            (f) => f.reason,
            'reason',
            BearerAuthFailureReason.missing,
          ),
        ),
      );
    });

    test('StaticBearerTokenAuthenticator rejects unknown tokens', () {
      final auth = StaticBearerTokenAuthenticator({'token': _testPrincipal('x')});
      expect(
        () => auth.authenticate('not-in-map'),
        throwsA(
          isA<BearerAuthFailure>().having(
            (f) => f.reason,
            'reason',
            BearerAuthFailureReason.rejected,
          ),
        ),
      );
    });

    test('StaticBearerTokenAuthenticator copies the input map (mutation-safe)', () {
      final mutable = <String, TomPrincipal>{
        'token-a': _testPrincipal('alpha'),
      };
      final auth = StaticBearerTokenAuthenticator(mutable);
      // Mutating the original map after construction must not affect
      // the authenticator's view of the world.
      mutable['token-b'] = _testPrincipal('beta');
      expect(
        () => auth.authenticate('token-b'),
        throwsA(
          isA<BearerAuthFailure>().having(
            (f) => f.reason,
            'reason',
            BearerAuthFailureReason.rejected,
          ),
        ),
      );
    });

    test('JwtBearerTokenAuthenticator rejects empty tokens as missing', () {
      const auth = JwtBearerTokenAuthenticator();
      expect(
        () => auth.authenticate(''),
        throwsA(
          isA<BearerAuthFailure>().having(
            (f) => f.reason,
            'reason',
            BearerAuthFailureReason.missing,
          ),
        ),
      );
    });

    test('JwtBearerTokenAuthenticator rejects malformed JWTs', () {
      const auth = JwtBearerTokenAuthenticator();
      expect(
        () => auth.authenticate('not-a-jwt'),
        throwsA(
          isA<BearerAuthFailure>().having(
            (f) => f.reason,
            'reason',
            BearerAuthFailureReason.malformed,
          ),
        ),
      );
    });

    test('BearerAuthFailure.toString carries the reason tag for telemetry', () {
      const failure = BearerAuthFailure(
        BearerAuthFailureReason.rejected,
        'sample diagnostic',
      );
      expect(failure.toString(), contains('rejected'));
      expect(failure.toString(), contains('sample diagnostic'));
    });
  });
}

TomPrincipal _testPrincipal(String username) {
  // Build a principal with `authenticated: true` and a non-guest
  // username — that's all the authenticator surface checks. The
  // static authenticator does not look at ACI; tool-level
  // authorisation (A.77) will.
  return TomPrincipal(
    authenticated: true,
    user: TomUser(username: username),
  );
}

/// A minimal in-isolate test environment mirroring `dart_mcp`'s own
/// `TestEnvironment` helper and the A.75 test harness.
///
/// Extended over A.75's `_TestEnv` by accepting an optional
/// [authenticator] and an optional `bearerToken` on the handshake
/// helper. The token is placed under `_meta.tomBrainBearerToken` so
/// the server's `initialize` override picks it up.
class _TestEnv {
  final clientController = StreamController<String>();
  final serverController = StreamController<String>();

  late final StreamChannel<String> clientChannel;
  late final StreamChannel<String> serverChannel;
  late final mcp_client.MCPClient client;
  late final TomBrainMemoryMcpServer server;
  late final mcp_client.ServerConnection serverConnection;

  _TestEnv({BearerTokenAuthenticator<TomPrincipal>? authenticator}) {
    clientChannel = StreamChannel<String>.withCloseGuarantee(
      serverController.stream,
      clientController.sink,
    );
    serverChannel = StreamChannel<String>.withCloseGuarantee(
      clientController.stream,
      serverController.sink,
    );
    client = _TestMcpClient();
    server = TomBrainMemoryMcpServer(
      serverChannel,
      authenticator: authenticator,
    );
    serverConnection = client.connectServer(clientChannel);
  }

  Future<mcp_server.InitializeResult> initializeHandshake({
    mcp_server.ProtocolVersion protocolVersion =
        mcp_server.ProtocolVersion.latestSupported,
    String? bearerToken,
  }) async {
    final meta = bearerToken == null
        ? null
        : mcp_server.MetaWithProgressToken.fromMap({
            bearerTokenMetaKey: bearerToken,
          });
    final result = await serverConnection.initialize(
      mcp_server.InitializeRequest(
        protocolVersion: protocolVersion,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
        meta: meta,
      ),
    );
    if (result.protocolVersion?.isSupported == true) {
      serverConnection.notifyInitialized(mcp_server.InitializedNotification());
      await server.initialized;
    }
    return result;
  }

  Future<void> shutdown() async {
    await client.shutdown();
    await server.shutdown();
  }
}

base class _TestMcpClient extends mcp_client.MCPClient {
  _TestMcpClient()
    : super(
        mcp_client.Implementation(name: 'a76-test-client', version: '0.0.1'),
      );
}
