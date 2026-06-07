// Plan Extension-H step #29 — deterministic parsing of retrieval-role
// output (substrate § 6.2a).
//
// § 6.2a: "Each role carries a structured output schema so its result
// parses deterministically; an unparseable result is a `retrieval.*`
// graceful-degrade (hub § 23.9), never a crash."
//
// The role's `outputSchema` (a provider-portable JSON-schema map on
// `RoleTemplate`) is what the model is *asked* to produce. This file is
// the consuming half: given the JSON object a retrieval role returned, it
// produces a typed [RetrievalRoleOutput] when the payload is well-formed,
// or a [RetrievalRoleDegraded] carrying [retrievalRoleOutputMalformed]
// when it is not. It never throws — a malformed model output is an
// expected operational event (PE-6, graceful degrade), not a bug.
//
// Why hand-written parsers and not a general JSON-schema validator:
//
//   * There are exactly six shapes, each small and fixed. A general
//     schema-validation engine (draft-07 keyword coverage, $ref
//     resolution, format assertions) would be far more code than the six
//     parsers, and would still need per-role glue to lift the validated
//     map into a typed output class. The hand-written parser does the
//     validation and the lift in one pass, and reads as the contract.
//   * The output classes are what the procedure layer actually consumes —
//     `RecallPlannerOutput.questions`, `ProfileSelectorOutput.confidence`,
//     etc. A validator that only said "valid / invalid" would still leave
//     the caller to re-read the map.
//
// The degrade code is a single new failure row — `retrieval.role.output.
// malformed` — added to hub spec § 23.9 in the same change.

/// The hub § 23.9 failure code for a retrieval-role output that does not
/// parse against its role's declared schema. Distinct from
/// `retrieval.recall.multi.malformed` (a malformed *seed* on the
/// memory-side MCP arg) — this is a malformed *LLM result* on the
/// substrate side.
const String retrievalRoleOutputMalformed = 'retrieval.role.output.malformed';

/// The outcome of parsing a retrieval role's output: either a typed
/// [RetrievalRoleParsed] or a [RetrievalRoleDegraded].
///
/// Sealed so a consumer's `switch` is exhaustive — there is no third
/// "maybe" state, and no path throws.
sealed class RetrievalRoleParse {
  const RetrievalRoleParse();
}

/// A well-formed parse carrying the typed [output].
final class RetrievalRoleParsed extends RetrievalRoleParse {
  /// The typed result lifted from the role's JSON payload.
  final RetrievalRoleOutput output;

  const RetrievalRoleParsed(this.output);
}

/// A graceful-degrade parse: the payload did not match the role's schema.
///
/// Carries the hub § 23.9 [code] (always [retrievalRoleOutputMalformed]
/// here) and a human-readable [reason] for the trail / `note`. The caller
/// drops the LLM seed and proceeds on the cheap non-LLM pass (PE-6).
final class RetrievalRoleDegraded extends RetrievalRoleParse {
  /// The hub § 23.9 failure code.
  final String code;

  /// Why the payload was rejected — surfaced in a `note` / trail entry.
  final String reason;

  const RetrievalRoleDegraded({required this.code, required this.reason});

  @override
  String toString() => 'RetrievalRoleDegraded($code: $reason)';
}

/// The typed output of one retrieval role. Sealed — one subclass per
/// role id in [substrate § 6.2a].
sealed class RetrievalRoleOutput {
  const RetrievalRoleOutput();
}

/// `recall_planner` → the clarifying questions to seed HyDE vector recall.
final class RecallPlannerOutput extends RetrievalRoleOutput {
  /// The clarifying questions, in model-emitted order.
  final List<String> questions;

  const RecallPlannerOutput(this.questions);
}

/// `hypothesis_writer` → the plausible sample answers (HyDE).
final class HypothesisWriterOutput extends RetrievalRoleOutput {
  /// The hypothetical answers whose embeddings seed vector recall.
  final List<String> answers;

  const HypothesisWriterOutput(this.answers);
}

/// `query_term_writer` → a focused FTS query plus synonym expansions.
final class QueryTermWriterOutput extends RetrievalRoleOutput {
  /// The focused full-text / boolean query.
  final String query;

  /// Synonym expansions that broaden lexical recall.
  final List<String> synonyms;

  const QueryTermWriterOutput({required this.query, required this.synonyms});
}

/// `category_selector` → the picked node-types / edge-types / Concept names.
final class CategorySelectorOutput extends RetrievalRoleOutput {
  /// Selected node-types.
  final List<String> nodeTypes;

  /// Selected edge-types.
  final List<String> edgeTypes;

  /// Selected Concept names.
  final List<String> conceptNames;

  const CategorySelectorOutput({
    required this.nodeTypes,
    required this.edgeTypes,
    required this.conceptNames,
  });
}

/// One scored entry in a [RetrievalRerankerOutput].
final class RankedCandidate {
  /// The candidate node id.
  final String id;

  /// The relevance score; higher means more relevant.
  final double score;

  const RankedCandidate({required this.id, required this.score});
}

/// `retrieval_reranker` → a scored ordering of the fused candidate set.
final class RetrievalRerankerOutput extends RetrievalRoleOutput {
  /// The scored ordering, in model-emitted order.
  final List<RankedCandidate> ranking;

  const RetrievalRerankerOutput(this.ranking);
}

/// `profile_selector` → a memory-profile name plus a confidence.
final class ProfileSelectorOutput extends RetrievalRoleOutput {
  /// The selected memory-profile name.
  final String profile;

  /// Confidence in `[0, 1]`.
  final double confidence;

  const ProfileSelectorOutput({required this.profile, required this.confidence});
}

/// Parses [json] as the output of the retrieval role [roleId].
///
/// Returns a [RetrievalRoleParsed] with the typed [RetrievalRoleOutput]
/// when the payload matches the role's schema, or a
/// [RetrievalRoleDegraded] carrying [retrievalRoleOutputMalformed] when it
/// does not (including an unknown [roleId]). **Never throws** — the §
/// 6.2a contract is that a bad model output degrades gracefully.
RetrievalRoleParse parseRetrievalRoleOutput(
  String roleId,
  Map<String, Object?> json,
) {
  switch (roleId) {
    case 'recall_planner':
      return _wrapList(
        json,
        'questions',
        (items) => RecallPlannerOutput(items),
      );
    case 'hypothesis_writer':
      return _wrapList(
        json,
        'answers',
        (items) => HypothesisWriterOutput(items),
      );
    case 'query_term_writer':
      return _parseQueryTermWriter(json);
    case 'category_selector':
      return _parseCategorySelector(json);
    case 'retrieval_reranker':
      return _parseRetrievalReranker(json);
    case 'profile_selector':
      return _parseProfileSelector(json);
    default:
      return RetrievalRoleDegraded(
        code: retrievalRoleOutputMalformed,
        reason: 'unknown retrieval role "$roleId"',
      );
  }
}

// ----- per-role parsers -----

RetrievalRoleParse _wrapList(
  Map<String, Object?> json,
  String key,
  RetrievalRoleOutput Function(List<String>) build,
) {
  final items = _readStringList(json, key);
  if (items == null) {
    return _malformed('$key must be a non-null array of strings');
  }
  return RetrievalRoleParsed(build(items));
}

RetrievalRoleParse _parseQueryTermWriter(Map<String, Object?> json) {
  final query = json['query'];
  if (query is! String || query.trim().isEmpty) {
    return _malformed('query must be a non-empty string');
  }
  final synonyms = _readStringList(json, 'synonyms');
  if (synonyms == null) {
    return _malformed('synonyms must be a non-null array of strings');
  }
  return RetrievalRoleParsed(
    QueryTermWriterOutput(query: query, synonyms: synonyms),
  );
}

RetrievalRoleParse _parseCategorySelector(Map<String, Object?> json) {
  final nodeTypes = _readStringList(json, 'node_types');
  final edgeTypes = _readStringList(json, 'edge_types');
  final conceptNames = _readStringList(json, 'concept_names');
  if (nodeTypes == null || edgeTypes == null || conceptNames == null) {
    return _malformed('node_types, edge_types, and concept_names must each '
        'be a non-null array of strings');
  }
  return RetrievalRoleParsed(CategorySelectorOutput(
    nodeTypes: nodeTypes,
    edgeTypes: edgeTypes,
    conceptNames: conceptNames,
  ));
}

RetrievalRoleParse _parseRetrievalReranker(Map<String, Object?> json) {
  final raw = json['ranking'];
  if (raw is! List) {
    return _malformed('ranking must be an array');
  }
  final ranking = <RankedCandidate>[];
  for (final entry in raw) {
    if (entry is! Map) {
      return _malformed('each ranking entry must be an object');
    }
    final id = entry['id'];
    final score = entry['score'];
    if (id is! String || id.isEmpty) {
      return _malformed('each ranking entry needs a non-empty string id');
    }
    if (score is! num) {
      return _malformed('each ranking entry needs a numeric score');
    }
    ranking.add(RankedCandidate(id: id, score: score.toDouble()));
  }
  return RetrievalRoleParsed(RetrievalRerankerOutput(ranking));
}

RetrievalRoleParse _parseProfileSelector(Map<String, Object?> json) {
  final profile = json['profile'];
  if (profile is! String || profile.trim().isEmpty) {
    return _malformed('profile must be a non-empty string');
  }
  final confidence = json['confidence'];
  if (confidence is! num) {
    return _malformed('confidence must be a number');
  }
  final c = confidence.toDouble();
  if (c.isNaN || c < 0 || c > 1) {
    return _malformed('confidence must be a number in [0, 1]');
  }
  return RetrievalRoleParsed(
    ProfileSelectorOutput(profile: profile, confidence: c),
  );
}

// ----- helpers -----

/// Reads [key] from [json] as a `List<String>`, or `null` when the key is
/// absent, not a list, or contains a non-string / null element. An empty
/// list is a valid (if degenerate) result and is returned as `<String>[]`.
List<String>? _readStringList(Map<String, Object?> json, String key) {
  final raw = json[key];
  if (raw is! List) return null;
  final out = <String>[];
  for (final item in raw) {
    if (item is! String) return null;
    out.add(item);
  }
  return out;
}

RetrievalRoleDegraded _malformed(String reason) =>
    RetrievalRoleDegraded(code: retrievalRoleOutputMalformed, reason: reason);
