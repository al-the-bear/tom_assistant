// SubstrateToolEmbedSurface — the [ToolEmbedSurface] the `memory.write` tool
// routes through, adapting a `TomBrainSubstrateClient`'s `embed` primitive
// (`tom_brain_procedure_specification.md` § 21.4).
//
// `memory.write` must produce a vector for any node type that declares an
// embedding policy, because memory never embeds lazily. This adapter calls the
// substrate client's `embed` and returns just the vector — memory stamps the
// model identity itself from the type's policy (`memory_specification.md`
// § 7.4), so the producing identity does not ride through here.
//
// Budget note: it wraps the substrate **client**, not the budget-charging
// `SubstrateBridge`. The embedding is an internal step of the one `memoryWrites`
// charge `memory.write` already makes (PE-8); routing through the bridge would
// add a spurious charge for a call the tool's own write already accounts for.

import 'package:tom_brain_shared/tom_brain_shared.dart' show Vec;
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show TomBrainSubstrateClient;

import 'tool_embed_surface.dart';

/// Adapts a [TomBrainSubstrateClient] into the narrow [ToolEmbedSurface] the
/// `memory.write` tool needs.
///
/// Holds the raw substrate client (never the budget-charging bridge) so the
/// embedding step does not double-count the `memoryWrites` unit the write
/// already charges (PE-8).
final class SubstrateToolEmbedSurface implements ToolEmbedSurface {
  /// The substrate client the embed call routes through.
  final TomBrainSubstrateClient client;

  /// Wraps [client]'s embedding service as a [ToolEmbedSurface].
  const SubstrateToolEmbedSurface(this.client);

  @override
  Future<Vec> embed(String text) async => (await client.embed(text)).vec;
}
