// validateToolArgs — the `args`-against-`inputSchema` gate `tool.invoke`
// applies before running a tool
// (`tom_brain_procedure_specification.md` § 21.2).
//
// A deliberately small JSON-Schema subset — enough to reject the malformed
// `args` an LLM produces, no more. The supported keywords are the ones the
// basic tool set (§ 21.4) declares and the ones VS Code's
// `ToolDefinitionJson` carries (§ 21.8), so the two registries stay
// schema-compatible:
//
//   - `required: [<key>, …]`            — every listed key must be present.
//   - `properties.<key>.type`           — a scalar/structural type tag, one
//                                         of: string, integer, number,
//                                         boolean, array, object.
//   - `additionalProperties: false`     — reject any key not in `properties`.
//
// Anything else in the schema (nested object schemas, `enum`, `items`, …) is
// not validated here — it is honoured by being ignored, never by rejecting a
// value the subset does not understand. The function is pure: it returns the
// first violation as a human-readable `String`, or `null` when `args` satisfy
// the supported keywords.

/// Validates [args] against the supported subset of [schema]. Returns the
/// first violation as a message, or `null` when the args are acceptable.
String? validateToolArgs(
  Map<String, Object?> schema,
  Map<String, Object?> args,
) {
  final required = schema['required'];
  if (required is List) {
    for (final key in required) {
      if (key is String && !args.containsKey(key)) {
        return 'missing required argument "$key"';
      }
    }
  }

  final properties = schema['properties'];
  final props =
      properties is Map<String, Object?> ? properties : const <String, Object?>{};

  if (schema['additionalProperties'] == false) {
    for (final key in args.keys) {
      if (!props.containsKey(key)) {
        return 'unexpected argument "$key"';
      }
    }
  }

  for (final entry in props.entries) {
    final key = entry.key;
    if (!args.containsKey(key)) continue; // presence is `required`'s job.
    final spec = entry.value;
    if (spec is! Map<String, Object?>) continue;
    final type = spec['type'];
    if (type is! String) continue;
    final value = args[key];
    if (!_matchesType(type, value)) {
      return 'argument "$key" must be $type';
    }
  }

  return null;
}

/// Whether [value] satisfies the JSON-Schema [type] tag. An unknown tag is
/// treated as "no constraint" (returns `true`) — the subset never rejects a
/// value on a keyword it does not model.
bool _matchesType(String type, Object? value) {
  switch (type) {
    case 'string':
      return value is String;
    case 'integer':
      return value is int;
    case 'number':
      return value is num;
    case 'boolean':
      return value is bool;
    case 'array':
      return value is List;
    case 'object':
      return value is Map;
    default:
      return true;
  }
}
