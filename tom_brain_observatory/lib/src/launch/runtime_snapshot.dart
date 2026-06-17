// RuntimeSnapshot — the live, in-process values the running brain actually
// bound, threaded into the observatory by the run assembly (`prompt_tracing.md`
// § 8.3(13), § 6.4 Runtime tab).
//
// The observatory runs in its own isolate and reads the brain's config only as
// files on disk; it cannot see what the live process actually bound (which port
// the OpenAI edge is listening on, whether the Telegram channel came up). Those
// values exist only in the running brain. `brain_serve` therefore captures them
// into this snapshot at boot and passes it through `ObservatoryOptions.runtime`,
// across the `Isolate.spawn` boundary, to the `GET /api/runtime` route.
//
// This is the *currently-running* side of the Runtime tab's two-value display
// (§ 6.4): the tab shows this beside the on-disk `brain_run.yaml` value, and
// flags "modification requires restart" when they diverge. It is a read of the
// live process, never a control path (OBS-4): the snapshot is a value copied at
// boot, holding no port, socket, or callback back into the brain.
//
// Sendable across isolates by construction — every field is a primitive, a
// nullable primitive, or a JSON-ready map of such (the resolved [history]
// sizing), so `Isolate.spawn` deep-copies it cleanly.

/// The live runtime values the running brain bound, for `GET /api/runtime`.
final class RuntimeSnapshot {
  /// The TCP port the OpenAI HTTP/SSE gateway is listening on (the value the
  /// process actually bound, not the config request).
  final int openAiPort;

  /// The base path the OpenAI routes mount under (e.g. `/v1`).
  final String openAiBasePath;

  /// The Ollama gateway port, or `null` when no Ollama channel came up.
  final int? ollamaPort;

  /// The base path the Ollama routes mount under (e.g. `/api`).
  final String ollamaBasePath;

  /// The Anthropic gateway port, or `null` when no Anthropic channel came up.
  final int? anthropicPort;

  /// The base path the Anthropic route mounts under (e.g. `/v1`).
  final String anthropicBasePath;

  /// Whether the Telegram channel is enabled (a bot token was configured).
  final bool telegramEnabled;

  /// The resolved on-disk memory store root the live process opened, or `null`
  /// when not configured.
  final String? memoryRoot;

  /// The resolved trail root the live process is writing to, or `null` in
  /// unconfigured trail mode.
  final String? trailRoot;

  /// The resolved cognition config root the live process loaded, or `null` when
  /// no cognition tree was configured.
  final String? cognitionRoot;

  /// The resolved conversation-history sizing the brain bound, as the JSON-ready
  /// `{defaults: {…4 knobs}, lanes: {laneId: {…4 knobs}}}` map produced by
  /// `HistoryConfig.toJson()` (the `lane → defaults → code default` resolution
  /// of `brain_run.yaml`'s `history:` block), or `null` when no live brain
  /// threaded one in (standalone). Pre-serialized to a map of primitives so the
  /// snapshot stays isolate-sendable; it surfaces the effective per-lane sizing
  /// in the Runtime tab (todo #16; `prompt_tracing.md` § 6.4, § 8.3(13)).
  final Map<String, Object?>? history;

  /// Binds the snapshot. Only the always-present OpenAI gateway values are
  /// required; the optional channels, roots, and resolved [history] sizing are
  /// `null` when absent.
  const RuntimeSnapshot({
    required this.openAiPort,
    required this.openAiBasePath,
    this.ollamaPort,
    this.ollamaBasePath = '/api',
    this.anthropicPort,
    this.anthropicBasePath = '/v1',
    this.telegramEnabled = false,
    this.memoryRoot,
    this.trailRoot,
    this.cognitionRoot,
    this.history,
  });

  /// The wire form served by `GET /api/runtime`. The web Runtime tab reads each
  /// gateway's `port` / `basePath` and the roots from this map.
  Map<String, Object?> toJson() => <String, Object?>{
        'gateways': <String, Object?>{
          'openai': <String, Object?>{
            'port': openAiPort,
            'basePath': openAiBasePath,
          },
          if (ollamaPort != null)
            'ollama': <String, Object?>{
              'port': ollamaPort,
              'basePath': ollamaBasePath,
            },
          if (anthropicPort != null)
            'anthropic': <String, Object?>{
              'port': anthropicPort,
              'basePath': anthropicBasePath,
            },
        },
        'telegramEnabled': telegramEnabled,
        'roots': <String, Object?>{
          'memory': memoryRoot,
          'trail': trailRoot,
          'cognition': cognitionRoot,
        },
        // The resolved per-lane history sizing, omitted standalone (no live
        // brain threaded one in) so the no-snapshot case is byte-stable.
        if (history != null) 'history': history,
      };
}
