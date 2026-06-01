// Barrel for the `json_shape/` module (Plan step B.44).
//
// Module surface:
//
//   * `JsonShape` — static-only namespace of pure JSON shape readers
//     for the `Map<String, Object?>` shape returned by
//     `dart:convert.jsonDecode` on a JSON object.
//   * `JsonShapeException` — raised by the `requireMap` /
//     `requireList` cast helpers when a top-level shape assertion
//     fails. Callers translate to their own typed exception at the
//     boundary.
//
// Origin: B.44 reuse-extraction pass. The substrate's LLM HTTP
// clients (Ollama, OpenAI passthrough) repeated the `(json[k] as T?)
// ?? fallback` pattern more than 20 times across two files; the
// shared layer is the right home because:
//
//   1. Pure value-shape helpers, no I/O, no side effects — fits the
//      A.9 dependency-discipline contract.
//   2. Multi-consumer surface anticipated: memory's MCP server
//      payload parsing, planning / creation / procedure on-disk JSON
//      stores. The rule-of-three is reached at the substrate alone;
//      the cross-component criterion is already true forward.
//
// What is deliberately NOT here:
//
//   * No `jsonDecode` wrapper. `dart:convert` is the canonical entry
//     point. Helpers operate on the *decoded* value.
//   * No schema validator. A typed-decoder library (e.g. JSON Schema,
//     Freezed-style codecs) is a different problem; these helpers are
//     a one-step typed-read primitive, not a validator.
//   * No coercion. `readBool` does not parse `"true"`; `readInt` does
//     not parse `"42"`. JSON has typed values — coercion would hide
//     vendor-side bugs.

export 'json_shape_helpers.dart' show JsonShape, JsonShapeException;
