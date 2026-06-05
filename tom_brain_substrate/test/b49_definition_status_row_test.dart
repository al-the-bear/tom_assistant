// B.49 — Definition § 17 substrate-prototype status row sentinel.
//
// Plan step B.49 reads:
//
//   "Update relevant `tom_brain_definition.md` § 17 status row to ✅."
//
// This test is the code-level sentinel that pins the result of that
// step. The substrate prototype is *done at Phase B* (B.45 API
// conformance + B.46 anchor enforcement + B.47 coverage matrix +
// B.48 provider-matrix smoke, with the full suite green at B.48 and
// `dart analyze` clean), and the per-component status row in
// `tom_brain_definition.md` § 17 is the canonical readout of that
// fact for any cross-quest reader.
//
// Failure modes the sentinel catches:
//
//   1. The definition file is edited in a way that demotes the
//      substrate row away from ✅ without simultaneously demoting
//      the implementation. The phase-close attestation would
//      silently degrade.
//   2. The § 17 status table is renamed or restructured, breaking
//      cross-references in `phase_b_completeness_coverage.md` § 4
//      and in this details file's B.49 entry.
//   3. The companion rows the B.49 deliverable adds (memory
//      prototype, substrate prototype, future Phase C / D / E
//      rows) are removed or renamed without an accompanying spec
//      revision.
//
// The test deliberately does *not* assert anything about Phase A /
// C / D / E components — those have their own per-phase sentinels.
// This file is the substrate's half of the contract.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('B.49 — tom_brain_definition.md § 17 status row', () {
    // The definition document lives at the quest root. Tests run with
    // cwd = the substrate package root (tom_assistant/tom_brain_substrate),
    // so the relative path crosses two directories up into the
    // workspace, then down into the quest folder.
    final file = File(
      '../../_ai/quests/tom_brain/tom_brain_definition.md',
    );

    late List<String> lines;
    late int sectionStart;
    late int tableStart;
    late int tableEnd;

    setUpAll(() {
      expect(
        file.existsSync(),
        isTrue,
        reason: 'B.49 must be run from the tom_brain_substrate package '
            'root; expected ${file.path} to exist.',
      );
      lines = file.readAsLinesSync();

      // Locate "## 17. Status" — the section heading that owns the
      // table this test inspects.
      sectionStart = lines.indexWhere(
        (l) => l.trim() == '## 17. Status',
      );
      expect(
        sectionStart,
        greaterThanOrEqualTo(0),
        reason: 'Could not find "## 17. Status" heading in '
            '${file.path}. If the section was renamed or moved, '
            'update this test and the cross-references in '
            'phase_b_completeness_coverage.md § 4 simultaneously.',
      );

      // The table starts at the first row that looks like a markdown
      // table header below the section heading, and ends at the next
      // blank line (or end of file).
      tableStart = -1;
      for (var i = sectionStart + 1; i < lines.length; i++) {
        final trimmed = lines[i].trim();
        if (trimmed.startsWith('| Item') ||
            trimmed.startsWith('|Item')) {
          tableStart = i;
          break;
        }
      }
      expect(
        tableStart,
        greaterThanOrEqualTo(0),
        reason: 'Could not find the "| Item | State |" header row '
            'under § 17 in ${file.path}.',
      );

      tableEnd = lines.length;
      for (var i = tableStart + 2; i < lines.length; i++) {
        if (!lines[i].trim().startsWith('|')) {
          tableEnd = i;
          break;
        }
      }
    });

    test('§ 17 section header is present and well-formed', () {
      // Verified in setUpAll; this test is here so the failure
      // surfaces as its own reportable assertion in the test
      // reporter rather than as a setUpAll error.
      expect(sectionStart, greaterThanOrEqualTo(0));
      expect(tableStart, greaterThan(sectionStart));
      expect(tableEnd, greaterThan(tableStart));
    });

    test('substrate-prototype row exists and reads ✅', () {
      // The B.49 deliverable: the per-component status row for the
      // substrate prototype must exist and must be marked ✅. The
      // row's leading column is the canonical substring
      // "`tom_brain_substrate` (prototype)" — surface drift on
      // either side will break this assertion.
      final row = _findRow(
        lines,
        tableStart,
        tableEnd,
        leadingNeedle: '`tom_brain_substrate` (prototype)',
      );
      expect(
        row,
        isNotNull,
        reason: 'Expected a row whose Item column contains '
            '"`tom_brain_substrate` (prototype)" in § 17 of '
            '${file.path}. The B.49 deliverable adds this row and '
            'phase_b_completeness_coverage.md § 4 cites it.',
      );
      final state = _stateCell(row!);
      expect(
        state.startsWith('✅'),
        isTrue,
        reason: 'The tom_brain_substrate prototype row must be ✅ at '
            'the end of Phase B (B.49). Found: "$state". If this '
            'is being demoted, the corresponding implementation '
            'rollback must land in the same change.',
      );
    });

    test('substrate-specification row reads ✅', () {
      // B.49 also flips substrate_specification.md to ✅ — the spec
      // has been load-bearing through every Phase B step (B.3
      // authored it; B.43 / B.45 / B.46 / B.47 / B.48 all cited
      // its sections as the contracts they pin).
      final row = _findRow(
        lines,
        tableStart,
        tableEnd,
        leadingNeedle: '`substrate_specification.md`',
      );
      expect(row, isNotNull,
          reason: '§ 17 must retain the substrate_specification.md row.');
      expect(
        _stateCell(row!).startsWith('✅'),
        isTrue,
        reason: 'substrate_specification.md must read ✅ at B.49.',
      );
    });

    test('memory-prototype row exists and reads ✅', () {
      // Phase A's deliverable, lifted into § 17 as a per-component
      // row by B.49 so the table reads symmetrically. If a future
      // edit demotes Phase A's status, that would surface here.
      final row = _findRow(
        lines,
        tableStart,
        tableEnd,
        leadingNeedle: '`tom_brain_memory` (prototype)',
      );
      expect(row, isNotNull,
          reason: 'Expected `tom_brain_memory` (prototype) row in § 17.');
      expect(
        _stateCell(row!).startsWith('✅'),
        isTrue,
        reason: 'tom_brain_memory prototype must read ✅ — it was '
            'closed at Phase A (A.89 / A.90 / A.92).',
      );
    });

    test('tom_brain_shared row exists and reads ✅', () {
      // The cross-component vocabulary library. Listed explicitly
      // because the substrate's anchor enforcement (B.46) depends
      // on its `AssistantDedicationAnchor` constants and the B.44
      // extraction landed `JsonShape` into it.
      final row = _findRow(
        lines,
        tableStart,
        tableEnd,
        leadingNeedle: '`tom_brain_shared`',
      );
      expect(row, isNotNull,
          reason: 'Expected `tom_brain_shared` row in § 17.');
      expect(
        _stateCell(row!).startsWith('✅'),
        isTrue,
        reason: 'tom_brain_shared must read ✅ — every Phase B step '
            'consumed it.',
      );
    });

    test('forward-looking rows for unfinished phases remain ⏳', () {
      // The companion rows for the still-unbuilt Phase C / D
      // components must NOT be flipped to ✅ by this step. If a later
      // phase tries to silently piggy-back on B.49, this guard
      // surfaces the drift.
      //
      // `End-to-end smoke` was originally guarded here too, but it was
      // *legitimately* flipped ⏳→✅ at the Phase-E close (E.57 audit,
      // commit b5a98062 — `tom_brain_smoke_prototype` 42/42). That is a
      // real, documented phase progression, not the silent B.49-era
      // piggy-back this sentinel was written to catch. Per this file's
      // own scope note ("deliberately does *not* assert anything about
      // Phase … E components — those have their own per-phase
      // sentinels"), a now-finished Phase-E deliverable no longer
      // belongs in this Phase-B forward-looking guard, so it is dropped.
      // The two genuinely-still-⏳ Phase-C/D rows stay guarded.
      const forwardRows = <String>[
        '`tom_brain_procedure_engine` (prototype)',
        '`tom_brain_access` (prototype)',
      ];
      for (final needle in forwardRows) {
        final row = _findRow(
          lines,
          tableStart,
          tableEnd,
          leadingNeedle: needle,
        );
        expect(row, isNotNull,
            reason: 'Expected forward-looking row "$needle" in § 17.');
        expect(
          _stateCell(row!).startsWith('⏳'),
          isTrue,
          reason: 'Forward-looking row "$needle" must remain ⏳ at '
              'B.49 — it is Phase C / D / E\'s deliverable, not '
              'Phase B\'s. Found: "${_stateCell(row)}".',
        );
      }
    });
  });
}

/// Returns the first table row (under `start..end`) whose Item
/// (first non-separator) column contains [leadingNeedle], or `null`.
String? _findRow(
  List<String> lines,
  int start,
  int end, {
  required String leadingNeedle,
}) {
  for (var i = start; i < end; i++) {
    final l = lines[i];
    if (!l.trim().startsWith('|')) continue;
    // Skip the header + separator rows.
    if (l.contains('---')) continue;
    if (l.contains('| Item') || l.contains('|Item')) continue;
    if (l.contains(leadingNeedle)) return l;
  }
  return null;
}

/// Extracts the State cell (second `|`-delimited field) from a row.
String _stateCell(String row) {
  // A markdown row of shape "| Item | State |" splits into
  // ['', ' Item ', ' State ', ''] when separated by '|'.
  final parts = row.split('|');
  expect(parts.length, greaterThanOrEqualTo(4),
      reason: 'Malformed table row: "$row"');
  return parts[2].trim();
}
