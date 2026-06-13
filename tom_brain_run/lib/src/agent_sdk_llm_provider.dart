// AgentSdkLlmProvider — the Anthropic Agent SDK as a substrate `LlmProvider`
// (request a; `agent_sdk_provider_and_mcp_liveness.md` § 1).
//
// ── The control inversion, and why it still fits `LlmProvider` (§ 1.1) ──
//
// In tom_brain's normal model a *procedure* owns the loop: it calls `sub.run`
// (one completion), then drives tools / recall / re-entry itself. The Agent SDK
// inverts this — Claude Code owns the tool loop, the MCP-server loop, and all of
// its own memory. We hand it a prompt; it runs its *own* agentic loop and
// streams back assistant text plus a terminal result. That inversion is
// invisible at the `LlmProvider` seam: from tom_brain's side the Agent SDK is a
// single very capable black-box completion. So this provider implements the
// existing `LlmProvider` interface unchanged — it lives in `tom_brain_run` (not
// the transport-pure substrate) only because it depends on
// `tom_vscode_scripting_api` and a live VS Code bridge, a run-layer integration
// concern.
//
// ── Stream translation (§ 1.1) ──
//
//   * one [LlmStreamStarted] first;
//   * each `SdkAssistantMessage`'s `TextBlock`s → [LlmStreamChunk]
//     (`ThinkingBlock`s are dropped from the answer text — they are not part of
//     the assistant's reply — but their token cost is still counted, because the
//     terminal usage figures already include them);
//   * the terminal `SdkResultMessage` → [LlmStreamCompleted] with an
//     [LlmCallReport] whose tokens / cost / wall-clock are read off the result
//     message (cost from `total_cost_usd`, § OC-3 — never the substrate price
//     table, which has no Claude entries);
//   * any SDK failure → [LlmStreamFailed].
//
// **Deliberately NOT surfaced:** [LlmStreamToolCallProposed]. Tool / MCP calls
// run *inside* Claude Code; tom_brain never sees them, so the provider never
// emits a tool-call event.
//
// ── Anchor invariant (§ 1.1; Postulate 3 / spec § 4.1) ──
//
// The role registry has already prepended the assistant-dedication anchor into
// `WirePrompt.body`. The provider sends `wire.body` to Claude Code **unmodified**
// (as the `query` prompt) and stamps `report.anchorHash = wire.anchorHash` on
// every report, exactly like the HTTP providers. Claude Code's own system prompt
// is additive context, never a replacement for the anchor — so `Options.systemPrompt`
// is left at its append/preset default and is never set to `override`.
//
// Phase 2 (this file) wires **session mode `none`** only: every call is a first
// call, no session id is ever set. Modes `brain` / `quest` are layered on in
// phase 3 through the [SessionMode] seam.

import 'dart:async';

import 'package:tom_brain_substrate/tom_brain_substrate.dart';
import 'package:tom_core_agentic/tom_core_agentic.dart' show promptSha256;
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart';

/// One Anthropic-Agent-SDK backend, exposed as a substrate [LlmProvider].
///
/// Constructed by the run substrate builder's `_buildProvider` for a
/// `kind: agent_sdk` config row. The [clientFactory] is memoised on first use so
/// the (async) bridge connect is deferred until the first call and shared across
/// every subsequent call — keeping `_buildProvider` synchronous while the socket
/// is opened lazily. Tests inject a factory over a fake `AgentSdkTransport`.
final class AgentSdkLlmProvider implements LlmProvider {
  @override
  final String id;

  /// Model id used when [LlmOptions.model] is null. The router resolves
  /// `options.model` before invoking the provider; this is the route default.
  final String defaultModel;

  /// Claude Code's internal agentic-loop turn cap, or `null` for the SDK default.
  final int? maxTurns;

  /// The permission posture handed to Claude Code's own tool loop.
  final PermissionMode permissionMode;

  /// Builds (and connects) the [AgentSdkClient]. Memoised on first call via
  /// [_clientFuture] so the bridge socket is opened once and reused.
  final Future<AgentSdkClient> Function() clientFactory;

  Future<AgentSdkClient>? _clientFuture;

  AgentSdkLlmProvider({
    required this.id,
    required this.defaultModel,
    required this.clientFactory,
    this.maxTurns,
    this.permissionMode = PermissionMode.default_,
  });

  /// The memoised client (one bridge connection shared across calls).
  Future<AgentSdkClient> _client() => _clientFuture ??= clientFactory();

  @override
  Future<LlmCallReport> complete(WirePrompt prompt, LlmOptions options) async {
    LlmCallReport? completedReport;
    await for (final event in completeStream(prompt, options)) {
      if (event is LlmStreamCompleted) {
        completedReport = event.report;
      } else if (event is LlmStreamFailed) {
        // Per the `LlmProvider` contract, the non-streaming path surfaces a
        // backend failure as an exception; the router classifies it.
        final cause = event.failure.cause;
        if (cause is Object) throw cause;
        throw AgentSdkQueryException(event.failure.message);
      }
    }
    // `completeStream` always terminates with exactly one Completed or Failed
    // event; reaching here without a report would be a provider defect.
    return completedReport!;
  }

  @override
  Stream<LlmStreamEvent> completeStream(
    WirePrompt prompt,
    LlmOptions options,
  ) async* {
    final stopwatch = Stopwatch()..start();
    final modelId = options.model ?? defaultModel;
    final callId = _newCallId(prompt);

    yield LlmStreamStarted(
      callId: callId,
      providerId: id,
      modelId: modelId,
    );

    final sdkOptions = Options(
      model: modelId,
      maxTurns: maxTurns,
      permissionMode: permissionMode,
      // Session mode `none`: no `resume` / `sessionId` is ever set (phase 2).
      // `systemPrompt` is left at the SDK default so Claude Code's own system
      // prompt stays additive and never overrides the anchored `wire.body`.
    );

    SdkResultMessage? result;
    try {
      final client = await _client();
      // `wire.body` carries the assistant-dedication anchor verbatim and is
      // handed to Claude Code unmodified.
      final query = client.query(prompt: prompt.body, options: sdkOptions);
      await for (final message in query) {
        if (message is SdkAssistantMessage) {
          for (final block in message.content) {
            if (block is TextBlock && block.text.isNotEmpty) {
              yield LlmStreamChunk(callId: callId, text: block.text);
            }
            // ThinkingBlock / tool blocks are not part of the assistant reply.
          }
        } else if (message is SdkResultMessage) {
          result = message;
        }
      }
    } catch (e) {
      stopwatch.stop();
      yield LlmStreamFailed(
        callId: callId,
        failure: LlmFailure(
          // Unclassified here; the router maps onto the spec § 5.4 taxonomy.
          classCode: 'unknown',
          message: e.toString(),
          cause: e,
        ),
        report: _buildReport(
          prompt: prompt,
          modelId: modelId,
          wallClockMs: stopwatch.elapsedMilliseconds,
        ),
      );
      return;
    }

    stopwatch.stop();

    if (result == null) {
      // The SDK stream closed without a terminal `result` message — a
      // protocol-shape failure.
      yield LlmStreamFailed(
        callId: callId,
        failure: const LlmFailure(
          classCode: 'format',
          message: 'Agent SDK stream ended without a terminal result message.',
        ),
        report: _buildReport(
          prompt: prompt,
          modelId: modelId,
          wallClockMs: stopwatch.elapsedMilliseconds,
        ),
      );
      return;
    }

    final resolved = result;
    final report = _buildReport(
      prompt: prompt,
      modelId: modelId,
      wallClockMs: resolved.durationMs ?? stopwatch.elapsedMilliseconds,
      tokensIn: _usageTokens(resolved.usage, 'input_tokens'),
      tokensOut: _usageTokens(resolved.usage, 'output_tokens'),
      cost: resolved.totalCostUsd,
    );

    if (resolved.isError) {
      yield LlmStreamFailed(
        callId: callId,
        failure: LlmFailure(
          classCode: 'unknown',
          message: resolved.result ?? 'Agent SDK reported an error result.',
        ),
        report: report,
      );
      return;
    }

    yield LlmStreamCompleted(callId: callId, report: report);
  }

  /// Builds an [LlmCallReport] with the provider-invariant fields filled:
  /// provenance (`providerId` = [id]), the anchor stamp
  /// (`anchorHash` = the prompt's), the body hash, `retries: 0`, and the
  /// prompt's `templateSha`. Mirrors `HttpLlmProviderBase.buildReport`, which
  /// the run layer cannot reach (it is substrate-internal).
  LlmCallReport _buildReport({
    required WirePrompt prompt,
    required String modelId,
    required int wallClockMs,
    int tokensIn = 0,
    int tokensOut = 0,
    double? cost,
  }) {
    return LlmCallReport(
      providerId: id,
      modelId: modelId,
      anchorHash: prompt.anchorHash,
      promptHash: promptSha256(prompt.body),
      tokensIn: tokensIn,
      tokensOut: tokensOut,
      retries: 0,
      wallClockMs: wallClockMs,
      cost: cost,
      templateSha: prompt.templateSha,
    );
  }

  /// Reads an integer token count out of the SDK result's `usage` map; 0 when
  /// the field is absent or non-numeric.
  static int _usageTokens(Map<String, dynamic>? usage, String key) =>
      (usage?[key] as num?)?.toInt() ?? 0;

  /// A per-call id unique enough for trail correlation:
  /// `agentsdk-<id>-<micros>-<32-bit body hash>`.
  String _newCallId(WirePrompt prompt) {
    final now = DateTime.now().microsecondsSinceEpoch;
    return 'agentsdk-$id-$now-${prompt.body.hashCode.toUnsigned(32)}';
  }
}
