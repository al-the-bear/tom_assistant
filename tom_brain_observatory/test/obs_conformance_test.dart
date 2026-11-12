// PT-8.1..PT-8.3 — the read-only / no-interference conformance suite
// (`prompt_tracing.md` § 6.2, `prompt_tracing_plan.md` § 9). This is the proof
// that the observatory is the "one-way mirror" the spec promises (G-5): a fully
// wired server can be driven across its entire surface without writing one
// trail byte, without a write door into memory, without opening a DB handle,
// and without any control path into the brain.
//
// The suite consolidates the per-endpoint OBS micro-checks (which each proved
// one route read-only against the same fixture) into one comprehensive walk,
// and adds the three invariants that no single-endpoint test can state:
//
//   PT-8.1 / OBS-1  — exercising every endpoint mutates no file under the trail
//                     root (a snapshot of modified+changed+size+mode + the path
//                     set, before vs after the whole walk).
//   PT-8.2 / OBS-2  — the memory read client's registry excludes the write tool.
//   PT-8.2 / OBS-3  — the only memory door (the MCP client) holds no `dart:io`,
//                     and exercising every endpoint never touches sentinel
//                     `.db`/`-wal`/`-shm` files dropped into the trail tree.
//   PT-8.3 / OBS-4  — no source in `lib/` carries write/control IO vocabulary,
//                     and no route maps to `memory.persistNote`.
//   PT-8.3 / OBS-5  — the live-tail's only change source is an OS file-watch
//                     (`Directory.watch`); it installs no in-process hook.
//
// OBS-1/3's "no write" claims are stated two ways on purpose: behaviourally
// (the file-snapshot walk) and structurally (the source scan). The structural
// proofs are the ones that stay red if a future edit *adds* a write path even
// when no test happens to exercise it.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tom_brain_observatory/tom_brain_observatory.dart';
import 'package:tom_brain_config/tom_brain_config.dart' show CognitionConfigLoader;
import 'package:test/test.dart';

import 'memory/support/fake_read_connection.dart';
import 'support/obs_harness.dart';

/// A fully wired server: trail host + web root + script root + a (faked) memory
/// client, so [exerciseEveryEndpoint] reaches every route. When [cognitionRoot]
/// is supplied the catalogue + template/config read routes (steps 14–16) execute
/// their real read path against that tree (rather than answering `503`); the tree
/// is the editable authoring surface, deliberately *not* one of the brain-owned
/// roots OBS-1 snapshots, so a read of it leaves the trail untouched all the same.
TrailReadApi _wiredApi(String hostPath, {Directory? cognitionRoot}) =>
    TrailReadApi(
      host: TrailHost.at(hostPath),
      webRoot: Directory(fixtureWebRootPath),
      scriptRoot: Directory(fixtureScriptRootPath),
      memory: MemoryReadClient(FakeReadConnection(allReadToolStubs())),
      cognition: cognitionRoot == null
          ? null
          : CognitionConfigLoader.loadFromDir(cognitionRoot.path),
      cognitionRoot: cognitionRoot,
    );

/// Recursively copies the trail tree at [from] into a fresh temp dir, returning
/// the copy's path — so the DB-sentinel test can mutate-around without touching
/// the committed fixture.
String _copyTreeToTemp(String from) {
  final dest = Directory.systemTemp.createTempSync('obs_conformance_');
  for (final entity in Directory(from).listSync(recursive: true)) {
    final rel = p.relative(entity.path, from: from);
    final target = p.join(dest.path, rel);
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      Directory(p.dirname(target)).createSync(recursive: true);
      entity.copySync(target);
    }
  }
  return dest.path;
}

void main() {
  group('PT-8.1 — OBS-1: the app never writes the trail tree', () {
    test('exercising every endpoint mutates no file the brain owns', () async {
      // Wire a real cognition tree so the steps-14..16 read routes
      // (`/api/catalogue`, `GET /api/templates`, `GET /api/config`) execute their
      // real read path inside the walk — not merely the `503` config-unavailable
      // branch — and prove they touch no brain-owned file either.
      final cognitionDir = Directory.systemTemp.createTempSync('obs_conf_cog_');
      addTearDown(() => cognitionDir.deleteSync(recursive: true));
      writeMinimalCognitionTree(cognitionDir);
      final api = _wiredApi(fixtureHostPath, cognitionRoot: cognitionDir);
      // Everything the brain wrote that this app reads: the trail tree, the
      // procedure-script root, and the served web build. The cognition tree is
      // the editable authoring surface, not a brain-owned read root, so it is not
      // snapshotted here (its writes are the dedicated endpoint tests' concern).
      final roots = <String>[
        fixtureHostPath,
        fixtureScriptRootPath,
        fixtureWebRootPath,
      ];
      final before = <String, FsSnapshot>{
        for (final root in roots) root: FsSnapshot.capture(root),
      };

      await exerciseEveryEndpoint(api);

      for (final root in roots) {
        expect(before[root]!.diff(FsSnapshot.capture(root)), isEmpty,
            reason: 'a read-only surface must create/truncate/modify nothing '
                'under $root');
      }
    });
  });

  group('PT-8.2 — OBS-2: the app never writes memory', () {
    test('the read client registry excludes the write tool', () {
      expect(MemoryReadClient.readToolNames, hasLength(9));
      expect(MemoryReadClient.writeToolName, 'memory.persistNote');
      expect(MemoryReadClient.readToolNames,
          isNot(contains(MemoryReadClient.writeToolName)));
    });

    test('no /api/memory route maps to the write tool', () {
      final src = libDartSources()['lib/src/api/memory_read_api.dart'];
      expect(src, isNotNull);
      // The write tool name appears only in the comment that explains its
      // absence — never as a registered route. There is no `persistNote` route
      // method, so the HTTP surface has no write door (§ 6.2).
      expect(src, isNot(contains("router.post('/api/memory")));
      expect(RegExp(r"\.post\('/api/memory/[^']*persist").hasMatch(src!),
          isFalse);
    });
  });

  group('PT-8.2 — OBS-3: the app never touches the memory DB files', () {
    test('the only memory door (lib/src/memory/) imports no dart:io', () {
      final memorySources = <String, String>{
        for (final entry in libDartSources().entries)
          if (p.split(entry.key).contains('memory')) entry.key: entry.value,
      };
      expect(memorySources, isNotEmpty,
          reason: 'the memory subsystem must exist to be checked');
      for (final entry in memorySources.entries) {
        expect(entry.value, isNot(contains("import 'dart:io'")),
            reason: '${entry.key} is a memory-door file and must hold no '
                'filesystem capability — memory flows only through MCP (OBS-3)');
      }
    });

    test('no lib/ source references a memory DB / storage-stack file', () {
      // DB-file paths (`.db`/`-wal`/`-shm`, the sqlite-vec / FTS5 index names)
      // and the storage-stack package imports — never the English word "drift",
      // which legitimately appears in prose about spec drift.
      final dbTokens = <RegExp>[
        RegExp(r'\.db\b'),
        RegExp(r'-wal\b'),
        RegExp(r'-shm\b'),
        RegExp(r'package:(sqlite|sqflite|drift|hive)', caseSensitive: false),
        RegExp('vec0'),
        RegExp('fts5', caseSensitive: false),
      ];
      for (final entry in libDartSources().entries) {
        for (final token in dbTokens) {
          expect(token.hasMatch(entry.value), isFalse,
              reason: '${entry.key} references "${token.pattern}" — the app '
                  'must hold no DB-file path (OBS-3)');
        }
      }
    });

    test('exercising every endpoint never opens/mutates a DB-file sentinel',
        () async {
      final hostPath = _copyTreeToTemp(fixtureHostPath);
      addTearDown(() => Directory(hostPath).deleteSync(recursive: true));
      // Drop the three storage-stack file shapes into the trail tree. If any
      // code path opened one for writing (or locked+rewrote it), the snapshot
      // diff would surface it.
      for (final name in <String>['memory.db', 'memory.db-wal', 'memory.db-shm']) {
        File(p.join(hostPath, name)).writeAsStringSync('SENTINEL');
      }
      final api = _wiredApi(hostPath);
      final before = FsSnapshot.capture(hostPath);

      await exerciseEveryEndpoint(api);

      expect(before.diff(FsSnapshot.capture(hostPath)), isEmpty);
    });
  });

  group('PT-8.3 — OBS-4: writes confined to the source-authoring surface', () {
    // The source-authoring surface (`prompt_tracing.md` § 6.3, AUTH-1) is the
    // *one* sanctioned write site: `PUT /api/procedures/<id>` and
    // `PUT /api/templates?id=&part=` write a procedure script / template file
    // under containment (AUTH-2) + validation (AUTH-3). It is still not a
    // control path into the brain (OBS-4): the brain pulls the edit by
    // re-reading source (AUTH-5); the app never pushes. Every *other* lib/
    // source stays write-free, and even the authoring file may write only via
    // the single sanctioned verb — never a delete / rename / truncate /
    // openWrite / raw-file write that could reach the trail or memory (OBS-1 /
    // OBS-3 prove those roots stay byte-for-byte untouched under exercise).
    const authoringSurface = 'lib/src/api/trail_read_api.dart';

    /// The destructive / raw write verbs no source may carry — the sanctioned
    /// `writeAsStringSync` of the authoring surface is deliberately absent so it
    /// can be checked separately.
    final destructiveIo = <RegExp>[
      RegExp(r'\.openWrite\('),
      RegExp(r'\.writeAsBytes'),
      RegExp(r'RandomAccessFile'),
      RegExp(r'FileMode\.(write|append|writeOnly|writeOnlyAppend)'),
      RegExp(r'\.create(Sync)?\('),
      RegExp(r'\.delete(Sync)?\('),
      RegExp(r'\.rename(Sync)?\('),
      RegExp(r'\.truncate(Sync)?\('),
    ];

    test('no lib/ source outside the authoring surface carries any write IO',
        () {
      // The operationalisation of "no write path is introduced anywhere in the
      // package at any phase" (`prompt_tracing_plan.md` § 10), minus the one
      // file the spec sanctions. A future edit that adds write IO to any other
      // file — or that adds a control path — turns this red with no endpoint
      // test.
      final writeIo = <RegExp>[...destructiveIo, RegExp(r'\.writeAsString')];
      for (final entry in libDartSources().entries) {
        if (entry.key == authoringSurface) continue;
        for (final token in writeIo) {
          expect(token.hasMatch(entry.value), isFalse,
              reason: '${entry.key} matches "${token.pattern}" — only the '
                  'authoring surface ($authoringSurface) may write (OBS-4)');
        }
      }
    });

    test('the authoring surface writes only via the sanctioned verb', () {
      final src = libDartSources()[authoringSurface];
      expect(src, isNotNull);
      // The two PUT handlers write through `writeAsStringSync` and nothing
      // else: no destructive or raw-file verb that could reach the trail or
      // memory is present.
      for (final token in destructiveIo) {
        expect(token.hasMatch(src!), isFalse,
            reason: '$authoringSurface matches "${token.pattern}" — the '
                'authoring surface may only write source files, never '
                'delete/rename/truncate or raw-write (AUTH-1)');
      }
      expect(src, contains('writeAsStringSync'));
    });
  });

  group('PT-8.4 — the mutation surface is exactly the three authoring routes',
      () {
    // Step 17: the only mutation routes are `PUT /api/procedures/<id>`,
    // `PUT /api/templates`, and `PUT /api/config`; everything else is
    // read-only. This is the HTTP-edge counterpart to OBS-1/OBS-3 (which prove
    // the *trail* and *memory* roots stay byte-for-byte untouched): here we
    // enumerate every route registration across the whole `lib/` surface, by
    // verb, so a future edit that adds a write/delete door anywhere turns this
    // red with no endpoint test.

    /// Every route path registered with HTTP [method] across all lib sources —
    /// matches the `..put('PATH', …)` / `router.post('PATH', …)` registration
    /// forms used by the three route files.
    Set<String> routesFor(String method) {
      final re = RegExp("\\.$method\\('([^']+)'");
      return <String>{
        for (final src in libDartSources().values)
          for (final m in re.allMatches(src)) m.group(1)!,
      };
    }

    test('the only write-source (PUT) routes are the three sanctioned ones',
        () {
      expect(routesFor('put'), <String>{
        '/api/procedures/<procedureId>',
        '/api/templates',
        '/api/config',
      });
    });

    test('no route uses the destructive DELETE verb', () {
      expect(routesFor('delete'), isEmpty,
          reason: 'a DELETE route is a mutation door — the only mutation '
              'routes are the three PUT authoring routes (step 17)');
    });

    test('every POST route is a read-only memory query, never a mutation', () {
      // POST carries a request body, but only for the memory recall/classify
      // *reads* (OBS-2 proves none maps to the write tool). No POST exists
      // outside the memory read surface, so POST is not a hidden mutation door.
      for (final route in routesFor('post')) {
        expect(route, startsWith('/api/memory/'),
            reason: 'POST $route is outside the memory read surface — the only '
                'mutation routes are the three PUT authoring routes (step 17)');
      }
    });
  });

  group('PT-8.4 — AUTH-6: the anchor and tool-policy profiles are not editable',
      () {
    // AUTH-6 (`prompt_tracing.md` § 6.3): the assistant-dedication anchor and
    // the tool-policy profiles are structural — the anchor is injected on every
    // LLM call by `RoleTemplate.assemble`, the profiles gate tool access — and
    // must never be reachable through the authoring surface. Proven two ways:
    // behaviourally (the config wire-kind alphabet refuses them; the anchor is
    // not a catalogue template) and structurally (the kind translator names
    // only the four editable kinds).
    late Directory cognitionDir;

    setUp(() {
      cognitionDir = Directory.systemTemp.createTempSync('obs_auth6_');
      writeMinimalCognitionTree(cognitionDir);
    });
    tearDown(() {
      if (cognitionDir.existsSync()) cognitionDir.deleteSync(recursive: true);
    });

    TrailReadApi cognitionWired() => TrailReadApi(
          host: TrailHost.at(fixtureHostPath),
          cognition: CognitionConfigLoader.loadFromDir(cognitionDir.path),
          cognitionRoot: cognitionDir,
        );

    test('PUT /api/config refuses an anchor / tool-policy / profile kind (403)',
        () async {
      final api = cognitionWired();
      for (final kind in <String>[
        'anchor',
        'tool_policy',
        'tool_policy_profile',
        'profile',
        'persona_anchor',
      ]) {
        final res = await obsPut(
          api,
          'api/config?kind=${Uri.encodeQueryComponent(kind)}&name=any',
          body: 'whatever: 1',
        );
        expect(res.statusCode, HttpStatus.forbidden,
            reason: 'kind=$kind is outside the editable alphabet — the anchor '
                'and tool-policy profiles are not editable at the HTTP surface '
                '(AUTH-6)');
      }
    });

    test('PUT /api/templates refuses the dedication anchor (unregistered, 403)',
        () async {
      // The assistant-dedication anchor is injected structurally by
      // `RoleTemplate.assemble`; it is not a catalogue-registered template, so
      // it has no editable door through the template surface either (AUTH-6).
      final res = await obsPut(
        cognitionWired(),
        'api/templates?id=assistant_dedication_anchor&part=system',
        body: 'a hijacked anchor',
      );
      expect(res.statusCode, HttpStatus.forbidden);
    });

    test('the config kind alphabet names only the four editable kinds', () {
      final src = libDartSources()['lib/src/api/trail_read_api.dart']!;
      // Positive: `_kindFromWire` (the single gate) names the four editable
      // kinds. Negative: it names no anchor / tool-policy / profile kind, so a
      // future edit that makes one editable turns this red even before a
      // behavioural test exists for it (AUTH-6).
      for (final kind in <String>[
        "'registry'",
        "'procedure'",
        "'llm_route'",
        "'substrate'",
      ]) {
        expect(src, contains(kind));
      }
      for (final forbidden in <String>[
        "'anchor'",
        "'tool_policy'",
        "'profile'",
        "'persona_anchor'",
      ]) {
        expect(src, isNot(contains(forbidden)),
            reason: '$forbidden appears as a config kind — the anchor and '
                'tool-policy profiles must not be editable (AUTH-6)');
      }
    });
  });

  group('PT-8.3 — OBS-5: live-tail is a file watch, not a hook', () {
    test('the live-tail change source is an OS Directory.watch only', () {
      final src = libDartSources()['lib/src/live/live_tail.dart'];
      expect(src, isNotNull);
      // The change signal is produced by watching the parent directory — an OS
      // file-watch — and nothing else. `liveTrailChanges` (the production
      // change source) is built on `Directory.watch`; the tail subscribes to
      // *that* stream, never to a sink or callback inside the brain process
      // (there is no brain reference here to register a hook on).
      expect(src, contains('.watch(events:'));
      expect(src, contains('FileSystemEvent.modify'));
    });

    test('the list-level stream also watches a directory, never hooks', () {
      final src = libDartSources()['lib/src/api/trail_read_api.dart'];
      expect(src, isNotNull);
      expect(src, contains('.watch()'));
    });
  });
}
