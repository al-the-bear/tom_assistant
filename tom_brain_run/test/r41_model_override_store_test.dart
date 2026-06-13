// r41 — ModelOverrideStore: the on-disk persistence behind `/switch_model`
// (request e). The store reads/writes a flat `model_overrides.yaml`
// (prompt-id → "<providerId>:<model>") at the cognition root, so a switch
// survives a process restart instead of living only in the process registry.

import 'dart:io';

import 'package:tom_brain_run/tom_brain_run.dart'
    show ModelOverride, ModelOverrideStore, ModelOverrideStoreException;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String filePath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('model_override_store_');
    filePath = '${dir.path}/model_overrides.yaml';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  ModelOverrideStore store() => ModelOverrideStore(filePath: filePath);

  group('ModelOverrideStore.load', () {
    test('MOS-1: an absent file loads as an empty map', () {
      expect(File(filePath).existsSync(), isFalse);
      expect(store().load(), isEmpty);
    });

    test('MOS-2: a comment-only file loads as an empty map', () {
      File(filePath).writeAsStringSync('# just a comment\n\n');
      expect(store().load(), isEmpty);
    });

    test('MOS-3: a flat map loads into ModelOverride entries', () {
      File(filePath).writeAsStringSync(
        '"assist_user.answer.main": "openrouter:meta-llama/llama-3-70b"\n',
      );
      final loaded = store().load();
      final ov = loaded['assist_user.answer.main']!;
      expect(ov.providerId, 'openrouter');
      expect(ov.model, 'meta-llama/llama-3-70b');
    });

    test('MOS-4: a model name carrying colons splits on the FIRST colon', () {
      File(filePath).writeAsStringSync('"a.b.c": "local:gemma3:27b"\n');
      final ov = store().load()['a.b.c']!;
      expect(ov.providerId, 'local');
      expect(ov.model, 'gemma3:27b');
    });

    test('MOS-5: a non-string value is rejected', () {
      File(filePath).writeAsStringSync('"a.b.c": 42\n');
      expect(store().load, throwsA(isA<ModelOverrideStoreException>()));
    });

    test('MOS-6: a value without a colon is rejected', () {
      File(filePath).writeAsStringSync('"a.b.c": "gemma3"\n');
      expect(store().load, throwsA(isA<ModelOverrideStoreException>()));
    });
  });

  group('ModelOverrideStore.save', () {
    test('MOS-7: save then load round-trips every entry', () {
      store().save(<String, ModelOverride>{
        'assist_user.answer.main':
            const ModelOverride(providerId: 'local', model: 'gemma3:27b'),
        'assist_user.think.main': const ModelOverride(
            providerId: 'openrouter', model: 'meta-llama/llama-3-70b'),
      });

      final loaded = store().load();
      expect(loaded, hasLength(2));
      expect(loaded['assist_user.answer.main']!.providerId, 'local');
      expect(loaded['assist_user.answer.main']!.model, 'gemma3:27b');
      expect(loaded['assist_user.think.main']!.providerId, 'openrouter');
      expect(loaded['assist_user.think.main']!.model, 'meta-llama/llama-3-70b');
    });

    test('MOS-8: save is deterministic — keys are written sorted', () {
      final entries = <String, ModelOverride>{
        'z.last.one': const ModelOverride(providerId: 'local', model: 'm1'),
        'a.first.one': const ModelOverride(providerId: 'local', model: 'm2'),
      };
      store().save(entries);
      final text = File(filePath).readAsStringSync();
      expect(text.indexOf('a.first.one'),
          lessThan(text.indexOf('z.last.one')));
    });

    test('MOS-9: save overwrites prior content (a removed key is gone)', () {
      store().save(<String, ModelOverride>{
        'a.b.c': const ModelOverride(providerId: 'local', model: 'm1'),
        'd.e.f': const ModelOverride(providerId: 'local', model: 'm2'),
      });
      store().save(<String, ModelOverride>{
        'a.b.c': const ModelOverride(providerId: 'local', model: 'm1'),
      });
      final loaded = store().load();
      expect(loaded.keys, ['a.b.c']);
    });

    test('MOS-10: save creates the parent directory when missing', () {
      final nested = '${dir.path}/sub/dir/model_overrides.yaml';
      ModelOverrideStore(filePath: nested).save(<String, ModelOverride>{
        'a.b.c': const ModelOverride(providerId: 'local', model: 'm1'),
      });
      expect(File(nested).existsSync(), isTrue);
    });

    test('MOS-11: saving an empty map writes a loadable empty file', () {
      store().save(const <String, ModelOverride>{});
      expect(store().load(), isEmpty);
    });
  });
}
