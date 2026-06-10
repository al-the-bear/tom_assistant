// SubstrateIsolateExceptions — the closed-taxonomy codec that lets the
// substrate layer's typed exceptions survive an isolate-boundary round
// trip (Tom Brain completion-plan item #12).
//
// The in-isolate executor catches an exception, flattens it to the
// sendable wire form (`IsolateErrorResponse` / `StreamErrorEnvelope`:
// a type tag + message + a sendable `details` map) and sends it to the
// host. The host rebuilds the *same* typed instance via the generic
// `IsolateExceptionRegistry`, so a procedure that ran the substrate
// behind the isolate boundary catches the same type it would in-process
// — no prose parsing, no untyped wrapper.
//
// The fidelity that matters here is [AnchorViolation]. The proxy
// independently re-checks every report's anchor and throws
// `AnchorViolation` *locally* (it never crosses the wire in the common
// case). But the worker-side facade *also* enforces the anchor; if it
// throws `AnchorViolation` first, that exception crosses the boundary,
// and the proxy must surface it as `AnchorViolation` — not as a generic
// boundary wrapper. So `AnchorViolation` is the one entry this codec
// guarantees round-trips with full structure.
//
// The taxonomy is deliberately narrow. Anything outside it (a
// `RoleNotFound`, a provider library error, a core `StateError`) is not
// packed — `pack` returns `null` and the host falls back to
// `IsolateBoundaryException`. Widening the taxonomy is a deliberate
// change that lands the codec entry + its round-trip test together.

import 'package:tom_core_agentic/tom_core_agentic.dart'
    show IsolateExceptionRegistry;

import '../llm/anchor_registry.dart';

/// The flat wire form of a packed taxonomy exception: its runtime type
/// tag, a human message, and a sendable map of its structured fields.
typedef PackedSubstrateException = ({
  String type,
  String message,
  Map<String, Object?> details,
});

/// Codec for the closed substrate exception taxonomy across the isolate
/// boundary. Pure static surface — no instance state.
abstract final class SubstrateIsolateExceptions {
  /// Flattens [error] into its wire form when it belongs to the closed
  /// taxonomy, or returns `null` when it does not (the boundary then
  /// falls back to the generic `IsolateBoundaryException`).
  static PackedSubstrateException? pack(Object error) {
    switch (error) {
      case AnchorViolation():
        return (
          type: 'AnchorViolation',
          message: error.toString(),
          details: <String, Object?>{
            'expected': error.expected,
            'actual': error.actual,
            'providerId': error.providerId,
            'modelId': error.modelId,
            'roleId': error.roleId,
          },
        );
      default:
        return null;
    }
  }

  /// Registers a reconstruction factory for every taxonomy type into
  /// [registry]. The host calls this once at construction; the factory
  /// keys mirror the [pack] type tags exactly.
  static void registerInto(IsolateExceptionRegistry registry) {
    registry.register(
      'AnchorViolation',
      (m, d) => AnchorViolation(
        expected: d['expected']! as String,
        actual: d['actual']! as String,
        providerId: d['providerId']! as String,
        modelId: d['modelId']! as String,
        roleId: d['roleId']! as String,
      ),
    );
  }
}
