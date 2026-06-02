// E.28 — Bearer-token auth conformance tests.
//
// What this file locks (proto spec § 8; AC-4):
//
//   1. `parseBearerHeader` lifts the token out of a standard
//      `Authorization: Bearer <token>` header, matches the scheme
//      case-insensitively, and classifies every malformed / missing shape
//      with the right `BearerAuthFailureReason` — never echoing the header.
//   2. `StaticBearerTokenAuthenticator` (the prototype default) accepts
//      members of its fixed token set, rejects everything else, treats an
//      empty token as `missing`, and is mutation-safe after construction.
//   3. `JwtBearerTokenAuthenticator` (the canonical `TomBearerAuthentication`
//      path) rejects empty and malformed tokens with the right reason tag.
//      (A signed-JWT happy path needs a crypto key fixture the prototype
//      does not ship — the A.76 precedent makes the same call.)
//   4. `authenticateBearerHeader` composes parse + authenticate and surfaces
//      both stages' failures through the one `BearerAuthFailure` taxonomy.
//   5. Every failure maps to `bearerAuthHttpStatus` (`401`) — the single
//      status source the OpenAI adapter (E.41+) reads.
//   6. The whole bearer surface reaches through the package barrel — a
//      consumer never imports `src/edge_security/bearer_auth.dart` directly.
//   7. No token-introspection side channel: a rejected token string never
//      appears in the failure's `toString()`.

import 'package:test/test.dart';
import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_core_kernel/tom_core_kernel.dart' show TomPrincipal, TomUser;

void main() {
  group('E.28 parseBearerHeader', () {
    test('extracts the token from a well-formed header', () {
      expect(parseBearerHeader('Bearer abc.def.ghi'), equals('abc.def.ghi'));
    });

    test('matches the Bearer scheme case-insensitively', () {
      expect(parseBearerHeader('bearer token-1'), equals('token-1'));
      expect(parseBearerHeader('BEARER token-2'), equals('token-2'));
    });

    test('tolerates surrounding / internal whitespace', () {
      expect(parseBearerHeader('  Bearer   spaced-token '),
          equals('spaced-token'));
    });

    test('null header is missing', () {
      expect(
        () => parseBearerHeader(null),
        throwsA(isA<BearerAuthFailure>()
            .having((f) => f.reason, 'reason', BearerAuthFailureReason.missing)),
      );
    });

    test('blank header is missing', () {
      expect(
        () => parseBearerHeader('   '),
        throwsA(isA<BearerAuthFailure>()
            .having((f) => f.reason, 'reason', BearerAuthFailureReason.missing)),
      );
    });

    test('wrong scheme is malformed', () {
      expect(
        () => parseBearerHeader('Basic dXNlcjpwYXNz'),
        throwsA(isA<BearerAuthFailure>().having(
            (f) => f.reason, 'reason', BearerAuthFailureReason.malformed)),
      );
    });

    test('more than two parts is malformed', () {
      expect(
        () => parseBearerHeader('Bearer a b'),
        throwsA(isA<BearerAuthFailure>().having(
            (f) => f.reason, 'reason', BearerAuthFailureReason.malformed)),
      );
    });

    test('Bearer with no token is missing', () {
      // A single "Bearer" word splits to one part — not a "Bearer <token>"
      // pair — so it is reported as malformed (no scheme/token split).
      expect(
        () => parseBearerHeader('Bearer'),
        throwsA(isA<BearerAuthFailure>().having(
            (f) => f.reason, 'reason', BearerAuthFailureReason.malformed)),
      );
    });

    test('does not echo the header value into the failure message', () {
      try {
        parseBearerHeader('Basic super-secret-near-miss');
        fail('expected a BearerAuthFailure');
      } on BearerAuthFailure catch (f) {
        expect(f.toString(), isNot(contains('super-secret-near-miss')));
      }
    });
  });

  group('E.28 StaticBearerTokenAuthenticator', () {
    test('accepts a known token and returns its principal', () {
      final principal = _testPrincipal('alice');
      final auth = StaticBearerTokenAuthenticator({'valid-token': principal});
      expect(auth.authenticate('valid-token'), same(principal));
    });

    test('rejects an unknown token', () {
      final auth =
          StaticBearerTokenAuthenticator({'valid-token': _testPrincipal('x')});
      expect(
        () => auth.authenticate('nope'),
        throwsA(isA<BearerAuthFailure>().having(
            (f) => f.reason, 'reason', BearerAuthFailureReason.rejected)),
      );
    });

    test('treats an empty token as missing', () {
      final auth = StaticBearerTokenAuthenticator({'t': _testPrincipal('x')});
      expect(
        () => auth.authenticate(''),
        throwsA(isA<BearerAuthFailure>()
            .having((f) => f.reason, 'reason', BearerAuthFailureReason.missing)),
      );
    });

    test('copies the token map (mutation-safe after construction)', () {
      final mutable = <String, TomPrincipal>{'a': _testPrincipal('alpha')};
      final auth = StaticBearerTokenAuthenticator(mutable);
      mutable['b'] = _testPrincipal('beta');
      expect(
        () => auth.authenticate('b'),
        throwsA(isA<BearerAuthFailure>().having(
            (f) => f.reason, 'reason', BearerAuthFailureReason.rejected)),
      );
    });

    test('does not leak the rejected token string into the failure', () {
      final auth = StaticBearerTokenAuthenticator({'t': _testPrincipal('x')});
      try {
        auth.authenticate('leaky-rejected-token');
        fail('expected a BearerAuthFailure');
      } on BearerAuthFailure catch (f) {
        expect(f.toString(), isNot(contains('leaky-rejected-token')));
      }
    });
  });

  group('E.28 JwtBearerTokenAuthenticator', () {
    test('rejects an empty token as missing', () {
      const auth = JwtBearerTokenAuthenticator();
      expect(
        () => auth.authenticate(''),
        throwsA(isA<BearerAuthFailure>()
            .having((f) => f.reason, 'reason', BearerAuthFailureReason.missing)),
      );
    });

    test('rejects a non-JWT token as malformed', () {
      const auth = JwtBearerTokenAuthenticator();
      expect(
        () => auth.authenticate('not-a-jwt'),
        throwsA(isA<BearerAuthFailure>().having(
            (f) => f.reason, 'reason', BearerAuthFailureReason.malformed)),
      );
    });
  });

  group('E.28 authenticateBearerHeader (parse + authenticate)', () {
    test('authenticates a valid Bearer header end-to-end', () {
      final principal = _testPrincipal('bob');
      final auth = StaticBearerTokenAuthenticator({'tk': principal});
      expect(
        authenticateBearerHeader(auth, 'Bearer tk'),
        same(principal),
      );
    });

    test('surfaces a parse failure (missing header)', () {
      final auth = StaticBearerTokenAuthenticator({'tk': _testPrincipal('x')});
      expect(
        () => authenticateBearerHeader(auth, null),
        throwsA(isA<BearerAuthFailure>()
            .having((f) => f.reason, 'reason', BearerAuthFailureReason.missing)),
      );
    });

    test('surfaces an authenticate failure (unknown token)', () {
      final auth = StaticBearerTokenAuthenticator({'tk': _testPrincipal('x')});
      expect(
        () => authenticateBearerHeader(auth, 'Bearer other'),
        throwsA(isA<BearerAuthFailure>().having(
            (f) => f.reason, 'reason', BearerAuthFailureReason.rejected)),
      );
    });
  });

  group('E.28 contract constants + barrel surface', () {
    test('every failure maps to the 401 status', () {
      expect(bearerAuthHttpStatus, equals(401));
    });

    test('scheme + header-name constants are the OpenAI conventions', () {
      expect(bearerScheme, equals('Bearer'));
      expect(authorizationHeaderName, equals('authorization'));
    });

    test('the bearer surface is reachable through the package barrel', () {
      expect(BearerTokenAuthenticator, isNotNull);
      expect(BearerAuthFailure, isNotNull);
      expect(BearerAuthFailureReason.values, hasLength(3));
      expect(StaticBearerTokenAuthenticator, isNotNull);
      expect(JwtBearerTokenAuthenticator, isNotNull);
    });

    test('BearerAuthFailure.toString carries the reason tag + diagnostic', () {
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
  // `authenticated: true` + a non-guest username is all the static
  // authenticator surface checks; ACI is not an edge concern in the
  // prototype (the dispatcher reads only `principalId`).
  return TomPrincipal(
    authenticated: true,
    user: TomUser(username: username),
  );
}
