// StreamQuery — cursor-backed bulk iteration (§ 9.2).
//
// Agents (Extractor, Connector, Synthesizer, …) iterate over
// potentially huge node sets. `TomBrainMemory.stream(StreamQuery)`
// returns a `Stream<Node>`; the cursor that backs it survives
// process restarts via `StreamCursor.save()` / `restore()`.

import 'recall_query.dart' show SymbolicFilter;

/// Cursor state that lets an interrupted stream resume.
///
/// The cursor is an opaque token from the caller's perspective. The
/// shape is exposed so it can be persisted as JSON in
/// `checkpoints/`; concrete encoding is memory's concern.
final class StreamCursor {
  /// Stable id of the stream (one per agent run).
  final String streamId;

  /// Opaque payload — memory-internal pagination state.
  ///
  /// At A.24 this is just a JSON-encodable map; the concrete shape
  /// (last-seen-id + sort-key tuple) lands at A.62 with the cursor
  /// implementation.
  final Map<String, Object?> payload;

  const StreamCursor({
    required this.streamId,
    required this.payload,
  });
}

/// Input for `TomBrainMemory.stream`.
final class StreamQuery {
  /// Symbolic filter applied to the underlying scan.
  final SymbolicFilter filter;

  /// Suggested batch size. The cursor is checkpointed every batch.
  final int batchSize;

  /// Resume cursor from a prior run; `null` starts a fresh stream.
  final StreamCursor? resumeFrom;

  const StreamQuery({
    required this.filter,
    this.batchSize = 256,
    this.resumeFrom,
  });
}
