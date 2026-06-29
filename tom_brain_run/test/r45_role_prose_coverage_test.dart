// R.45 — role-prose coverage over the committed `config/bomber/cognition`
// tree (prompt-restructuring plan step 7 / `prompt_configuration.md` §7.1,
// increment 8 close-out).
//
// Step 7 externalises the persona + objective prose for *every* live role to
// `cognition/<rolesFolder>/<role>.persona.md` + `<role>.objective.md`, keeping
// the in-code prose as the reviewed fallback and the capability surface in
// code (AUTH-6 / Postulate 3). The loader behaviour itself (override,
// fallback, capability-surface invariance, anchor) is unit-tested at the
// substrate layer in `p2_11_file_backed_role_loader_test.dart` over temp
// dirs. This file pins the *run* obligation the unit tests cannot see: that
// the committed bomber config tree actually carries a present, non-blank prose
// pair for every role the live roster
// (`bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningDreamAndHistory()`)
// registers — so no live role silently degrades to its in-code fallback — and
// that there are no orphan prose files for ids the roster does not contain.
//
// Why this is a run-level test, not a substrate one: the live roster is
// composed in `tom_brain_substrate`, but the *prose files* are committed under
// `tom_brain_run/config/bomber/cognition/roles`, and the wiring that overlays
// them (`provision_brain.dart` → `ReloadingRoleRegistry.reloading(base: <live
// roster>, rolesDir: cognition/<rolesFolder>)`) lives in `tom_brain_run`. A new
// role added to the roster without its two prose files would pass every
// substrate test (the loader falls back happily) yet ship a live run whose new
// role speaks its in-code voice instead of the externalised one. This test is
// the regression guard for exactly that gap.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show AssistantDedicationAnchor;
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

/// The committed cognition config tree this test reads the role prose from.
/// `Directory.current` is the package root under `dart test` / testkit.
String _cognitionRoot() => Directory(
      '${Directory.current.absolute.path}${Platform.pathSeparator}config'
      '${Platform.pathSeparator}bomber${Platform.pathSeparator}cognition',
    ).absolute.path;

void main() {
  late RoleRegistry liveRoster;
  late CognitionConfig cognitionConfig;
  late Directory rolesDir;

  setUpAll(() {
    liveRoster =
        bootstrapRoleRegistryWithRetrievalProcedureCreationPlanningDreamAndHistory();
    cognitionConfig = CognitionConfigLoader.loadFromDir(_cognitionRoot());
    rolesDir = Directory(
      '${_cognitionRoot()}${Platform.pathSeparator}'
      '${cognitionConfig.registry.rolesFolder}',
    );
  });

  String? readTrimmed(String fileName) {
    final file = File('${rolesDir.path}${Platform.pathSeparator}$fileName');
    if (!file.existsSync()) return null;
    final trimmed = file.readAsStringSync().trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  group('R.45 — prose coverage over the live roster', () {
    test('every live role has a present, non-blank .persona.md', () {
      final missing = <String>[];
      for (final id in liveRoster.ids) {
        if (readTrimmed('$id.persona.md') == null) missing.add(id);
      }
      expect(
        missing,
        isEmpty,
        reason: 'these live roles have no committed persona file (they would '
            'silently fall back to the in-code voice on a live run): $missing',
      );
    });

    test('every live role has a present, non-blank .objective.md', () {
      final missing = <String>[];
      for (final id in liveRoster.ids) {
        if (readTrimmed('$id.objective.md') == null) missing.add(id);
      }
      expect(
        missing,
        isEmpty,
        reason: 'these live roles have no committed objective file: $missing',
      );
    });

    test('the roster is the full thirty-two-role live cognition (regression on '
        'silent roster shrinkage)', () {
      // The number is load-bearing only as a tripwire: if a future roster
      // change adds or drops roles, this forces a deliberate update here and a
      // matching prose-file change, rather than a silent coverage gap. The
      // thirty-second role is `history_compactor` (completion-plan item 4,
      // HC-81) — the dedicated home the engine-side `HistoryCompactor` routes
      // under, composed on after the eight dreaming roles.
      expect(liveRoster.length, equals(32));
    });
  });

  group('R.45 — no orphan prose files', () {
    test('every <stem>.persona.md / <stem>.objective.md maps to a live role',
        () {
      final rosterIds = liveRoster.ids.toSet();
      final orphans = <String>[];
      for (final entity in rolesDir.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        String? stem;
        if (name.endsWith('.persona.md')) {
          stem = name.substring(0, name.length - '.persona.md'.length);
        } else if (name.endsWith('.objective.md')) {
          stem = name.substring(0, name.length - '.objective.md'.length);
        }
        if (stem != null && !rosterIds.contains(stem)) {
          orphans.add(name);
        }
      }
      expect(
        orphans,
        isEmpty,
        reason: 'these prose files name an id no live role uses (a stale file '
            'after a role rename / removal): $orphans',
      );
    });
  });

  group('R.45 — the committed prose is actually sourced on a live run', () {
    late RoleRegistry fileBacked;

    setUp(() {
      fileBacked =
          loadFileBackedRoleRegistry(base: liveRoster, rolesDir: rolesDir);
    });

    test('each role assembles its persona/objective from the on-disk file, not '
        'the in-code fallback', () {
      for (final id in liveRoster.ids) {
        expect(
          fileBacked.get(id).personaText,
          equals(readTrimmed('$id.persona.md')),
          reason: '$id persona must come from the committed file',
        );
        expect(
          fileBacked.get(id).objective,
          equals(readTrimmed('$id.objective.md')),
          reason: '$id objective must come from the committed file',
        );
      }
    });

    test('the capability surface is unaffected by the on-disk prose '
        '(AUTH-6 / Postulate 3)', () {
      for (final id in liveRoster.ids) {
        final base = liveRoster.get(id);
        final loaded = fileBacked.get(id);
        expect(loaded.allowedActions, equals(base.allowedActions),
            reason: '$id allowedActions must stay the in-code authority');
        expect(loaded.forbiddenActions, equals(base.forbiddenActions),
            reason: '$id forbiddenActions must stay the in-code authority');
        expect(loaded.outputSchema, equals(base.outputSchema),
            reason: '$id outputSchema must stay the in-code authority');
        expect(loaded.budgetDefaults, equals(base.budgetDefaults),
            reason: '$id budgetDefaults must stay the in-code authority');
      }
    });

    test('every file-backed role still leads its prompt with the anchor and '
        'records the current hash', () {
      for (final id in liveRoster.ids) {
        final prompt = fileBacked.get(id).assemble();
        expect(
          prompt.system.startsWith(AssistantDedicationAnchor.text),
          isTrue,
          reason: '$id (file-loaded) must open the system channel with the '
              'anchor',
        );
        expect(prompt.anchorHash, equals(AnchorRegistry.currentHash));
        // The on-disk persona must survive into the assembled system channel.
        expect(prompt.system, contains(readTrimmed('$id.persona.md')!));
      }
    });
  });
}
