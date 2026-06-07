// Typed failures of the basic tool set
// (`tom_brain_procedure_prototype_specification.md` § 21.4, § 5.1).
//
// These are the hard refusals a shipped `BrainTool` raises from `run` — a
// sandbox breach, a node-shape violation, a non-serialisable script result, or
// a missing optional surface. They are *not* the soft `{ok: false, error}` the
// `tool.invoke` bridge returns for an unknown / policy-denied / schema-invalid
// call (§ 21.2): those three are caught before `run` ever starts. A failure
// here means the call passed the gate and then hit a boundary the tool must
// not cross, so it propagates exactly like `ProcedureBudgetExceeded` and
// `RecursionLimitExceeded` do — loudly, ending the call.
//
// Each mirrors the package exception convention (`final class … implements
// Exception`, a wire-stable `code` constant + getter, a `message`, and a
// `toString()` that prefixes `$code:`), matching `ToolAlreadyRegistered` and
// the `config/` error family.

/// Wire-stable discriminator for a file-scope sandbox escape.
const String fileScopeViolationCode = 'tool.file_scope_violation';

/// Raised when a file-group tool is handed a path that resolves outside the
/// configured file-scope root (`ToolContext.fileScopeRoot`, § 21.4).
///
/// The file sandbox is a value, not a capability: the tool re-derives a
/// `dart:io` handle from the root string and the caller's relative path, then
/// refuses any resolved path that is not within the root (PE-1). A `..`
/// segment, an absolute path, or a symlink-style escape all surface here
/// *before* any byte is read or written.
final class FileScopeViolation implements Exception {
  /// The configured file-scope root the path tried to escape.
  final String root;

  /// The caller-supplied path that resolved outside [root].
  final String requested;

  /// Builds the failure for [requested] against [root].
  const FileScopeViolation({required this.root, required this.requested});

  /// The wire-stable failure class (`tool.file_scope_violation`).
  String get code => fileScopeViolationCode;

  /// Human-readable detail.
  String get message =>
      'path "$requested" escapes the file-scope root "$root"';

  @override
  String toString() => '$code: $message';
}

/// Wire-stable discriminator for a disallowed `memory.write` node shape.
const String nodeShapeNotWritableCode = 'tool.node_shape_not_writable';

/// Raised when `memory.write` is asked to persist a node type outside the
/// § 5.1 allow-list (`Conclusion` / `Claim` / `Question` / `Procedure`).
///
/// `Event` writes in particular go through the recorder's trail, never the
/// `persist` tool, so a tool-driven `Event` write is a contract error caught
/// before it reaches memory — the memory client does not enforce this rule, so
/// the tool does.
final class NodeShapeNotWritable implements Exception {
  /// The rejected node type name.
  final String typeName;

  /// The allowed type names, for the message.
  final Set<String> allowed;

  /// Builds the failure for the rejected [typeName].
  const NodeShapeNotWritable({required this.typeName, required this.allowed});

  /// The wire-stable failure class (`tool.node_shape_not_writable`).
  String get code => nodeShapeNotWritableCode;

  /// Human-readable detail.
  String get message =>
      'memory.write cannot persist a "$typeName" node — '
      'allowed: ${(allowed.toList()..sort()).join(', ')}';

  @override
  String toString() => '$code: $message';
}

/// Wire-stable discriminator for a non-JSON `script.run_d4rt` result.
const String scriptResultNotJsonCode = 'tool.script_result_not_json';

/// Raised when `script.run_d4rt`'s nested evaluation returns a value that is
/// not JSON-serialisable (§ 21.4).
///
/// The tool's contract is "runs a d4rt script returning JSON"; a script that
/// yields a `DateTime`, a closure, or any non-primitive/structural value
/// breaks that contract, so the result is refused rather than smuggled out as
/// an opaque object.
final class ScriptResultNotJson implements Exception {
  /// The runtime type of the offending result, for the message.
  final String runtimeTypeName;

  /// Builds the failure for a result of type [runtimeTypeName].
  const ScriptResultNotJson(this.runtimeTypeName);

  /// The wire-stable failure class (`tool.script_result_not_json`).
  String get code => scriptResultNotJsonCode;

  /// Human-readable detail.
  String get message =>
      'script.run_d4rt result of type $runtimeTypeName is not JSON-serialisable';

  @override
  String toString() => '$code: $message';
}

/// Wire-stable discriminator for a tool invoked without its required surface.
const String toolSurfaceUnavailableCode = 'tool.surface_unavailable';

/// Raised when a tool that needs an optional [ToolContext] surface (the web
/// surface for `web.*`, the engine surface for `script.run_d4rt` /
/// `procedure.*`) runs in a context that did not supply it.
///
/// A memory-only run carries no web/engine surface; exposing such a tool there
/// is a wiring mistake the policy should have prevented, so it surfaces loudly
/// rather than silently returning an empty result.
final class ToolSurfaceUnavailable implements Exception {
  /// The name of the missing surface (`web`, `engine`).
  final String surface;

  /// The tool that needed it.
  final String tool;

  /// Builds the failure for [tool] needing [surface].
  const ToolSurfaceUnavailable({required this.surface, required this.tool});

  /// The wire-stable failure class (`tool.surface_unavailable`).
  String get code => toolSurfaceUnavailableCode;

  /// Human-readable detail.
  String get message =>
      'tool "$tool" needs the "$surface" surface, which this run does not carry';

  @override
  String toString() => '$code: $message';
}
