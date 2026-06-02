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
// E.9 lands the first concrete public symbols: the `tom_build_base`
// `ToolDefinition` (`accessPrototypeTool`), the `serve` executor
// (`AccessServeExecutor` + `createAccessPrototypeExecutors`), and the
// version constants. `bin/tom_brain_access_prototype.dart` is the only
// consumer today; tests drive the same surface black-box.

export 'access_prototype_tool.dart';
export 'access_serve_executor.dart';
