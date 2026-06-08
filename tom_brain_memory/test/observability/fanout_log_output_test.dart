// FanoutLogOutput — the console+file teeing log sink (logging-spec §5.1; §10
// build-order step #3).
//
// `FanoutLogOutput` is a `TomLogOutput` that tees every line to the console
// (preserving the existing stdout/stderr behaviour) AND to on-disk files,
// routing by the `[<namespace>.<component>.<area>]` tag that `MemoryLog` /
// `SubstrateLog` prepend:
//
//   * every headline-level line (status / warn / error / severe / fatal) →
//     `<root>/brain.log`;
//   * every detail line down to `debug` that carries a recognised
//     `tom_brain.<component>.*` tag → `<root>/components/<component>.log`.
//
// Files are size-rotated (`brain.log` → `brain.log.1` → … → `brain.log.5`,
// oldest dropped) and the whole sink is best-effort: a file-write failure must
// never throw into the caller (a trail-write must never fail a turn).
//
// `<root>` is the current working directory in unconfigured mode and
// `trail.root` in full mode — here it is just the injected directory.

import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_basics/tom_basics.dart';

import 'package:tom_brain_memory/tom_brain_memory.dart' show FanoutLogOutput;

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tbm_fanout_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String brainLog() {
    final f = File('${root.path}/brain.log');
    return f.existsSync() ? f.readAsStringSync() : '';
  }

  String componentLog(String component) {
    final f = File('${root.path}/components/$component.log');
    return f.existsSync() ? f.readAsStringSync() : '';
  }

  // Emits one line through [out]. `loggerLevel` is `all` so the console tee is
  // never the thing filtering — file routing is the sink's own concern.
  void emit(
    FanoutLogOutput out,
    TomLogLevel level,
    String levelStr,
    String message,
  ) {
    out.output(
      TomLogLevel.all,
      level,
      levelStr,
      message,
      'TestIso',
      DateTime.utc(2026, 6, 8, 12, 0, 0),
      'Cls.method',
    );
  }

  group('component + brain routing', () {
    test('a tagged status line lands in both brain.log and its component file',
        () {
      final out = FanoutLogOutput(logRoot: root, console: _NullConsole());
      emit(out, TomLogLevel.status, 'STATUS ',
          '[tom_brain.substrate.llm] provider opened');

      expect(brainLog(), contains('provider opened'));
      expect(brainLog(), contains('[tom_brain.substrate.llm]'));
      expect(componentLog('substrate'), contains('provider opened'));
    });

    test('a debug line lands in its component file but NOT in brain.log', () {
      final out = FanoutLogOutput(logRoot: root, console: _NullConsole());
      emit(out, TomLogLevel.debug, 'DEBUG  ',
          '[tom_brain.memory.store] vec0 loaded');

      expect(componentLog('memory'), contains('vec0 loaded'));
      expect(brainLog(), isNot(contains('vec0 loaded')));
    });

    test('an info line is component-only (below the brain.log headline floor)',
        () {
      final out = FanoutLogOutput(logRoot: root, console: _NullConsole());
      emit(out, TomLogLevel.info, 'INFO   ',
          '[tom_brain.substrate.embed] identity probed');

      expect(componentLog('substrate'), contains('identity probed'));
      expect(brainLog(), isNot(contains('identity probed')));
    });

    test('a trace line reaches neither file (below the component floor)', () {
      final out = FanoutLogOutput(logRoot: root, console: _NullConsole());
      emit(out, TomLogLevel.trace, 'TRACE  ',
          '[tom_brain.substrate.llm] entering classify');

      expect(componentLog('substrate'), isEmpty);
      expect(brainLog(), isEmpty);
    });

    test('an untagged headline line lands in brain.log only (no component file)',
        () {
      final out = FanoutLogOutput(logRoot: root, console: _NullConsole());
      emit(out, TomLogLevel.warn, 'WARN   ', 'something happened without a tag');

      expect(brainLog(), contains('something happened without a tag'));
      expect(Directory('${root.path}/components').existsSync(), isFalse);
    });

    test('a foreign-namespace tag is not routed to a component file', () {
      final out = FanoutLogOutput(logRoot: root, console: _NullConsole());
      emit(out, TomLogLevel.warn, 'WARN   ', '[other.substrate.llm] not ours');

      // Headline still goes to brain.log, but no `components/substrate.log`.
      expect(brainLog(), contains('not ours'));
      expect(componentLog('substrate'), isEmpty);
    });
  });

  group('console tee', () {
    test('every emitted line is forwarded to the injected console', () {
      final console = _RecordingConsole();
      final out = FanoutLogOutput(logRoot: root, console: console);

      emit(out, TomLogLevel.status, 'STATUS ', '[tom_brain.substrate.llm] hi');
      emit(out, TomLogLevel.trace, 'TRACE  ', '[tom_brain.memory.store] lo');

      expect(console.messages, hasLength(2));
      expect(console.messages[0], contains('hi'));
      expect(console.messages[1], contains('lo'));
    });
  });

  group('size rotation', () {
    test('brain.log rotates to brain.log.1 once it exceeds the byte cap', () {
      final out = FanoutLogOutput(
        logRoot: root,
        console: _NullConsole(),
        rotateBytes: 256,
        rotateKeep: 5,
      );

      // Each status line is ~80+ bytes; a handful tips past 256.
      for (var i = 0; i < 12; i++) {
        emit(out, TomLogLevel.status, 'STATUS ',
            '[tom_brain.substrate.llm] line number $i of the rotation probe');
      }

      expect(File('${root.path}/brain.log').existsSync(), isTrue);
      expect(File('${root.path}/brain.log.1').existsSync(), isTrue,
          reason: 'the oldest segment must have been rotated out');
      expect(File('${root.path}/brain.log').lengthSync(),
          lessThanOrEqualTo(256 + 200));
    });

    test('rotation never keeps more than rotateKeep backup segments', () {
      final out = FanoutLogOutput(
        logRoot: root,
        console: _NullConsole(),
        rotateBytes: 128,
        rotateKeep: 3,
      );

      for (var i = 0; i < 60; i++) {
        emit(out, TomLogLevel.status, 'STATUS ',
            '[tom_brain.substrate.llm] saturating segment $i with padding text');
      }

      expect(File('${root.path}/brain.log.3').existsSync(), isTrue);
      expect(File('${root.path}/brain.log.4').existsSync(), isFalse,
          reason: 'no segment beyond rotateKeep should survive');
    });
  });

  group('best-effort', () {
    test('a write failure never throws into the caller', () {
      // Point the root at a *file*, so creating `components/` (or the log
      // files) underneath it must fail — the sink must swallow it.
      final blocker = File('${root.path}/not-a-dir');
      blocker.writeAsStringSync('x');
      final out = FanoutLogOutput(
        logRoot: Directory('${blocker.path}/nested'),
        console: _NullConsole(),
      );

      expect(
        () => emit(out, TomLogLevel.error, 'ERROR  ',
            '[tom_brain.substrate.llm] boom'),
        returnsNormally,
      );
    });
  });
}

/// A console sink that records the stringified message of every call.
class _RecordingConsole extends TomLogOutput {
  final List<String> messages = <String>[];

  @override
  void output(
    TomLogLevel loggerLevel,
    TomLogLevel logLevel,
    String level,
    Object message,
    String isolateName,
    DateTime timeStamp, [
    String? origin,
  ]) {
    messages.add(convertToString(message));
  }
}

/// A console sink that discards everything — isolates the file-routing
/// assertions from stdout noise.
class _NullConsole extends TomLogOutput {
  @override
  void output(
    TomLogLevel loggerLevel,
    TomLogLevel logLevel,
    String level,
    Object message,
    String isolateName,
    DateTime timeStamp, [
    String? origin,
  ]) {}
}
