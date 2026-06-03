// Internal `toString` text-preview helper (review action A.2.1).
//
// `InboundRequest` and `OutboundChunk` each defined a verbatim `_preview`
// that truncates a possibly-large text body so a `toString` / log line never
// dumps a full prompt or answer. Centralised here so the eliding rule (and
// the truncation marker) lives in one place.
//
// Why `internal/`: a formatting aid for this package's own value types, not
// part of the public import surface.

/// Truncates [s] to at most [max] characters for `toString` / log output,
/// appending a single-character ellipsis when elided. Keeps a full prompt or
/// answer body out of logs. [max] defaults to 40.
String previewText(String s, {int max = 40}) =>
    s.length <= max ? s : '${s.substring(0, max)}…';
