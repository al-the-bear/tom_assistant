// ToolEmbedSurface — the narrow embedding capability the `memory.write` tool
// routes through (`tom_brain_procedure_specification.md` § 21.4).
//
// Memory never embeds lazily (`memory_specification.md` § 2.4): a node type that
// declares an embedding policy must be persisted with a pre-computed vector, so
// the *caller* of `persist` produces it. Scripted procedures do this through
// `sub.embed` before `mem.persist`; the `memory.write` tool needs the same
// step. This surface is that one capability — embed a string into the substrate
// embedding model's vector — and nothing a tool can reach past (PE-1).
//
// Budget note: `tool.invoke` pre-charges one `toolCalls` unit per call and
// `memory.write` adds one `memoryWrites` unit (PE-8); the embedding is an
// internal step of that one write, not a separately-budgeted call. So an
// implementation routes through the substrate **client**, not the
// budget-charging `SubstrateBridge`, exactly as `ToolWebSurface` does — embedding
// a node's text to satisfy its policy must not double-count the write.

import 'package:tom_brain_shared/tom_brain_shared.dart' show Vec;

/// The embedding capability the `memory.write` tool may use to satisfy a node
/// type's embedding policy before persisting.
///
/// Method-only and result-as-data: an implementation adapts the substrate
/// embedding service into the single call the tool needs, and nothing a tool can
/// reach past (PE-1). Optional on a `ToolContext` — a run that writes only
/// embedding-`none` node types carries none.
abstract interface class ToolEmbedSurface {
  /// Embeds [text] into the substrate embedding model's vector. The returned
  /// [Vec] rides into the persisted [NodeDraft]; memory stamps the producing
  /// model's identity from the node type's policy (`memory_specification.md`
  /// § 7.4), so the caller hands over only the vector.
  Future<Vec> embed(String text);
}
