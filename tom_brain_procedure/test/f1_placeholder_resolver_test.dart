// Extension F, step 1 — the d4rt-expression-backed placeholder resolver
// (`tom_brain_procedure_specification.md` § 21.7;
// `prototype_tools_mcp_extension_plan.md` step 1).
//
// Proves the public contract of `PlaceholderResolver` /
// `D4rtExpressionContext` / `PlaceholderStack`:
//
//   - the three resolving forms `${name}` / `${{ expr }}` / `${env:NAME}`,
//     plus the equivalence of the simple form to `${{ name }}`;
//   - a `setup` script that binds a variable a later expression reads;
//   - recursive re-scan that terminates, and the 10-level cap that turns a
//     cycle into `placeholder.recursion.exceeded`;
//   - the scope stack: push a child frame, same-name shadow, pop restores
//     the parent binding (no upward leak);
//   - an expression that throws / will not parse → `placeholder.expression.failed`;
//   - the reserved `${file:…}` / `${state:…}` prefixes survive verbatim;
//   - strict vs lenient handling of an unknown `${name}`.
//
// The tests drive the resolver over the default `D4rtExpressionEvaluator`
// (a bare `D4rt` interpreter — PE-10 reuse, no bridges needed here), so
// they exercise the real d4rt evaluation path the production wiring uses.

import 'dart:io';

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  group('PlaceholderStack', () {
    test('binds, looks up, and reports depth from a single root frame', () {
      final stack = PlaceholderStack();
      expect(stack.depth, 1);
      stack.bind('x', 'root');
      expect(stack.has('x'), isTrue);
      expect(stack.lookup('x'), 'root');
      expect(stack.has('missing'), isFalse);
      expect(stack.lookup('missing'), isNull);
    });

    test('push adds a child frame; same-name binding shadows the parent', () {
      final stack = PlaceholderStack();
      stack.bind('x', 'outer');
      stack.push();
      expect(stack.depth, 2);
      stack.bind('x', 'inner');
      expect(stack.lookup('x'), 'inner');
    });

    test('pop discards the child and restores the parent binding', () {
      final stack = PlaceholderStack();
      stack.bind('x', 'outer');
      stack.push();
      stack.bind('x', 'inner');
      stack.pop();
      expect(stack.depth, 1);
      expect(stack.lookup('x'), 'outer');
    });

    test('pop on the root frame is refused', () {
      final stack = PlaceholderStack();
      expect(stack.pop, throwsStateError);
    });

    test('flatten merges root→top with the child winning on collisions', () {
      final stack = PlaceholderStack();
      stack.bind('a', 1);
      stack.bind('b', 1);
      stack.push();
      stack.bind('b', 2);
      stack.bind('c', 3);
      expect(stack.flatten(), <String, Object?>{'a': 1, 'b': 2, 'c': 3});
    });
  });

  group('PlaceholderResolver — forms', () {
    late PlaceholderResolver resolver;

    setUp(() {
      resolver = PlaceholderResolver();
    });

    test('simple form reads a binding from the current scope', () async {
      resolver.stack.bind('greeting', 'hi');
      expect(await resolver.resolve(r'${greeting}'), 'hi');
    });

    test('simple form is equivalent to the d4rt-expression form', () async {
      resolver.stack.bind('v', 'X');
      expect(
        await resolver.resolve(r'${v}'),
        await resolver.resolve(r'${{ v }}'),
      );
    });

    test('d4rt-expression form evaluates against the scope', () async {
      resolver.stack.bind('count', 3);
      expect(await resolver.resolve(r'${{ count * 2 }}'), '6');
      expect(
        await resolver.resolve(r"${{ count > 0 ? 'yes' : 'no' }}"),
        'yes',
      );
    });

    test('env form reads a present process-environment variable', () async {
      final entry = Platform.environment.entries.firstWhere(
        (e) => e.value.isNotEmpty,
      );
      expect(await resolver.resolve('\${env:${entry.key}}'), entry.value);
    });

    test('a setup script binds a variable a later expression reads',
        () async {
      await resolver.context.runSetup('''
Map<String, Object?> main() {
  return {'greeting': 'hello', 'count': 4};
}
''');
      expect(await resolver.resolve(r'${greeting}'), 'hello');
      expect(await resolver.resolve(r'${{ count + 1 }}'), '5');
    });
  });

  group('PlaceholderResolver — recursion', () {
    test('a value that contains another placeholder is recursively expanded',
        () async {
      final resolver = PlaceholderResolver();
      resolver.stack.bind('a', r'${b}');
      resolver.stack.bind('b', 'done');
      expect(await resolver.resolve(r'${a}'), 'done');
    });

    test('a self-referential placeholder errors at the recursion cap',
        () async {
      final resolver = PlaceholderResolver();
      resolver.stack.bind('a', r'${a}');
      await expectLater(
        resolver.resolve(r'${a}'),
        throwsA(isA<PlaceholderRecursionException>()),
      );
    });

    test('a two-node cycle is caught at the cap', () async {
      final resolver = PlaceholderResolver();
      resolver.stack.bind('a', r'${b}');
      resolver.stack.bind('b', r'${a}');
      await expectLater(
        resolver.resolve(r'${a}'),
        throwsA(
          isA<PlaceholderRecursionException>().having(
            (e) => e.code,
            'code',
            'placeholder.recursion.exceeded',
          ),
        ),
      );
    });
  });

  group('PlaceholderResolver — scope shadowing through resolve', () {
    test('push/same-name-shadow/pop restores the parent value', () async {
      final resolver = PlaceholderResolver();
      resolver.stack.bind('x', 'outer');
      resolver.stack.push();
      resolver.stack.bind('x', 'inner');
      expect(await resolver.resolve(r'${x}'), 'inner');
      resolver.stack.pop();
      expect(await resolver.resolve(r'${x}'), 'outer');
    });
  });

  group('PlaceholderResolver — failure modes', () {
    test('an expression that references an unknown name fails typed',
        () async {
      final resolver = PlaceholderResolver();
      await expectLater(
        resolver.resolve(r'${{ undefinedVar }}'),
        throwsA(
          isA<PlaceholderExpressionException>().having(
            (e) => e.code,
            'code',
            'placeholder.expression.failed',
          ),
        ),
      );
    });

    test('reserved file:/state: prefixes survive verbatim', () async {
      final resolver = PlaceholderResolver();
      expect(
        await resolver.resolve(r'a ${file:notes.txt} b'),
        r'a ${file:notes.txt} b',
      );
      expect(
        await resolver.resolve(r'${state:cursor}'),
        r'${state:cursor}',
      );
    });

    test('strict mode errors on an unknown simple placeholder', () async {
      final resolver = PlaceholderResolver(strict: true);
      await expectLater(
        resolver.resolve(r'${missing}'),
        throwsA(
          isA<PlaceholderUnresolvedException>().having(
            (e) => e.code,
            'code',
            'placeholder.unresolved',
          ),
        ),
      );
    });

    test('lenient mode renders an unknown simple placeholder as empty',
        () async {
      final resolver = PlaceholderResolver(strict: false);
      expect(await resolver.resolve(r'[${missing}]'), '[]');
    });

    test('strict mode errors on an unknown env variable', () async {
      final resolver = PlaceholderResolver(strict: true);
      await expectLater(
        resolver.resolve(r'${env:TOM_BRAIN_DEFINITELY_ABSENT_VAR}'),
        throwsA(isA<PlaceholderUnresolvedException>()),
      );
    });

    test('lenient mode renders an unknown env variable as empty', () async {
      final resolver = PlaceholderResolver(strict: false);
      expect(
        await resolver.resolve(r'[${env:TOM_BRAIN_DEFINITELY_ABSENT_VAR}]'),
        '[]',
      );
    });
  });
}
