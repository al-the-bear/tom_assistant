// The client model for `GET /api/runtime` (§ 6.4 Runtime tab, § 8.3(13)): the
// live, in-process values the running brain actually bound — the gateway ports
// + base paths, the Telegram toggle, and the resolved roots. The wire shape is
// owned by the observatory's `RuntimeSnapshot.toJson()`; this mirror parses it.
//
// This is the *currently-running* side of the Runtime tab's two-value display:
// the tab shows these beside the on-disk `brain_run.yaml` (the editable `run`
// config), so an operator can see "running on port 8841 (modification requires
// restart)". The snapshot is absent (host `503`) when the observatory was
// launched standalone — there is no live brain to ask, and the tab then shows
// only the on-disk config.

/// One bound HTTP gateway: its channel [name] (`openai` / `ollama` /
/// `anthropic`), the [port] the process is listening on, and the [basePath] the
/// routes mount under.
class RuntimeGateway {
  final String name;
  final int port;
  final String basePath;

  const RuntimeGateway({
    required this.name,
    required this.port,
    required this.basePath,
  });

  factory RuntimeGateway.fromJson(String name, Map<String, dynamic> json) =>
      RuntimeGateway(
        name: name,
        port: json['port'] as int? ?? 0,
        basePath: json['basePath'] as String? ?? '',
      );
}

/// The live runtime snapshot: the bound [gateways] (always at least `openai`),
/// the [telegramEnabled] toggle, and the resolved on-disk roots.
class RuntimeSnapshot {
  final List<RuntimeGateway> gateways;
  final bool telegramEnabled;
  final String? memoryRoot;
  final String? trailRoot;
  final String? cognitionRoot;

  const RuntimeSnapshot({
    this.gateways = const <RuntimeGateway>[],
    this.telegramEnabled = false,
    this.memoryRoot,
    this.trailRoot,
    this.cognitionRoot,
  });

  factory RuntimeSnapshot.fromJson(Map<String, dynamic> json) {
    final gatewaysJson =
        (json['gateways'] as Map<String, dynamic>? ?? const <String, dynamic>{});
    final roots =
        (json['roots'] as Map<String, dynamic>? ?? const <String, dynamic>{});
    // Preserve a stable display order regardless of map iteration order: the
    // always-present OpenAI edge first, then the optional channels.
    const order = <String>['openai', 'ollama', 'anthropic'];
    return RuntimeSnapshot(
      gateways: <RuntimeGateway>[
        for (final name in order)
          if (gatewaysJson[name] is Map<String, dynamic>)
            RuntimeGateway.fromJson(
                name, gatewaysJson[name] as Map<String, dynamic>),
      ],
      telegramEnabled: json['telegramEnabled'] as bool? ?? false,
      memoryRoot: roots['memory'] as String?,
      trailRoot: roots['trail'] as String?,
      cognitionRoot: roots['cognition'] as String?,
    );
  }
}
