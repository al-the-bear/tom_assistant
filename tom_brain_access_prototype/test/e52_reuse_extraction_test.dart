// E.52 — Phase-E reuse-extraction pass sentinel.
//
// The plan's E.52 names four types — `OutboundChunk`, `InboundRequest`,
// `DeliveryStalled`, `BackpressureSignal` — that "should likely live in
// `tom_brain_shared` because the dispatcher and the engine both reference
// them. Move and republish." The move was pulled forward at D.11
// (`OutboundChunk` / `InboundRequest`) and E.39 (`DeliveryStalled` /
// `BackpressureSignal`) per the D.4 ownership rule, so all four are already
// declared exactly once, in `tom_brain_shared`. The E.52 pass therefore
// *confirms* the extraction rather than performing it, and surveys the
// Phase-E surface for any further cross-phase type (none qualifies — see
// `prototype_implementation_details.md` § E.52).
//
// A reuse conclusion that is prose only erodes the instant a later edit
// re-declares one of the four in a consumer package: the duplicate would
// compile (Dart resolves the local name) and the prose would still read
// "single home". This sentinel pins the conclusion as code by *flowing the
// shared types across the package boundary the plan names*:
//
//   * the access layer (`tom_brain_access_prototype` — `DeliveryRegistry` /
//     `ChannelDelivery` / `DeliveryBinding`) *produces* a `DeliverCallback`
//     typed in the shared `OutboundChunk` and surfaces a shared
//     `DeliveryStalled` / `BackpressureSignal` through its backpressure
//     stream, while
//   * the dispatcher (`tom_brain_procedure_prototype` — `InboundClassifier`)
//     *consumes* the shared `Access` / `InboundRequest` the same callback is
//     handed to.
//
// Because the test imports the four types only from `package:tom_brain_shared`
// and drives both consumer packages with the *same* values, it cannot compile
// if either package re-declares any of the four (the local type would not
// unify with the shared one at the `Access.deliver` seam). The single home is
// thus enforced by the type checker, not by documentation.

import 'package:tom_brain_access_prototype/tom_brain_access_prototype.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart'
    show InboundClassifier;
import 'package:tom_brain_shared/tom_brain_shared.dart';
import 'package:test/test.dart';

/// A minimal [DeliveryBinding] carrying the two shared handles the registry
/// reads — proving [DeliveryBinding] is typed in the shared `ResolvedIdentity`
/// / `InboundRequest`, not package-local copies.
final class _FakeBinding implements DeliveryBinding {
  @override
  final AccessChannel channel;
  @override
  final ResolvedIdentity identity;
  @override
  final InboundRequest envelope;

  _FakeBinding({
    required this.channel,
    required this.identity,
    required this.envelope,
  });
}

/// A delivery path whose `DeliverCallback` returns the shared backpressure
/// streams: a terminal [DeliveryStalled] (a [BackpressureSignal]) on the final
/// chunk, [Backpressure.clear] otherwise. It records every [OutboundChunk] it
/// is handed so the test can assert the shared value flowed through unchanged.
final class _StallingDelivery implements ChannelDelivery {
  @override
  final AccessChannel channel;
  final List<OutboundChunk> seen = <OutboundChunk>[];

  _StallingDelivery(this.channel);

  @override
  DeliverCallback bindDeliver(DeliveryBinding binding) {
    return (OutboundChunk chunk) {
      seen.add(chunk);
      if (chunk.isFinal) {
        return Backpressure.stalled(
          DeliveryStalled.terminal(
            channel: channel.wireName,
            reason: StallReason.clientDisconnected,
            detail: 'sentinel',
          ),
        );
      }
      return Backpressure.clear;
    };
  }
}

void main() {
  group('E.52-1 — the four reuse types have a single home in tom_brain_shared',
      () {
    // Each is constructed here from the `tom_brain_shared` barrel only. The
    // import list above pulls them from no other package, so a green compile
    // is itself the single-home assertion; the bodies pin the surface the two
    // consumer packages depend on.
    test('OutboundChunk constructs and carries its increment', () {
      final OutboundChunk chunk =
          OutboundChunk(textDelta: 'hi', isFinal: true, index: 0);
      expect(chunk.textDelta, 'hi');
      expect(chunk.isFinal, isTrue);
      expect(chunk.index, 0);
    });

    test('InboundRequest constructs and carries the kind hint', () {
      final InboundRequest req = InboundRequest(
        text: 'how do I automate backups?',
        kindHint: InboundKinds.userPrompt,
        messageId: 'm1',
        conversationId: 'c1',
      );
      expect(req.text, 'how do I automate backups?');
      expect(req.kindHint, InboundKinds.userPrompt);
    });

    test('DeliveryStalled is a BackpressureSignal and an Exception', () {
      final DeliveryStalled stalled = DeliveryStalled.transient(
        channel: 'telegram',
        reason: StallReason.rateLimited,
        retryAfter: const Duration(seconds: 2),
      );
      expect(stalled, isA<BackpressureSignal>());
      expect(stalled, isA<Exception>());
      expect(stalled.isTerminal, isFalse);
      expect(stalled.retryAfter, const Duration(seconds: 2));
    });

    test('BackpressureSignal is sealed — DeliveryStalled is its realisation',
        () {
      final BackpressureSignal signal = DeliveryStalled.terminal(
        channel: 'openai',
        reason: StallReason.channelClosed,
      );
      // Exhaustive switch over the sealed base: a green compile proves the
      // base + its one realisation both resolve from shared.
      final String kind = switch (signal) {
        DeliveryStalled() => 'stalled',
      };
      expect(kind, 'stalled');
    });
  });

  group(
      'E.52-2 — access produces & dispatcher consumes the same shared symbols',
      () {
    test(
        'a registry-produced DeliverCallback is the Access.deliver the '
        'dispatcher classifies, and surfaces a shared DeliveryStalled', () {
      // ── access layer PRODUCES ───────────────────────────────────────────
      final _StallingDelivery path = _StallingDelivery(AccessChannel.openai);
      final DeliveryRegistry registry = DeliveryRegistry();
      registry.register(path);

      final InboundRequest envelope = InboundRequest(
        text: 'how do I automate backups?',
        kindHint: InboundKinds.userPrompt,
        messageId: 'm1',
        conversationId: 'c1',
      );
      final ResolvedIdentity identity =
          ResolvedIdentity(principalId: 'p1');
      final DeliveryBinding binding = _FakeBinding(
        channel: AccessChannel.openai,
        identity: identity,
        envelope: envelope,
      );

      // The access layer mints the per-Access DeliverCallback. Its static
      // type is the shared `DeliverCallback` (Stream<OutboundChunk> Function).
      final DeliverCallback deliver = registry.deliverFor(binding);

      // ── the shared Access carries the access-produced callback ───────────
      final Access access = Access(
        envelope: envelope,
        identity: identity,
        session: Session(sessionId: 's1', conversationId: 'c1'),
        persona: Persona.assistant(),
        deliver: deliver,
      );

      // ── dispatcher CONSUMES the same shared Access / InboundRequest ──────
      // If the dispatcher package had its own `Access` / `InboundRequest`,
      // this call would not type-check against the shared `access` above.
      final String kind = InboundClassifier().classify(access);
      expect(kind, InboundKinds.userPrompt);
    });

    test(
        'the shared OutboundChunk flows through the access callback and the '
        'backpressure stream surfaces a shared BackpressureSignal', () async {
      final _StallingDelivery path = _StallingDelivery(AccessChannel.openai);
      final DeliveryRegistry registry = DeliveryRegistry();
      registry.register(path);

      final InboundRequest envelope = InboundRequest(
        text: 'stream me',
        messageId: 'm2',
      );
      final DeliverCallback deliver = registry.deliverFor(
        _FakeBinding(
          channel: AccessChannel.openai,
          identity: ResolvedIdentity(principalId: 'p2'),
          envelope: envelope,
        ),
      );

      // A non-final chunk: clear backpressure (empty stream).
      final OutboundChunk mid = OutboundChunk(textDelta: 'tok', isFinal: false);
      expect(await deliver(mid).toList(), isEmpty);

      // The final chunk: the path stalls. The backpressure stream carries the
      // shared signal as a stream error.
      final OutboundChunk last = OutboundChunk(textDelta: '', isFinal: true);
      Object? surfaced;
      await for (final _ in deliver(last).handleError((Object e) {
        surfaced = e;
      })) {
        fail('the backpressure stream must not emit an OutboundChunk');
      }

      expect(surfaced, isA<BackpressureSignal>());
      expect(surfaced, isA<DeliveryStalled>());
      final DeliveryStalled stalled = surfaced! as DeliveryStalled;
      expect(stalled.channel, AccessChannel.openai.wireName);
      expect(stalled.isTerminal, isTrue);

      // The exact shared OutboundChunk instances flowed through the access
      // path unchanged (single type — no copy-conversion at the boundary).
      expect(path.seen, <OutboundChunk>[mid, last]);
      expect(identical(path.seen.last, last), isTrue);
    });
  });

  group('E.52-3 — the registry contract is typed in the shared handles', () {
    test('UnknownDeliveryChannel surfaces for an unregistered channel', () {
      final DeliveryRegistry registry = DeliveryRegistry();
      final DeliveryBinding binding = _FakeBinding(
        channel: AccessChannel.telegram,
        identity: ResolvedIdentity(principalId: 'p3'),
        envelope: InboundRequest(text: 'hi', messageId: 'm3'),
      );
      expect(
        () => registry.deliverFor(binding),
        throwsA(isA<UnknownDeliveryChannel>()),
      );
    });
  });
}
