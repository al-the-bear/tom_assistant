// P1.3 #8 — engine-native `emit` primitive (Dart-level unit tests).
//
// Drives `EmitPrimitive` directly, off the d4rt boundary. The companion
// `native_primitives_installer_test.dart` proves the d4rt-facing half (a
// script calling `emit(...)` reaches the sink).
//
// These tests pin: the primitive forwards each text delta to the injected
// outbound sink in call order; a sink-less primitive is a no-op that
// completes immediately (the internal / free-time path); `isBound` reports
// whether a sink is wired; and the future a bound `emit` returns resolves
// only after the sink resolves (the backpressure contract).

import 'dart:async';

import 'package:test/test.dart';

import 'package:tom_brain_procedure/tom_brain_procedure.dart';

void main() {
  group('EmitPrimitive', () {
    test('forwards each text delta to the bound sink in call order', () async {
      final deltas = <String>[];
      final primitive = EmitPrimitive(sink: (delta) async => deltas.add(delta));

      await primitive.emit('Hel');
      await primitive.emit('lo, ');
      await primitive.emit('world');

      expect(deltas, <String>['Hel', 'lo, ', 'world']);
    });

    test('isBound is true when a sink is wired', () {
      final primitive = EmitPrimitive(sink: (_) async {});
      expect(primitive.isBound, isTrue);
    });

    test('isBound is false and emit is a no-op when no sink is wired', () async {
      final primitive = EmitPrimitive();
      expect(primitive.isBound, isFalse);
      // Must complete without throwing — a background body may emit blindly.
      await primitive.emit('dropped');
    });

    test('awaits the sink so backpressure reaches the caller', () async {
      final gate = Completer<void>();
      final primitive = EmitPrimitive(sink: (_) => gate.future);

      var resolved = false;
      unawaited(primitive.emit('x').then((_) => resolved = true));

      // The emit future must not resolve until the sink's future does.
      await Future<void>.delayed(Duration.zero);
      expect(resolved, isFalse);

      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(resolved, isTrue);
    });
  });
}
