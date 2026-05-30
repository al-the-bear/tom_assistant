// Barrel for the `anchor/` module (Plan step A.17).
//
// Module surface:
//
//   * `AssistantDedicationAnchor` — the framing that opens every
//     internal prompt Tom Brain ever issues. Static-only class.
//                        - `text`            : canonical anchor text
//                        - `version`         : revision number of text
//                        - `wrap(prompt)`    : prepend anchor (idempotent;
//                                              empty / null / whitespace-
//                                              only inputs collapse to the
//                                              anchor alone)
//                        - `containsAnchor(s)`: predicate used by the
//                                              substrate enforcement test
//                                              and the access-edge anchor
//                                              pre-check
//                        - `wrapAll(messages)`: anchor the first element
//                                              of a multi-message prompt
//                                              (the system message)
//
// What is deliberately NOT here:
//
//   * No content hashing. The trail records "the anchor's content
//     hash" (`thinking_specification.md` § 10.1) per LLM call, but
//     hashing needs `package:crypto` which A.9 forbids at the shared-
//     types layer. The substrate computes the hash from
//     [AssistantDedicationAnchor.text]; the version number exposed
//     here pairs with the hash so a recorded mismatch flags a text
//     change without a version bump.
//   * No role-template assembly. Roles add their objective /
//     constraints / output schema *after* the anchor; that assembly
//     lives in `tom_brain_substrate` (Plan step B.22).
//   * No `Message` type. The substrate defines the message-list shape
//     at Plan step B.10. [AssistantDedicationAnchor.wrapAll] operates
//     on `String`s so this module ships before that type exists.

export 'assistant_dedication_anchor.dart' show AssistantDedicationAnchor;
