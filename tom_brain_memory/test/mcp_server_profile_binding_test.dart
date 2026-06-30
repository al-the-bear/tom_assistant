// The standalone memory MCP server (`bin/memory_mcp_server.dart`) must open
// the **default memory profile** store, not the bare-root legacy store
// (`memory_specification.md` § 2.5 / § 3.2; Issue-4 root-cause fix). Before the
// memory-profile work the brain wrote at `<root>/memory.db`; § 8.1 retired that
// layout — every profile, the default included, now lives under
// `<root>/profiles/<name>/`. A bare-root-opened MCP server therefore reads a
// stale pre-profiles store and cannot resolve any node id the live brain wrote,
// which surfaced in the Observatory as `No node '<id>'` on every deep-link.
//
// `resolveMcpServerMemoryConfig` is the pure decision the bin makes: bind the
// process config to a memory profile before opening it. This unit pins the
// contract without launching a process or a vec0 store.

import 'package:tom_brain_memory/tom_brain_memory.dart';
import 'package:test/test.dart';

void main() {
  group('resolveMcpServerMemoryConfig — MCP server profile binding', () {
    final base = MemoryConfig.forTesting(root: '/tmp/brain_root');

    test('with no override, binds the default memory profile', () {
      final resolved = resolveMcpServerMemoryConfig(base);
      expect(resolved.profile, equals(defaultMemoryProfile));
      // The opened DB now lives under the default profile directory, never the
      // bare root the pre-profiles brain used.
      expect(resolved.dataDir, endsWith('profiles/$defaultMemoryProfile'));
      expect(resolved.memoryDbPath, isNot(equals(base.memoryDbPath)));
    });

    test('an explicit profile override binds that profile', () {
      final resolved = resolveMcpServerMemoryConfig(base, profile: 'eval_a');
      expect(resolved.profile, equals('eval_a'));
      expect(resolved.dataDir, endsWith('profiles/eval_a'));
    });

    test('a null override is the same as no override (default profile)', () {
      expect(
        resolveMcpServerMemoryConfig(base, profile: null).profile,
        equals(defaultMemoryProfile),
      );
    });

    test('an empty override is the same as no override (default profile)', () {
      expect(
        resolveMcpServerMemoryConfig(base, profile: '').profile,
        equals(defaultMemoryProfile),
      );
    });

    test('a path-traversal override is rejected before any store is opened', () {
      expect(
        () => resolveMcpServerMemoryConfig(base, profile: '../escape'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
