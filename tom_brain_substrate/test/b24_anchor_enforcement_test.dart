// B.24 — Anchor enforcement conformance suite.
//
// Plan-step text (verbatim):
//
//   "B.24 Tests: every role's output prompt contains the anchor;
//    tampering attempts (passing an already-wrapped string, passing
//    an empty prompt, passing a multi-message prompt) all converge
//    on the anchor."
//
// Relationship to `b23_anchor_injection_test.dart`:
//
//   B.23's test file pins the *contract* of `RoleTemplate.assemble`
//   and the `AnchorRegistry` shape — what the assembled `WirePrompt`
//   looks like, what the hash format is, what an `AnchorViolation`
//   carries. It walks the bootstrap roster as one of several groups.
//
//   B.24 is the focused *enforcement* suite the plan-step text
//   names. It restates the two structural claims the plan asks for —
//
//     (1) "every role's output prompt contains the anchor"
//     (2) "tampering attempts […] all converge on the anchor"
//
//   — and pins them across every legal input shape, on both the
//   substrate role layer (`RoleTemplate.assemble`) and the shared
//   anchor primitive the substrate composes on
//   (`AssistantDedicationAnchor.wrap` / `wrapAll`). The multi-message
//   tampering vector is covered exclusively at the shared primitive,
//   because the substrate's role-assembly path does not yet expose
//   a multi-message input shape (`Message` type lives at B.10's
//   `WirePrompt` boundary which carries a single body string; the
//   multi-message *system+user* split is the provider's
//   responsibility per B.14 / B.15 / B.16 and never carries a
//   second un-anchored system message).
//
// Why this is a separate file from B.23 even though there is some
// overlap with B.23's "Tampering vectors" group:
//
//   * The plan numbers B.23 (the injection mechanism) and B.24 (the
//     enforcement test) as two distinct steps. Co-locating B.24's
//     assertions inside B.23's test file would obscure the audit
//     trail — a reader of the B.24 commit should see the
//     enforcement suite added as one structurally-clean change.
//   * The B.23 file pins per-field contracts (`body` starts-with,
//     `anchorHash` equality, section markers present, …); B.24 pins
//     a *property*: `containsAnchor(body) == true` for every input
//     shape on every role, plus the same property on the shared
//     primitive for every tamper vector the plan names. The two
//     concerns answer different questions and read independently.
//   * Future restructuring may retire B.23's "Tampering vectors"
//     group once B.24 owns the property; for now the small overlap
//     is acceptable and the two groups assert distinct things (B.23
//     asserts double-wrap *count* and section ordering; B.24
//     asserts anchor *presence* and primitive convergence).
//
// What this test deliberately does NOT cover:
//
//   * The provider-side anchor stamp on `LlmCallReport.anchorHash`.
//     B.46's cross-provider conformance suite verifies every
//     emitted report against `AnchorRegistry.currentHash`. B.24 is
//     upstream of that — it proves the *prompt* carries the anchor;
//     B.46 proves the *report* records it.
//   * The runtime hook at the `TomBrainSubstrate` facade (B.40)
//     that raises `AnchorViolation` on every report whose
//     `anchorHash` does not equal `AnchorRegistry.currentHash`. B.24
//     proves the prompt is anchored; B.40's hook proves the report
//     was emitted by code that read the same anchor.
//   * The `templateRef` / `templateSha` field on `WirePrompt`. Both
//     deferred to B.36 with the file-backed loader.

import 'package:test/test.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

void main() {
  // ----------------------------------------------------------------
  // Claim (1): "every role's output prompt contains the anchor"
  //
  // The bootstrap roster is the entire role surface the substrate
  // exposes at the prototype boundary. The claim must hold:
  //   - for every role in `bootstrapRoleRegistry().templates`,
  //   - across every input shape a caller could plausibly hand in,
  //   - on every call to `assemble(...)` (the property is stable
  //     across repeated invocations).
  // ----------------------------------------------------------------
  group('every role\'s output prompt contains the anchor', () {
    final registry = bootstrapRoleRegistry();
    final roles = registry.templates.toList(growable: false);

    test('the bootstrap registry has the six core roles', () {
      // Pre-flight: if the registry roster ever shrinks, the
      // remaining tests would still pass against the shrunken set
      // and we would silently lose coverage. Pin the expected ids
      // here so a future B.22 change that touches the roster shows
      // up as a B.24 failure. The roster is the prototype five (§ 6.2)
      // plus the completion-phase `researcher` (§ 6.2b, G-T3).
      expect(
        roles.map((t) => t.id).toList(),
        equals(const [
          'assistant_to_user',
          'analyser',
          'sub_thinker',
          'recaller',
          'evaluator',
          'researcher',
        ]),
      );
    });

    for (final role in roles) {
      group('role ${role.id}', () {
        test('no-arg assemble produces an anchored body', () {
          final p = role.assemble();
          expect(
            AssistantDedicationAnchor.containsAnchor(p.combined),
            isTrue,
            reason: '${role.id}: assemble() body must contain the anchor',
          );
        });

        test('empty inputs map produces an anchored body', () {
          final p = role.assemble(inputs: const <String, Object?>{});
          expect(
            AssistantDedicationAnchor.containsAnchor(p.combined),
            isTrue,
            reason:
                '${role.id}: assemble(inputs: {}) body must contain the anchor',
          );
        });

        test('populated inputs map produces an anchored body', () {
          final p = role.assemble(inputs: const <String, Object?>{
            'user_prompt': 'A non-trivial question about Tom Brain.',
            'thinking_trail_summary':
                'Prior context: the user has asked similar questions before.',
          });
          expect(
            AssistantDedicationAnchor.containsAnchor(p.combined),
            isTrue,
            reason: '${role.id}: populated-inputs body must contain the anchor',
          );
        });

        test('every call stamps AnchorRegistry.currentHash', () {
          // Property (1) is body-level — but the substrate's stronger
          // guarantee is that the *recorded* hash on the WirePrompt
          // matches the current registry value. If the body is
          // anchored but the hash drifts, the B.46 conformance test
          // downstream would still fail. Pin it here so the failure
          // surfaces at the role layer where the bug lives.
          final p = role.assemble();
          expect(p.anchorHash, equals(AnchorRegistry.currentHash));
        });

        test('repeated calls produce stable anchored bodies', () {
          final p1 = role.assemble();
          final p2 = role.assemble();
          expect(
            AssistantDedicationAnchor.containsAnchor(p1.combined),
            isTrue,
          );
          expect(
            AssistantDedicationAnchor.containsAnchor(p2.combined),
            isTrue,
          );
          // The property is stable across calls — not just "happens
          // to hold once".
          expect(p1.combined, equals(p2.combined));
        });
      });
    }
  });

  // ----------------------------------------------------------------
  // Claim (2a): tampering attempt — "passing an already-wrapped
  // string"
  //
  // Surface: a caller hands in an input whose value is itself the
  // anchor text (or a string that contains the anchor verbatim),
  // attempting to either bypass the wrap (by claiming the anchor is
  // "already there") or to produce a double-wrap that downstream
  // tools could mistake for a degraded prompt.
  //
  // Required outcome: the assembled body still satisfies
  // `containsAnchor`, and the shared primitive's `wrap` is
  // idempotent at the boundary.
  // ----------------------------------------------------------------
  group('tampering: already-wrapped string', () {
    test('AssistantDedicationAnchor.wrap is idempotent on the anchor text', () {
      // The most direct already-wrapped case: hand the wrap helper
      // its own output back. Idempotent → returned string is
      // identical (no double-prepend, no truncation).
      final once = AssistantDedicationAnchor.wrap('hello');
      final twice = AssistantDedicationAnchor.wrap(once);
      expect(twice, equals(once));
      expect(
        AssistantDedicationAnchor.text.allMatches(twice).length,
        equals(1),
        reason: 'idempotent wrap must leave exactly one anchor occurrence',
      );
    });

    test('wrap is idempotent when the anchor is embedded mid-string', () {
      // The "anchor pasted after some other text" case named in the
      // shared module header. `wrap` keys on `contains(text)` for
      // idempotency, so a mid-string anchor still satisfies the
      // bypass-detection.
      const tampered = 'prefix-text ${AssistantDedicationAnchor.text}suffix';
      final out = AssistantDedicationAnchor.wrap(tampered);
      expect(out, equals(tampered),
          reason: 'wrap must not prepend when the anchor is already present, '
              'even at mid-string position');
      expect(
        AssistantDedicationAnchor.containsAnchor(out),
        isTrue,
      );
    });

    test('role assemble converges on the anchor when input contains it', () {
      // The substrate's stronger contract: even when an input value
      // is pre-anchored, the assembled body still satisfies the
      // anchor invariant *and* still starts with the anchor (the
      // role layer prepends unconditionally; the input-value
      // occurrence is the second one).
      final role = bootstrapRoleRegistry().get('assistant_to_user');
      final p = role.assemble(inputs: <String, Object?>{
        'pre_anchored_input': AssistantDedicationAnchor.text,
      });
      expect(
        AssistantDedicationAnchor.containsAnchor(p.combined),
        isTrue,
        reason: 'pre-anchored input must not bypass the wrap',
      );
      expect(
        p.combined.startsWith(AssistantDedicationAnchor.text),
        isTrue,
        reason: 'the prepended anchor must precede the pre-anchored input',
      );
    });

    test('every bootstrap role converges on the anchor for pre-anchored input',
        () {
      // The cross-role version of the above: the convergence
      // property holds for every role, not just `assistant_to_user`.
      final registry = bootstrapRoleRegistry();
      for (final role in registry.templates) {
        final p = role.assemble(inputs: <String, Object?>{
          'tampered_input': 'preamble ${AssistantDedicationAnchor.text} tail',
        });
        expect(
          AssistantDedicationAnchor.containsAnchor(p.combined),
          isTrue,
          reason: '${role.id}: pre-anchored input did not converge on anchor',
        );
      }
    });
  });

  // ----------------------------------------------------------------
  // Claim (2b): tampering attempt — "passing an empty prompt"
  //
  // Surface: a caller hands in an empty / null / whitespace-only
  // prompt, attempting to produce a substrate outbound message that
  // carries no anchor (the "missing system prompt" vector).
  //
  // Required outcome: the wrap helper produces the anchor alone for
  // empty / null / whitespace-only input; the role layer's assemble
  // produces an anchored body when inputs are empty; the resulting
  // string satisfies `containsAnchor`.
  // ----------------------------------------------------------------
  group('tampering: empty prompt', () {
    test('wrap(null) returns the anchor alone', () {
      final out = AssistantDedicationAnchor.wrap(null);
      expect(out, equals(AssistantDedicationAnchor.text));
      expect(AssistantDedicationAnchor.containsAnchor(out), isTrue);
    });

    test('wrap("") returns the anchor alone', () {
      final out = AssistantDedicationAnchor.wrap('');
      expect(out, equals(AssistantDedicationAnchor.text));
      expect(AssistantDedicationAnchor.containsAnchor(out), isTrue);
    });

    test('wrap("   \\t\\n  ") returns the anchor alone', () {
      // Whitespace-only is treated as empty per the shared module
      // header: "Whitespace-only input → treated as empty; anchor
      // returned alone."
      final out = AssistantDedicationAnchor.wrap('   \t\n  ');
      expect(out, equals(AssistantDedicationAnchor.text));
      expect(AssistantDedicationAnchor.containsAnchor(out), isTrue);
    });

    test('role assemble with empty inputs converges on the anchor', () {
      // The role-layer empty-input case: every role's assemble path
      // produces an anchored body when no inputs are supplied. The
      // role's persona + objective fill the body; the anchor
      // prepends.
      final registry = bootstrapRoleRegistry();
      for (final role in registry.templates) {
        final p = role.assemble();
        expect(
          AssistantDedicationAnchor.containsAnchor(p.combined),
          isTrue,
          reason: '${role.id}: empty-inputs assemble did not converge on '
              'anchor',
        );
        // And the body is non-trivial — it carries the persona and
        // objective; the anchor is not the *only* content. The
        // empty-prompt tamper vector tries to produce an
        // anchor-only outbound; the role layer's empty-input case
        // produces a richer body that still carries the anchor.
        expect(p.combined.length, greaterThan(AssistantDedicationAnchor.text.length));
      }
    });

    test('role assemble with empty-string input values still anchors', () {
      // Adjacent tamper vector: the caller supplies inputs whose
      // *values* are empty strings. The role's `_composeBody` will
      // render `key: ` (empty value) lines; the anchor still
      // prepends.
      final role = bootstrapRoleRegistry().get('analyser');
      final p = role.assemble(inputs: const <String, Object?>{
        'empty_value_one': '',
        'empty_value_two': '',
      });
      expect(
        AssistantDedicationAnchor.containsAnchor(p.combined),
        isTrue,
      );
      expect(
        p.combined.startsWith(AssistantDedicationAnchor.text),
        isTrue,
      );
    });
  });

  // ----------------------------------------------------------------
  // Claim (2c): tampering attempt — "passing a multi-message prompt"
  //
  // Surface: a caller hands in a *list* of messages, attempting to
  // produce an outbound batch where the first / system message is
  // un-anchored (the "split-system-prompt" vector). The shared
  // primitive's `wrapAll` is the load-bearing function — the
  // substrate's multi-message paths (eventual provider-side
  // `messages: [...]` shape per `llm_provider.dart` line 105) all
  // compose on it.
  //
  // Required outcome: `wrapAll` produces a list whose first element
  // satisfies `containsAnchor`, for every input shape — empty list,
  // single un-anchored element, single anchored element, multi-
  // element list with un-anchored first, multi-element list with
  // already-anchored first, multi-element list with anchor only in
  // a non-first position.
  // ----------------------------------------------------------------
  group('tampering: multi-message prompt', () {
    test('wrapAll([]) returns a single-element list carrying the anchor', () {
      // The "missing system prompt" vector — caller hands an empty
      // list, attempting to produce an outbound batch with no
      // system framing.
      final out = AssistantDedicationAnchor.wrapAll(<String>[]);
      expect(out.length, equals(1));
      expect(out.first, equals(AssistantDedicationAnchor.text));
      expect(AssistantDedicationAnchor.containsAnchor(out.first), isTrue);
    });

    test('wrapAll([un-anchored]) anchors the first element', () {
      final out = AssistantDedicationAnchor.wrapAll(<String>['plain system']);
      expect(out.length, equals(1));
      expect(AssistantDedicationAnchor.containsAnchor(out.first), isTrue);
      expect(
        out.first.startsWith(AssistantDedicationAnchor.text),
        isTrue,
      );
    });

    test('wrapAll([already-anchored]) returns the input unchanged (idempotent)',
        () {
      final input = <String>[
        '${AssistantDedicationAnchor.text}already wrapped system',
      ];
      final out = AssistantDedicationAnchor.wrapAll(input);
      expect(out, equals(input));
      // Exactly one anchor occurrence in the first element.
      expect(
        AssistantDedicationAnchor.text.allMatches(out.first).length,
        equals(1),
        reason: 'wrapAll must be idempotent — no double-anchor on first',
      );
    });

    test('wrapAll([un-anchored-first, user, user]) anchors only the first', () {
      // The canonical multi-message system+user[+user] shape. The
      // anchor lands on the system message (position 0); the user
      // messages are untouched.
      final out = AssistantDedicationAnchor.wrapAll(<String>[
        'plain system',
        'first user message',
        'second user message',
      ]);
      expect(out.length, equals(3));
      expect(AssistantDedicationAnchor.containsAnchor(out[0]), isTrue);
      expect(AssistantDedicationAnchor.containsAnchor(out[1]), isFalse);
      expect(AssistantDedicationAnchor.containsAnchor(out[2]), isFalse);
      expect(out[1], equals('first user message'));
      expect(out[2], equals('second user message'));
    });

    test('wrapAll([anchored-first, user]) leaves the user untouched', () {
      // Already-anchored first element + a user message: the user
      // message is preserved verbatim; the first element is the
      // unchanged anchored system; the list is the same reference
      // shape (frozen unmodifiable).
      final out = AssistantDedicationAnchor.wrapAll(<String>[
        '${AssistantDedicationAnchor.text}already anchored system',
        'a user message',
      ]);
      expect(out.length, equals(2));
      expect(AssistantDedicationAnchor.containsAnchor(out[0]), isTrue);
      expect(
        AssistantDedicationAnchor.text.allMatches(out[0]).length,
        equals(1),
        reason: 'no double-anchor on idempotent first',
      );
      expect(out[1], equals('a user message'));
    });

    test('wrapAll([un-anchored-first, anchor-in-second]) STILL anchors first',
        () {
      // A subtler tamper: the caller puts the anchor in a non-first
      // position (position 1 — e.g. a user message containing the
      // anchor text) and leaves the system position blank. The
      // structural invariant is "the *first* element is anchored";
      // a misplaced anchor at position 1 does not satisfy it. The
      // wrapAll helper must anchor position 0 regardless of what
      // later positions contain.
      final out = AssistantDedicationAnchor.wrapAll(<String>[
        'plain un-anchored system',
        '${AssistantDedicationAnchor.text}user message that includes the anchor',
      ]);
      expect(out.length, equals(2));
      expect(
        AssistantDedicationAnchor.containsAnchor(out[0]),
        isTrue,
        reason: 'first element must be anchored regardless of position-1 '
            'content',
      );
      expect(
        out[0].startsWith(AssistantDedicationAnchor.text),
        isTrue,
      );
    });

    test('wrapAll([empty-first, user]) anchors the first element', () {
      // Empty / whitespace-only first element: `wrap` collapses to
      // the anchor alone for that position, and the user message is
      // preserved.
      final out = AssistantDedicationAnchor.wrapAll(<String>[
        '',
        'a non-empty user message',
      ]);
      expect(out.length, equals(2));
      expect(out[0], equals(AssistantDedicationAnchor.text));
      expect(out[1], equals('a non-empty user message'));
    });

    test('wrapAll output is an unmodifiable list', () {
      // The shared module guarantees `List.unmodifiable` on the
      // return path — a caller cannot mutate the produced list to
      // strip the anchor after wrapping. Structural property: the
      // returned list rejects mutation.
      final out = AssistantDedicationAnchor.wrapAll(<String>['system', 'user']);
      expect(
        () => out[0] = 'tampered',
        throwsUnsupportedError,
        reason: 'returned list must be unmodifiable to prevent post-wrap '
            'mutation',
      );
    });

    test('wrapAll preserves every non-first element verbatim', () {
      // Composite check: the second-through-last messages are
      // returned byte-for-byte, including ones that look like
      // system framings. The anchoring is *positional*, not
      // content-pattern matching — wrapAll never mutates anything
      // other than position 0.
      const tail = <String>[
        'user 1',
        '',
        '   whitespace user   ',
        'user containing ANCHOR-like text but not the actual anchor',
      ];
      final out = AssistantDedicationAnchor.wrapAll(<String>[
        'un-anchored first',
        ...tail,
      ]);
      expect(out.length, equals(tail.length + 1));
      for (var i = 0; i < tail.length; i++) {
        expect(out[i + 1], equals(tail[i]),
            reason: 'position ${i + 1} must be preserved verbatim');
      }
    });
  });

  // ----------------------------------------------------------------
  // Cross-cutting: convergence across all three tamper vectors.
  //
  // The plan-step text reads "[…] all converge on the anchor." The
  // structural claim is one property — `containsAnchor(out) == true`
  // — applied to every output of every legal entry point. The tests
  // above pin the property per-vector; the test below states it as
  // a single composite assertion so a regression that breaks ANY of
  // the three vectors at the primitive layer fails this one test
  // first, before the per-vector groups produce nine failures.
  // ----------------------------------------------------------------
  group('convergence: every primitive output contains the anchor', () {
    test('exhaustive: wrap + wrapAll outputs all satisfy containsAnchor', () {
      // Every input enumerated in the shared module header as a
      // tamper vector, plus the role-layer empty / pre-anchored
      // shapes.
      final primitiveInputs = <String?>[
        null,
        '',
        '   ',
        '\t\n',
        'plain text',
        AssistantDedicationAnchor.text,
        '${AssistantDedicationAnchor.text}suffix',
        'prefix ${AssistantDedicationAnchor.text}',
        'prefix ${AssistantDedicationAnchor.text} suffix',
      ];
      for (final input in primitiveInputs) {
        final out = AssistantDedicationAnchor.wrap(input);
        expect(
          AssistantDedicationAnchor.containsAnchor(out),
          isTrue,
          reason: 'wrap(${input == null ? "null" : "\"$input\""}) must '
              'converge on the anchor',
        );
      }

      final multiMessageInputs = <List<String>>[
        <String>[],
        <String>[''],
        <String>['   '],
        <String>['plain system'],
        <String>['${AssistantDedicationAnchor.text}already wrapped'],
        <String>['', 'user'],
        <String>['plain system', 'user 1', 'user 2'],
        <String>[
          '${AssistantDedicationAnchor.text}wrapped',
          'user 1',
          'user 2',
        ],
        <String>[
          'plain un-anchored',
          '${AssistantDedicationAnchor.text}misplaced',
        ],
      ];
      for (final input in multiMessageInputs) {
        final out = AssistantDedicationAnchor.wrapAll(input);
        expect(out, isNotEmpty,
            reason: 'wrapAll must always return at least one element');
        expect(
          AssistantDedicationAnchor.containsAnchor(out.first),
          isTrue,
          reason: 'wrapAll($input).first must contain the anchor',
        );
      }
    });

    test('exhaustive: every role × every input shape satisfies '
        'containsAnchor', () {
      final registry = bootstrapRoleRegistry();
      final inputShapes = <Map<String, Object?>>[
        const <String, Object?>{},
        const <String, Object?>{'q': 'plain question'},
        <String, Object?>{'pre_anchored': AssistantDedicationAnchor.text},
        const <String, Object?>{'empty_value': ''},
        const <String, Object?>{'whitespace_value': '   '},
        const <String, Object?>{'null_value': null},
        <String, Object?>{
          'multi_line_value':
              'line 1\nline 2\nline 3 with ${AssistantDedicationAnchor.text}'
                  'inline anchor',
        },
      ];
      for (final role in registry.templates) {
        for (final inputs in inputShapes) {
          final p = role.assemble(inputs: inputs);
          expect(
            AssistantDedicationAnchor.containsAnchor(p.combined),
            isTrue,
            reason: '${role.id} × ${inputs.keys.toList()}: '
                'assembled body did not converge on the anchor',
          );
          expect(
            p.anchorHash,
            equals(AnchorRegistry.currentHash),
            reason: '${role.id} × ${inputs.keys.toList()}: '
                'anchor hash drifted from registry',
          );
        }
      }
    });
  });
}
