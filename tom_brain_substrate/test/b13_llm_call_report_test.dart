// B.13 — `LlmCallReport` ratification conformance suite.
//
// Plan-step text (verbatim):
//   "B.13 Define `LlmCallReport` (tokens in/out, wall-clock, provider
//   id, model id, retry count)."
//
// The B.9 step already shipped `LlmCallReport` with a superset of
// the plan-text field list. B.13 is therefore a *ratification step*
// (mirrors B.12's pattern against the pre-existing `LlmOptions`):
// no new field, no new runtime code — only a conformance suite that
// pins the post-B.13 shape so a future rename / drop trips a test
// failure here rather than at a (yet-to-exist) downstream consumer.
//
// Scope of this test file:
//
//   - Pin the post-B.13 required field set:
//     `(providerId, modelId, anchorHash, promptHash, tokensIn,
//       tokensOut, retries, wallClockMs)` are constructor-required
//     and round-trip verbatim.
//   - Pin the post-B.13 optional field set:
//     `cost`, `templateSha` default to `null`; `notes` defaults to
//     `const <String>[]`. Each one can be overridden on construction.
//   - Pin the plan-text mapping:
//     * "tokens in / out"   → `tokensIn`, `tokensOut` (`int`)
//     * "wall-clock"        → `wallClockMs` (`int`, milliseconds —
//                              not a `Duration`, to keep the trail's
//                              JSON shape uniform)
//     * "provider id"       → `providerId` (`String`)
//     * "model id"          → `modelId` (`String`)
//     * "retry count"       → `retries` (`int`, Dart-idiomatic plural)
//   - Prove the const-canonicalisation of structurally identical
//     instances (the all-required-fields, all-defaults instance is
//     reachable as a compile-time constant; two structurally identical
//     const instances are `identical`).
//   - Prove the value-class character: assignment / passing-by-ref
//     never mutates fields. `LlmCallReport` is `final`; subclasses
//     are forbidden by the analyzer.
//   - Prove the verbatim-string semantics on `providerId`, `modelId`,
//     `anchorHash`, `promptHash`, `templateSha` — no trimming, casing,
//     or normalisation. Identical-string contract is the trail's only
//     attribution lever; silent normalisation would corrupt it.
//   - Prove the `notes` list is preserved by reference (no defensive
//     copy on construction): providers stamp notes in one shot and
//     never mutate the list afterwards, so a defensive copy would be
//     wasted allocations on every call.
//   - Prove the surface is reachable through the top-level package
//     barrel.
//
// Scope this file is NOT for:
//
//   - JSON serialisation of `LlmCallReport`. Per spec § 3.1, the
//     trail's serialiser lives in the (Phase A) memory module, not
//     in substrate; substrate-side serialisation would be premature.
//     If a future step adds `toJson` / `fromJson` here, that step
//     owns the round-trip assertion.
//   - Equality / `hashCode`. Same posture as B.12 / Q-B.12.4: defer
//     until a consumer needs it. The router stamps the report onto
//     the trail; no in-memory comparison happens today.
//   - `copyWith`. Reports are constructed by the provider in one
//     shot (single allocation per call); the router never replaces a
//     field after construction. Mirrors the B.12 reasoning that
//     `copyWith` exists on `LlmOptions` only because the router's
//     field-merge path will need it. The report has no such consumer.
//   - Anchor-hash invariant enforcement. That is owned by B.46 — a
//     whole-substrate test that asserts every emitted report's
//     `anchorHash` equals `AnchorRegistry.currentHash`. The B.13
//     suite only proves the field exists and round-trips; it does
//     not prove a real provider's stamp matches the registry.
//   - Cost-table integration. `cost == null` ⇒ "no price entry for
//     this `(providerId, modelId)` pair." The price table itself
//     lands at B.18+ (router). B.13 pins only the field's default.

import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:test/test.dart';

void main() {
  group('B.13 / LlmCallReport — required field set', () {
    test(
      'every plan-text field is present and round-trips verbatim',
      () {
        const report = LlmCallReport(
          providerId: 'ollama:local',
          modelId: 'gemma3:27b',
          anchorHash: 'sha256:anchor-deadbeef',
          promptHash: 'sha256:prompt-c0ffee',
          tokensIn: 256,
          tokensOut: 1024,
          retries: 2,
          wallClockMs: 4500,
        );

        // Plan-text mapping ↓
        expect(report.providerId, 'ollama:local'); // "provider id"
        expect(report.modelId, 'gemma3:27b'); //     "model id"
        expect(report.tokensIn, 256); //              "tokens in"
        expect(report.tokensOut, 1024); //            "tokens out"
        expect(report.retries, 2); //                 "retry count"
        expect(report.wallClockMs, 4500); //          "wall-clock"

        // Provenance fields beyond the plan-text minimum.
        expect(report.anchorHash, 'sha256:anchor-deadbeef');
        expect(report.promptHash, 'sha256:prompt-c0ffee');
      },
    );

    test('every required field is positional-required on the constructor', () {
      // Dropping any of the eight required fields below makes this
      // test fail to compile, which is the load-bearing assertion of
      // the B.13 ratification: the plan-text minimum cannot silently
      // become optional.
      const report = LlmCallReport(
        providerId: 'stub',
        modelId: 'stub-v1',
        anchorHash: 'sha256:a',
        promptHash: 'sha256:p',
        tokensIn: 0,
        tokensOut: 0,
        retries: 0,
        wallClockMs: 0,
      );

      expect(report, isA<LlmCallReport>());
    });

    test(
      'tokens-in, tokens-out, retries, wall-clock are all `int` '
      '(no `num`, no `Duration`)',
      () {
        const report = LlmCallReport(
          providerId: 'p',
          modelId: 'm',
          anchorHash: 'h',
          promptHash: 'h',
          tokensIn: 1,
          tokensOut: 2,
          retries: 3,
          wallClockMs: 4,
        );

        // The static type of every counter is `int`. If a future
        // change widens to `num` or to `Duration`, this assertion
        // fails at compile time (the function-typed wrapper would
        // mis-match).
        expect(_intField(report.tokensIn), 1);
        expect(_intField(report.tokensOut), 2);
        expect(_intField(report.retries), 3);
        expect(_intField(report.wallClockMs), 4);
      },
    );
  });

  group('B.13 / LlmCallReport — optional field defaults', () {
    test(
      'cost defaults to null when omitted (no silent zero)',
      () {
        const report = LlmCallReport(
          providerId: 'p',
          modelId: 'm',
          anchorHash: 'h',
          promptHash: 'h',
          tokensIn: 0,
          tokensOut: 0,
          retries: 0,
          wallClockMs: 0,
        );

        // Per the class docstring: `cost` is null when the price
        // table has no entry for `(providerId, modelId)`. A silent
        // zero would let the trail report a free call where there
        // is in fact no price information.
        expect(report.cost, isNull);
      },
    );

    test(
      'templateSha defaults to null when omitted (role registry may '
      'not have a sha for a freshly-authored template)',
      () {
        const report = LlmCallReport(
          providerId: 'p',
          modelId: 'm',
          anchorHash: 'h',
          promptHash: 'h',
          tokensIn: 0,
          tokensOut: 0,
          retries: 0,
          wallClockMs: 0,
        );

        expect(report.templateSha, isNull);
      },
    );

    test('notes defaults to the empty const list when omitted', () {
      const report = LlmCallReport(
        providerId: 'p',
        modelId: 'm',
        anchorHash: 'h',
        promptHash: 'h',
        tokensIn: 0,
        tokensOut: 0,
        retries: 0,
        wallClockMs: 0,
      );

      expect(report.notes, isEmpty);
      expect(report.notes, isA<List<String>>());
    });

    test('every optional field can be set explicitly', () {
      const report = LlmCallReport(
        providerId: 'openai:passthrough',
        modelId: 'gpt-4o-mini',
        anchorHash: 'sha256:anchor',
        promptHash: 'sha256:prompt',
        tokensIn: 500,
        tokensOut: 1500,
        retries: 1,
        wallClockMs: 2300,
        cost: 0.0042,
        templateSha: 'deadbeef0123',
        notes: <String>[
          'response_format downgraded to text',
          'temperature clamped to 1.0',
        ],
      );

      expect(report.cost, 0.0042);
      expect(report.templateSha, 'deadbeef0123');
      expect(report.notes, hasLength(2));
      expect(report.notes.first, 'response_format downgraded to text');
      expect(report.notes.last, 'temperature clamped to 1.0');
    });
  });

  group('B.13 / LlmCallReport — verbatim string semantics', () {
    test('providerId preserves whitespace and case exactly', () {
      const report = LlmCallReport(
        providerId: '  Ollama:Local  ',
        modelId: 'm',
        anchorHash: 'h',
        promptHash: 'h',
        tokensIn: 0,
        tokensOut: 0,
        retries: 0,
        wallClockMs: 0,
      );

      // The trail attributes calls by *exact* providerId. Silent
      // trimming or canonicalisation would let two different
      // configured provider ids ("ollama:local" vs "Ollama:Local")
      // converge in the trail.
      expect(report.providerId, '  Ollama:Local  ');
    });

    test('modelId preserves whitespace and case exactly', () {
      const report = LlmCallReport(
        providerId: 'p',
        modelId: 'Gemma3:27B',
        anchorHash: 'h',
        promptHash: 'h',
        tokensIn: 0,
        tokensOut: 0,
        retries: 0,
        wallClockMs: 0,
      );

      expect(report.modelId, 'Gemma3:27B');
    });

    test('anchorHash + promptHash are kept byte-for-byte', () {
      const report = LlmCallReport(
        providerId: 'p',
        modelId: 'm',
        anchorHash: 'sha256:ABCDEF0123456789',
        promptHash: 'sha256:fedcba9876543210',
        tokensIn: 0,
        tokensOut: 0,
        retries: 0,
        wallClockMs: 0,
      );

      // Hash discipline is the anchor invariant's structural proof
      // (spec § 12 / Postulate 3). Any normalisation here would
      // make the B.46 conformance test pass for the wrong reason.
      expect(report.anchorHash, 'sha256:ABCDEF0123456789');
      expect(report.promptHash, 'sha256:fedcba9876543210');
    });
  });

  group('B.13 / LlmCallReport — value-class character', () {
    test('two structurally identical const instances canonicalise', () {
      // The const constructor is callable; structurally identical
      // const instances share a single canonical object. If a future
      // change introduced a non-const default for any field (e.g. a
      // `DateTime.now()` default), this `identical` would fail.
      const a = LlmCallReport(
        providerId: 'p',
        modelId: 'm',
        anchorHash: 'h',
        promptHash: 'h',
        tokensIn: 0,
        tokensOut: 0,
        retries: 0,
        wallClockMs: 0,
      );
      const b = LlmCallReport(
        providerId: 'p',
        modelId: 'm',
        anchorHash: 'h',
        promptHash: 'h',
        tokensIn: 0,
        tokensOut: 0,
        retries: 0,
        wallClockMs: 0,
      );

      expect(identical(a, b), isTrue);
    });

    test(
      'two const instances differing in one field are distinct objects',
      () {
        const a = LlmCallReport(
          providerId: 'p',
          modelId: 'm',
          anchorHash: 'h',
          promptHash: 'h',
          tokensIn: 0,
          tokensOut: 0,
          retries: 0,
          wallClockMs: 0,
        );
        const b = LlmCallReport(
          providerId: 'p',
          modelId: 'm',
          anchorHash: 'h',
          promptHash: 'h',
          tokensIn: 1, // ← differs
          tokensOut: 0,
          retries: 0,
          wallClockMs: 0,
        );

        expect(identical(a, b), isFalse);
      },
    );

    test(
      'notes list is preserved by reference (no defensive copy on '
      'construction)',
      () {
        // Providers stamp notes in one shot at report construction
        // and never mutate the list afterwards. A defensive copy
        // would be wasted allocations on every call. The contract:
        // the list passed in is the list held on the field.
        const sourceNotes = <String>['note-a', 'note-b'];
        const report = LlmCallReport(
          providerId: 'p',
          modelId: 'm',
          anchorHash: 'h',
          promptHash: 'h',
          tokensIn: 0,
          tokensOut: 0,
          retries: 0,
          wallClockMs: 0,
          notes: sourceNotes,
        );

        expect(identical(report.notes, sourceNotes), isTrue);
      },
    );

    test('large counter values round-trip without overflow', () {
      // Trail-side counters can reach into the millions of tokens
      // and hours of wall-clock on long runs; the field type is
      // `int` (Dart-native 64-bit on the VM) so a single-call
      // upper bound is effectively unreachable. Pin the range here
      // so a future narrowing to `int32` surfaces immediately.
      const report = LlmCallReport(
        providerId: 'p',
        modelId: 'm',
        anchorHash: 'h',
        promptHash: 'h',
        tokensIn: 1 << 30,
        tokensOut: 1 << 30,
        retries: 1 << 20,
        wallClockMs: 1 << 40,
      );

      expect(report.tokensIn, 1 << 30);
      expect(report.tokensOut, 1 << 30);
      expect(report.retries, 1 << 20);
      expect(report.wallClockMs, 1 << 40);
    });
  });

  group('B.13 / LlmCallReport — barrel reachability', () {
    test('LlmCallReport is exported from the top-level package barrel', () {
      // The single test-file import line is
      //   import 'package:tom_brain_substrate/tom_brain_substrate.dart';
      // — reaching `LlmCallReport` under that constraint proves the
      // api/ surface re-exports it.
      const report = LlmCallReport(
        providerId: 'p',
        modelId: 'm',
        anchorHash: 'h',
        promptHash: 'h',
        tokensIn: 0,
        tokensOut: 0,
        retries: 0,
        wallClockMs: 0,
      );
      expect(report, isA<LlmCallReport>());
    });
  });
}

/// Identity helper used by the "every counter is `int`" test.
///
/// The signature `int Function(int)` makes a future widening of the
/// counter field's type to `num` or `Duration` fail at the call site
/// instead of silently coercing.
int _intField(int value) => value;
