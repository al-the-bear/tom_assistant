// B.9 — `SubstrateConfig` placeholder.
//
// substrate_specification.md § 9 defines the YAML shape (providers,
// role routes, embedding, web tools, MCP client endpoints, price
// table). The full loader + every config sub-type land at B.36
// ("Implement `SubstrateConfig` YAML loader with the provider
// routing policy + role registry + embedding choice").
//
// B.9 only needs the *type* — `TomBrainSubstrateClient.open` takes
// a `SubstrateConfig` argument and the consumer-facing interface
// has to compile without the loader being in place. So this file
// declares an opaque placeholder: an abstract class with no
// members, whose only purpose is to be the type of the `open`
// parameter.
//
// When B.36 lands the concrete `SubstrateConfig` (with `providers`,
// `roleRoutes`, `embedding`, `webSearch`, `webFetch`, `mcpClient`,
// `priceTable`), it replaces this stub *by becoming* the class
// declared here — the api/ surface keeps using the same type name
// and no consumer needs to re-import.
//
// Q-B.9.5 logs the open question: should `SubstrateConfig` live in
// api/ (consumer-visible) or in a sibling config/ folder (loader-
// visible, with a re-export from the package barrel like
// `MemoryConfig`)? Memory chose the second pattern (config/ folder
// with a top-level re-export). At B.9 the type is in api/ for
// minimum coupling; the move to config/ at B.36 is a one-import-
// rewrite if we decide to mirror the memory pattern.

/// Configuration consumed by `TomBrainSubstrateClient.open`.
///
/// **B.9 status:** opaque placeholder. The full structured config —
/// providers, role routes, embedding choice, web-tool settings, MCP
/// endpoints, price table — is declared in
/// `substrate_specification.md` § 9 and lands as the concrete shape
/// at plan step B.36. The api/ surface needs the type now so
/// `TomBrainSubstrateClient.open(SubstrateConfig)` can compile; at
/// B.36 the concrete fields land and this class becomes the
/// configuration root rather than a placeholder.
///
/// Consumers must **not** instantiate this class at B.9 — there are
/// no producers yet. The only legitimate caller of `open` at B.9 is
/// a test fixture that mocks `TomBrainSubstrateClient` end-to-end;
/// such tests build their own subclass of [SubstrateConfig] to pass
/// through, since the class is abstract by design (cannot be
/// `const`-constructed) but not sealed (test fakes can extend it).
abstract class SubstrateConfig {
  /// Subclass hook. Kept `const` so test fakes can stay `const`.
  const SubstrateConfig();
}
