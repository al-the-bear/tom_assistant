// Tests for the `anchor/` module (Plan step A.17).
//
// Two goals:
//
//   1. The public surface behaves as documented (text constant present,
//      version pinned, wrap / containsAnchor / wrapAll do what the
//      doc-comments say).
//   2. The anchor is *inescapable*. For every tamper vector listed in
//      Plan step B.24 — already-wrapped, empty / null / whitespace-only,
//      multi-message — the helper produces an output that satisfies
//      `containsAnchor`. This is the structural enforcement test the
//      substrate (B.46) will compose on top of.
//
// The "inescapability" group is the load-bearing one. The substrate
// can never emit an outbound prompt that bypasses the anchor as long
// as it routes through `wrap` / `wrapAll` and those two functions
// satisfy the property `containsAnchor(out) == true` for every legal
// input.

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart';

void main() {
  group('AssistantDedicationAnchor.text', () {
    test('is non-empty', () {
      expect(AssistantDedicationAnchor.text, isNotEmpty);
    });

    test('opens with the "I exist to help this user" framing', () {
      // The first clause is the present-tense identity declaration
      // (overview's Postulate 3). Lock the opening so a future text
      // change that loses this framing is caught by this test.
      expect(
        AssistantDedicationAnchor.text.startsWith('I exist to help this user'),
        isTrue,
      );
    });

    test('names the explicit negation "not a general agent"', () {
      // The explicit-negation clause forecloses the "I am an agent
      // that happens to be helping someone" escape route. Required by
      // Postulate 3's "structural, not advisory" framing.
      expect(
        AssistantDedicationAnchor.text.contains('not a general agent'),
        isTrue,
      );
    });

    test('names "dedicated to this user"', () {
      // The constitutive-dedication clause is the second half of the
      // negation. Required for the safety lever.
      expect(
        AssistantDedicationAnchor.text.contains('dedicated to this user'),
        isTrue,
      );
    });

    test('lists all three categories (option, conclusion, action)', () {
      // Postulate 3 demands the framing apply to the full cognitive
      // surface. Removing any of the three would open a loophole.
      expect(AssistantDedicationAnchor.text.contains('option'), isTrue);
      expect(AssistantDedicationAnchor.text.contains('conclusion'), isTrue);
      expect(AssistantDedicationAnchor.text.contains('action'), isTrue);
    });

    test('ends with a trailing newline', () {
      // `wrap` relies on the trailing newline to produce a clean
      // boundary without the caller inserting one.
      expect(AssistantDedicationAnchor.text.endsWith('\n'), isTrue);
    });

    test('is canonical UTF-8 with no surprising whitespace', () {
      // Catch accidental double-spaces / tabs / unicode whitespace.
      // The canonical form is ASCII letters, ASCII punctuation, single
      // spaces between words, and one trailing newline.
      final body = AssistantDedicationAnchor.text.trimRight();
      expect(body.contains('  '), isFalse,
          reason: 'no double spaces in canonical body');
      expect(body.contains('\t'), isFalse,
          reason: 'no tabs in canonical body');
      expect(body.contains('\u00A0'), isFalse,
          reason: 'no non-breaking spaces in canonical body');
    });
  });

  group('AssistantDedicationAnchor.version', () {
    test('is the initial revision (1)', () {
      expect(AssistantDedicationAnchor.version, equals(1));
    });

    test('is a positive integer', () {
      expect(AssistantDedicationAnchor.version, greaterThanOrEqualTo(1));
    });
  });

  group('AssistantDedicationAnchor.wrap', () {
    test('prepends the anchor to a non-empty body', () {
      final out = AssistantDedicationAnchor.wrap('Tell me a joke.');
      expect(out.startsWith(AssistantDedicationAnchor.text), isTrue);
      expect(out.endsWith('Tell me a joke.'), isTrue);
    });

    test('inserts the trailing newline from text without doubling it', () {
      final out = AssistantDedicationAnchor.wrap('Body.');
      // The anchor's own trailing newline is the boundary; no extra
      // separator is inserted. The body follows immediately.
      expect(
        out,
        equals('${AssistantDedicationAnchor.text}Body.'),
      );
    });

    test('is idempotent on already-anchored input', () {
      final once = AssistantDedicationAnchor.wrap('Body.');
      final twice = AssistantDedicationAnchor.wrap(once);
      expect(twice, equals(once));
    });

    test('is idempotent across many repeated wraps', () {
      // Stronger property than the two-call version: an attacker can
      // not produce a multi-anchored output by repeatedly wrapping.
      var current = AssistantDedicationAnchor.wrap('Body.');
      for (var i = 0; i < 10; i++) {
        current = AssistantDedicationAnchor.wrap(current);
      }
      // Anchor must appear exactly once (no duplicates).
      final occurrences = AssistantDedicationAnchor.text.allMatches(current).length;
      expect(occurrences, equals(1));
    });

    test('returns the anchor alone for an empty input', () {
      // Tamper vector: empty prompt. The empty body cannot escape
      // carrying the anchor.
      expect(AssistantDedicationAnchor.wrap(''), equals(AssistantDedicationAnchor.text));
    });

    test('returns the anchor alone for a whitespace-only input', () {
      // Tamper vector: spaces / tabs / newlines only. Treated as empty.
      expect(
        AssistantDedicationAnchor.wrap('   \t\n  '),
        equals(AssistantDedicationAnchor.text),
      );
    });

    test('returns the anchor alone for null input', () {
      // Tamper vector: null. The signature accepts null so a
      // forgetful caller cannot bypass the anchor by omitting the
      // body.
      expect(AssistantDedicationAnchor.wrap(null), equals(AssistantDedicationAnchor.text));
    });

    test('still anchors when the input already carries a *different* leading string', () {
      // The substrate might wrap an inbound user message with a role-
      // specific prefix before calling `wrap` (the prefix is the
      // role's brief, not the anchor). Ensure the anchor is added
      // even when the body is non-trivially formed.
      const body = 'Role: analyst\n\nQuestion: what is 2+2?';
      final out = AssistantDedicationAnchor.wrap(body);
      expect(out.startsWith(AssistantDedicationAnchor.text), isTrue);
      expect(out.contains(body), isTrue);
    });

    test('preserves the body verbatim when prepending', () {
      // No normalisation / trimming / casing change to the body.
      const body = '  Multi-line\nbody with   spaces.\n';
      final out = AssistantDedicationAnchor.wrap(body);
      expect(out.endsWith(body), isTrue);
    });

    test('is a pure function (same input → same output across calls)', () {
      final a = AssistantDedicationAnchor.wrap('Body.');
      final b = AssistantDedicationAnchor.wrap('Body.');
      expect(a, equals(b));
    });
  });

  group('AssistantDedicationAnchor.ensurePrefix', () {
    test('prepends the anchor to a non-empty body', () {
      final out = AssistantDedicationAnchor.ensurePrefix('Tell me a joke.');
      expect(out.startsWith(AssistantDedicationAnchor.text), isTrue);
      expect(out.endsWith('Tell me a joke.'), isTrue);
    });

    test('result always starts with the anchor (stronger than wrap)', () {
      // The defining difference from `wrap`: `ensurePrefix` guarantees the
      // anchor is the *prefix*, not merely present somewhere. This is the
      // substrate invariant 1 ("body starts with anchor") and the reason
      // the role layer needs a starts-with primitive.
      const body = 'PERSONA:\nanalyst\n\nOBJECTIVE:\nanswer';
      final out = AssistantDedicationAnchor.ensurePrefix(body);
      expect(out.startsWith(AssistantDedicationAnchor.text), isTrue);
    });

    test('is idempotent on already-prefixed input', () {
      final once = AssistantDedicationAnchor.ensurePrefix('Body.');
      final twice = AssistantDedicationAnchor.ensurePrefix(once);
      expect(twice, equals(once));
    });

    test('prepends even when the anchor occurs mid-string', () {
      // The "input value contains the anchor text mid-string" tamper
      // vector: `wrap` would return it unchanged (the result would NOT
      // start with the anchor); `ensurePrefix` prepends so the result
      // still starts with the anchor.
      const body = 'leading text ${'noise'} then the body';
      final embedded = '$body${AssistantDedicationAnchor.text}tail';
      final out = AssistantDedicationAnchor.ensurePrefix(embedded);
      expect(out.startsWith(AssistantDedicationAnchor.text), isTrue);
    });

    test('returns the anchor alone for empty / whitespace / null input', () {
      expect(AssistantDedicationAnchor.ensurePrefix(''),
          equals(AssistantDedicationAnchor.text));
      expect(AssistantDedicationAnchor.ensurePrefix('  \t\n '),
          equals(AssistantDedicationAnchor.text));
      expect(AssistantDedicationAnchor.ensurePrefix(null),
          equals(AssistantDedicationAnchor.text));
    });

    test('preserves the body verbatim after the prefix', () {
      const body = '  Multi-line\nbody with   spaces.\n';
      final out = AssistantDedicationAnchor.ensurePrefix(body);
      expect(out, equals('${AssistantDedicationAnchor.text}$body'));
    });
  });

  group('AssistantDedicationAnchor.containsAnchor', () {
    test('returns true for a wrapped string', () {
      final wrapped = AssistantDedicationAnchor.wrap('Body.');
      expect(AssistantDedicationAnchor.containsAnchor(wrapped), isTrue);
    });

    test('returns true for an unwrapped string that happens to contain the anchor', () {
      // Mid-string occurrence still counts. Position is the role
      // template's concern; presence is this predicate's concern.
      final embedded =
          'Some preamble.\n${AssistantDedicationAnchor.text}\nMore body.';
      expect(AssistantDedicationAnchor.containsAnchor(embedded), isTrue);
    });

    test('returns false for an arbitrary unwrapped body', () {
      expect(
        AssistantDedicationAnchor.containsAnchor('Tell me a joke.'),
        isFalse,
      );
    });

    test('returns false for null', () {
      expect(AssistantDedicationAnchor.containsAnchor(null), isFalse);
    });

    test('returns false for the empty string', () {
      expect(AssistantDedicationAnchor.containsAnchor(''), isFalse);
    });

    test('returns false for whitespace-only input', () {
      // Whitespace cannot contain the anchor by construction (the
      // anchor's first character is "I", not whitespace).
      expect(
        AssistantDedicationAnchor.containsAnchor('   \t\n  '),
        isFalse,
      );
    });

    test('returns false for a partial anchor (truncated text)', () {
      // A substring of the anchor is not the anchor. Catches "anchor
      // half-copied by a faulty role template" cases.
      final truncated =
          AssistantDedicationAnchor.text.substring(0, AssistantDedicationAnchor.text.length - 10);
      expect(AssistantDedicationAnchor.containsAnchor(truncated), isFalse);
    });

    test('is case-sensitive (a lowercased anchor is not the anchor)', () {
      // The trail records a content hash; a lowercased copy would
      // produce a different hash. Accepting it here would silently
      // mark a tampered message as compliant.
      final lowered = AssistantDedicationAnchor.text.toLowerCase();
      expect(AssistantDedicationAnchor.containsAnchor(lowered), isFalse);
    });
  });

  group('AssistantDedicationAnchor.wrapAll', () {
    test('returns a single-element list with the anchor for empty input', () {
      // Tamper vector: empty message list. Cannot escape carrying
      // the anchor.
      final out = AssistantDedicationAnchor.wrapAll(const <String>[]);
      expect(out, hasLength(1));
      expect(out.first, equals(AssistantDedicationAnchor.text));
    });

    test('anchors the first element when no element is anchored', () {
      final out = AssistantDedicationAnchor.wrapAll(const [
        'System brief.',
        'User question.',
        'Assistant draft.',
      ]);
      expect(out, hasLength(3));
      expect(out.first.startsWith(AssistantDedicationAnchor.text), isTrue);
      expect(out.first.endsWith('System brief.'), isTrue);
      expect(out[1], equals('User question.'));
      expect(out[2], equals('Assistant draft.'));
    });

    test('returns the input unchanged when the first element is already anchored', () {
      final firstAnchored = AssistantDedicationAnchor.wrap('System brief.');
      final input = <String>[
        firstAnchored,
        'User question.',
      ];
      final out = AssistantDedicationAnchor.wrapAll(input);
      expect(out, hasLength(2));
      expect(out[0], equals(firstAnchored));
      expect(out[1], equals('User question.'));
    });

    test('is idempotent across repeated calls', () {
      final once = AssistantDedicationAnchor.wrapAll(const [
        'System brief.',
        'User question.',
      ]);
      final twice = AssistantDedicationAnchor.wrapAll(once);
      expect(twice, equals(once));
    });

    test('produces a list whose first element always satisfies containsAnchor', () {
      // The structural property: no matter what input shape we pass,
      // the first element of the output carries the anchor.
      final cases = <Iterable<String>>[
        const <String>[],
        const <String>[''],
        const <String>['Hello.'],
        const <String>['', 'middle', 'tail'],
        <String>[AssistantDedicationAnchor.wrap('already anchored'), 'tail'],
      ];
      for (final input in cases) {
        final out = AssistantDedicationAnchor.wrapAll(input);
        expect(out, isNotEmpty,
            reason: 'wrapAll must always produce at least one element');
        expect(
          AssistantDedicationAnchor.containsAnchor(out.first),
          isTrue,
          reason:
              'first element of wrapAll output must always contain the anchor; '
              'input was $input',
        );
      }
    });

    test('does not mutate the input list', () {
      final input = <String>['System brief.', 'User question.'];
      final snapshot = List<String>.from(input);
      AssistantDedicationAnchor.wrapAll(input);
      expect(input, equals(snapshot));
    });

    test('returned list is unmodifiable', () {
      // Catches a downstream call site that would try to splice
      // un-anchored content in front of an already-anchored first
      // element after the fact.
      final out = AssistantDedicationAnchor.wrapAll(const ['System brief.']);
      expect(() => out.add('Sneaky.'), throwsUnsupportedError);
      expect(() => out[0] = 'Replaced.', throwsUnsupportedError);
    });
  });

  group('Inescapability — structural property', () {
    // The load-bearing claim: for *every* legal input to either of
    // the two output-producing helpers, the result contains the
    // anchor. If a future change to `wrap` or `wrapAll` ever violates
    // this group, the substrate's anchor-enforcement test (B.46)
    // will fail; locking it here so the property breaks at the
    // earliest possible layer.
    final stringInputs = <String?>[
      null,
      '',
      ' ',
      '\n\t\n',
      'short',
      'Body.',
      AssistantDedicationAnchor.text,
      AssistantDedicationAnchor.wrap('Body.'),
      'Multi\nline\nbody\nwith\nnewlines.',
      'Contains the word "anchor" but not the actual anchor text.',
    ];

    for (final input in stringInputs) {
      test('wrap(${_describe(input)}) → contains anchor', () {
        final out = AssistantDedicationAnchor.wrap(input);
        expect(AssistantDedicationAnchor.containsAnchor(out), isTrue);
      });
    }

    final listInputs = <List<String>>[
      <String>[],
      <String>[''],
      <String>['a'],
      <String>['', 'b'],
      <String>[AssistantDedicationAnchor.text],
      <String>[AssistantDedicationAnchor.wrap('first'), 'second'],
      <String>['first', 'second', 'third'],
      <String>['', '', '', ''],
    ];

    for (var i = 0; i < listInputs.length; i++) {
      final input = listInputs[i];
      test('wrapAll(case #$i, length ${input.length}) → first element contains anchor', () {
        final out = AssistantDedicationAnchor.wrapAll(input);
        expect(out, isNotEmpty);
        expect(AssistantDedicationAnchor.containsAnchor(out.first), isTrue);
      });
    }
  });

  group('Type-level invariants', () {
    test('AssistantDedicationAnchor cannot be instantiated', () {
      // The constructor is private (`._`), so no public path exists
      // to allocate an instance. We assert the *consequence*: every
      // member of the public surface is `static` and reachable
      // without an instance. The test reaching this point with the
      // helpers below already exercised proves the surface is fully
      // static-accessible.
      expect(AssistantDedicationAnchor.text, isA<String>());
      expect(AssistantDedicationAnchor.version, isA<int>());
      expect(AssistantDedicationAnchor.wrap('x'), isA<String>());
      expect(
        AssistantDedicationAnchor.containsAnchor('x'),
        isA<bool>(),
      );
      expect(
        AssistantDedicationAnchor.wrapAll(const ['x']),
        isA<List<String>>(),
      );
    });
  });
}

String _describe(String? input) {
  if (input == null) return 'null';
  if (input.isEmpty) return '""';
  if (input == AssistantDedicationAnchor.text) return '<anchor.text>';
  if (input.contains(AssistantDedicationAnchor.text)) {
    return '<contains anchor>';
  }
  final preview = input.length <= 20 ? input : '${input.substring(0, 20)}…';
  return '"${preview.replaceAll('\n', '\\n').replaceAll('\t', '\\t')}"';
}
