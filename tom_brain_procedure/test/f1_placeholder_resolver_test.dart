// Extension F, step 1 — the d4rt-expression backing for the shared
// placeholder resolver (`tom_brain_procedure_specification.md` § 21.7).
//
// The resolver *core* — `PlaceholderResolver`, `PlaceholderStack`, the typed
// failures, and the `PlaceholderExpressions` seam — now lives in
// `tom_core_agentic` and is unit-tested there (`placeholder_resolver_test.dart`,
// `placeholder_stack_test.dart`). What this file pins is the part that owns
// the d4rt dependency and only exists here: `D4rtExpressionContext`, the
// backing that turns a `${{ expr }}` body into a real d4rt evaluation against
// the current scope, plus its `setup`-script contract.
//
// What this file proves end-to-end over the real `D4rtExpressionEvaluator`
// (a bare `D4rt` interpreter — PE-10 reuse, no bridges needed):
//
//   - the `${{ expr }}` form evaluates against the live scope, and the simple
//     `${name}` form is equivalent to `${{ name }}`;
//   - a `setup` script returns a bindings map the caller seeds into the
//     stack, which a later expression then reads;
//   - an expression that references an unknown name / will not parse surfaces
//     as a typed `PlaceholderExpressionException`
//     (`placeholder.expression.failed`).

import 'package:test/test.dart';

import 'package:tom_core_agentic/tom_core_agentic.dart';
import 'package:tom_brain_procedure/tom_brain_procedure.dart';

/// Builds a resolver wired to a fresh standalone d4rt backing.
PlaceholderResolver _resolver() =>
    PlaceholderResolver(expressions: D4rtExpressionContext());

void main() {
  group(r'D4rtExpressionContext — ${{ … }} evaluation', () {
    test('the simple form is equivalent to the d4rt-expression form',
        () async {
      final resolver = _resolver();
      resolver.stack.bind('v', 'X');
      expect(
        await resolver.resolve(r'${v}'),
        await resolver.resolve(r'${{ v }}'),
      );
    });

    test('an expression evaluates against the current scope', () async {
      final resolver = _resolver();
      resolver.stack.bind('count', 3);
      expect(await resolver.resolve(r'${{ count * 2 }}'), '6');
      expect(
        await resolver.resolve(r"${{ count > 0 ? 'yes' : 'no' }}"),
        'yes',
      );
    });

    test('a binding shadowed in a child frame is what the expression reads',
        () async {
      final resolver = _resolver();
      resolver.stack.bind('x', 'outer');
      resolver.stack.push();
      resolver.stack.bind('x', 'inner');
      expect(await resolver.resolve(r'${{ x }}'), 'inner');
      resolver.stack.pop();
      expect(await resolver.resolve(r'${{ x }}'), 'outer');
    });
  });

  group('D4rtExpressionContext — setup script', () {
    test('runSetup returns the bindings a later expression reads', () async {
      final context = D4rtExpressionContext();
      final resolver = PlaceholderResolver(expressions: context);
      final bindings = await context.runSetup('''
Map<String, Object?> main() {
  return {'greeting': 'hello', 'count': 4};
}
''');
      resolver.stack.bindAll(bindings);
      expect(await resolver.resolve(r'${greeting}'), 'hello');
      expect(await resolver.resolve(r'${{ count + 1 }}'), '5');
    });

    test('a null return binds nothing (empty map)', () async {
      final context = D4rtExpressionContext();
      final bindings = await context.runSetup('''
Object? main() => null;
''');
      expect(bindings, isEmpty);
    });

    test('a non-Map, non-null return is a setup-contract violation', () async {
      final context = D4rtExpressionContext();
      await expectLater(
        context.runSetup('int main() => 7;'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('D4rtExpressionContext — failure modes', () {
    test('an expression referencing an unknown name fails typed', () async {
      final resolver = _resolver();
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
  });
}
