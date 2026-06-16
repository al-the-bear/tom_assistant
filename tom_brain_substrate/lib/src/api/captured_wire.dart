// CapturedWirePrompt now lives in `tom_core_agentic`.
//
// Migrated out of the substrate into the generic agent layer (TomSpecs editor
// §20 step 3 / §19 T3) so the provider seam is reusable outside the brain. The
// class definition is owned by `tom_core_agentic`; this file re-exports it so
// every existing `api/captured_wire.dart` import path — and the `api/` barrel
// surface — keeps resolving to the single canonical type. No duplicate
// definition remains here.
export 'package:tom_core_agentic/tom_core_agentic.dart' show CapturedWirePrompt;
