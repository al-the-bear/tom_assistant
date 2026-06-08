// TrailJanitor — the §8 overgrowth-cap enforcer + §7 `.gitignore`
// (`tom_brain_logging.md` §10 step #10).
//
// The janitor runs at process boot. It (1) writes the §7 `.gitignore` into the
// trail root, (2) enforces the per-folder count caps on the raw tiers
// (`llm/<role>/`, `incoming/<channel>/`, `procedures/<proc>/`) — keep newest N,
// delete oldest — and (3) enforces the aggregate raw-size ceiling across those
// three trees (oldest-first eviction). Size rotation of the log files and the
// prompt-count cap on the versioned summaries are owned by their own writers
// (steps #3 / #5 / #6 / #8), not here.

import 'dart:io';

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('trail_janitor_test_');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  /// Writes [count] files named `00.raw.json` … into `<root>/<tier>/<folder>/`,
  /// each carrying [bytes] bytes, in lexical order (so creation order, mtime,
  /// and name all agree on "newest = highest name"). Returns the folder.
  Directory seedFolder(
    String tier,
    String folder, {
    required int count,
    String ext = 'raw.json',
    int bytes = 8,
  }) {
    final dir = Directory('${tempRoot.path}/$tier/$folder')
      ..createSync(recursive: true);
    for (var i = 0; i < count; i++) {
      File('${dir.path}/${i.toString().padLeft(2, '0')}.$ext')
          .writeAsStringSync('x' * bytes, flush: true);
    }
    return dir;
  }

  Set<String> fileNamesIn(Directory dir) => dir
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .toSet();

  group('.gitignore (§7)', () {
    test('writes the §7 raw-tier ignore body into the trail root', () {
      TrailJanitor(root: tempRoot).sweep();

      final gitignore = File('${tempRoot.path}/.gitignore');
      expect(gitignore.existsSync(), isTrue);
      final body = gitignore.readAsStringSync();
      // The raw / operational tier is ignored …
      expect(body, contains('brain.log*'));
      expect(body, contains('components/'));
      expect(body, contains('memory/'));
      expect(body, contains('llm/'));
      expect(body, contains('incoming/'));
      expect(body, contains('procedures/'));
      // … the summary tier is intentionally NOT ignored.
      expect(body, isNot(contains('\nsessions/')));
      expect(body, isNot(contains('\nsummary/')));
    });

    test('creates the trail root when it does not exist yet', () {
      final missing = Directory('${tempRoot.path}/not_yet');
      expect(missing.existsSync(), isFalse);

      TrailJanitor(root: missing).sweep();

      expect(File('${missing.path}/.gitignore').existsSync(), isTrue);
    });
  });

  group('per-folder count caps (§8)', () {
    test('llm/<role>/ keeps the newest llmPerRoleCap files, deletes oldest', () {
      final folder = seedFolder('llm', 'recaller', count: 10);

      TrailJanitor(root: tempRoot, llmPerRoleCap: 4).sweep();

      // Newest 4 (highest names) survive; oldest 6 are gone.
      expect(
        fileNamesIn(folder),
        <String>{'06.raw.json', '07.raw.json', '08.raw.json', '09.raw.json'},
      );
    });

    test('caps each role folder independently', () {
      final recaller = seedFolder('llm', 'recaller', count: 6);
      final evaluator = seedFolder('llm', 'evaluator', count: 2);

      TrailJanitor(root: tempRoot, llmPerRoleCap: 3).sweep();

      expect(fileNamesIn(recaller).length, 3);
      expect(fileNamesIn(evaluator).length, 2); // under cap → untouched
    });

    test('incoming/<channel>/ count cap', () {
      final telegram = seedFolder('incoming', 'telegram', count: 5);

      TrailJanitor(root: tempRoot, incomingPerChannelCap: 2).sweep();

      expect(
        fileNamesIn(telegram),
        <String>{'03.raw.json', '04.raw.json'},
      );
    });

    test('procedures/<proc>/ count cap (covers dreaming runs)', () {
      final dream =
          seedFolder('procedures', 'dream_extractor_v1', count: 5, ext: 'log');

      TrailJanitor(root: tempRoot, proceduresPerKindCap: 2).sweep();

      expect(
        fileNamesIn(dream),
        <String>{'03.log', '04.log'},
      );
    });

    test('a folder at or under its cap is left untouched', () {
      final folder = seedFolder('llm', 'analyser', count: 3);

      TrailJanitor(root: tempRoot, llmPerRoleCap: 3).sweep();

      expect(fileNamesIn(folder).length, 3);
    });
  });

  group('aggregate raw-size ceiling (§8)', () {
    test('evicts oldest across llm/+incoming/+procedures/ until under ceiling',
        () {
      // 1 MB ceiling; seed ~2 MB so eviction must run. ~400 KB per file.
      const big = 400 * 1024;
      seedFolder('llm', 'recaller', count: 3, bytes: big); // 00,01,02
      seedFolder('incoming', 'telegram', count: 2, bytes: big); // 00,01

      TrailJanitor(
        root: tempRoot,
        // Keep the per-folder caps generous so only the aggregate cap bites.
        llmPerRoleCap: 100,
        incomingPerChannelCap: 100,
        rawAggregateSizeMb: 1,
      ).sweep();

      var total = 0;
      for (final tier in const ['llm', 'incoming', 'procedures']) {
        final dir = Directory('${tempRoot.path}/$tier');
        if (!dir.existsSync()) continue;
        for (final f in dir.listSync(recursive: true).whereType<File>()) {
          total += f.lengthSync();
        }
      }
      expect(total, lessThanOrEqualTo(1024 * 1024));
    });

    test('does not evict the versioned summary tier', () {
      // A summary file far larger than the raw ceiling must survive.
      final sessions = Directory('${tempRoot.path}/sessions')
        ..createSync(recursive: true);
      final summaryFile = File('${sessions.path}/sess-1.summary.md')
        ..writeAsStringSync('x' * (2 * 1024 * 1024), flush: true);
      seedFolder('llm', 'recaller', count: 2, bytes: 8);

      TrailJanitor(root: tempRoot, rawAggregateSizeMb: 1).sweep();

      expect(summaryFile.existsSync(), isTrue);
    });
  });

  group('robustness (§9)', () {
    test('idempotent — a second sweep changes nothing and never throws', () {
      final folder = seedFolder('llm', 'recaller', count: 6);
      final janitor = TrailJanitor(root: tempRoot, llmPerRoleCap: 3);

      janitor.sweep();
      final afterFirst = fileNamesIn(folder);
      expect(() => janitor.sweep(), returnsNormally);
      expect(fileNamesIn(folder), afterFirst);
    });

    test('an empty / fresh root sweeps without error', () {
      expect(() => TrailJanitor(root: tempRoot).sweep(), returnsNormally);
    });

    test('fromConfig carries every cap off the TrailConfig', () {
      final config = TrailConfig(
        root: tempRoot.path,
        llmPerRoleCap: 2,
        incomingPerChannelCap: 7,
        proceduresPerKindCap: 9,
        rawAggregateSizeMb: 5,
      );
      final folder = seedFolder('llm', 'recaller', count: 5);

      TrailJanitor.fromConfig(config).sweep();

      // The llmPerRoleCap=2 off the config trimmed the role folder to 2.
      expect(fileNamesIn(folder).length, 2);
    });
  });
}
