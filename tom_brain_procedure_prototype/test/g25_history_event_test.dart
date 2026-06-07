// Extension G step 25 — `HistoryEvent` + `HistoryEventBus` *type surface*
// (`prototype_tools_mcp_extension_plan.md` step 25;
// `tom_brain_procedure_prototype_specification.md` § 22.10; access § 14).
//
// ── Why this suite asserts the surface, not emission ────────────────
//
// Step 25 owns § 22.10's *typed observability* for the history subsystem: one
// variant per documented failure row, its kind, payload, and the bus. The
// failures themselves are detected in two different runtimes — the engine-side
// `HistoryCompactor` (compaction.failed / .truncated, already shipped at G.21)
// and the access layer (session.unknown / wire.history.malformed /
// remote_tool.no_session, whose loop is built in the paused steps 11–12 / the
// access-prototype remote-tool steps). So, exactly like step 16 deferred the
// `LlmLoopEvent` emission to the `call_llm_v1` loop, this suite locks the
// *taxonomy* now and the emission rides with each runtime as it lands. See
// `lib/src/config/history_event.dart`'s header for the same note.
//
// What this suite locks now:
//
//   - The five variants construct, carry their payloads, inherit `BrainEvent`,
//     and carry the canonical `<area>.<name>` kind from the § 22.10 / § 14
//     failure-mode tables.
//   - `runId` stays *optional* (unlike the loop events): two of the five
//     failures are detected before any run id exists (access-edge parse,
//     session resolve).
//   - `payloadJson()` / `toJson()` compose correctly (nullable
//     `requestedSessionId` is omitted when absent).
//   - `HistoryEvent` is a closed sealed sum (exhaustive switch compiles).
//   - `HistoryEventBus` fans events out (broadcast, ordered, closes cleanly)
//     and rejects emit-after-close.
//
// Drives the public package barrel only.

import 'package:test/test.dart';
import 'package:tom_brain_procedure_prototype/tom_brain_procedure_prototype.dart';
import 'package:tom_brain_shared/tom_brain_shared.dart' show BrainEvent;

/// A fixed UTC timestamp the variant constructors share.
final DateTime _at = DateTime.utc(2026, 6, 7, 12, 0, 0);

/// Builds one of each variant (the canonical fixtures the suite reuses).
List<HistoryEvent> _oneOfEach() => <HistoryEvent>[
      HistoryCompactionFailed(occurredAt: _at, runId: 'run_1', pendingKept: 7),
      HistoryCompactionTruncated(
          occurredAt: _at, runId: 'run_1', bound: 6000, producedChars: 6400),
      HistorySessionUnknown(
          occurredAt: _at, requestedSessionId: 's_bad', mintedSessionId: 's_new'),
      HistoryWireMalformed(
          occurredAt: _at, channel: 'openai', detail: 'tools[0] not a map'),
      HistoryRemoteToolNoSession(occurredAt: _at, mintedSessionId: 's_new'),
    ];

/// Exhaustive switch over the closed sum — the compile-time drift guard.
String _describe(HistoryEvent event) => switch (event) {
      HistoryCompactionFailed() => 'compaction-failed',
      HistoryCompactionTruncated() => 'compaction-truncated',
      HistorySessionUnknown() => 'session-unknown',
      HistoryWireMalformed() => 'wire-malformed',
      HistoryRemoteToolNoSession() => 'remote-tool-no-session',
    };

void main() {
  group('G.25-hist-1: construction + optional runId', () {
    test('every variant is a HistoryEvent and a BrainEvent', () {
      for (final event in _oneOfEach()) {
        expect(event, isA<HistoryEvent>());
        expect(event, isA<BrainEvent>());
      }
    });

    test('runId is optional — the access-edge variants carry none', () {
      expect(
          HistoryCompactionFailed(occurredAt: _at, runId: 'run_1', pendingKept: 1)
              .runId,
          'run_1');
      expect(
          HistorySessionUnknown(
                  occurredAt: _at,
                  requestedSessionId: 's',
                  mintedSessionId: 's2')
              .runId,
          isNull);
      expect(
          HistoryWireMalformed(occurredAt: _at, channel: 'openai', detail: 'x')
              .runId,
          isNull);
    });

    test('occurredAt + causedBy pass through the base', () {
      final event = HistoryCompactionFailed(
        occurredAt: _at,
        runId: 'run_1',
        causedBy: 'ev_0',
        pendingKept: 3,
      );
      expect(event.occurredAt, _at);
      expect(event.causedBy, 'ev_0');
    });
  });

  group('G.25-hist-2: kind discriminators (§ 22.10 / § 14 failure codes)', () {
    test('each variant carries its canonical failure-code kind', () {
      final kinds = <Type, String>{
        HistoryCompactionFailed: 'history.compaction.failed',
        HistoryCompactionTruncated: 'history.compaction.truncated',
        HistorySessionUnknown: 'access.session.unknown',
        HistoryWireMalformed: 'access.wire.history.malformed',
        HistoryRemoteToolNoSession: 'access.remote_tool.no_session',
      };
      for (final event in _oneOfEach()) {
        expect(event.kind, kinds[event.runtimeType]);
      }
    });

    test('every kind is unique', () {
      expect(_oneOfEach().map((e) => e.kind).toSet(), hasLength(5));
    });
  });

  group('G.25-hist-3: payloadJson + toJson', () {
    test('HistoryCompactionFailed carries pendingKept', () {
      expect(
        HistoryCompactionFailed(occurredAt: _at, runId: 'run_1', pendingKept: 7)
            .payloadJson(),
        <String, Object?>{'pendingKept': 7},
      );
    });

    test('HistoryCompactionTruncated carries bound + producedChars', () {
      expect(
        HistoryCompactionTruncated(
                occurredAt: _at, runId: 'run_1', bound: 6000, producedChars: 6400)
            .payloadJson(),
        <String, Object?>{'bound': 6000, 'producedChars': 6400},
      );
    });

    test('HistorySessionUnknown carries both ids when requested is present', () {
      expect(
        HistorySessionUnknown(
                occurredAt: _at,
                requestedSessionId: 's_bad',
                mintedSessionId: 's_new')
            .payloadJson(),
        <String, Object?>{
          'requestedSessionId': 's_bad',
          'mintedSessionId': 's_new',
        },
      );
    });

    test('HistorySessionUnknown omits requestedSessionId when absent', () {
      expect(
        HistorySessionUnknown(occurredAt: _at, mintedSessionId: 's_new')
            .payloadJson(),
        <String, Object?>{'mintedSessionId': 's_new'},
      );
    });

    test('HistoryWireMalformed carries channel + detail', () {
      expect(
        HistoryWireMalformed(
                occurredAt: _at, channel: 'openai', detail: 'tools[0] not a map')
            .payloadJson(),
        <String, Object?>{'channel': 'openai', 'detail': 'tools[0] not a map'},
      );
    });

    test('HistoryRemoteToolNoSession carries mintedSessionId', () {
      expect(
        HistoryRemoteToolNoSession(occurredAt: _at, mintedSessionId: 's_new')
            .payloadJson(),
        <String, Object?>{'mintedSessionId': 's_new'},
      );
    });

    test('toJson composes kind + base (runId omitted when null) + payload', () {
      final json =
          HistoryWireMalformed(occurredAt: _at, channel: 'openai', detail: 'x')
              .toJson();
      expect(json, <String, Object?>{
        'kind': 'access.wire.history.malformed',
        'occurredAt': _at.toIso8601String(),
        'payload': <String, Object?>{'channel': 'openai', 'detail': 'x'},
      });
    });

    test('toJson includes runId when present', () {
      final json =
          HistoryCompactionFailed(occurredAt: _at, runId: 'run_1', pendingKept: 2)
              .toJson();
      expect(json['runId'], 'run_1');
    });
  });

  group('G.25-hist-4: closed sealed sum (drift guard)', () {
    test('exhaustive switch maps each variant', () {
      expect(
        _oneOfEach().map(_describe).toList(),
        <String>[
          'compaction-failed',
          'compaction-truncated',
          'session-unknown',
          'wire-malformed',
          'remote-tool-no-session',
        ],
      );
    });
  });

  group('G.25-hist-5: HistoryEventBus', () {
    test('events() delivers each failure event in order', () async {
      final bus = HistoryEventBus();
      final received = <String>[];
      final sub = bus.events().listen((e) => received.add(e.kind));

      for (final event in _oneOfEach()) {
        bus.emit(event);
      }

      await bus.close();
      await sub.cancel();

      expect(received, <String>[
        'history.compaction.failed',
        'history.compaction.truncated',
        'access.session.unknown',
        'access.wire.history.malformed',
        'access.remote_tool.no_session',
      ]);
    });

    test('emit after close throws StateError', () async {
      final bus = HistoryEventBus();
      await bus.close();
      expect(
        () => bus.emit(
            HistoryRemoteToolNoSession(occurredAt: _at, mintedSessionId: 's')),
        throwsStateError,
      );
    });
  });

  group('G.25-hist-6: the sink typedef', () {
    test('a HistoryEventSink receives the events it is handed', () {
      final collected = <HistoryEvent>[];
      final HistoryEventSink sink = collected.add;
      for (final event in _oneOfEach()) {
        sink(event);
      }
      expect(collected.map(_describe).toList(), <String>[
        'compaction-failed',
        'compaction-truncated',
        'session-unknown',
        'wire-malformed',
        'remote-tool-no-session',
      ]);
    });
  });
}
