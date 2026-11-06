/// The brain's Agent SDK provider through a **real Claude Code**, over the
/// CLI server of a running VS Code.
///
/// The offline suites (`tom_core_agentic`'s `resume_test.dart`, this
/// package's r31 and r44) prove the mechanics against a scripted transport
/// that does what we told it to. Three things only a real far end can answer:
///
/// 1. whether the conversation id Claude Code names is resumable by a later
///    query — a fact said in one call is known in the next;
/// 2. whether a conversation id Claude Code does not know produces an error
///    `agentSdkLooksLikeResumeError` recognises, so the run retries fresh once;
/// 3. whether `/cli_server_port` moves a live provider — off the server and
///    back on.
///
/// Plus the attribution the brain relies on: the run is the profile's, and
/// Claude Code's own tool calls stay out of the caller's run.
///
/// **Opt-in, run by hand** on a machine with VS Code open and the Tom
/// extension's CLI server started (`tomAi.cliServer.start`; it does not
/// autostart):
///
/// ```bash
/// cd tom_assistant/tom_brain_run
/// TOM_BRAIN_AGENT_SDK_LIVE=1 dart test test/live_agent_sdk_brain_test.dart
/// ```
///
/// `TOM_BRAIN_AGENT_SDK_PORT` names the server's port when it is not the
/// bridge default (19900). The suite asks first: one tiny completion through
/// `probeAgentSdkModel`. A model answering runs the tests; a server with no
/// model behind it skips them with the sentence naming the credential; a
/// server that cannot be reached fails, because the variable asked for one.
/// Without the variable nothing here runs, so `dart test` needs no editor.
///
/// **Deadline.** Each test makes up to two real completions with tool use; a
/// completion has measured up to a minute, so the file allows six.
@Timeout(Duration(minutes: 6))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:tom_basics/tom_basics.dart' show TomPlatformUtils;
import 'package:tom_brain_run/tom_brain_run.dart';
import 'package:tom_brain_substrate/tom_brain_substrate.dart'
    show InProcessTomBrainSubstrate, SubstrateConfigLoader;
import 'package:tom_core_agentic/agent_sdk.dart';
import 'package:tom_core_agentic/agent_sdk_live_probe.dart';
import 'package:tom_core_server/tom_core_server.dart'
    show standalonePlatformUtils;
import 'package:tom_llm/tom_llm.dart';
import 'package:tom_vscode_scripting_api/tom_vscode_scripting_api.dart'
    show defaultVSCodeBridgePort;

const _liveVar = 'TOM_BRAIN_AGENT_SDK_LIVE';
const _portVar = 'TOM_BRAIN_AGENT_SDK_PORT';

/// The profile id the run must be attributed to.
const _profile = 'claude';

bool get _enabled => Platform.environment[_liveVar] == '1';

int get _port =>
    int.tryParse(Platform.environment[_portVar] ?? '') ??
    defaultVSCodeBridgePort;

/// The `substrate:` section: one `agent_sdk` row on the live server, keeping
/// its conversations per brain session, with permission to use Claude Code's
/// read tools; and the Ollama row the substrate requires for embeddings,
/// which is only manufactured, never dialled.
String _substrateYaml(int port) =>
    '''
substrate:
  providers:
    - id: $_profile
      kind: agent_sdk
      models:
        - claude-sonnet-4-6
      options:
        bridgePort: $port
        sessionMode: brain
        permissionMode: bypassPermissions
        maxTurns: 4
    - id: ollama
      kind: ollama
      baseUrl: http://127.0.0.1:11434
      models:
        - nomic-embed-text
  roleRoutes:
    assistant_to_user:
      - providerId: $_profile
        model: claude-sonnet-4-6
  embedding:
    providerId: ollama
    model: nomic-embed-text
    dims: 768
    normalize: true
''';

/// A word no model guesses: it can only come back from the conversation or
/// the file it was put in.
String _codeWord() {
  final r = Random();
  const syllables = ['ka', 'zu', 'mo', 'ri', 've', 'tal', 'quo', 'nix'];
  return [
    for (var i = 0; i < 4; i++) syllables[r.nextInt(syllables.length)],
  ].join();
}

LlmRequest _request(String sessionId, String text) => LlmRequest(
  prompt: WirePrompt(system: '', user: text, roleId: 'assistant_to_user'),
  options: LlmOptions(sessionId: sessionId),
);

Future<String> _answer(List<LlmEvent> events) =>
    llmAnswerText(Stream.fromIterable(events)).join();

Map<String, dynamic> _store(Directory root) {
  final file = File('${root.path}/agent_sdk_sessions.json');
  if (!file.existsSync()) return const {};
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  if (!_enabled) {
    test('skipped — set $_liveVar', () {}, skip: 'set $_liveVar=1 to enable');
    return;
  }

  late AgentSdkProbe probe;
  late Directory root;
  late InProcessTomBrainSubstrate substrate;
  late AgentSdkSessionProvider provider;
  InProcessTomBrainSubstrate? built;

  setUpAll(() async {
    // The Ollama row's HTTP client comes from the active platform; a bare
    // `dart test` runs the fallback one, whose client throws (as in r31).
    TomPlatformUtils.setCurrentPlatform(standalonePlatformUtils);
    probe = await probeAgentSdkModel(
      brainCliServerTransport('127.0.0.1', _port),
    );
    // ignore: avoid_print
    print('probe on port $_port: $probe');
    root = Directory.systemTemp.createTempSync('tom_brain_live_agent_sdk_');
    substrate = buildSubstrate(
      SubstrateConfigLoader.parse(_substrateYaml(_port)),
      agentSdkSessionRoot: root.path,
    );
    built = substrate;
    provider = substrate.providers[_profile]! as AgentSdkSessionProvider;
  });

  tearDownAll(() async {
    await built?.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Skips with the probe's sentence when no model answered; fails when the
  /// server could not be reached, which is what the variable asked for.
  bool skipWithoutModel() {
    switch (probe.outcome) {
      case AgentSdkProbeOutcome.answered:
        return false;
      case AgentSdkProbeOutcome.noModel:
        markTestSkipped(probe.detail);
        return true;
      case AgentSdkProbeOutcome.unreachable:
        fail(
          'no CLI server on port $_port (start it with tomAi.cliServer.start): '
          '${probe.detail}',
        );
    }
  }

  test('LIVE-BRAIN-1: a fact said in one call is known in the next; the '
      'store keeps the conversation', () async {
    if (skipWithoutModel()) return;
    const session = 'live-brain-1';
    final word = _codeWord();

    final first = await provider
        .run(
          _request(
            session,
            'Remember this code word: $word. '
            'Reply with the single word OK.',
          ),
        )
        .toList();
    expect(first.last, isA<LlmRunCompleted>(), reason: '$first');
    final conversation = _store(root)[session];
    expect(
      conversation,
      isA<String>(),
      reason: 'agent_sdk_sessions.json names no conversation for $session',
    );

    final second = await provider
        .run(
          _request(
            session,
            'What was the code word I gave you? '
            'Reply with the word only.',
          ),
        )
        .toList();
    expect(second.last, isA<LlmRunCompleted>(), reason: '$second');
    expect((await _answer(second)).toLowerCase(), contains(word));
    expect(
      (second.last as LlmRunCompleted).report.retries,
      0,
      reason: 'the stored conversation was resumable as it stood',
    );
    expect(_store(root)[session], isA<String>());
  });

  test('LIVE-BRAIN-2: a conversation Claude Code does not know is retried '
      'fresh, once, and the run completes', () async {
    if (skipWithoutModel()) return;
    const session = 'live-brain-2';
    const madeUp = '00000000-dead-4bee-8f00-000000000042';
    // A substrate of its own, over a store written before the provider reads
    // it: the store caches the file on its first read, so an entry written
    // beside a provider that has already read it would never be sent.
    final own = Directory.systemTemp.createTempSync('tom_brain_live_stale_');
    addTearDown(() => own.deleteSync(recursive: true));
    await AgentSdkResumeStore(
      File('${own.path}/agent_sdk_sessions.json'),
    ).put(session, madeUp);
    final staleSubstrate = buildSubstrate(
      SubstrateConfigLoader.parse(_substrateYaml(_port)),
      agentSdkSessionRoot: own.path,
    );
    addTearDown(staleSubstrate.close);
    final stale =
        staleSubstrate.providers[_profile]! as AgentSdkSessionProvider;

    final events = await stale
        .run(_request(session, 'Reply with the single word OK.'))
        .toList();

    expect(events.last, isA<LlmRunCompleted>(), reason: '$events');
    expect((events.last as LlmRunCompleted).report.retries, 1);
    expect(events.whereType<LlmRetry>(), hasLength(1));
    expect(
      events.whereType<LlmRunError>(),
      isEmpty,
      reason: 'the stale attempt is a retry, not an error of the run',
    );
    expect(_store(own)[session], allOf(isA<String>(), isNot(madeUp)));
  });

  test("LIVE-BRAIN-3: the run is the profile's, and Claude Code's tool calls "
      "stay out of the caller's run", () async {
    if (skipWithoutModel()) return;
    const session = 'live-brain-3';
    final word = _codeWord();
    final file = File('${root.path}/code_word.txt')
      ..writeAsStringSync('The code word is $word.\n');

    final events = await provider
        .run(
          _request(
            session,
            'Use your Read tool to read the file '
            '${file.path} and reply with the code word it names, the word '
            'only.',
          ),
        )
        .toList();

    expect(events.last, isA<LlmRunCompleted>(), reason: '$events');
    expect(events.whereType<LlmRunStarted>().single.providerId, _profile);
    expect((events.last as LlmRunCompleted).report.providerId, _profile);
    expect((await _answer(events)).toLowerCase(), contains(word));
    expect(
      events.whereType<LlmToolCall>(),
      isEmpty,
      reason: "Claude Code's loop ran the tool; the caller ran none",
    );
    expect(
      provider.trails
          .recordsOf(session)
          .map((r) => r.event)
          .whereType<LlmToolCall>(),
      isNotEmpty,
      reason: 'the trail holds the tool call Claude Code made',
    );
  });

  test('LIVE-BRAIN-4: /cli_server_port moves the live provider off the '
      'server and back on', () async {
    if (skipWithoutModel()) return;
    final controller = TomBrainCliServerPortController(providers: [provider]);
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closed = socket.port;
    await socket.close();

    final away = await controller.setCliServerPort(port: closed);
    expect(away, contains('1 of 1 agent-SDK provider reconnected'));
    final off = await provider
        .run(_request('live-brain-4', 'Reply with the single word OK.'))
        .toList();
    expect(
      off.last,
      isNot(isA<LlmRunCompleted>()),
      reason: 'port $closed has no server, yet the run completed',
    );
    expect(off.whereType<LlmRunError>(), isNotEmpty);

    final back = await controller.setCliServerPort(port: _port);
    expect(back, contains('1 of 1 agent-SDK provider reconnected'));
    final on = await provider
        .run(_request('live-brain-4', 'Reply with the single word OK.'))
        .toList();
    expect(on.last, isA<LlmRunCompleted>(), reason: '$on');
    expect((await _answer(on)).toUpperCase(), contains('OK'));
  });
}
