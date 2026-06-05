// P2.14 — bootstrap catalogue on open().
//
// prototype_implementation_plan_2.md #14:
//   "Memory: bootstrap catalogue on open. Register the 21 node types,
//    12-edge alphabet, and 6 bootstrap stacks during open() (idempotent).
//    Test: all 21/12/6 present and re-open() is a no-op. Verify:
//    listNodeTypes() returns the full catalogue."
//
// open() now boots the storage stack AND seeds the catalogue: the 21
// spec node types from the bootstrap manifest, the six reserved stacks
// from § 5.4, all referencing only the closed 12-edge alphabet
// (EdgeType). Because open() refuses to boot without a loadable vec0
// (P1.1), these positive cases need the packaged binary and are
// skipped — not failed — when the running platform has no binary under
// tom_binaries/sqlite_vec/<platform>/, mirroring
// p2_13_sqlite_memory_open_test.dart.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart';

/// The 21 spec node types (memory_specification.md § 4). Mirrors the
/// set asserted by a39_end_to_end_test.dart so the manifest, the
/// registry, and the store stay in lockstep.
const _expectedNodeTypes = <String>{
  'Event',
  'Claim',
  'Concept',
  'Conclusion',
  'Question',
  'Pattern',
  'Contradiction',
  'Source',
  'Plan',
  'PlanStep',
  'Artifact',
  'Procedure',
  'ProcedureRun',
  'AutomationIdea',
  'InterestItem',
  'NodeType',
  'Session',
  'Trail',
  'Stack',
  'StackEntry',
  'Tombstone',
};

/// The six reserved bootstrap stacks (memory_specification.md § 5.4).
const _expectedStacks = <String>{
  'questions_open',
  'automation_ideas',
  'interests',
  'inflight',
  'recent_runs',
  'restructure_backlog',
};

/// Locates `<workspace>/tom_binaries/sqlite_vec` by walking up from the
/// test runner's CWD. Mirrors p2_13_sqlite_memory_open_test.dart.
String? _findSqliteVecRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    final candidate =
        Directory('${dir.path}${Platform.pathSeparator}tom_binaries'
            '${Platform.pathSeparator}sqlite_vec');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  final vecRoot = _findSqliteVecRoot();
  final resolver = SqliteVecBinaryResolver();

  String? resolvedPath;
  if (vecRoot != null && resolver.isSupported) {
    final path = resolver.resolve(vecRoot);
    if (File(path).existsSync()) resolvedPath = path;
  }

  final skipNoBinary = resolvedPath == null
      ? 'No packaged vec0 binary for this platform under '
          'tom_binaries/sqlite_vec (resolver.isSupported='
          '${resolver.isSupported}, vecRoot=$vecRoot).'
      : null;

  group('SqliteTomBrainMemory.open — bootstrap catalogue (needs vec0)', () {
    test(
      'seeds all 21 node types, only the 12-edge alphabet, and the '
      '6 bootstrap stacks; listNodeTypes() returns the full catalogue',
      () async {
        final root = Directory.systemTemp.createTempSync('tbm_catalogue_');
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });

        final store = SqliteTomBrainMemory();
        addTearDown(store.close);
        await store.open(MemoryConfig.forTesting(
          root: root.path,
          binariesRoot: vecRoot!,
        ));

        // 21 node types via the public surface.
        final types = await store.listNodeTypes();
        expect(types, hasLength(21));
        expect(types.map((d) => d.typeName).toSet(), equals(_expectedNodeTypes));

        // Each registered type at bootstrap version 1, reachable via
        // getNodeType.
        for (final name in _expectedNodeTypes) {
          final decl = await store.getNodeType(name);
          expect(decl, isNotNull, reason: 'getNodeType($name)');
          expect(decl!.version.value, equals(1));
        }

        // 12-edge alphabet: every allowed-edge label round-trips to a
        // valid EdgeType. A manifest typo that survived YAML parsing
        // must not survive registration.
        for (final decl in types) {
          for (final out in decl.allowedOutgoing) {
            expect(EdgeType.values, contains(out),
                reason: 'allowedOutgoing on ${decl.typeName}');
          }
          for (final inc in decl.allowedIncoming) {
            expect(EdgeType.values, contains(inc),
                reason: 'allowedIncoming on ${decl.typeName}');
          }
        }

        // 6 bootstrap stacks present and flagged is_bootstrap.
        final stackRows = store.debugMemoryDatabase
            .select('SELECT name, is_bootstrap FROM stacks')
            .toList();
        expect(stackRows.map((r) => r['name'] as String).toSet(),
            equals(_expectedStacks));
        for (final r in stackRows) {
          expect(r['is_bootstrap'], equals(1),
              reason: 'stack ${r['name']} must be flagged bootstrap');
        }
      },
      skip: skipNoBinary,
    );

    test(
      're-open() against the same root is a no-op: no duplicate node '
      'types or stacks',
      () async {
        final root = Directory.systemTemp.createTempSync('tbm_catalogue_re_');
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });

        final config = MemoryConfig.forTesting(
          root: root.path,
          binariesRoot: vecRoot!,
        );

        // First open seeds the catalogue, then close so the second
        // open re-runs the seeding path against an already-seeded DB.
        final first = SqliteTomBrainMemory();
        await first.open(config);
        expect(await first.listNodeTypes(), hasLength(21));
        await first.close();

        final second = SqliteTomBrainMemory();
        addTearDown(second.close);
        await second.open(config);

        // Still exactly 21 node types and 6 stacks — the seeding path
        // skipped everything already present.
        expect(await second.listNodeTypes(), hasLength(21));
        expect(
          second.debugMemoryDatabase
              .select('SELECT COUNT(*) AS n FROM node_types')
              .first['n'],
          equals(21),
        );
        expect(
          second.debugMemoryDatabase
              .select('SELECT COUNT(*) AS n FROM stacks')
              .first['n'],
          equals(6),
        );
      },
      skip: skipNoBinary,
    );
  });
}
