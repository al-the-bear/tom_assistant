// B.18 — `LlmRouter`.
//
// `substrate_specification.md` § 5.1 says the router resolves
// `(roleId, options.modelHint?, budget) → provider` via the role's
// `routeChain`. The decision tree:
//
//   1. Look up the role's `routeChain`.
//   2. For each entry in order: ask the provider for a health snapshot;
//      if it's in cooldown, skip; if its auth profile has no available
//      credential, skip; if `conditions.maxInputTokens` is exceeded by
//      the call, skip.
//   3. Take the first entry that survives the filter.
//   4. If none survive, surface `NoRouteAvailable` with the chain's
//      audit trail attached.
//
// At B.18 the wiring is:
//
//   * Per-role provider selection — implemented by walking
//     [roleRoutes][roleId] in order.
//   * Free-tier rotation — implemented by chain ordering (spec § 5.3:
//     "tier escalation is expressed by *profile ordering* inside
//     `routeChain`, not by separate logic"). The router does not know
//     "free" vs "paid".
//   * Paid-tier opt-in — same: a paid-tier credential is a later entry
//     in the chain. A role whose chain has no paid entry will never
//     touch a paid provider regardless of failover.
//   * Failover classification — delegated to [LlmFailureClassifier]
//     (spec § 5.4). The router converts the resulting [LlmFailureClass]
//     into a [LlmRouterAction] and acts accordingly.
//   * Per-credential cooldown — keyed by `<providerId>:<modelId>:<class>`
//     (B.18 prototype; spec calls for `(profile, credential, errorClass)`
//     once the credential layer lands at B.30+).
//   * Wall-clock budget enforcement — every attempt checks
//     `Budget.covers` for the elapsed wall-clock; a per-call deadline
//     stops the chain even if more entries remain.
//
// What this file deliberately defers to later steps:
//
//   * Token-spend charging against the [Budget] — B.32+ wires the
//     full token-spend accounting; B.18 only enforces wall-clock.
//   * Streaming dispatch (`dispatchStream`) — pinned to the same
//     classifier + cooldown machinery; B.18 lands the non-streaming
//     path first (the conformance suite at B.20 covers the streaming
//     path).  Streaming is included at B.18 to satisfy the spec § 4.3
//     invariant that a route chain works for SSE forwarding from day
//     one of the router; the streaming path uses the same chain walk
//     and reads the per-call result from `LlmStreamCompleted` /
//     `LlmStreamFailed`.
//   * The role registry (B.21+) — the router does NOT assemble prompts;
//     it consumes a pre-built [WirePrompt]. The role registry is the
//     only producer of `WirePrompt`. Callers wishing to dispatch by
//     role without holding the registry use [TomBrainSubstrate.complete]
//     once that lands; at B.18 the router's API is `WirePrompt`-first
//     because the only B.18 caller is the conformance suite, which
//     constructs prompts directly.

import 'dart:async';
import 'dart:math';

import 'package:tom_brain_shared/tom_brain_shared.dart' show Budget;

import '../api/cancellation.dart';
import '../api/llm_call.dart';
import '../api/llm_stream_event.dart';
import '../llm/llm_provider.dart';
import '../llm/wire_prompt.dart';
import 'llm_failure_classifier.dart';
import 'route_entry.dart';
import 'router_errors.dart';
import 'router_policy.dart';

/// Routes role-keyed LLM calls across an ordered chain of providers,
/// with failover classification and per-credential cooldown.
///
/// At B.18 the router exposes:
///
///   * [dispatch] — buffered call. Returns the [LlmCallReport] of the
///     first route that produced a non-failure terminal result, or
///     throws [NoRouteAvailable] / [ContextOverflowError] /
///     [RoleNotFound] per the spec.
///   * [dispatchStream] — streaming call. Emits the stream of the first
///     route that produced a non-failure terminal result; if every
///     route fails the stream terminates with a [LlmStreamFailed]
///     wrapping the last classification and a one-line audit summary
///     in `notes`.
///
/// The router is stateful only in its cooldown bookkeeping (per spec § 2
/// item 3, this is the one form of state substrate carries across calls).
/// Cooldowns are in-process and not persisted; a substrate restart
/// clears them all by design (a transient backend issue should not
/// outlive a process restart).
class LlmRouter {
  /// Providers keyed by `LlmProvider.id`. Constructed once and passed in.
  ///
  /// Kept separate from [policy] because providers are runtime objects
  /// (they hold `HttpClient` state, credentials, host connections),
  /// while [policy] is pure data loadable from YAML (spec § 9 / B.36).
  final Map<String, LlmProvider> providers;

  /// Immutable routing configuration (B.19).
  ///
  /// Carries the role → chain map, per-class cooldown durations, the
  /// in-route retry budget, and the overloaded-backoff window. The
  /// router never mutates the policy; replacing routing config means
  /// constructing a fresh [LlmRouter] with the new policy.
  final RouterPolicy policy;

  /// Classifier used on every caught exception / provider-supplied
  /// failure. Stateless; defaults to [LlmFailureClassifier.shared].
  final LlmFailureClassifier classifier;

  /// Clock seam for tests. Defaults to [DateTime.now].
  final DateTime Function() now;

  /// Random seam for jittered backoff. Defaults to a process-wide
  /// [Random] instance.
  final Random _random;

  /// Per-role ordered route chain. Pulled from [policy] for ergonomic
  /// access inside the dispatch loop; mirrors `policy.roleRoutes`.
  Map<String, List<RouteEntry>> get roleRoutes => policy.roleRoutes;

  /// Per-class cooldown window. Mirrors `policy.cooldownByClass`.
  Map<LlmFailureClass, Duration> get cooldownByClass => policy.cooldownByClass;

  /// In-route retry count per [LlmRouterAction.retryThenRotate] class.
  /// Mirrors `policy.retriesPerClass`.
  int get retriesPerClass => policy.retriesPerClass;

  /// Backoff base for `overloaded` retries. Mirrors
  /// `policy.overloadedBackoff`.
  Duration get overloadedBackoff => policy.overloadedBackoff;

  /// Cooldown bookkeeping, keyed by a structured [_CooldownKey] rather
  /// than a `:`-joined string. Model ids legitimately contain colons
  /// (`gemma3:27b`, `llama3.1:8b`), so a string key matched by prefix
  /// would let one model's cooldown bleed onto a sibling that shares a
  /// `<provider>:<prefix>` segment. The value class compares fields, not
  /// substrings, so `(ollama, gemma3:27b)` and `(ollama, gemma3)` are
  /// distinct keys.
  ///
  /// A key with a null [_CooldownKey.modelId] is provider-wide (e.g.
  /// `auth`, where the credential is provider-scoped not route-scoped)
  /// and matches every model of the provider.
  ///
  /// The map only holds entries that are currently in cooldown; an
  /// entry expires by being read past its [DateTime] and re-evaluated.
  final Map<_CooldownKey, DateTime> _cooldownUntil = <_CooldownKey, DateTime>{};

  /// Construct a router from a [RouterPolicy] + provider registry.
  ///
  /// `classifier`, `now`, and `random` are test seams; production code
  /// can leave them at their defaults.
  LlmRouter({
    required this.providers,
    required this.policy,
    LlmFailureClassifier? classifier,
    DateTime Function()? now,
    Random? random,
  })  : classifier = classifier ?? LlmFailureClassifier.shared,
        now = now ?? DateTime.now,
        _random = random ?? Random();

  /// Number of routes currently parked under a cooldown. Useful for
  /// tests and for `SubstrateStats` (B.34+).
  int get cooldownsActive {
    final t = now();
    int active = 0;
    _cooldownUntil.forEach((_, deadline) {
      if (deadline.isAfter(t)) active++;
    });
    return active;
  }

  /// Returns `true` iff the `(providerId, modelId)` route is in cooldown
  /// at this instant. Exposed for tests; production code calls
  /// [_isCooldownActive] internally.
  bool isInCooldown({
    required String providerId,
    required String modelId,
  }) {
    final t = now();
    for (final entry in _cooldownUntil.entries) {
      if (!entry.value.isAfter(t)) continue;
      if (entry.key.matchesRoute(providerId, modelId)) {
        return true;
      }
    }
    return false;
  }

  // ─── Public dispatch ─────────────────────────────────────────────

  /// Buffered dispatch — runs the role's chain until a route returns a
  /// non-failure [LlmCallReport] or every entry is exhausted.
  ///
  /// Throws:
  ///   * [RoleNotFound] if [roleId] is not in [roleRoutes].
  ///   * [ContextOverflowError] on the first route that reports
  ///     `context_overflow` (spec § 5.4 — surfaced to caller, not
  ///     rotated past).
  ///   * [NoRouteAvailable] if every entry was filter-skipped or every
  ///     attempt failed.
  ///
  /// On success, returns the report with `retries` carrying the total
  /// in-route retries the router burned on the winning entry.
  Future<LlmCallReport> dispatch({
    required String roleId,
    required WirePrompt prompt,
    required LlmOptions options,
    required Budget budget,
    CancellationToken cancellationToken = CancellationToken.none,
    int? inputTokensHint,
  }) async {
    final chain = roleRoutes[roleId];
    if (chain == null) throw RoleNotFound(roleId);

    final attempts = <RouteAttempt>[];
    final overallWatch = Stopwatch()..start();
    LlmFailureClass? lastClass;

    for (final entry in chain) {
      if (cancellationToken.isCancelled) {
        throw const NoRouteAvailable(
          roleId: '',
          attempts: <RouteAttempt>[],
          lastClass: LlmFailureClass.cancelledByConsumer,
        );
      }

      final filtered = _filter(
        entry,
        inputTokensHint: inputTokensHint,
        attempts: attempts,
      );
      if (filtered != null) continue;

      // Wall-clock budget check before the attempt.
      if (overallWatch.elapsedMilliseconds >= budget.wallClockMs) {
        attempts.add(RouteAttempt(
          routeKey: '${entry.providerId}:${entry.model}',
          outcome: 'skipped:budget_wall_clock',
          retries: 0,
        ));
        break;
      }

      final provider = providers[entry.providerId]!;
      final resolvedOptions = _resolveOptions(options, entry.model);
      int retries = 0;
      Object? lastException;

      while (true) {
        if (cancellationToken.isCancelled) {
          lastClass = LlmFailureClass.cancelledByConsumer;
          attempts.add(RouteAttempt(
            routeKey: '${entry.providerId}:${entry.model}',
            outcome: 'failed:cancelled_by_consumer:cancelled',
            retries: retries,
            classification: lastClass,
          ));
          throw NoRouteAvailable(
            roleId: roleId,
            attempts: List<RouteAttempt>.unmodifiable(attempts),
            lastClass: lastClass,
          );
        }

        try {
          final report =
              await provider.complete(prompt, resolvedOptions);
          attempts.add(RouteAttempt(
            routeKey: '${entry.providerId}:${entry.model}',
            outcome: 'succeeded',
            retries: retries,
            classification: null,
          ));
          return LlmCallReport(
            providerId: report.providerId,
            modelId: report.modelId,
            anchorHash: report.anchorHash,
            promptHash: report.promptHash,
            tokensIn: report.tokensIn,
            tokensOut: report.tokensOut,
            retries: report.retries + retries,
            wallClockMs: report.wallClockMs,
            cost: report.cost,
            templateSha: report.templateSha,
            notes: report.notes,
          );
        } catch (e) {
          lastException = e;
          final cls = classifier.classify(e);
          lastClass = cls;
          final action = cls.routerAction;

          if (cls == LlmFailureClass.contextOverflow) {
            attempts.add(RouteAttempt(
              routeKey: '${entry.providerId}:${entry.model}',
              outcome: 'failed:context_overflow:${_summarise(e)}',
              retries: retries,
              classification: cls,
            ));
            throw ContextOverflowError(
              roleId: roleId,
              providerId: entry.providerId,
              modelId: entry.model,
              message: e.toString(),
              cause: e,
            );
          }

          if (cls == LlmFailureClass.cancelledByConsumer) {
            attempts.add(RouteAttempt(
              routeKey: '${entry.providerId}:${entry.model}',
              outcome: 'failed:cancelled_by_consumer:${_summarise(e)}',
              retries: retries,
              classification: cls,
            ));
            throw NoRouteAvailable(
              roleId: roleId,
              attempts: List<RouteAttempt>.unmodifiable(attempts),
              lastClass: cls,
            );
          }

          if (action == LlmRouterAction.retryThenRotate &&
              retries < retriesPerClass &&
              overallWatch.elapsedMilliseconds < budget.wallClockMs) {
            retries++;
            await _waitForRetry(cls);
            continue;
          }

          // Rotate. Apply cooldown / removal per action.
          _applyAction(action, cls, entry);
          attempts.add(RouteAttempt(
            routeKey: '${entry.providerId}:${entry.model}',
            outcome: 'failed:${cls.code}:${_summarise(e)}',
            retries: retries,
            classification: cls,
          ));
          break;
        }
      }

      // After rotation, drop through the for-loop to the next entry.
      // `lastException` is preserved so the trail names a real cause.
      // ignore: unused_local_variable
      final _ = lastException;
    }

    throw NoRouteAvailable(
      roleId: roleId,
      attempts: List<RouteAttempt>.unmodifiable(attempts),
      lastClass: lastClass,
    );
  }

  /// Streaming dispatch — same chain walk as [dispatch] but consumes
  /// `provider.completeStream` instead.
  ///
  /// The router buffers the upstream stream until it sees the terminal
  /// event:
  ///
  ///   * On `LlmStreamCompleted` — the router forwards every observed
  ///     event (including the `Started` and any `Chunk` / `ToolCallProposed`)
  ///     to the returned stream and terminates with the same
  ///     `Completed` event, with `report.retries` adjusted to include
  ///     any router-level retries on the winning route.
  ///
  ///   * On `LlmStreamFailed` — the router classifies the failure,
  ///     decides retry / rotate, and either re-issues the chain step
  ///     (retry) or moves to the next entry (rotate). Forwarded events
  ///     from the failed attempt are *not* relayed (the caller never
  ///     sees a half-stream that gave up).
  ///
  /// On chain exhaustion the stream emits a single [LlmStreamFailed]
  /// carrying the classifier's last class and a synthetic report whose
  /// `notes` summarises the chain audit trail.
  Stream<LlmStreamEvent> dispatchStream({
    required String roleId,
    required WirePrompt prompt,
    required LlmOptions options,
    required Budget budget,
    CancellationToken cancellationToken = CancellationToken.none,
    int? inputTokensHint,
  }) async* {
    final chain = roleRoutes[roleId];
    if (chain == null) throw RoleNotFound(roleId);

    final attempts = <RouteAttempt>[];
    final overallWatch = Stopwatch()..start();
    LlmFailureClass? lastClass;

    for (final entry in chain) {
      if (cancellationToken.isCancelled) {
        yield _exhaustedFailedEvent(
          roleId: roleId,
          attempts: attempts,
          lastClass: LlmFailureClass.cancelledByConsumer,
          provider: providers[entry.providerId],
          entry: entry,
        );
        return;
      }

      final filtered = _filter(
        entry,
        inputTokensHint: inputTokensHint,
        attempts: attempts,
      );
      if (filtered != null) continue;

      if (overallWatch.elapsedMilliseconds >= budget.wallClockMs) {
        attempts.add(RouteAttempt(
          routeKey: '${entry.providerId}:${entry.model}',
          outcome: 'skipped:budget_wall_clock',
          retries: 0,
        ));
        break;
      }

      final provider = providers[entry.providerId]!;
      final resolvedOptions = _resolveOptions(options, entry.model);
      int retries = 0;

      while (true) {
        if (cancellationToken.isCancelled) {
          attempts.add(RouteAttempt(
            routeKey: '${entry.providerId}:${entry.model}',
            outcome: 'failed:cancelled_by_consumer:cancelled',
            retries: retries,
            classification: LlmFailureClass.cancelledByConsumer,
          ));
          yield _exhaustedFailedEvent(
            roleId: roleId,
            attempts: attempts,
            lastClass: LlmFailureClass.cancelledByConsumer,
            provider: provider,
            entry: entry,
          );
          return;
        }

        final buffered = <LlmStreamEvent>[];
        LlmStreamFailed? terminalFail;
        LlmStreamCompleted? terminalDone;

        try {
          await for (final ev in provider.completeStream(
            prompt,
            resolvedOptions,
          )) {
            if (ev is LlmStreamCompleted) {
              terminalDone = ev;
              buffered.add(ev);
              break;
            }
            if (ev is LlmStreamFailed) {
              terminalFail = ev;
              break;
            }
            buffered.add(ev);
          }
        } catch (e) {
          terminalFail = LlmStreamFailed(
            callId: 'router-${entry.providerId}-${entry.model}',
            failure: classifier.wrap(e),
            report: _syntheticReport(
              provider: provider,
              entry: entry,
              prompt: prompt,
              options: resolvedOptions,
              retries: retries,
              wallClockMs: overallWatch.elapsedMilliseconds,
            ),
          );
        }

        if (terminalDone != null) {
          // Success: replay buffered chunks, then the terminal event
          // with retries folded in.
          for (final ev in buffered.take(buffered.length - 1)) {
            yield ev;
          }
          final report = terminalDone.report;
          attempts.add(RouteAttempt(
            routeKey: '${entry.providerId}:${entry.model}',
            outcome: 'succeeded',
            retries: retries,
          ));
          yield LlmStreamCompleted(
            callId: terminalDone.callId,
            report: LlmCallReport(
              providerId: report.providerId,
              modelId: report.modelId,
              anchorHash: report.anchorHash,
              promptHash: report.promptHash,
              tokensIn: report.tokensIn,
              tokensOut: report.tokensOut,
              retries: report.retries + retries,
              wallClockMs: report.wallClockMs,
              cost: report.cost,
              templateSha: report.templateSha,
              notes: report.notes,
            ),
          );
          return;
        }

        // Failure path.
        final fail = terminalFail!;
        final cls = classifier.classify(fail.failure);
        lastClass = cls;
        final action = cls.routerAction;

        if (cls == LlmFailureClass.contextOverflow) {
          attempts.add(RouteAttempt(
            routeKey: '${entry.providerId}:${entry.model}',
            outcome: 'failed:context_overflow:${fail.failure.message}',
            retries: retries,
            classification: cls,
          ));
          yield LlmStreamFailed(
            callId: fail.callId,
            failure: LlmFailure(
              classCode: cls.code,
              message: fail.failure.message,
              cause: fail.failure.cause,
            ),
            report: fail.report,
          );
          return;
        }

        if (cls == LlmFailureClass.cancelledByConsumer) {
          attempts.add(RouteAttempt(
            routeKey: '${entry.providerId}:${entry.model}',
            outcome: 'failed:cancelled_by_consumer:${fail.failure.message}',
            retries: retries,
            classification: cls,
          ));
          yield LlmStreamFailed(
            callId: fail.callId,
            failure: fail.failure,
            report: fail.report,
          );
          return;
        }

        if (action == LlmRouterAction.retryThenRotate &&
            retries < retriesPerClass &&
            overallWatch.elapsedMilliseconds < budget.wallClockMs) {
          retries++;
          await _waitForRetry(cls);
          continue;
        }

        _applyAction(action, cls, entry);
        attempts.add(RouteAttempt(
          routeKey: '${entry.providerId}:${entry.model}',
          outcome: 'failed:${cls.code}:${fail.failure.message}',
          retries: retries,
          classification: cls,
        ));
        break;
      }
    }

    // Chain exhausted.
    yield _exhaustedFailedEvent(
      roleId: roleId,
      attempts: attempts,
      lastClass: lastClass,
      provider: providers.values.isEmpty ? null : providers.values.first,
      entry: chain.isEmpty ? null : chain.first,
    );
  }

  // ─── Internals ───────────────────────────────────────────────────

  /// Filter step (spec § 5.1 step 2). Returns a non-null skip reason
  /// when the entry should be passed over, `null` when the entry is
  /// allowed to attempt.
  ///
  /// Side effect: appends a `skipped:*` audit line to [attempts] when
  /// the entry is filtered.
  String? _filter(
    RouteEntry entry, {
    required int? inputTokensHint,
    required List<RouteAttempt> attempts,
  }) {
    final provider = providers[entry.providerId];
    if (provider == null) {
      attempts.add(RouteAttempt(
        routeKey: '${entry.providerId}:${entry.model}',
        outcome: 'skipped:no_provider',
        retries: 0,
      ));
      return 'no_provider';
    }
    if (_isCooldownActive(entry)) {
      attempts.add(RouteAttempt(
        routeKey: '${entry.providerId}:${entry.model}',
        outcome: 'skipped:cooldown',
        retries: 0,
      ));
      return 'cooldown';
    }
    final maxIn = entry.conditions.maxInputTokens;
    if (maxIn != null && inputTokensHint != null && inputTokensHint > maxIn) {
      attempts.add(RouteAttempt(
        routeKey: '${entry.providerId}:${entry.model}',
        outcome: 'skipped:conditions:max_input_tokens',
        retries: 0,
      ));
      return 'conditions';
    }
    return null;
  }

  bool _isCooldownActive(RouteEntry entry) {
    final t = now();
    for (final mapEntry in _cooldownUntil.entries) {
      if (!mapEntry.value.isAfter(t)) continue;
      if (mapEntry.key.matchesRoute(entry.providerId, entry.model)) {
        return true;
      }
    }
    return false;
  }

  void _applyAction(
    LlmRouterAction action,
    LlmFailureClass cls,
    RouteEntry entry,
  ) {
    switch (action) {
      case LlmRouterAction.cooldownAndRotate:
        final dur = cooldownByClass[cls];
        if (dur != null && dur > Duration.zero) {
          _cooldownUntil[_CooldownKey.route(
            entry.providerId,
            entry.model,
            cls.code,
          )] = now().add(dur);
        }
      case LlmRouterAction.removeCredential:
        // Provider-wide park.
        final dur = cooldownByClass[cls] ?? const Duration(days: 365);
        _cooldownUntil[_CooldownKey.provider(entry.providerId, cls.code)] =
            now().add(dur);
      case LlmRouterAction.removeRoute:
        final dur = cooldownByClass[cls] ?? const Duration(days: 365);
        _cooldownUntil[_CooldownKey.route(
          entry.providerId,
          entry.model,
          cls.code,
        )] = now().add(dur);
      case LlmRouterAction.retryThenRotate:
        // No cooldown after a retry-exhausted rotation. The route stays
        // dispatchable on the next call; only the in-route retry budget
        // is consumed. A future policy field could attach a short
        // cool-off here if a real provider proves it needs one.
        break;
      case LlmRouterAction.surfaceToCaller:
        // No state change; the caller is in charge.
        break;
    }
  }

  Future<void> _waitForRetry(LlmFailureClass cls) async {
    if (cls != LlmFailureClass.overloaded) return;
    final jitterMicros = _random.nextInt(overloadedBackoff.inMicroseconds + 1);
    if (jitterMicros == 0) return;
    await Future<void>.delayed(Duration(microseconds: jitterMicros));
  }

  LlmOptions _resolveOptions(LlmOptions options, String routeModel) {
    if (options.model != null) return options;
    return options.copyWith(model: routeModel);
  }

  String _summarise(Object exception) {
    final s = exception.toString();
    return s.length > 120 ? '${s.substring(0, 117)}...' : s;
  }

  LlmStreamFailed _exhaustedFailedEvent({
    required String roleId,
    required List<RouteAttempt> attempts,
    required LlmFailureClass? lastClass,
    required LlmProvider? provider,
    required RouteEntry? entry,
  }) {
    final cls = lastClass ?? LlmFailureClass.unknown;
    final summary = attempts.map((a) => a.outcome).join(' | ');
    return LlmStreamFailed(
      callId: 'router-exhausted-$roleId',
      failure: LlmFailure(
        classCode: cls.code,
        message: 'NoRouteAvailable(role=$roleId)',
      ),
      report: LlmCallReport(
        providerId: provider?.id ?? '',
        modelId: entry?.model ?? '',
        anchorHash: '',
        promptHash: '',
        tokensIn: 0,
        tokensOut: 0,
        retries: 0,
        wallClockMs: 0,
        notes: <String>['router:chain_audit:$summary'],
      ),
    );
  }

  LlmCallReport _syntheticReport({
    required LlmProvider provider,
    required RouteEntry entry,
    required WirePrompt prompt,
    required LlmOptions options,
    required int retries,
    required int wallClockMs,
  }) {
    return LlmCallReport(
      providerId: provider.id,
      modelId: options.model ?? entry.model,
      anchorHash: prompt.anchorHash,
      promptHash: '',
      tokensIn: 0,
      tokensOut: 0,
      retries: retries,
      wallClockMs: wallClockMs,
      templateSha: prompt.templateSha,
      notes: const <String>['router:synthetic_report:stream_failure'],
    );
  }

  /// Clear all cooldowns. Test-only; production code never calls this.
  void resetCooldownsForTest() {
    _cooldownUntil.clear();
  }
}

/// Structured cooldown-map key. Replaces the earlier `:`-joined string
/// key, which collided when a model id contained a colon (`gemma3:27b`):
/// a prefix match on `<provider>:<modelPrefix>:` would falsely flag a
/// sibling model as cooled down.
///
/// Equality compares fields rather than substrings, so distinct routes
/// never alias. A null [modelId] marks a provider-wide park (e.g. an
/// `auth` failure removes a credential, not a single route) and
/// [matchesRoute] then matches every model of the provider.
class _CooldownKey {
  final String providerId;

  /// `null` ⇒ provider-wide park (matches any model of [providerId]).
  final String? modelId;
  final String classCode;

  const _CooldownKey._(this.providerId, this.modelId, this.classCode);

  /// Per-route, per-class cooldown.
  const _CooldownKey.route(
    String providerId,
    String modelId,
    String classCode,
  ) : this._(providerId, modelId, classCode);

  /// Provider-wide, per-class cooldown (credential-scoped).
  const _CooldownKey.provider(String providerId, String classCode)
      : this._(providerId, null, classCode);

  /// Whether this key covers the `(providerId, modelId)` route. A
  /// provider-wide key ([modelId] null) covers every model of the
  /// provider; a route key covers only its exact model.
  bool matchesRoute(String providerId, String modelId) {
    if (this.providerId != providerId) return false;
    return this.modelId == null || this.modelId == modelId;
  }

  @override
  bool operator ==(Object other) =>
      other is _CooldownKey &&
      other.providerId == providerId &&
      other.modelId == modelId &&
      other.classCode == classCode;

  @override
  int get hashCode => Object.hash(providerId, modelId, classCode);

  @override
  String toString() =>
      '_CooldownKey($providerId, ${modelId ?? '*'}, $classCode)';
}
