// Tests for `AgentRegistration` (Plan step A.70).
//
// Surface under test:
//
//   * Construction validation: agent name + procedure id non-empty;
//     scope tags well-formed.
//   * Defensive immutability of the two scope sets.
//   * `allowsRead` / `allowsWrite` matching:
//       - exact match
//       - per-kind wildcard (`node:*`, `edge:*`, `stack:*`)
//       - global wildcard (`*`)
//       - explicit deny when nothing matches
//   * The three helper builders (`nodeScope`, `edgeScope`,
//     `stackScope`) produce the exact strings the matcher consumes.
//   * Value equality, hash, toString contract.

import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

void main() {
  final budget = WriteBudget(maxNodes: 10, maxEdges: 10, maxStackEntries: 10);

  group('AgentRegistration construction', () {
    test('canonical construction yields the supplied fields', () {
      final reg = AgentRegistration(
        agentName: 'extractor',
        procedureId: 'dream_extract_v1',
        defaultBudget: budget,
        readScopes: {'node:Event'},
        writeScopes: {'node:Claim', 'edge:derived_from'},
      );
      expect(reg.agentName, equals('extractor'));
      expect(reg.procedureId, equals('dream_extract_v1'));
      expect(reg.defaultBudget, equals(budget));
      expect(reg.readScopes, equals({'node:Event'}));
      expect(reg.writeScopes, equals({'node:Claim', 'edge:derived_from'}));
    });

    test('empty agentName is rejected', () {
      expect(
        () => AgentRegistration(
          agentName: '',
          procedureId: 'p1',
          defaultBudget: budget,
          readScopes: const {},
          writeScopes: const {},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('empty procedureId is rejected', () {
      expect(
        () => AgentRegistration(
          agentName: 'a',
          procedureId: '',
          defaultBudget: budget,
          readScopes: const {},
          writeScopes: const {},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('empty scope tag in readScopes is rejected', () {
      expect(
        () => AgentRegistration(
          agentName: 'a',
          procedureId: 'p',
          defaultBudget: budget,
          readScopes: const {''},
          writeScopes: const {},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('malformed scope tag (no colon, not a wildcard) is rejected', () {
      expect(
        () => AgentRegistration(
          agentName: 'a',
          procedureId: 'p',
          defaultBudget: budget,
          readScopes: const {},
          writeScopes: const {'badtag'},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('scope tag with empty name is rejected', () {
      expect(
        () => AgentRegistration(
          agentName: 'a',
          procedureId: 'p',
          defaultBudget: budget,
          readScopes: const {},
          writeScopes: const {'node:'},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('scope tag with empty kind is rejected', () {
      expect(
        () => AgentRegistration(
          agentName: 'a',
          procedureId: 'p',
          defaultBudget: budget,
          readScopes: const {},
          writeScopes: const {':Event'},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('global wildcard "*" is accepted', () {
      final reg = AgentRegistration(
        agentName: 'bootstrap',
        procedureId: 'bootstrap_v1',
        defaultBudget: budget,
        readScopes: const {'*'},
        writeScopes: const {'*'},
      );
      expect(reg.allowsWrite('node:Event'), isTrue);
      expect(reg.allowsRead('stack:anything'), isTrue);
    });

    test('per-kind wildcard "<kind>:*" is accepted', () {
      final reg = AgentRegistration(
        agentName: 'a',
        procedureId: 'p',
        defaultBudget: budget,
        readScopes: const {'node:*'},
        writeScopes: const {'edge:*', 'stack:*'},
      );
      expect(reg.allowsWrite('edge:mentions'), isTrue);
      expect(reg.allowsWrite('stack:questions_open'), isTrue);
      expect(reg.allowsRead('node:Concept'), isTrue);
    });
  });

  group('AgentRegistration scope matching', () {
    final reg = AgentRegistration(
      agentName: 'extractor',
      procedureId: 'dream_extract_v1',
      defaultBudget: budget,
      readScopes: const {'node:Event', 'node:Source'},
      writeScopes: const {
        'node:Claim',
        'edge:derived_from',
        'stack:questions_open',
      },
    );

    test('exact write scope match returns true', () {
      expect(reg.allowsWrite('node:Claim'), isTrue);
      expect(reg.allowsWrite('edge:derived_from'), isTrue);
      expect(reg.allowsWrite('stack:questions_open'), isTrue);
    });

    test('unmatched write scope returns false', () {
      expect(reg.allowsWrite('node:Procedure'), isFalse,
          reason: 'A Connector / Extractor cannot write Procedure nodes.');
      expect(reg.allowsWrite('edge:contradicts'), isFalse);
      expect(reg.allowsWrite('stack:inflight'), isFalse);
    });

    test('exact read scope match returns true', () {
      expect(reg.allowsRead('node:Event'), isTrue);
      expect(reg.allowsRead('node:Source'), isTrue);
    });

    test('unmatched read scope returns false', () {
      expect(reg.allowsRead('node:Claim'), isFalse);
      expect(reg.allowsRead('edge:derived_from'), isFalse);
    });

    test('empty granted set always denies', () {
      final pruner = AgentRegistration(
        agentName: 'pruner',
        procedureId: 'dream_prune_v1',
        defaultBudget: WriteBudget(
          maxNodes: 0,
          maxEdges: 0,
          maxStackEntries: 0,
        ),
        readScopes: const {'*'},
        writeScopes: const {},
      );
      expect(pruner.allowsWrite('node:Event'), isFalse);
      expect(pruner.allowsWrite('edge:mentions'), isFalse);
    });

    test('per-kind wildcard does not bleed across kinds', () {
      final r = AgentRegistration(
        agentName: 'a',
        procedureId: 'p',
        defaultBudget: budget,
        readScopes: const {},
        writeScopes: const {'node:*'},
      );
      expect(r.allowsWrite('node:Anything'), isTrue);
      expect(r.allowsWrite('edge:mentions'), isFalse,
          reason: '"node:*" must not match an edge scope.');
      expect(r.allowsWrite('stack:inflight'), isFalse);
    });
  });

  group('AgentRegistration helpers', () {
    test('nodeScope / edgeScope / stackScope produce the canonical strings',
        () {
      expect(AgentRegistration.nodeScope('Event'), equals('node:Event'));
      expect(
        AgentRegistration.edgeScope('contradicts'),
        equals('edge:contradicts'),
      );
      expect(
        AgentRegistration.stackScope('questions_open'),
        equals('stack:questions_open'),
      );
    });

    test('kindWildcard produces the canonical wildcard', () {
      expect(AgentRegistration.kindWildcard('node'), equals('node:*'));
    });

    test('globalWildcard is the literal "*"', () {
      expect(AgentRegistration.globalWildcard, equals('*'));
    });
  });

  group('AgentRegistration immutability', () {
    test('readScopes / writeScopes are unmodifiable', () {
      final reg = AgentRegistration(
        agentName: 'a',
        procedureId: 'p',
        defaultBudget: budget,
        readScopes: {'node:Event'},
        writeScopes: {'node:Claim'},
      );
      expect(
        () => reg.readScopes.add('node:Source'),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => reg.writeScopes.add('edge:mentions'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('mutating the input set after construction does not change the '
        'registration', () {
      final source = <String>{'node:Event'};
      final reg = AgentRegistration(
        agentName: 'a',
        procedureId: 'p',
        defaultBudget: budget,
        readScopes: source,
        writeScopes: const {},
      );
      source.add('node:Source');
      expect(reg.readScopes, equals({'node:Event'}),
          reason: 'Registration must defensively copy its input sets.');
    });
  });

  group('AgentRegistration equality + toString', () {
    test('equal field-by-field registrations are ==', () {
      AgentRegistration build() => AgentRegistration(
            agentName: 'extractor',
            procedureId: 'dream_extract_v1',
            defaultBudget: budget,
            readScopes: const {'node:Event'},
            writeScopes: const {'node:Claim', 'edge:derived_from'},
          );
      expect(build(), equals(build()));
      expect(build().hashCode, equals(build().hashCode));
    });

    test('differing scope sets are not equal', () {
      final a = AgentRegistration(
        agentName: 'x',
        procedureId: 'p',
        defaultBudget: budget,
        readScopes: const {},
        writeScopes: const {'node:Claim'},
      );
      final b = AgentRegistration(
        agentName: 'x',
        procedureId: 'p',
        defaultBudget: budget,
        readScopes: const {},
        writeScopes: const {'node:Concept'},
      );
      expect(a, isNot(equals(b)));
    });

    test('toString carries the field values', () {
      final reg = AgentRegistration(
        agentName: 'extractor',
        procedureId: 'dream_extract_v1',
        defaultBudget: budget,
        readScopes: const {'node:Event'},
        writeScopes: const {'node:Claim'},
      );
      final s = reg.toString();
      expect(s, contains('extractor'));
      expect(s, contains('dream_extract_v1'));
      expect(s, contains('node:Claim'));
    });
  });
}
