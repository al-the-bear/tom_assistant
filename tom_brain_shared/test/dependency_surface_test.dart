// Dependency-surface test for `tom_brain_shared` (prototype-plan-2 item 8).
//
// The sibling `dependency_discipline_test.dart` polices the *pubspec*: it
// asserts the declared runtime dependencies are exactly `tom_basics` +
// `tom_core_agentic`. That guards what the package is *allowed to pull in*.
//
// This test guards the complementary half: what the package's *source*
// actually imports. A pubspec can be clean while a single `import 'dart:io'`
// slips into `lib/src`, which is exactly the leak item 8 calls out ("Enforce
// the no-`dart:io`/no-HTTP/no-storage constraint"). So this test walks every
// `lib/**/*.dart` file, extracts each `import`/`export` URI, and asserts none
// of them name a forbidden target.
//
// Forbidden:
//   * `dart:io`            — no filesystem, no sockets, no processes here.
//   * Side-effect packages — HTTP clients, storage engines, MCP, crypto,
//     loggers (the same forbid-list the pubspec test names, matched by
//     `package:<name>/...`).
//
// Allowed: the side-effect-free `dart:` libraries (`async`, `typed_data`,
// `convert`, `math`, `collection`), the two baseline packages
// (`tom_basics`, `tom_core_agentic`), the package's own
// `package:tom_brain_shared/...` re-imports, and all relative imports.

import 'dart:io';

import 'package:test/test.dart';

/// Side-effect package names that must never appear as `package:<name>/...`
/// in the library source. Mirrors the pubspec forbid-list in
/// `dependency_discipline_test.dart`; kept in lockstep with it.
const _forbiddenPackages = <String>{
  'http',
  'dio',
  'sqlite3',
  'dart_mcp',
  'shelf',
  'shelf_router',
  'dart_jsonwebtoken',
  'path_provider',
  'file',
  'crypto',
  'logging',
  'logger',
  'sqflite',
  'drift',
};

/// `dart:` libraries that carry side effects and so are forbidden at the
/// pure-types layer. `dart:io` is the one that matters; the rest are listed
/// for an explicit, named failure if one is ever added.
const _forbiddenDartLibraries = <String>{
  'dart:io',
  'dart:isolate',
  'dart:ffi',
  'dart:cli',
};

/// Matches the URI in an `import`/`export` directive:
/// `import 'dart:io';`, `export "package:http/http.dart";`, etc.
final _directiveUri = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// Returns every `import`/`export` URI declared in [source].
Iterable<String> _directiveUris(String source) =>
    _directiveUri.allMatches(source).map((m) => m.group(1)!);

/// Classifies [uri] as forbidden, returning a human-readable reason, or
/// `null` when the URI is allowed.
String? _forbiddenReason(String uri) {
  if (_forbiddenDartLibraries.contains(uri)) {
    return 'forbidden core library "$uri" (side effects)';
  }
  if (uri.startsWith('package:')) {
    final name = uri.substring('package:'.length).split('/').first;
    if (_forbiddenPackages.contains(name)) {
      return 'forbidden side-effect package "$name"';
    }
  }
  return null;
}

void main() {
  group('tom_brain_shared dependency surface (item 8)', () {
    late List<File> libFiles;

    setUpAll(() {
      final lib = Directory('lib');
      expect(
        lib.existsSync(),
        isTrue,
        reason:
            'lib/ must be readable from the package root '
            '(test cwd is the package root under `dart test`).',
      );
      libFiles = lib
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(
        libFiles,
        isNotEmpty,
        reason: 'lib/ must contain Dart source to police.',
      );
    });

    test('no library source imports dart:io or another side-effect core lib', () {
      final offenders = <String>[];
      for (final file in libFiles) {
        for (final uri in _directiveUris(file.readAsStringSync())) {
          if (_forbiddenDartLibraries.contains(uri)) {
            offenders.add('${file.path}: $uri');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'tom_brain_shared is the pure-types layer: no `dart:io` (or other '
            'side-effect core library) may appear in lib/ source. Offenders:\n'
            '${offenders.join('\n')}',
      );
    });

    test('no library source imports a forbidden side-effect package', () {
      final offenders = <String>[];
      for (final file in libFiles) {
        for (final uri in _directiveUris(file.readAsStringSync())) {
          if (uri.startsWith('package:')) {
            final name = uri.substring('package:'.length).split('/').first;
            if (_forbiddenPackages.contains(name)) {
              offenders.add('${file.path}: $uri');
            }
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'tom_brain_shared must not import HTTP, storage, MCP, crypto, or '
            'logging packages in lib/ source — those belong in the downstream '
            'components. Offenders:\n${offenders.join('\n')}',
      );
    });

    test('every lib/ import/export URI is on the allow-list', () {
      // Defensive catch-all: any forbidden URI surfaces here with its reason,
      // even if a future forbid-list entry is added without its own test.
      final offenders = <String>[];
      for (final file in libFiles) {
        for (final uri in _directiveUris(file.readAsStringSync())) {
          final reason = _forbiddenReason(uri);
          if (reason != null) {
            offenders.add('${file.path}: $uri — $reason');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'Forbidden import/export directives found in lib/ source:\n'
            '${offenders.join('\n')}',
      );
    });
  });
}
