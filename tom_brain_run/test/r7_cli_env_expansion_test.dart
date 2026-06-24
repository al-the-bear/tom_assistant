// r7_cli_env_expansion_test.dart — CLI `${env:…}` flag expansion (CLI plan
// step #7; `tom_brain_cli.md` § 5 note / § 11.7 / `--set` § 5.3).
//
// Every CLI flag value and every `--set key=value` value passes through the
// SAME `${env:NAME}` expander the YAML config loaders use, BEFORE any path
// resolution (`tom_brain_cli.md` line 200/221). An unset variable is a clear
// startup error — never an empty string — so a misspelled or missing secret
// fails loudly at boot. A literal value with no placeholder passes through
// unchanged. The environment is reachable ONLY via the `${env:NAME}` form; a
// bare `${NAME}` fails with a message that points at the `env:` form.
//
// These tests exercise the pure expander (`env` injected) the step-8 CLI will
// drive with `Platform.environment`.

import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:test/test.dart';

void main() {
  group('#7 expandCliFlag — single flag value', () {
    test('a whole-value token expands from the environment', () {
      expect(
        expandCliFlag('--telegram-token', r'${env:TG_TOKEN}',
            env: <String, String>{'TG_TOKEN': 'super-secret'}),
        'super-secret',
      );
    });

    test('an embedded token expands inside a larger value', () {
      expect(
        expandCliFlag('--providers', r'${env:CFG}/providers',
            env: <String, String>{'CFG': '/etc/brain'}),
        '/etc/brain/providers',
      );
    });

    test('a literal value with no placeholder passes through unchanged', () {
      expect(
        expandCliFlag('--home', '/srv/brain', env: const <String, String>{}),
        '/srv/brain',
      );
    });

    test('an unset variable is a clear startup error, not an empty string', () {
      expect(
        () => expandCliFlag('--telegram-token', r'${env:MISSING_TOKEN}',
            env: const <String, String>{}),
        throwsA(
          isA<CliEnvExpansionException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('--telegram-token'),
              contains('MISSING_TOKEN'),
              contains('undefined'),
            ),
          ),
        ),
      );
    });

    test('a bare \${NAME} fails and points at the \${env:NAME} form', () {
      expect(
        () => expandCliFlag('--openai', r'${PORT}',
            env: <String, String>{'PORT': '8080'}),
        throwsA(
          isA<CliEnvExpansionException>().having(
            (e) => e.message,
            'message',
            contains('env:'),
          ),
        ),
      );
    });
  });

  group('#7 expandCliFlags — uniform across every flag', () {
    test('expands each value, leaving literals untouched', () {
      final out = expandCliFlags(
        <String, String>{
          '--home': r'${env:BRAIN_HOME}',
          '--openai': r'${env:PORT}',
          '--telegram-token': r'${env:TG}',
          '--scripts': '/literal/scripts',
        },
        env: <String, String>{
          'BRAIN_HOME': '/srv/home',
          'PORT': '9090',
          'TG': 'tok',
        },
      );

      expect(out['--home'], '/srv/home');
      expect(out['--openai'], '9090');
      expect(out['--telegram-token'], 'tok');
      expect(out['--scripts'], '/literal/scripts');
    });

    test('an unset variable reports the offending flag by name', () {
      expect(
        () => expandCliFlags(
          <String, String>{
            '--home': '/ok',
            '--telegram-token': r'${env:NOPE}',
          },
          env: const <String, String>{},
        ),
        throwsA(
          isA<CliEnvExpansionException>().having(
            (e) => e.message,
            'message',
            allOf(contains('--telegram-token'), contains('NOPE')),
          ),
        ),
      );
    });
  });

  group('#7 expandSetValue — --set key=value', () {
    test('expands the value half and reports by --set <key>', () {
      expect(
        expandSetValue('access.openai.port', r'${env:PORT}',
            env: <String, String>{'PORT': '7000'}),
        '7000',
      );
    });

    test('an unset variable in a --set value names the key', () {
      expect(
        () => expandSetValue('memory.root', r'${env:MROOT}',
            env: const <String, String>{}),
        throwsA(
          isA<CliEnvExpansionException>().having(
            (e) => e.message,
            'message',
            allOf(contains('--set'), contains('memory.root'), contains('MROOT')),
          ),
        ),
      );
    });
  });
}
