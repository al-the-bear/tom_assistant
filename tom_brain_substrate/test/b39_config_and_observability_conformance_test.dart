// B.39 — Configuration + observability slice conformance suite.
//
// Plan step B.39 (verbatim):
//   "Tests: config roundtrip; event ordering; logger categorisation."
//
// B.36 / B.37 / B.38 each landed their own focused unit suite for the
// piece they introduced (`b36_substrate_config_loader_test.dart`,
// `b37_substrate_log_test.dart`, `b38_substrate_event_bus_test.dart`).
// Those suites prove that each piece satisfies its own contract in
// isolation.
//
// B.39 is the **section-closure** suite. It asserts the three
// properties named in the plan step at the *integration* level — i.e.
// not "the loader parses" but "the loader is idempotent through a
// disk roundtrip and structurally stable across two loads of the same
// content"; not "the bus fans out one event" but "the bus preserves
// emission order across a long interleaved sequence from multiple
// logical emitters"; not "category X tags a line" but "all six
// categories interleaved tag each line independently with no
// cross-contamination". This is the conformance test the way B.20
// (router), B.28 (embedding), B.32 (web), B.35 (MCP client) close
// out their own sub-sections — a single black-box file that proves
// the slice's contract on the public surface only.
//
// Pattern decisions (mirror prior conformance steps):
//
//   * **Public-API only.** Imports flow through
//     `package:tom_brain_substrate/tom_brain_substrate.dart`; no
//     reach into `lib/src/`.
//   * **No live network, no live LLM.** The config fixtures reference
//     stub providers / hand-written endpoints; no test boots a real
//     Ollama or HTTP server.
//   * **Deterministic emission ordering.** Emits are issued
//     synchronously from the same isolate, then a `Future.delayed
//     (Duration.zero)` drains the microtask queue before assertions —
//     matching the discipline locked at B.38.
//
// Spec-vs-plan alignment locked here:
//
//   * Config slice — `SubstrateConfigLoader.parse` is deterministic:
//     two loads of the same YAML produce sections that are pairwise
//     value-equivalent (same providers in same order, same
//     `roleRoutes` chains in same order, same embedding choice, same
//     mcpClient endpoint shapes, same priceTable entries). The disk
//     roundtrip leg adds: `loadFromFile` of a file containing the
//     same YAML yields a structurally identical config (no path
//     leakage, no env leakage when `envVars` is the same constant
//     map).
//   * Event slice — events emitted in submission order across
//     multiple logical emitters arrive at every live subscriber in
//     the same global order, with no reordering and no per-emitter
//     interleaving artefacts.
//   * Log slice — interleaved emissions across all six
//     `SubstrateLog.<area>` instances each tag their own line with
//     the canonical `[tom_brain.substrate.<area>]` prefix and never
//     bleed across categories.

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tom_basics/tom_basics.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart';

/// Captures every log line emitted via `tomLog` for the duration of a
/// test. Records the trimmed level string and the stringified message
/// so assertions can match against the canonical
/// `[tom_brain.substrate.<area>] …` prefix shape.
class _CapturingLogOutput extends TomLogOutput {
  final List<_LogLine> records = <_LogLine>[];

  @override
  void output(
    TomLogLevel loggerLevel,
    TomLogLevel logLevel,
    String level,
    Object message,
    String isolateName,
    DateTime timeStamp, [
    String? origin,
  ]) {
    // `convertToString` honours the `() => String` lazy contract that
    // `SubstrateLog._tag` preserves through the wrap; using it here
    // means a future regression that breaks the lazy contract surfaces
    // as a `Closure: …` literal in the captured message string.
    records.add(
      _LogLine(level: level.trim(), message: convertToString(message)),
    );
  }
}

class _LogLine {
  _LogLine({required this.level, required this.message});
  final String level;
  final String message;

  @override
  String toString() => '($level) $message';
}

void main() {
  // ─────────────────────────────────────────────────────────────────
  // Config roundtrip leg.
  // ─────────────────────────────────────────────────────────────────

  group('B.39 — config roundtrip', () {
    test(
      'parse is deterministic: two loads of the same YAML produce '
      'structurally equivalent configs',
      () {
        final a = SubstrateConfigLoader.parse(_fullYaml);
        final b = SubstrateConfigLoader.parse(_fullYaml);
        _expectConfigsEquivalent(a, b);
      },
    );

    test(
      'loadFromFile produces the same structural config as parse on '
      'the same YAML content',
      () async {
        final memCfg = SubstrateConfigLoader.parse(_fullYaml);

        final dir =
            await Directory.systemTemp.createTemp('substrate_b39_roundtrip_');
        final file = File('${dir.path}/substrate.yaml');
        await file.writeAsString(_fullYaml);
        try {
          final diskCfg = SubstrateConfigLoader.loadFromFile(file.path);
          _expectConfigsEquivalent(memCfg, diskCfg);
        } finally {
          await dir.delete(recursive: true);
        }
      },
    );

    test(
      'env substitution survives the roundtrip: identical envVars '
      'maps produce identical resolved values',
      () {
        const envVars = <String, String>{
          'OLLAMA_URL': 'http://gpu-host:11434',
          'OPENROUTER_TOKEN_PATH': '_ai/secrets/openrouter.token',
        };
        final a = SubstrateConfigLoader.parse(
          _envExpansionYaml,
          envVars: envVars,
        );
        final b = SubstrateConfigLoader.parse(
          _envExpansionYaml,
          envVars: envVars,
        );
        _expectConfigsEquivalent(a, b);
        // Spot-check the actual substituted values landed.
        expect(
          a.providers[0].baseUrl,
          equals(Uri.parse('http://gpu-host:11434')),
        );
        expect(
          a.providers[1].auth.apiKeySecretRef,
          equals('_ai/secrets/openrouter.token'),
        );
      },
    );

    test(
      'buildRouterPolicy on a roundtripped config preserves '
      'declaration order across loads',
      () {
        // The plan's "config roundtrip" property requires more than
        // structural equivalence — the derived `RouterPolicy` (which
        // is what every dispatch uses) must also be order-stable.
        // Pre-A.36 builds occasionally reordered routes when the
        // YAML loader walked the underlying YamlMap with a hash
        // iterator; this test is the gate against a re-introduction.
        final a = SubstrateConfigLoader.parse(_fullYaml).buildRouterPolicy();
        final b = SubstrateConfigLoader.parse(_fullYaml).buildRouterPolicy();
        expect(a.roleRoutes.keys.toList(), equals(b.roleRoutes.keys.toList()));
        for (final roleId in a.roleRoutes.keys) {
          final chainA = a.roleRoutes[roleId]!;
          final chainB = b.roleRoutes[roleId]!;
          expect(chainA, hasLength(chainB.length));
          for (var i = 0; i < chainA.length; i++) {
            expect(chainA[i].providerId, equals(chainB[i].providerId));
            expect(chainA[i].model, equals(chainB[i].model));
            expect(
              chainA[i].conditions.maxInputTokens,
              equals(chainB[i].conditions.maxInputTokens),
            );
          }
        }
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────
  // Event ordering leg.
  // ─────────────────────────────────────────────────────────────────

  group('B.39 — event ordering', () {
    test(
      'events from a single emitter arrive in submission order at '
      'every subscriber',
      () async {
        final bus = SubstrateEventBus();
        addTearDown(bus.close);

        final received1 = <SubstrateEvent>[];
        final received2 = <SubstrateEvent>[];
        final sub1 = bus.events().listen(received1.add);
        final sub2 = bus.events().listen(received2.add);
        addTearDown(sub1.cancel);
        addTearDown(sub2.cancel);

        final t0 = DateTime.now().toUtc();
        // Emit 25 events with monotonically increasing call ids so a
        // future regression that reorders within a single emitter
        // surfaces in the assertion diff.
        final expected = <String>[];
        for (var i = 0; i < 25; i++) {
          final id = 'call_${i.toString().padLeft(2, '0')}';
          expected.add(id);
          bus.emit(
            LlmCallStarted(
              occurredAt: t0.add(Duration(microseconds: i)),
              callId: id,
              roleId: 'analyser',
              providerId: 'stub',
              modelId: 'stub-1',
            ),
          );
        }
        await Future<void>.delayed(Duration.zero);

        expect(
          received1.map((e) => (e as LlmCallStarted).callId).toList(),
          equals(expected),
        );
        expect(
          received2.map((e) => (e as LlmCallStarted).callId).toList(),
          equals(expected),
        );
      },
    );

    test(
      'interleaved emissions from multiple logical emitters preserve '
      'global submission order',
      () async {
        // The substrate's composition root (B.40+) hands `bus.emit` to
        // every per-subsystem emitter (router, providers, embedding,
        // web, mcp). Each "emitter" is a `void Function(SubstrateEvent)`
        // closure over the same `bus.emit`. The contract under test:
        // a subscriber sees the interleaved emissions in the same order
        // the emitters issued them, with no per-emitter batching, no
        // grouping by category, and no reordering.
        final bus = SubstrateEventBus();
        addTearDown(bus.close);

        final received = <SubstrateEvent>[];
        final sub = bus.events().listen(received.add);
        addTearDown(sub.cancel);

        final t0 = DateTime.now().toUtc();
        void Function(SubstrateEvent) emitter = bus.emit;
        // Each tuple represents a logical sub-emitter and the event
        // it just produced. The "ticket" string is what we assert
        // arrived in the right order.
        final tickets = <String>[];

        void issueLlm(int i) {
          final t = 'llm#$i';
          tickets.add(t);
          emitter(
            LlmCallStarted(
              occurredAt: t0,
              callId: t,
              roleId: 'analyser',
              providerId: 'stub',
              modelId: 'stub-1',
            ),
          );
        }

        void issueEmbed(int i) {
          final t = 'embed#$i';
          tickets.add(t);
          emitter(
            EmbeddingComputed(
              occurredAt: t0,
              providerId: 'ollama',
              modelId: 'nomic-embed-text',
              dims: 768,
              batchSize: i,
            ),
          );
        }

        void issueFetch(int i) {
          final t = 'fetch#$i';
          tickets.add(t);
          emitter(
            WebFetchCompleted(
              occurredAt: t0,
              url: 'https://example.com/$i',
              status: 200,
              bytes: i,
              truncated: false,
            ),
          );
        }

        void issueFailover(int i) {
          final t = 'failover#$i';
          tickets.add(t);
          emitter(
            ProviderFailover(
              occurredAt: t0,
              fromProviderId: 'stub',
              toProviderId: 'ollama',
              reason: 'rate_limit#$i',
            ),
          );
        }

        // Interleave emissions across four logical emitters. The
        // pattern is intentionally non-round-robin to catch any
        // implicit grouping.
        for (var i = 0; i < 8; i++) {
          issueLlm(i);
          issueEmbed(i);
          issueFetch(i);
          if (i.isEven) issueFailover(i ~/ 2);
          issueLlm(i + 100); // second "llm" round mid-loop
        }

        await Future<void>.delayed(Duration.zero);

        // Recover the ticket back from each received event. The four
        // typed branches map cleanly onto the four issuers.
        final receivedTickets = <String>[
          for (final e in received)
            switch (e) {
              LlmCallStarted(:final callId) => callId,
              EmbeddingComputed(:final batchSize) => 'embed#$batchSize',
              WebFetchCompleted(:final bytes) => 'fetch#$bytes',
              ProviderFailover(:final reason) =>
                'failover#${reason.split('#').last}',
              _ => 'unexpected:${e.kind}',
            },
        ];
        expect(receivedTickets, equals(tickets));
      },
    );

    test(
      'event ordering is independent of subscriber attach order',
      () async {
        // A subscriber that attaches after the first event still sees
        // every *subsequent* event in the same order as a subscriber
        // that was already attached. The broadcast contract from B.38
        // is "late subscribers do not see prior events"; B.39 locks
        // that subsequent events nonetheless arrive in the same
        // order on both subscribers.
        final bus = SubstrateEventBus();
        addTearDown(bus.close);

        final earlyReceived = <SubstrateEvent>[];
        final early = bus.events().listen(earlyReceived.add);
        addTearDown(early.cancel);

        final t0 = DateTime.now().toUtc();
        bus.emit(
          LlmCallStarted(
            occurredAt: t0,
            callId: 'pre_subscribe',
            roleId: 'analyser',
            providerId: 'stub',
            modelId: 'stub-1',
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final lateReceived = <SubstrateEvent>[];
        final late_ = bus.events().listen(lateReceived.add);
        addTearDown(late_.cancel);

        final laterTickets = <String>[];
        for (var i = 0; i < 5; i++) {
          final id = 'post_${i.toString().padLeft(2, '0')}';
          laterTickets.add(id);
          bus.emit(
            LlmCallStarted(
              occurredAt: t0,
              callId: id,
              roleId: 'analyser',
              providerId: 'stub',
              modelId: 'stub-1',
            ),
          );
        }
        await Future<void>.delayed(Duration.zero);

        // Early subscriber: saw pre-subscribe + all five.
        expect(
          earlyReceived.map((e) => (e as LlmCallStarted).callId).toList(),
          equals(<String>['pre_subscribe', ...laterTickets]),
        );
        // Late subscriber: only the five post-subscribe events,
        // in the same order.
        expect(
          lateReceived.map((e) => (e as LlmCallStarted).callId).toList(),
          equals(laterTickets),
        );
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────
  // Logger categorisation leg.
  // ─────────────────────────────────────────────────────────────────

  group('B.39 — logger categorisation', () {
    late _CapturingLogOutput capturing;
    late TomLogOutput previousOutput;
    late TomLogLevel previousLevel;

    setUp(() {
      capturing = _CapturingLogOutput();
      previousOutput = tomLog.logOutput;
      previousLevel = tomLog.logLevel;
      tomLog.logOutput = capturing;
      tomLog.setLogLevel(TomLogLevel.development);
    });

    tearDown(() {
      tomLog.logOutput = previousOutput;
      tomLog.setLogLevel(previousLevel);
    });

    test(
      'interleaved emissions across all six categories each tag '
      'their own line with the canonical prefix',
      () {
        // Round-robin emit one line per category, twice, at different
        // levels. Each line must land with the matching
        // `[tom_brain.substrate.<area>]` prefix and the matching
        // level — no cross-contamination.
        for (final iteration in <int>[1, 2]) {
          for (final logger in SubstrateLog.all) {
            logger.info('iter-$iteration message on ${logger.category.name}');
          }
        }

        expect(
          capturing.records,
          hasLength(2 * SubstrateLog.all.length),
          reason: 'every emission must land exactly one captured line',
        );
        for (var iteration = 1; iteration <= 2; iteration++) {
          for (var i = 0; i < SubstrateLog.all.length; i++) {
            final globalIdx = (iteration - 1) * SubstrateLog.all.length + i;
            final logger = SubstrateLog.all[i];
            final line = capturing.records[globalIdx];
            expect(line.level, equals('INFO'));
            expect(
              line.message,
              equals(
                '[${logger.category.name}] iter-$iteration message on '
                '${logger.category.name}',
              ),
              reason: 'iteration $iteration, category ${logger.category.name} '
                  'mis-tagged at global index $globalIdx',
            );
          }
        }
      },
    );

    test(
      'every level honours category routing (no level drops the prefix)',
      () {
        // The bug we are guarding against: a future refactor that adds
        // a new level method and forgets to thread the prefix through
        // it. The fix is to emit every level for every category and
        // assert every captured line starts with the right prefix.
        final levelMethods = <String, void Function(SubstrateLog, Object)>{
          'TRACE': (l, m) => l.trace(m),
          'DEBUG': (l, m) => l.debug(m),
          'TRAFFIC': (l, m) => l.traffic(m),
          'INFO': (l, m) => l.info(m),
          'WARN': (l, m) => l.warn(m),
          'STATUS': (l, m) => l.status(m),
          'ERROR': (l, m) => l.error(m),
          'SEVERE': (l, m) => l.severe(m),
          'FATAL': (l, m) => l.fatal(m),
        };

        for (final logger in SubstrateLog.all) {
          for (final entry in levelMethods.entries) {
            entry.value(logger, 'lvl=${entry.key}');
          }
        }

        expect(
          capturing.records,
          hasLength(SubstrateLog.all.length * levelMethods.length),
        );

        // Walk in emit order — same nested order used above.
        var idx = 0;
        for (final logger in SubstrateLog.all) {
          for (final levelName in levelMethods.keys) {
            final line = capturing.records[idx];
            expect(line.level, equals(levelName));
            expect(
              line.message,
              equals('[${logger.category.name}] lvl=$levelName'),
              reason: '${logger.category.name} @ $levelName missing prefix',
            );
            idx++;
          }
        }
      },
    );

    test(
      'one logger never bleeds another logger\'s prefix into a line',
      () {
        // Interleave two categories at the same level. The captured
        // lines must alternate cleanly with no cross-contamination
        // (a regression that, e.g., stored the prefix on a shared
        // mutable buffer would show up as repeated prefixes).
        for (var i = 0; i < 10; i++) {
          if (i.isEven) {
            SubstrateLog.llm.info('llm-$i');
          } else {
            SubstrateLog.embed.info('embed-$i');
          }
        }
        expect(capturing.records, hasLength(10));
        for (var i = 0; i < 10; i++) {
          if (i.isEven) {
            expect(
              capturing.records[i].message,
              equals('[tom_brain.substrate.llm] llm-$i'),
            );
          } else {
            expect(
              capturing.records[i].message,
              equals('[tom_brain.substrate.embed] embed-$i'),
            );
          }
        }
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────
  // Cross-leg integration: event + log paired at one lifecycle moment.
  // ─────────────────────────────────────────────────────────────────

  group('B.39 — event + log pairing', () {
    test(
      'a paired emit (event on bus, line via SubstrateLog) preserves '
      'order across both channels',
      () async {
        // Q-B.37.3 / Q-B.38.3 deferred per-subsystem emit-site
        // migration to B.39 / B.40 with the note that the event +
        // log + counter for the same lifecycle moment should land
        // together. This test exercises the joint property: when a
        // caller pairs an event emit with a log line on the matching
        // category, both channels preserve the same emission order.
        final capturing = _CapturingLogOutput();
        final previousOutput = tomLog.logOutput;
        final previousLevel = tomLog.logLevel;
        tomLog.logOutput = capturing;
        tomLog.setLogLevel(TomLogLevel.development);
        addTearDown(() {
          tomLog.logOutput = previousOutput;
          tomLog.setLogLevel(previousLevel);
        });

        final bus = SubstrateEventBus();
        addTearDown(bus.close);

        final eventOrder = <String>[];
        final sub = bus.events().listen((e) {
          eventOrder.add(e.kind);
        });
        addTearDown(sub.cancel);

        final t0 = DateTime.now().toUtc();
        final expectedKinds = <String>[];

        for (var i = 0; i < 4; i++) {
          // Pair 1: LLM call started, log on `…llm`.
          SubstrateLog.llm.info('call_$i started');
          bus.emit(
            LlmCallStarted(
              occurredAt: t0,
              callId: 'call_$i',
              roleId: 'analyser',
              providerId: 'stub',
              modelId: 'stub-1',
            ),
          );
          expectedKinds.add('substrate.llm-call-started');

          // Pair 2: web fetch completed, log on `…web`.
          SubstrateLog.web.info('fetch_$i completed');
          bus.emit(
            WebFetchCompleted(
              occurredAt: t0,
              url: 'https://example.com/$i',
              status: 200,
              bytes: 1024 * i,
              truncated: false,
            ),
          );
          expectedKinds.add('substrate.web-fetch-completed');
        }
        await Future<void>.delayed(Duration.zero);

        // Event channel preserved the emission order.
        expect(eventOrder, equals(expectedKinds));

        // Log channel: every line in capture order carries the
        // expected category prefix, alternating llm / web.
        expect(capturing.records, hasLength(8));
        for (var i = 0; i < 8; i++) {
          if (i.isEven) {
            // i = 0,2,4,6 → llm pair
            final callId = 'call_${i ~/ 2}';
            expect(
              capturing.records[i].message,
              equals('[tom_brain.substrate.llm] $callId started'),
            );
          } else {
            // i = 1,3,5,7 → web pair
            final fetchId = 'fetch_${i ~/ 2}';
            expect(
              capturing.records[i].message,
              equals('[tom_brain.substrate.web] $fetchId completed'),
            );
          }
        }
      },
    );
  });
}

// ─── Helpers ─────────────────────────────────────────────────────

/// Asserts that two [SubstrateConfig] values are structurally
/// equivalent: same providers in same order with same fields, same
/// route chains in same order, same embedding choice, same web /
/// mcp / price-table shapes. Used to lock the loader's "roundtrip"
/// property — two parses of the same input must produce the same
/// observable model.
///
/// Deliberately field-by-field rather than via `==` because
/// [SubstrateConfig] and its members are value classes without
/// `==` / `hashCode` overrides (adding those is a separate decision;
/// not load-bearing for B.39).
void _expectConfigsEquivalent(SubstrateConfig a, SubstrateConfig b) {
  // Providers.
  expect(a.providers, hasLength(b.providers.length));
  for (var i = 0; i < a.providers.length; i++) {
    final pa = a.providers[i];
    final pb = b.providers[i];
    expect(pa.id, equals(pb.id));
    expect(pa.kind, equals(pb.kind));
    expect(pa.baseUrl, equals(pb.baseUrl));
    expect(pa.models, equals(pb.models));
    expect(pa.auth.isNone, equals(pb.auth.isNone));
    expect(pa.auth.isApiKey, equals(pb.auth.isApiKey));
    expect(pa.auth.apiKeyInlineToken, equals(pb.auth.apiKeyInlineToken));
    expect(pa.auth.apiKeySecretRef, equals(pb.auth.apiKeySecretRef));
  }

  // Role routes (declaration order matters — it IS the tier policy).
  expect(a.roleRoutes.keys.toList(), equals(b.roleRoutes.keys.toList()));
  for (final roleId in a.roleRoutes.keys) {
    final chainA = a.roleRoutes[roleId]!;
    final chainB = b.roleRoutes[roleId]!;
    expect(chainA, hasLength(chainB.length));
    for (var i = 0; i < chainA.length; i++) {
      expect(chainA[i].providerId, equals(chainB[i].providerId));
      expect(chainA[i].model, equals(chainB[i].model));
      expect(
        chainA[i].conditions?.maxInputTokens,
        equals(chainB[i].conditions?.maxInputTokens),
      );
    }
  }

  // Embedding.
  expect(a.embedding.providerId, equals(b.embedding.providerId));
  expect(a.embedding.model, equals(b.embedding.model));
  expect(a.embedding.dims, equals(b.embedding.dims));
  expect(a.embedding.normalize, equals(b.embedding.normalize));

  // Web search.
  expect(
    a.webSearch.defaultProvider,
    equals(b.webSearch.defaultProvider),
  );
  expect(
    a.webSearch.providers.keys.toList(),
    equals(b.webSearch.providers.keys.toList()),
  );
  for (final name in a.webSearch.providers.keys) {
    expect(
      a.webSearch.providers[name]!.kind,
      equals(b.webSearch.providers[name]!.kind),
    );
  }

  // Web fetch.
  expect(
    a.webFetch.defaultBudgetBytes,
    equals(b.webFetch.defaultBudgetBytes),
  );
  expect(a.webFetch.userAgent, equals(b.webFetch.userAgent));

  // MCP client.
  expect(
    a.mcpClient.endpoints.keys.toList(),
    equals(b.mcpClient.endpoints.keys.toList()),
  );
  for (final id in a.mcpClient.endpoints.keys) {
    final epA = a.mcpClient.endpoints[id]!;
    final epB = b.mcpClient.endpoints[id]!;
    expect(epA.transport, equals(epB.transport));
    expect(epA.command, equals(epB.command));
    expect(epA.url, equals(epB.url));
  }

  // Price table.
  expect(a.priceTable.keys.toList(), equals(b.priceTable.keys.toList()));
  for (final key in a.priceTable.keys) {
    expect(
      a.priceTable[key]!.inputPerMTokens,
      equals(b.priceTable[key]!.inputPerMTokens),
    );
    expect(
      a.priceTable[key]!.outputPerMTokens,
      equals(b.priceTable[key]!.outputPerMTokens),
    );
  }
}

// ─── Fixtures ────────────────────────────────────────────────────

const String _fullYaml = '''
substrate:
  providers:
    - id: local-ollama
      kind: ollama
      baseUrl: http://localhost:11434
      models:
        - gemma3:27b
        - nomic-embed-text
    - id: openrouter
      kind: openai
      baseUrl: https://openrouter.ai/api/v1
      auth:
        method: api_key
        secretRef: _ai/secrets/openrouter.token
      models:
        - gpt-4o-mini
  roleRoutes:
    analyser:
      - providerId: local-ollama
        model: gemma3:27b
      - providerId: openrouter
        model: gpt-4o-mini
        conditions:
          maxInputTokens: 8192
  embedding:
    providerId: local-ollama
    model: nomic-embed-text
    dims: 768
    normalize: true
  webSearch:
    defaultProvider: duckduckgo
    providers:
      duckduckgo:
        kind: ddg_html
  webFetch:
    defaultBudgetBytes: 524288
    userAgent: 'TomBrain/0.2 (+https://tom-brain.local)'
  mcpClient:
    endpoints:
      memory:
        transport: http
        url: http://localhost:8731
        auth:
          mode: bearer
          secretRef: _ai/secrets/memory.token
  priceTable:
    openrouter/gpt-4o-mini:
      inputPerMTokens: 0.15
      outputPerMTokens: 0.6
''';

const String _envExpansionYaml = r'''
substrate:
  providers:
    - id: local-ollama
      kind: ollama
      baseUrl: ${OLLAMA_URL}
      models: [gemma3:27b]
    - id: openrouter
      kind: openai
      baseUrl: https://openrouter.ai/api/v1
      auth:
        method: api_key
        secretRef: ${OPENROUTER_TOKEN_PATH}
      models: [gpt-4o-mini]
  roleRoutes:
    analyser:
      - providerId: local-ollama
        model: gemma3:27b
  embedding:
    providerId: local-ollama
    model: gemma3:27b
    dims: 768
''';
