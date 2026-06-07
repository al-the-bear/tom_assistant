// Request-fidelity element-type unit tests (Plan step G.19).
//
// Covers the three value types that populate `InboundRequest`'s four
// Extension-G fields (hub spec § 22.1 / access spec § 4.2):
//   * `PriorTurn`        — one ordered (role, text) turn of remote history.
//   * `RemoteToolResult` — one client-executed tool result echoed back.
//   * `RemoteToolDef`     — one client-declared tool definition the brain
//                           may propose but never executes.
//
// Each type is an immutable value object: field carry, structural
// equality / hashCode, rejection of an empty identity-bearing field, and
// a non-throwing `toString`. `RemoteToolDef` additionally defends its
// `inputSchema` map against external mutation.

import 'package:test/test.dart';

import 'package:tom_brain_shared/tom_brain_shared.dart'
    show PriorTurn, RemoteToolDef, RemoteToolResult;

void main() {
  group('PriorTurn', () {
    test('carries role and text', () {
      final t = PriorTurn(role: 'user', text: 'hello');
      expect(t.role, 'user');
      expect(t.text, 'hello');
    });

    test('rejects an empty role', () {
      expect(() => PriorTurn(role: '', text: 'x'), throwsArgumentError);
    });

    test('rejects a whitespace-only role', () {
      expect(() => PriorTurn(role: '  \t', text: 'x'), throwsArgumentError);
    });

    test('allows empty text (an empty turn body is legal)', () {
      final t = PriorTurn(role: 'assistant', text: '');
      expect(t.text, isEmpty);
    });

    test('value equality / hashCode over both fields', () {
      final a = PriorTurn(role: 'user', text: 'hi');
      final b = PriorTurn(role: 'user', text: 'hi');
      final c = PriorTurn(role: 'assistant', text: 'hi');
      final d = PriorTurn(role: 'user', text: 'bye');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
    });

    test('toString previews long text and never throws', () {
      final t = PriorTurn(role: 'user', text: 'x' * 200);
      expect(t.toString(), contains('…'));
      expect(t.toString(), contains('user'));
    });
  });

  group('RemoteToolResult', () {
    test('carries the tool-call id and content', () {
      final r = RemoteToolResult(toolCallId: 'call_1', content: '42');
      expect(r.toolCallId, 'call_1');
      expect(r.content, '42');
    });

    test('rejects an empty tool-call id', () {
      expect(
        () => RemoteToolResult(toolCallId: '', content: 'x'),
        throwsArgumentError,
      );
    });

    test('rejects a whitespace-only tool-call id', () {
      expect(
        () => RemoteToolResult(toolCallId: '   ', content: 'x'),
        throwsArgumentError,
      );
    });

    test('allows empty content (a tool may return nothing)', () {
      final r = RemoteToolResult(toolCallId: 'call_1', content: '');
      expect(r.content, isEmpty);
    });

    test('value equality / hashCode over both fields', () {
      final a = RemoteToolResult(toolCallId: 'c1', content: 'out');
      final b = RemoteToolResult(toolCallId: 'c1', content: 'out');
      final c = RemoteToolResult(toolCallId: 'c2', content: 'out');
      final d = RemoteToolResult(toolCallId: 'c1', content: 'other');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
    });

    test('toString previews long content and never throws', () {
      final r = RemoteToolResult(toolCallId: 'c1', content: 'y' * 200);
      expect(r.toString(), contains('…'));
      expect(r.toString(), contains('c1'));
    });
  });

  group('RemoteToolDef', () {
    test('carries name; description and schema default', () {
      final d = RemoteToolDef(name: 'get_weather');
      expect(d.name, 'get_weather');
      expect(d.description, isNull);
      expect(d.inputSchema, isEmpty);
    });

    test('carries all fields when supplied', () {
      final d = RemoteToolDef(
        name: 'get_weather',
        description: 'Look up the weather',
        inputSchema: {'type': 'object'},
      );
      expect(d.description, 'Look up the weather');
      expect(d.inputSchema, {'type': 'object'});
    });

    test('rejects an empty name', () {
      expect(() => RemoteToolDef(name: ''), throwsArgumentError);
    });

    test('rejects a whitespace-only name', () {
      expect(() => RemoteToolDef(name: '  \n'), throwsArgumentError);
    });

    test('inputSchema is an unmodifiable defensive copy', () {
      final source = <String, Object?>{'k': 1};
      final d = RemoteToolDef(name: 't', inputSchema: source);
      source['k'] = 2; // mutating the source must not leak in
      expect(d.inputSchema['k'], 1);
      expect(() => d.inputSchema['k'] = 9, throwsUnsupportedError);
    });

    test('value equality / hashCode over all fields', () {
      final a = RemoteToolDef(
        name: 't',
        description: 'd',
        inputSchema: {'type': 'object'},
      );
      final b = RemoteToolDef(
        name: 't',
        description: 'd',
        inputSchema: {'type': 'object'},
      );
      final c = RemoteToolDef(name: 't', description: 'other');
      final e = RemoteToolDef(
        name: 't',
        description: 'd',
        inputSchema: {'type': 'string'},
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(e)));
    });

    test('toString carries the name and never throws', () {
      final d = RemoteToolDef(name: 'lookup', description: 'x');
      expect(d.toString(), contains('lookup'));
    });
  });
}
