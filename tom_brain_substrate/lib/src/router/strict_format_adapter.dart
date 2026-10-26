// B.43 — `StrictFormatAdapter` (spec § 5.4, Q-B.43.2).
//
// `substrate_specification.md` § 5.4 row for `format`:
//
//   | `format` | HTTP 400 + format body | Re-emit with strict-format
//   |          |                        | adapter; single retry. |
//
// The classifier (`llm_failure_classifier.dart`) labels an HTTP-400 +
// format-body failure as `LlmFailureClass.format`. The router's response
// to that class is `LlmRouterAction.reformatThenRotate`: re-emit the
// prompt *once* through this adapter, then rotate to the next route if the
// re-emit also fails. This file owns the "re-emit with strict-format
// adapter" half of that contract.
//
// What the adapter does:
//
//   - Appends a strict-format reinforcement block to the [WirePrompt]
//     body. The block instructs the model to emit only the requested
//     structured output, without prose, markdown fences, or commentary.
//   - When the call carried a structured-output schema
//     (`LlmOptions.responseFormat`), the JSON-encoded schema is embedded
//     in the block so the re-emit names the exact shape expected.
//
// What the adapter deliberately does NOT do:
//
//   - It does not touch the anchor. The reinforcement is *appended*, so
//     the anchor block (which `RoleTemplate.assemble` guarantees is the
//     body's first paragraph — see `wire_prompt.dart`) stays first and
//     [WirePrompt.anchorHash] is preserved verbatim. The B.46 anchor
//     conformance test continues to pass on a reinforced prompt.
//   - It does not retry, rotate, or classify. That is the router's job;
//     the adapter is a pure `WirePrompt → WirePrompt` transform.
//   - It is applied at most once per route (the `format` action is a
//     single re-emit). Each route in the chain starts from the original
//     prompt, so the reinforcement never accumulates across rotations.

import 'dart:convert' show jsonEncode;

import 'package:tom_llm/tom_llm.dart' show WirePrompt;

/// Pure transform that re-emits a [WirePrompt] with a strict-format
/// reinforcement block appended.
///
/// Stateless and trivially shareable; use [StrictFormatAdapter.shared].
/// The router holds one instance and invokes [reinforce] on the single
/// `format`-class re-emit per route.
class StrictFormatAdapter {
  /// Shared instance. The adapter is stateless.
  static const StrictFormatAdapter shared = StrictFormatAdapter();

  const StrictFormatAdapter();

  /// Opening line of the reinforcement block. Exposed so the router's
  /// audit and the conformance tests can assert the block was applied
  /// without depending on the full wording.
  static const String reinforcementMarker = '[STRICT FORMAT REQUIRED]';

  /// Returns a copy of [prompt] with a strict-format reinforcement block
  /// appended to the [WirePrompt.system] channel. Every provenance field
  /// ([WirePrompt.anchorHash], [WirePrompt.roleId],
  /// [WirePrompt.templateSha]) and the [WirePrompt.user] channel are
  /// carried through unchanged. The block is a standing instruction, so
  /// it belongs in `system`; appending it there keeps the anchor leading
  /// the system channel.
  ///
  /// When [responseFormat] is non-null (the role declared a structured
  /// output via `LlmOptions.responseFormat`), the JSON-encoded schema is
  /// embedded so the model is told the exact shape to produce.
  WirePrompt reinforce(
    WirePrompt prompt, {
    Map<String, Object?>? responseFormat,
  }) {
    return WirePrompt(
      system: '${prompt.system}\n\n${_block(responseFormat)}',
      user: prompt.user,
      anchorHash: prompt.anchorHash,
      roleId: prompt.roleId,
      templateSha: prompt.templateSha,
    );
  }

  String _block(Map<String, Object?>? responseFormat) {
    final buffer = StringBuffer()
      ..writeln(reinforcementMarker)
      ..writeln(
        'The previous response was rejected because it did not match the '
        'required output format. Re-emit the answer as the requested '
        'structured output only. Do not wrap it in markdown code fences, '
        'prose, or commentary — output nothing except the structured '
        'payload.',
      );
    if (responseFormat != null) {
      buffer
        ..writeln()
        ..writeln('The output must be valid JSON conforming to this schema:')
        ..write(jsonEncode(responseFormat));
    }
    return buffer.toString();
  }
}
