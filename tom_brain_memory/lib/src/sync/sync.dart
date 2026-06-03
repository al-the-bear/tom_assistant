// Barrel for the `sync/` module — multi-machine deployment surface
// (memory_specification.md § 14).
//
// The module is a placeholder ahead of build-order step 9 (the
// canonical-authority topology with bomber as cognitive worker and
// laptop mirrors). Today it carries only the declared-but-not-wired
// `AuthorityUnreachable` observability leaf (spec §§ 14–16) so the
// typed `Stream<MemoryEvent>` surface is complete before the
// heartbeat monitor ships. The heartbeat / authority / mirror
// implementations land here when step 9 begins.

export 'sync_events.dart' show AuthorityUnreachable;
