import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart' show ClaudeEnvironment;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'agent_host.dart';
import 'agent_skill.dart';

/// The command: its arguments posted, form-encoded and in order, to the
/// caller's address; what comes back printed. curl is on every macOS and
/// Linux; it goes straight to the app, not through a proxy.
const _script = r'''#!/bin/sh
# BaoCode's command for its agents to start other agents and work with
# them (see the baocode-agents skill). Written by BaoCode as it starts.
if [ -z "$BAOCODE_AGENT_URL" ]; then
  echo "baocode-agent: only an agent BaoCode started can run this" >&2
  exit 2
fi
count=$#
first=$1
for argument do
  set -- "$@" --data-urlencode "arg=$argument"
done
shift "$count"
# A hook's: what its agent tells it, on its input.
if [ "$first" = hook ]; then
  set -- "$@" --data-urlencode "stdin@-"
fi
curl -sS --noproxy '*' --fail-with-body --data-urlencode "argc=$count" "$@" \
  "$BAOCODE_AGENT_URL"
status=$?
case $status in
  0) ;;
  22) exit 1 ;;
  7)
    echo "baocode-agent: BaoCode could not be reached. In a sandbox that" \
      "blocks the network, run this command outside it (escalated)." >&2
    exit 7
    ;;
  *) exit "$status" ;;
esac
''';

Future<void> serveAgents(
  AgentHost host, {
  required String directory,
  bool installSkill = true,
}) async {
  if (Platform.isWindows) return;
  try {
    final command = p.join(directory, 'baocode-agent');
    await Directory(directory).create(recursive: true);
    await File(command).writeAsString(_script);
    await Process.run('chmod', ['755', command]);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => _answer(host, request));
    host
      ..command = command
      ..url = 'http://${server.address.address}:${server.port}';
  } on Object catch (error) {
    debugPrint('The agents command is not served: $error');
    return;
  }
  if (installSkill) unawaited(_installSkill());
}

Future<void> _answer(AgentHost host, HttpRequest request) async {
  final response = request.response;
  try {
    final key = request.uri.pathSegments.firstOrNull;
    final AgentReply reply;
    if (request.method != 'POST' || key == null) {
      reply = const AgentReply.error('Not found');
    } else {
      final body = await utf8.decodeStream(request);
      final arguments = <String>[];
      String? input;
      for (final field in body.split('&')) {
        switch (field.split('=')) {
          case ['arg', final value]:
            arguments.add(Uri.decodeQueryComponent(value));
          case ['stdin', final value]:
            input = Uri.decodeQueryComponent(value);
        }
      }
      reply = await host.run(key, arguments, input: input);
    }
    response
      ..statusCode = reply.ok ? HttpStatus.ok : HttpStatus.badRequest
      ..headers.contentType = ContentType.text;
    // Nothing at all for nothing to say (a hook that lets a tool be).
    if (reply.text.isNotEmpty) {
      response.write(
        reply.text.endsWith('\n') ? reply.text : '${reply.text}\n',
      );
    }
    await response.close();
  } on Object {
    // The command was stopped (its agent's turn, say): no one to answer.
  }
}

/// Writes [AgentSkill] where Claude Code, Codex and pi find it: where there
/// is none, or BaoCode's is not the same.
Future<void> _installSkill() async {
  final home = Platform.environment['HOME'];
  final folders = [
    p.join(await ClaudeEnvironment.configDir(), 'skills'),
    if (home != null) p.join(home, '.agents', 'skills'),
  ];
  final text = AgentSkill.text;
  for (final folder in folders) {
    try {
      final file = File(p.join(folder, AgentSkill.name, 'SKILL.md'));
      final existing = await file.exists() ? await file.readAsString() : null;
      if (!AgentSkill.stale(existing, text)) continue;
      await file.parent.create(recursive: true);
      await file.writeAsString(text);
    } on Object catch (error) {
      debugPrint('The agents skill was not written in $folder: $error');
    }
  }
}
