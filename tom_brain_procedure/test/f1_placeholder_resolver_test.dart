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
//   - the `${{ expr }}` form evaluates against the live scope, and for an
//     identifier-shaped *bound* name the simple `${name}` form agrees with
//     `${{ name }}` (the forms are not equivalent in general — see the
//     divergence tests in `tom_core_agentic`);
//   - a non-identifier binding is dropped from the synthesised locals, which
//     is where the `isSimpleIdentifier` rule is actually enforced;
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
    test('a bound identifier reads the same through either form', () async {
      // The one case in which the two forms agree. They are NOT equivalent in
      // general: without a backing, or on resolveSync, or for an unbound name,
      // they diverge (pinned in tom_core_agentic).
      final resolver = _resolver();
      resolver.stack.bind('v', 'X');
      expect(
        await resolver.resolve(r'${v}'),
        await resolver.resolve(r'${{ v }}'),
      );
    });

    test('a non-identifier binding is dropped from the expression locals',
        () async {
      // This is the enforcement point for `isSimpleIdentifier`: the predicate
      // is not the simple form's grammar (which has none), it is the shape a
      // binding needs to become a d4rt parameter name. A dotted name — the
      // shape the brain substrate's `role.anchor` built-in uses — resolves
      // through the simple form and is invisible to the expression form.
      final resolver = _resolver();
      resolver.stack.bind('role.anchor', 'ANCHOR');
      expect(isSimpleIdentifier('role.anchor'), isFalse);

      // Readable through the simple form...
      expect(await resolver.resolve(r'${role.anchor}'), 'ANCHOR');

      // ...and absent from the locals, so naming it in an expression is an
      // unknown-name failure rather than a malformed-source one. The binding
      // is dropped silently; it does not corrupt the synthesised parameter
      // list.
      await expectLater(
        resolver.resolve(r'${{ 1 + 1 }}'),
        completion(equals('2')),
        reason: 'the dropped binding must not break source synthesis',
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
