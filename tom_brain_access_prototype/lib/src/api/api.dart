// Public surface of the access prototype.
//
// Owns the consumer-facing types the package exports through its
// top-level barrel — the access-layer entry points and any interfaces a
// test harness or `bin/` executable drives against (e.g. the boot
// handle, the adapter mount points). Symbols land here as the adapter,
// identity, security, classifier, delivery, and boot modules mature; the
// reuse-extraction pass (E.52) decides which of them migrate to
// `tom_brain_shared`. See
// `tom_brain_access_prototype_specification.md` § API and Plan steps
// E.9+ (first concrete symbol with the executable) / E.51 – E.52.
//
// At E.8 this folder is intentionally empty. No exports yet.
