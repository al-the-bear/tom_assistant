// Step 3 (tom_brain_cli_plan.md) — `BundledPromptResolver` behind the existing
// `PromptResolver` seam, plus the disk-overlays-bundle composition and the full
// `profile overlay → cognition disk → bundle → not-found` chain.
//
// The standalone `tom_brain` CLI ships its `cognition/` prompt templates as a
// *bundle* compiled into the executable (an in-memory `path → source` map),
// mirroring how `BundledProcedureStore` ships the `scripts/system/` procedures.
// A deployment may still drop template files into a writable disk cognition
// root; a disk template **overlays the bundle by template id** — the same
// `LayeredPromptResolver(overlay-first, base-fallthrough)` seam a profile's
// `templateOverlay` already uses.
//
// Contract under test (the new pieces this step adds):
//
//   * `buildBundledPromptResolver(config, builtins, bundlePrompts, …)` — a
//     `PromptResolver` that renders a registered prompt's body from the
//     compiled bundle map (keyed by the registered template's cognition-root
//     path), returning `null` for an unregistered id OR a registered id whose
//     template path is not in the bundle (the fall-through signal).
//   * `buildPromptResolver(…, fallThroughOnMissing: true)` — the disk resolver
//     in *soft* mode: a registered prompt whose template file is absent on disk
//     yields `null` (fall through to the bundle) instead of the hard
//     "missing present template file" error the default (`false`) path raises.
//   * Disk-overlays-bundle composes as
//     `LayeredPromptResolver(base: bundled, overlay: diskFallThrough)` and the
//     profile overlay layers on top, so the full chain is
//     `profile overlay → cognition disk → bundle → not-found`.

import 'dart:io';

import 'package:tom_brain_procedure/tom_brain_procedure.dart' as proc;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';

/// The cognition registry the synthetic config carries — only `llmDefault`
/// matters here (it backs the resolved route when a prompt sets no `llm:`).
const CognitionRegistry _registry = CognitionRegistry(
  procedures: <String, RegisteredProcedure>{},
  rolesFolder: 'roles',
  llmFolder: 'llm',
  llmDefault: 'default_route',
);

/// A registered prompt over a system-absent / user-`<stem>.user.md` pair. The
/// [userPresent] flag mirrors what the loader would record from a disk scan:
/// `true` when the disk cognition root carries the file, `false` for a
/// bundle-only prompt with no disk file.
ResolvedPrompt _prompt(String id, String userPath, {required bool userPresent}) =>
    ResolvedPrompt(
      id: id,
      mainProcedure: 'a',
      subProcedure: 'b',
      promptName: id.split('.').last,
      template: PromptTemplateFiles(
        system: ResolvedTemplateFile(
          path: userPath.replaceAll('.user.md', '.system.md'),
          present: false,
        ),
        user: ResolvedTemplateFile(path: userPath, present: userPresent),
      ),
      kind: PromptKind.prompt,
      settings: const PromptSettings(),
    );

void main() {
  late Directory root;
  late BrainBuiltins builtins;
  late CognitionConfig config;
  late Map<String, String> bundle;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bundled_prompt_');
    addTearDown(() => root.deleteSync(recursive: true));

    builtins = BrainBuiltins(
      hostname: 'testhost',
      trailFolder: '',
      configFolder: root.path,
      memoryRoot: '${root.path}/memory',
      scriptsFolder: '${root.path}/scripts',
    );

    // shadowed.user.md exists on disk (loader records present: true);
    // bundleonly + absent have no disk file (present: false).
    File('${root.path}/sh.user.md').writeAsStringSync('DISK shadowed');

    config = CognitionConfig(
      registry: _registry,
      prompts: <String, ResolvedPrompt>{
        'a.b.shadowed': _prompt('a.b.shadowed', 'sh.user.md', userPresent: true),
        'a.b.bundleonly':
            _prompt('a.b.bundleonly', 'bo.user.md', userPresent: false),
        'a.b.absent': _prompt('a.b.absent', 'ab.user.md', userPresent: false),
      },
      llmRoutes: const <String, LlmRouteConfig>{},
    );

    // The compiled bundle ships shadowed + bundleonly (not absent).
    bundle = <String, String>{
      'sh.user.md': 'BUNDLE shadowed',
      'bo.user.md': 'BUNDLE bundleonly',
    };
  });

  group('bundle-only — buildBundledPromptResolver renders from the bundle', () {
    test('a registered id whose template is in the bundle renders its body',
        () async {
      final resolve = buildBundledPromptResolver(config, builtins, bundle);
      final shadowed = await resolve('a.b.shadowed', const {});
      expect(shadowed, isNotNull);
      expect(shadowed!.templateBody, equals('BUNDLE shadowed'));
      expect(shadowed.llmRoute, equals('default_route'));

      final bundleonly = await resolve('a.b.bundleonly', const {});
      expect(bundleonly!.templateBody, equals('BUNDLE bundleonly'));
    });

    test('an unregistered id resolves to null (the seam fall-through signal)',
        () async {
      final resolve = buildBundledPromptResolver(config, builtins, bundle);
      expect(await resolve('a.b.unknown', const {}), isNull);
    });

    test('a registered id absent from the bundle resolves to null', () async {
      final resolve = buildBundledPromptResolver(config, builtins, bundle);
      expect(await resolve('a.b.absent', const {}), isNull);
    });
  });

  group('disk soft mode — buildPromptResolver(fallThroughOnMissing: true)', () {
    test('a present disk template renders from disk', () async {
      final resolve =
          buildPromptResolver(config, builtins, fallThroughOnMissing: true);
      final shadowed = await resolve('a.b.shadowed', const {});
      expect(shadowed!.templateBody, equals('DISK shadowed'));
    });

    test('a registered id with no disk file resolves to null (falls through)',
        () async {
      final resolve =
          buildPromptResolver(config, builtins, fallThroughOnMissing: true);
      expect(await resolve('a.b.bundleonly', const {}), isNull);
    });
  });

  group('disk-overlays-bundle — disk shadows the bundle by template id', () {
    proc.PromptResolver diskOverBundle() => proc.LayeredPromptResolver(
          base: buildBundledPromptResolver(config, builtins, bundle),
          overlay:
              buildPromptResolver(config, builtins, fallThroughOnMissing: true),
        ).asResolver;

    test('a disk template wins over the bundled one', () async {
      final resolve = diskOverBundle();
      final shadowed = await resolve('a.b.shadowed', const {});
      expect(shadowed!.templateBody, equals('DISK shadowed'),
          reason: 'disk overlays the bundle for the same template id');
    });

    test('a bundle-only template is served by the bundle', () async {
      final resolve = diskOverBundle();
      final bundleonly = await resolve('a.b.bundleonly', const {});
      expect(bundleonly!.templateBody, equals('BUNDLE bundleonly'));
    });

    test('an id in neither layer resolves to null (still fatal at the seam)',
        () async {
      final resolve = diskOverBundle();
      expect(await resolve('a.b.absent', const {}), isNull);
    });
  });

  group('full chain — profile overlay → cognition disk → bundle → not-found',
      () {
    proc.PromptResolver fullChain() {
      final diskOverBundle = proc.LayeredPromptResolver(
        base: buildBundledPromptResolver(config, builtins, bundle),
        overlay:
            buildPromptResolver(config, builtins, fallThroughOnMissing: true),
      ).asResolver;
      final overlay =
          buildOverlayPromptResolver(config, builtins)('myprofile');
      return proc.LayeredPromptResolver(
        base: diskOverBundle,
        overlay: overlay,
      ).asResolver;
    }

    setUp(() {
      // A profile template overlay that redefines only `shadowed`.
      Directory('${root.path}/overlays/myprofile').createSync(recursive: true);
      File('${root.path}/overlays/myprofile/sh.user.md')
          .writeAsStringSync('OVERLAY shadowed');
    });

    test('the profile overlay wins over disk and bundle', () async {
      final resolve = fullChain();
      final shadowed = await resolve('a.b.shadowed', const {});
      expect(shadowed!.templateBody, equals('OVERLAY shadowed'));
    });

    test('an id the overlay does not redefine falls to the bundle', () async {
      final resolve = fullChain();
      final bundleonly = await resolve('a.b.bundleonly', const {});
      expect(bundleonly!.templateBody, equals('BUNDLE bundleonly'));
    });

    test('an id in no layer resolves to null', () async {
      final resolve = fullChain();
      expect(await resolve('a.b.absent', const {}), isNull);
    });
  });
}
