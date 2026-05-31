// B.30 — `HtmlReadableExtractor`: minimal readability-style HTML →
// prose stripper for `WebFetch`'s `text/html` branch.
//
// substrate_specification.md § 8.2: `text/html` responses extract via a
// "Readability-style strip → main text". The full Readability.js
// algorithm (score-then-cluster on <p>, <article>, <main>) is out of
// scope for the prototype — its dependency surface and tuning footprint
// would dominate `WebFetch`'s code mass for marginal quality gains on a
// substrate whose primary fetch consumers are sub-thinkers that re-pass
// the prose through an LLM anyway. The prototype ships a strip-style
// extractor instead:
//
//   1. Decode bytes as UTF-8 (with `allowMalformed: true`, so a stray
//      non-UTF-8 byte does not throw).
//   2. Strip `<script>`, `<style>`, `<noscript>` blocks including their
//      contents (case-insensitive). These carry no prose.
//   3. Replace block-level closing tags (`</p>`, `</div>`, `</li>`,
//      `</h1..6>`, `</tr>`, `</br>`, `<br>`, `<br/>`) with `\n` so the
//      collapsed output preserves paragraph structure.
//   4. Strip all remaining tags (`<[^>]*>`).
//   5. Decode the standard named + numeric HTML entities. We reuse the
//      decoder shape from `DuckDuckGoHtmlSearchProvider` (B.29) so the
//      web/ module has one entity table to maintain.
//   6. Collapse runs of whitespace: every run of `\s` → single space,
//      then collapse 3+ newlines down to 2.
//   7. Trim leading / trailing whitespace.
//
// The result is plain text with paragraph breaks where the HTML had
// block boundaries. It loses tables, images, links — which is the
// point: the substrate hands the prose to the LLM, and the LLM
// re-formats. If a procedure later needs structured extraction (e.g.
// table → CSV), it asks for the raw HTML / JSON / binary bytes via a
// separate API (not in scope for the prototype).
//
// Q-B.30.1 logs the question of whether to upgrade to `package:html` +
// a real Readability-style scorer when (a) a fetch consumer empirically
// needs the structure or (b) `WebSearch`'s HTML parser (Q-B.29.1)
// reaches the same decision. Until then, the strip extractor is the
// shared parser for both tools, and it lives here.

import 'dart:convert';

/// Strips HTML in [bytes] down to readable prose.
///
/// [bytes] are decoded as UTF-8 with `allowMalformed: true`. The
/// caller is responsible for picking the right encoding when a
/// `Content-Type` charset other than UTF-8 is in play (the prototype
/// always assumes UTF-8 — see substrate_specification.md § 8.2 and
/// `WebHttpClient`'s contract in `web_http_client.dart`).
///
/// Returns the trimmed, whitespace-collapsed prose. May be empty when
/// the HTML had no extractable text.
String extractReadableHtml(List<int> bytes) {
  final raw = utf8.decode(bytes, allowMalformed: true);
  return extractReadableHtmlString(raw);
}

/// String form of [extractReadableHtml] — exposed so callers that
/// already hold a decoded string (e.g. tests, or future fetch impls
/// that consume `WebHttpResponse.body`) can reuse the same algorithm
/// without re-encoding.
String extractReadableHtmlString(String html) {
  // 1. Strip <script>, <style>, <noscript> blocks (including contents).
  //    The regex uses `[\s\S]*?` so it tolerates embedded newlines and
  //    is non-greedy to avoid swallowing across multiple blocks. The
  //    `caseSensitive: false` flag covers <SCRIPT>, <Script>, etc.
  var stripped = html
      .replaceAll(_scriptBlock, '')
      .replaceAll(_styleBlock, '')
      .replaceAll(_noscriptBlock, '');

  // 2. Replace block-level boundaries with newlines so paragraph
  //    structure survives the tag strip. Order matters: handle <br>
  //    variants before the generic tag strip catches them.
  stripped = stripped
      .replaceAllMapped(_brTag, (_) => '\n')
      .replaceAllMapped(_blockClose, (_) => '\n');

  // 3. Strip all remaining tags. The regex matches a `<` followed by
  //    anything-up-to-the-next-`>` — including malformed tags. HTML
  //    comments (<!-- ... -->) are caught by the same pattern.
  stripped = stripped.replaceAll(_anyTag, '');

  // 4. Decode entities.
  stripped = _decodeEntities(stripped);

  // 5. Collapse whitespace: tabs / non-breaking spaces / multiple
  //    spaces → single space. Then collapse 3+ newlines → 2 (paragraph
  //    break). Then trim.
  stripped = stripped
      .replaceAll(_horizWhitespace, ' ')
      .replaceAll(_multiNewline, '\n\n');

  // Collapse repeated spaces (post entity-decode, after \s mapped to
  // a single space).
  stripped = stripped.replaceAll(_multiSpace, ' ');

  // Trim spaces around newlines so paragraph boundaries are clean.
  stripped = stripped.replaceAll(_spaceAroundNewline, '\n');

  return stripped.trim();
}

// ---------- regexes -------------------------------------------------------

final RegExp _scriptBlock =
    RegExp(r'<script\b[^>]*>[\s\S]*?</script\s*>', caseSensitive: false);
final RegExp _styleBlock =
    RegExp(r'<style\b[^>]*>[\s\S]*?</style\s*>', caseSensitive: false);
final RegExp _noscriptBlock =
    RegExp(r'<noscript\b[^>]*>[\s\S]*?</noscript\s*>', caseSensitive: false);

final RegExp _brTag = RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false);

// Block-level closing tags: </p>, </div>, </li>, </h1>...</h6>, </tr>,
// </article>, </section>, </ul>, </ol>, </blockquote>, </pre>.
final RegExp _blockClose = RegExp(
  r'<\s*/\s*(p|div|li|h[1-6]|tr|article|section|ul|ol|blockquote|pre|table|td|th)\s*>',
  caseSensitive: false,
);

final RegExp _anyTag = RegExp(r'<[^>]*>');

// Whitespace classifiers. We keep `\n` intentionally so paragraph
// boundaries survive the first pass.
final RegExp _horizWhitespace = RegExp(r'[ \t\u00a0\u2028\u2029\r\f]+');
final RegExp _multiNewline = RegExp(r'\n{3,}');
final RegExp _multiSpace = RegExp(r' {2,}');
final RegExp _spaceAroundNewline = RegExp(r' *\n *');

// ---------- entity decode -------------------------------------------------

/// Decodes the named + numeric HTML entities that appear in
/// substrate-relevant prose. Mirrors the small entity table in
/// `DuckDuckGoHtmlSearchProvider` (B.29) so the web/ module has one
/// decoder. The named set covers the SGML core entities plus
/// `&nbsp;` and `&apos;`. Numeric entities (`&#NN;`, `&#xHH;`) are
/// decoded for the full Unicode range.
String _decodeEntities(String input) {
  // Named entities first.
  var out = input;
  _namedEntities.forEach((name, replacement) {
    out = out.replaceAll(name, replacement);
  });
  // Then numeric entities (decimal and hex).
  out = out.replaceAllMapped(_numericEntity, (match) {
    final spec = match.group(1)!;
    int? codePoint;
    if (spec.startsWith('x') || spec.startsWith('X')) {
      codePoint = int.tryParse(spec.substring(1), radix: 16);
    } else {
      codePoint = int.tryParse(spec);
    }
    if (codePoint == null || codePoint < 0 || codePoint > 0x10FFFF) {
      // Unparseable — leave the entity verbatim so the audit trail
      // still shows what came in. Stripping it would hide bugs.
      return match.group(0)!;
    }
    return String.fromCharCode(codePoint);
  });
  return out;
}

/// Named-entity table. Intentionally small; the WHATWG list has ~250
/// names but the substrate's fetch consumers see almost exclusively
/// the SGML core entities plus `&nbsp;` and `&apos;`.
const Map<String, String> _namedEntities = <String, String>{
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&apos;': "'",
  '&nbsp;': ' ',
  '&#39;': "'",
  '&#x27;': "'",
};

final RegExp _numericEntity = RegExp(r'&#([xX]?[0-9a-fA-F]+);');
