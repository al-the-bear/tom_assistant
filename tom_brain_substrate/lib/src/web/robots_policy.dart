// Q-B.30.3 — robots.txt enforcement for `WebFetch`.
//
// substrate_specification.md § 8.2: "Robots.txt is honoured per host
// with a configurable opt-out per route (procedures that need to fetch
// their own site can override)." This file is the policy layer that
// honours it; `DefaultWebFetch` consults a `RobotsGate` before every
// fetch unless the caller passed `WebFetchOptions.obeyRobots == false`
// (the per-route override).
//
// Why this lives on the `WebFetch` side (not the `WebHttpClient` seam):
// robots is a *fetch policy*, not a wire concern — `WebSearch` hits
// search-engine endpoints designed for external clients and must not be
// robots-gated (see `duckduckgo_search_provider.dart`). Keeping the gate
// here means search and fetch share the same HTTP seam without sharing
// the policy.
//
// Standard followed: RFC 9309 (Robots Exclusion Protocol).
//
//   - Group selection (§ 2.2.1): the crawler's product token is matched
//     case-insensitively against `User-agent` lines; the most specific
//     matching group wins, falling back to the `*` group.
//   - Rule precedence (§ 2.2.2): among matching `Allow` / `Disallow`
//     rules the one with the most octets (longest pattern) wins; an
//     `Allow` beats a `Disallow` of equal length. No matching rule ⇒
//     allowed.
//   - Pattern syntax (§ 2.2.3): `*` matches any run of characters and a
//     trailing `$` anchors to end-of-path. Patterns are start-anchored.
//   - Fetch outcome (§ 2.3.1): 2xx ⇒ parse and apply; 4xx ("Unavailable")
//     ⇒ allow everything; 5xx / transport-unreachable ("Unreachable") ⇒
//     fail closed (disallow everything). The fail-closed branch is why
//     the per-route opt-out exists — a flaky robots endpoint on a host
//     the procedure owns can be bypassed deliberately.
//
// Caching: results are cached per host (`scheme://host:port`) for the
// lifetime of the `RobotsGate` instance. robots.txt rarely changes
// within a single brain session; a TTL / revalidation policy is out of
// scope for the prototype (one fetch per host per process).

import 'web_fetch.dart' show RobotsDenialReason;
import 'web_http_client.dart';

/// Per-host robots.txt decider for `WebFetch`.
///
/// Construct one per [DefaultWebFetch]; it shares the fetch engine's
/// [WebHttpClient] seam (so retry / circuit-breaker policy at B.31
/// applies to robots fetches too) and the substrate's forced
/// `User-Agent`. [evaluate] answers whether the configured agent may
/// fetch a given URL, fetching and caching `/robots.txt` per host on
/// first ask.
class RobotsGate {
  final WebHttpClient _http;

  /// The substrate's product token (the part of the `User-Agent` before
  /// the first `/` or space), lower-cased. Matched against robots.txt
  /// `User-agent` lines.
  final String agentToken;

  /// The full `User-Agent` string forced on the robots.txt fetch — some
  /// hosts vary robots.txt by UA.
  final String userAgent;

  /// Timeout applied to the robots.txt fetch. `null` ⇒ no cap.
  final Duration? requestTimeout;

  final Map<String, _HostRobots> _cache = <String, _HostRobots>{};

  RobotsGate({
    required WebHttpClient httpClient,
    required this.userAgent,
    this.requestTimeout,
  })  : _http = httpClient,
        agentToken = robotsProductToken(userAgent);

  /// Evaluates whether the configured agent may fetch [url].
  ///
  /// Fetches `/robots.txt` for [url]'s host on first ask and caches the
  /// result per host. Returns `null` when the fetch is permitted (path
  /// allowed, or the host has no robots.txt / returned a 4xx). Returns
  /// [RobotsDenialReason.robotsDisallow] when a `Disallow` rule matches,
  /// and [RobotsDenialReason.robotsUnreachable] when robots.txt was
  /// unreachable (5xx / transport failure — fail closed per RFC 9309
  /// § 2.3.1.4).
  Future<RobotsDenialReason?> evaluate(Uri url) async {
    final key = _hostKey(url);
    final host = _cache[key] ??= await _loadHost(url);
    if (host.unreachable) return RobotsDenialReason.robotsUnreachable;
    return host.rules!.isAllowed(robotsMatchPath(url))
        ? null
        : RobotsDenialReason.robotsDisallow;
  }

  Future<_HostRobots> _loadHost(Uri url) async {
    final robotsUrl = url.replace(
      path: '/robots.txt',
      query: '',
      fragment: '',
    );
    final WebHttpResponse response;
    try {
      response = await _http.get(
        robotsUrl,
        headers: <String, String>{'User-Agent': userAgent},
        requestTimeout: requestTimeout,
      );
    } on Exception {
      // Unreachable ⇒ assume complete disallow (RFC 9309 § 2.3.1.4).
      return const _HostRobots.unreachable();
    }

    final code = response.statusCode;
    if (code >= 200 && code < 300) {
      return _HostRobots(parseRobotsTxt(response.body, agentToken));
    }
    if (code >= 400 && code < 500) {
      // "Unavailable" ⇒ no restrictions (RFC 9309 § 2.3.1.3).
      return _HostRobots(RobotsRules.allowAll());
    }
    // 5xx (and any other non-success) ⇒ fail closed.
    return const _HostRobots.unreachable();
  }

  static String _hostKey(Uri url) => '${url.scheme}://${url.host}:${url.port}';
}

/// Cached per-host robots.txt outcome: either the parsed [rules] or the
/// [unreachable] fail-closed marker.
class _HostRobots {
  final RobotsRules? rules;
  final bool unreachable;

  _HostRobots(RobotsRules this.rules) : unreachable = false;
  const _HostRobots.unreachable()
      : rules = null,
        unreachable = true;
}

/// Parsed robots.txt rules for one resolved agent group.
///
/// Produced by [parseRobotsTxt] (the group matching [robotsProductToken]
/// of the caller's `User-Agent`, falling back to the `*` group) or by
/// the [RobotsRules.allowAll] / [RobotsRules.denyAll] shortcuts.
class RobotsRules {
  final List<_RobotsRule> _rules;

  const RobotsRules._(this._rules);

  /// No restrictions — every path is allowed. Used when a host has no
  /// robots.txt (4xx) or when no rule group applies to the agent.
  factory RobotsRules.allowAll() => const RobotsRules._(<_RobotsRule>[]);

  /// Whether [path] (already in `path[?query]` form — see
  /// [robotsMatchPath]) is allowed under these rules.
  ///
  /// RFC 9309 § 2.2.2: the longest matching pattern wins; an `Allow`
  /// beats a `Disallow` of equal length; no match ⇒ allowed.
  bool isAllowed(String path) {
    _RobotsRule? best;
    for (final rule in _rules) {
      if (!rule.matches(path)) continue;
      if (best == null ||
          rule.specificity > best.specificity ||
          (rule.specificity == best.specificity && rule.allow && !best.allow)) {
        best = rule;
      }
    }
    return best?.allow ?? true;
  }
}

/// Parses robots.txt [content] and returns the rules for the group that
/// applies to [agentToken] (lower-case product token), falling back to
/// the `*` group, then to [RobotsRules.allowAll] when neither exists.
RobotsRules parseRobotsTxt(String content, String agentToken) {
  final groups = <_AgentGroup>[];
  _AgentGroup? current;
  // Whether `current` is still accumulating `User-agent` lines (true)
  // or has started taking rule lines (false). A `User-agent` line seen
  // after a rule line starts a new group.
  var collectingAgents = true;

  for (final rawLine in content.split('\n')) {
    final line = _stripComment(rawLine).trim();
    if (line.isEmpty) continue;

    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final field = line.substring(0, colon).trim().toLowerCase();
    final value = line.substring(colon + 1).trim();

    switch (field) {
      case 'user-agent':
        if (current == null || !collectingAgents) {
          current = _AgentGroup();
          groups.add(current);
          collectingAgents = true;
        }
        current.agents.add(value.toLowerCase());
      case 'allow':
      case 'disallow':
        if (current == null) continue; // rules before any group → ignore
        collectingAgents = false;
        if (value.isEmpty) continue; // empty pattern is a no-op (RFC)
        current.rules.add(_RobotsRule(allow: field == 'allow', pattern: value));
      default:
        // Unknown field (sitemap, crawl-delay, …): ignored, and does
        // not affect grouping.
        continue;
    }
  }

  _AgentGroup? best;
  var bestLen = -1;
  _AgentGroup? wildcard;
  for (final group in groups) {
    for (final agent in group.agents) {
      if (agent == '*') {
        wildcard ??= group;
      } else if (agent == agentToken && agent.length > bestLen) {
        best = group;
        bestLen = agent.length;
      }
    }
  }

  final selected = best ?? wildcard;
  if (selected == null) return RobotsRules.allowAll();
  return RobotsRules._(List<_RobotsRule>.unmodifiable(selected.rules));
}

/// The robots.txt product token for [userAgent]: the run of characters
/// before the first `/` or whitespace, lower-cased. `'TomBrain/0.1 (…)'`
/// → `'tombrain'`.
String robotsProductToken(String userAgent) {
  final trimmed = userAgent.trim();
  final match = RegExp(r'^[^/\s]+').firstMatch(trimmed);
  return (match?.group(0) ?? trimmed).toLowerCase();
}

/// The string a robots.txt pattern is matched against for [url]:
/// the path (`/` when empty) with `?query` appended when present.
String robotsMatchPath(Uri url) {
  final path = url.path.isEmpty ? '/' : url.path;
  return url.query.isEmpty ? path : '$path?${url.query}';
}

String _stripComment(String line) {
  final hash = line.indexOf('#');
  return hash == -1 ? line : line.substring(0, hash);
}

/// One `Allow` / `Disallow` rule, with its compiled matcher and its
/// specificity (the pattern's octet length, per RFC 9309 § 2.2.2).
class _RobotsRule {
  final bool allow;
  final int specificity;
  final RegExp _matcher;

  _RobotsRule({required this.allow, required String pattern})
      : specificity = pattern.length,
        _matcher = _compile(pattern);

  bool matches(String path) => _matcher.hasMatch(path);

  /// Compiles a robots pattern into a start-anchored [RegExp]: `*` →
  /// `.*`, a trailing `$` → end-anchor, everything else escaped.
  static RegExp _compile(String pattern) {
    final sb = StringBuffer('^');
    for (var i = 0; i < pattern.length; i++) {
      final ch = pattern[i];
      if (ch == '*') {
        sb.write('.*');
      } else if (ch == r'$' && i == pattern.length - 1) {
        sb.write(r'$');
      } else {
        sb.write(RegExp.escape(ch));
      }
    }
    return RegExp(sb.toString());
  }
}

/// Mutable accumulator used only during parsing: the agents that name a
/// group and the rules that follow them.
class _AgentGroup {
  final List<String> agents = <String>[];
  final List<_RobotsRule> rules = <_RobotsRule>[];
}
