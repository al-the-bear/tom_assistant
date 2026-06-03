// B.29 — `DefaultWebSearch`: registry-driven `WebSearch`
// implementation.
//
// Holds an immutable id → `WebSearchProvider` map plus a default
// provider id. `search(query, options)` looks up the provider (default
// or pinned), forwards the call, and returns the engine's structured
// result. No fan-out, no merge, no fallback at B.29 — that is a
// future router-aware variant's job (out of scope for the prototype).
//
// The class deliberately does not implement provider auth, key
// management, or per-route configuration: those concerns live on the
// concrete `WebSearchProvider` instances the caller registers. B.36
// (substrate config YAML loader) will construct the registry from the
// `webSearch.providers` map; B.40 (substrate facade) will hand the
// registered instance to the in-process facade.

import 'package:tom_core_agentic/tom_core_agentic.dart';

import '../api/web_results.dart';
import 'web_search.dart';
import 'web_search_provider.dart';

/// Default `WebSearch` implementation — dispatches one
/// `WebSearchProvider` per call.
///
/// Construction:
///
/// ```dart
/// final webSearch = DefaultWebSearch(
///   defaultProviderId: 'duckduckgo',
///   providers: <WebSearchProvider>[
///     DuckDuckGoHtmlSearchProvider(httpClient: webHttp),
///     // BraveSearchProvider(httpClient: webHttp, apiKey: braveKey),
///   ],
/// );
/// ```
///
/// **Provider registration invariants:**
///
///   - The provider list must be non-empty (a no-provider search would
///     always throw).
///   - All provider ids must be distinct (case-sensitive). Duplicate
///     ids surface as `ArgumentError` at construction.
///   - [defaultProviderId] must appear in the registered providers. A
///     mismatch surfaces as `ArgumentError` at construction.
///
/// **Lifecycle:**
///
///   - [close] forwards `close()` to every registered provider, in
///     registration order. Idempotent.
class DefaultWebSearch with CloseGuard implements WebSearch {
  final String defaultProviderId;
  final Map<String, WebSearchProvider> _providers;
  final List<String> _registrationOrder;

  DefaultWebSearch({
    required this.defaultProviderId,
    required List<WebSearchProvider> providers,
  })  : _providers = _buildRegistry(providers),
        _registrationOrder = providers.map((p) => p.id).toList(growable: false) {
    if (providers.isEmpty) {
      throw ArgumentError(
        'DefaultWebSearch requires at least one provider; none registered',
      );
    }
    if (!_providers.containsKey(defaultProviderId)) {
      throw ArgumentError(
        'DefaultWebSearch: defaultProviderId="$defaultProviderId" is not '
        'registered. Registered providers: [${_registrationOrder.join(', ')}]',
      );
    }
  }

  static Map<String, WebSearchProvider> _buildRegistry(
    List<WebSearchProvider> providers,
  ) {
    final out = <String, WebSearchProvider>{};
    for (final provider in providers) {
      if (out.containsKey(provider.id)) {
        throw ArgumentError(
          'DefaultWebSearch: duplicate provider id "${provider.id}"; '
          'every WebSearchProvider must declare a unique id',
        );
      }
      out[provider.id] = provider;
    }
    return out;
  }

  /// Ids of every registered provider, in registration order.
  ///
  /// Surfaced for diagnostics (the `UnknownWebSearchProvider`
  /// exception's `registeredProviders` list mirrors this).
  List<String> get registeredProviderIds =>
      List<String>.unmodifiable(_registrationOrder);

  @override
  Future<WebSearchResult> search(
    String query, {
    WebSearchOptions options = WebSearchOptions.empty,
  }) async {
    ensureOpen('DefaultWebSearch.search');
    final providerId = options.provider ?? defaultProviderId;
    final provider = _providers[providerId];
    if (provider == null) {
      throw UnknownWebSearchProvider(
        requestedProvider: providerId,
        registeredProviders: List<String>.unmodifiable(_registrationOrder),
      );
    }
    return provider.search(query, k: options.k);
  }

  @override
  void close() {
    if (!markClosed()) return;
    for (final id in _registrationOrder) {
      _providers[id]!.close();
    }
  }
}
