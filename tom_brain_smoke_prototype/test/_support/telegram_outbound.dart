// Telegram outbound helpers for the end-to-end smoke (E.49 / E.54 / E.55).
//
// The live Telegram edge surrounds the answer with several *control* and
// *notice* messages — all real production behaviours, unit-tested elsewhere:
//
//   * a boot-time startup announcement pinged to each whitelisted owner
//     (`telegramStartupAnnouncement(host)`), sent while the access process
//     comes up;
//   * an immediate processing acknowledgement sent to the sender on admission
//     (`telegramProcessingAcknowledgement(prompt)`), before the (potentially
//     slow) cognition runs; and
//   * out-of-band status notices the buffered Telegram path sends as their own
//     messages while the run is in flight — tool activity (`🔧 …`),
//     thinking-channel turns (`🤔 …`), and memory-recall traces (`🧠 …`).
//     Unlike a per-chunk channel (SSE), which drops these, a buffered channel
//     surfaces each as its own immediate message.
//
// None of these is the answer. These helpers strip them so a smoke / conformance
// assertion speaks about what the channel actually *answered* (or declined),
// rather than re-counting the control pings and status notices in every test.
// The control wording and the notice formats are covered by the tom_brain_access
// / tom_brain_procedure unit suites; here we only need to recognise and ignore
// them.

import 'dart:io' show Platform;

import 'package:tom_brain_access/tom_brain_access.dart'
    show telegramProcessingAcknowledgement, telegramStartupAnnouncement;
import 'package:tom_chattools/tom_chattools.dart' show ChatReceiver;

import 'loopback_chat_api.dart';

/// The leading status glyphs of an out-of-band notice the buffered Telegram path
/// delivers as its own message (tool `🔧`, thinking `🤔`, memory-recall `🧠`).
/// A message starting with one of these is a notice, not answer text. The smoke
/// answers never begin with one of these glyphs, so the recognition is exact.
const List<String> _noticeGlyphs = <String>['🔧', '🤔', '🧠'];

/// The boot-time startup announcement the edge pings each whitelisted owner
/// with, resolved over the same host the edge uses (`Platform.localHostname`).
String smokeStartupAnnouncement() =>
    telegramStartupAnnouncement(Platform.localHostname);

/// The per-prompt processing acknowledgement the edge sends a sender on
/// admission (echoes the prompt back so the sender sees it was received).
String smokeProcessingAck(String prompt) =>
    telegramProcessingAcknowledgement(prompt);

/// The substantive messages addressed to [receiverId] — the answer parts, or a
/// decline — in delivery order, with the boot startup announcement, the
/// per-[prompts] processing acknowledgements, and the out-of-band status notices
/// (tool `🔧` / thinking `🤔` / memory-recall `🧠`) stripped.
///
/// [prompts] are the inbound prompt texts driven in the test; each contributes
/// one expected acknowledgement string to the control set. A test that drove no
/// admitted prompt (the whitelist-gate path) passes no [prompts] — only the
/// startup announcement is stripped, leaving the decline.
List<String> answerMessagesTo(
  LoopbackChatApi loopback,
  String receiverId, {
  List<String> prompts = const <String>[],
}) {
  final Set<String> control = <String>{
    smokeStartupAnnouncement(),
    for (final String prompt in prompts) smokeProcessingAck(prompt),
  };
  final ChatReceiver target = ChatReceiver.id(receiverId);
  final List<String> answers = <String>[];
  for (int i = 0; i < loopback.sentMessages.length; i++) {
    if (loopback.sentReceivers[i] != target) continue;
    final String message = loopback.sentMessages[i];
    if (control.contains(message)) continue;
    if (_noticeGlyphs.any(message.startsWith)) continue;
    answers.add(message);
  }
  return answers;
}

/// Polls until at least [count] substantive answer message(s) to [receiverId]
/// have been delivered (control pings ignored), then settles briefly so a stray
/// extra message is still caught by a following count assertion. Throws a
/// [StateError] on [timeout].
///
/// The whole Telegram path is async across the memory worker isolate and the
/// buffered delivery, so a test waits on the *answer* arriving rather than on a
/// raw `sentMessages` length that the control pings would satisfy prematurely.
Future<void> waitForAnswersTo(
  LoopbackChatApi loopback,
  String receiverId, {
  List<String> prompts = const <String>[],
  int count = 1,
  Duration timeout = const Duration(seconds: 15),
  Duration settle = const Duration(milliseconds: 150),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (answerMessagesTo(loopback, receiverId, prompts: prompts).length <
      count) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError(
        'timed out waiting for $count answer message(s) to $receiverId; got '
        '${answerMessagesTo(loopback, receiverId, prompts: prompts)}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await Future<void>.delayed(settle);
}
