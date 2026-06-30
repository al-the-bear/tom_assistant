// cohostReadMemoryConfig — the profile-binding decision `defaultServeBoot`
// makes for the co-hosted read surfaces (the in-process memory MCP isolate the
// `--observatory` Trail Observatory connects to).
//
// Regression guard for the "No node '<id>' always" Observatory bug. The brain's
// own store opens at `withProfile(defaultMemoryProfile)` (provision step:
// `runConfig.memory.withProfile(defaultMemoryProfile)`), so every node the brain
// writes lives under `<root>/profiles/defaultmemory_default/`. The co-hosted
// memory MCP isolate, however, used to be spawned from the **profile-unbound**
// `config.memory`, so it opened the retired bare root `<root>/memory.db` — a
// near-empty store that resolves *none* of the brain's node ids. Every node
// deep-link in the Observatory therefore 404'd as `No node '<id>'`.
//
// The fix routes the co-host's config through the same binding decision the
// standalone `bin/memory_mcp_server.dart` uses, so the read surface opens the
// default-profile store the brain writes. This test pins that contract on the
// pure value resolution (no socket, no sqlite-vec needed).

import 'package:test/test.dart';
import 'package:tom_brain_memory/tom_brain_memory.dart'
    show MemoryConfig, MemoryConfigPaths;
import 'package:tom_brain_run/tom_brain_run.dart' show cohostReadMemoryConfig;
import 'package:tom_brain_shared/tom_brain_shared.dart'
    show defaultMemoryProfile;

void main() {
  group('cohostReadMemoryConfig', () {
    test(
        'binds the default memory profile the live brain writes, never the '
        'retired bare root', () {
      final configured = MemoryConfig.forTesting(root: '/srv/brain/memory');

      // The profile-unbound config (what the bug spawned the isolate from)
      // resolves to the bare root — the near-empty pre-profiles store.
      expect(configured.profile, isNull);
      expect(configured.dataDir, '/srv/brain/memory');

      final resolved = cohostReadMemoryConfig(configured);

      expect(
        resolved.profile,
        defaultMemoryProfile,
        reason: 'the co-hosted read surface must open the same default-profile '
            'store the brain writes, so node deep-links resolve',
      );
      expect(
        resolved.dataDir,
        endsWith('profiles/$defaultMemoryProfile'),
        reason: 'the resolved data dir is the default profile directory, not '
            'the retired bare root',
      );
      expect(
        resolved.root,
        configured.root,
        reason: 'the binding only adds the profile; the root is unchanged',
      );
    });
  });
}
