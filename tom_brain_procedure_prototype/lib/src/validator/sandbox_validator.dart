// SandboxValidator — the second of the three validator layers (Plan step
// C.28; `tom_brain_procedure_prototype_specification.md` § 7 row 3, § 4.2).
//
// This layer owns the spec's third row — "No forbidden imports / SDK
// touchpoints / disallowed identifiers" → `procedure.sandbox.violation`.
// It is the *static* half of the PE-1 surface lock: the bridged primitive
// API is the only surface a procedure can touch, enforced at two layers
// (d4rt sandbox + bridge). The validator scans a procedure's verbatim
// source *before* it ever reaches the host, so a script that imports
// `dart:io` or calls `Process.run` is kept out of the runnable set rather
// than being stopped only at runtime.
//
// The scan works on a **code projection** of the source: comments and the
// literal text of string literals are blanked out (replaced with spaces,
// newlines preserved), while the code inside string interpolations
// (`${ ... }` and `$identifier`) is kept — interpolated expressions are
// real code and could otherwise smuggle a disallowed reference past the
// scan. Working on the projection means a banned word that appears only in
// a comment or inside a string literal does not trip the validator.
//
// What the projection deliberately does *not* do: it is not a full Dart
// parser. The "d4rt source parses" check (`procedure.parse.failed`) is the
// host's job; nested string literals inside an interpolation are not
// tracked. For the prototype's defence-in-depth static gate — backed by
// the runtime d4rt sandbox and the bridge layer — a lexical projection is
// the right amount of machinery. See Q-C.28.x in
// `prototype_implementation_questions.md`.

import '../bridges/brain_bridges_registrar.dart';
import '../primitives_native/native_primitives_installer.dart'
    show engineNativeLibrary;
import '../primitives_native/procedure_inputs_bridge.dart'
    show procedureInputsLibrary;
import '../procedure_store/procedure_loader.dart';
import 'code_projection.dart';
import 'procedure_sandbox_violation.dart';

/// Statically rejects procedure sources that reach outside the bridged
/// primitive API: an `export` directive, an `import` of any library other
/// than the host-injected bridge / input / engine-native ones, or a
/// reference to a disallowed top-level identifier (an SDK gateway such as
/// `Process`, `File`, `Isolate`).
///
/// Stateless once constructed — every method is a pure function of its
/// input and the configured deny sets. Construct once and reuse, or use
/// the [shared] instance with the default deny sets. Failures throw
/// [ProcedureSandboxViolation] (wire code `procedure.sandbox.violation`).
final class SandboxValidator {
  /// Builds a validator with the given deny sets (defaulting to the
  /// built-in [defaultDisallowedDirectives] / [defaultDisallowedIdentifiers]
  /// / [defaultAllowedImportUris]).
  const SandboxValidator({
    this.disallowedDirectives = defaultDisallowedDirectives,
    this.disallowedIdentifiers = defaultDisallowedIdentifiers,
    this.allowedImportUris = defaultAllowedImportUris,
  });

  /// A shared, reusable validator with the default deny sets.
  static const SandboxValidator shared = SandboxValidator();

  /// Directive keywords a procedure may never use, *regardless of URI*.
  ///
  /// `export` re-exposes code from outside the bridged surface and is never
  /// legitimate in a procedure (§ 4.2). `import` is deliberately *not* in
  /// this set: a procedure reaches the bridged primitives precisely by
  /// importing the host-injected bridge / input / engine-native libraries
  /// (`D4rtDcliHost` injects `mem` / `sub` as globals keyed to those library
  /// URIs, and `runProcedure` / `note` are top-level functions registered
  /// under [engineNativeLibrary]). `import` is therefore allow-listed by URI
  /// in [allowedImportUris] rather than banned outright — the reconciliation
  /// of the old blanket import ban with the host's import-to-reach-`mem`/`sub`
  /// convention (Q-D.37.1). A consumer that wants the old blanket ban can put
  /// `'import'` back into this set.
  ///
  /// `library` / `part` are excluded — they cannot legitimately appear in a
  /// single-file procedure, so the host's parse layer
  /// (`procedure.parse.failed`) rejects that shape first, and keeping them out
  /// of this set avoids false positives on the common identifiers `part` /
  /// `library`. See Q-C.28.2.
  static const Set<String> defaultDisallowedDirectives = {'export'};

  /// The library URIs a procedure `import` may name. These are exactly the
  /// libraries the host injects effect surface through (PE-1): the two
  /// generated bridges (`mem` / `sub`), the engine-native primitives
  /// (`runProcedure` / `note` / `yield_if_foreground_waiting` and the sugar
  /// aliases), and the `ProcedureInputs` read surface. An `import` of any
  /// other URI — `dart:io`, an arbitrary package, a relative path — is a
  /// violation, because it pulls in code from outside the bridged surface.
  ///
  /// Sourced from the canonical URI constants (`BrainBridges.memoryLibrary` /
  /// `…substrateLibrary`, [engineNativeLibrary], [procedureInputsLibrary]) so
  /// the allow-list cannot drift from the libraries the host actually
  /// registers.
  static const Set<String> defaultAllowedImportUris = {
    BrainBridges.memoryLibrary,
    BrainBridges.substrateLibrary,
    engineNativeLibrary,
    procedureInputsLibrary,
  };

  /// Top-level identifiers a procedure may never reference. These are the
  /// SDK gateways through which a script could touch the file system, the
  /// network, processes, isolates, the standard streams, or `eval`-style
  /// indirection — every effect PE-1 reserves for the bridged primitives.
  ///
  /// Only *top-level* references are matched: `obj.Process` (a member named
  /// `Process`) is not flagged, because the deny scan requires the name to
  /// not be preceded by a `.`. A procedure cannot construct one of these
  /// types without naming it at the top level, so the top-level scan is
  /// sufficient for the static gate.
  static const Set<String> defaultDisallowedIdentifiers = {
    // dart:io — file system
    'File', 'Directory', 'Link', 'FileSystemEntity', 'FileStat',
    'RandomAccessFile',
    // dart:io — processes + platform
    'Process', 'ProcessResult', 'ProcessSignal', 'Platform',
    // dart:io — sockets + network
    'Socket', 'RawSocket', 'ServerSocket', 'RawServerSocket', 'SecureSocket',
    'RawDatagramSocket', 'Datagram', 'InternetAddress',
    'HttpClient', 'HttpServer', 'WebSocket',
    // dart:html
    'HttpRequest', 'window', 'document',
    // dart:isolate — concurrency / interpreter spawning
    'Isolate', 'ReceivePort', 'RawReceivePort', 'SendPort', 'Capability',
    // dart:io — standard streams + process control
    'stdin', 'stdout', 'stderr', 'exit', 'pid',
    // eval-style indirection over the procedure's own source
    'eval',
  };

  /// The directive keywords this validator rejects regardless of URI.
  final Set<String> disallowedDirectives;

  /// The top-level identifiers this validator rejects.
  final Set<String> disallowedIdentifiers;

  /// The library URIs an `import` directive may name (see
  /// [defaultAllowedImportUris]).
  final Set<String> allowedImportUris;

  /// The `import` keyword, located in the projection and allow-listed by URI.
  static const String _importKeyword = 'import';

  /// Scans a bare [source] for forbidden directives, off-allow-list imports,
  /// and disallowed top-level identifiers.
  ///
  /// [procedureId] is woven into the failure message when known. Throws
  /// [ProcedureSandboxViolation] on the first violation found (always-banned
  /// directives, then imports, then identifiers).
  void validateSource(String source, {String? procedureId}) {
    final projection = CodeProjection.project(source);
    _checkDirectives(projection, procedureId);
    _checkImports(projection, source, procedureId);
    _checkIdentifiers(projection, procedureId);
  }

  /// Scans a loaded [procedure]'s verbatim source, attributing any failure
  /// to its header id.
  void validate(LoadedProcedure procedure) =>
      validateSource(procedure.source, procedureId: procedure.header.id);

  /// Scans every procedure in a loaded set. Throws on the first violation.
  void validateAll(Iterable<LoadedProcedure> procedures) {
    for (final procedure in procedures) {
      validate(procedure);
    }
  }

  // --- checks ------------------------------------------------------------

  void _checkDirectives(String projection, String? procedureId) {
    for (final keyword in disallowedDirectives) {
      final match =
          RegExp('(?<![\\w\$.])$keyword(?![\\w\$])').firstMatch(projection);
      if (match != null) {
        throw ProcedureSandboxViolation(
          'procedures may not use the `$keyword` directive; the bridged '
          'primitive API is the only surface a procedure can touch (PE-1)',
          kind: SandboxViolationKind.forbiddenDirective,
          offender: keyword,
          line: CodeProjection.lineOf(projection, match.start),
          procedureId: procedureId,
        );
      }
    }
  }

  /// Rejects every `import` whose URI is not in [allowedImportUris].
  ///
  /// The `import` keyword is located in the [projection] (so an `import`
  /// inside a comment or string literal is not seen), but the URI is read
  /// from the raw [source]: [CodeProjection] blanks string-literal text, so
  /// the URI is spaces in the projection and only legible in the original.
  /// Offsets are preserved 1:1 between the two, so the keyword position found
  /// in the projection points at the same byte in the source. An `import`
  /// with no resolvable quoted URI (a dynamic or malformed import) is refused
  /// — the validator only trusts imports it can name.
  ///
  /// When `'import'` is in [disallowedDirectives] (a consumer restoring the
  /// old blanket ban), [_checkDirectives] has already thrown and this never
  /// runs.
  void _checkImports(String projection, String source, String? procedureId) {
    if (disallowedDirectives.contains(_importKeyword)) return;
    final pattern = RegExp('(?<![\\w\$.])$_importKeyword(?![\\w\$])');
    for (final match in pattern.allMatches(projection)) {
      final uri = _importUriAt(source, match.end);
      if (uri != null && allowedImportUris.contains(uri)) continue;
      throw ProcedureSandboxViolation(
        uri == null
            ? 'an `import` directive has no resolvable URI; a procedure may '
                'only import the host-injected bridge, input, and '
                'engine-native libraries (PE-1)'
            : 'procedures may not import `$uri`; only the host-injected '
                'bridge, input, and engine-native libraries may be imported '
                '(PE-1)',
        kind: SandboxViolationKind.forbiddenDirective,
        offender: _importKeyword,
        line: CodeProjection.lineOf(projection, match.start),
        procedureId: procedureId,
      );
    }
  }

  /// Reads the quoted URI of an `import` directive whose keyword ends at
  /// [start] in the raw [source], returning the URI text without quotes, or
  /// `null` when no string literal follows on the line (a dynamic/malformed
  /// import the validator refuses to trust). Import URIs carry no
  /// interpolation, so a plain scan to the matching quote is exact.
  static String? _importUriAt(String source, int start) {
    final n = source.length;
    var i = start;
    while (i < n && _isSpace(source[i])) {
      i++;
    }
    if (i < n && source[i] == 'r') i++; // tolerate a raw-string prefix
    if (i >= n) return null;
    final quote = source[i];
    if (quote != '"' && quote != "'") return null;
    i++;
    final uri = StringBuffer();
    while (i < n) {
      final c = source[i];
      if (c == quote) return uri.toString();
      if (c == '\n') return null; // unterminated on the line
      uri.write(c);
      i++;
    }
    return null; // unterminated
  }

  /// Whether [c] is inline whitespace (space, tab, CR, or newline).
  static bool _isSpace(String c) =>
      c == ' ' || c == '\t' || c == '\r' || c == '\n';

  void _checkIdentifiers(String projection, String? procedureId) {
    for (final identifier in disallowedIdentifiers) {
      final match = RegExp('(?<![\\w\$.])${RegExp.escape(identifier)}(?![\\w\$])')
          .firstMatch(projection);
      if (match != null) {
        throw ProcedureSandboxViolation(
          'procedures may not reference `$identifier`; reach the file '
          'system, network, processes, isolates, or providers only through '
          'a bridged primitive (PE-1)',
          kind: SandboxViolationKind.disallowedIdentifier,
          offender: identifier,
          line: CodeProjection.lineOf(projection, match.start),
          procedureId: procedureId,
        );
      }
    }
  }
}
