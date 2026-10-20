import 'dart:io';

import 'package:bao_remote/local.dart' show ClaudeEnvironment;

import '../../network/network_proxy_io.dart';
import '../jsonl_process_io.dart';
import 'codex_transport.dart';

/// `codex app-server` as a child process, over its stdin and stdout.
class CodexProcess extends JsonLinesProcess implements CodexTransport {
  CodexProcess(super.process) : super(exitMessage: CodexExit.message);
}

Future<CodexTransport> startCodexProcess(
  String cwd, {
  Map<String, String> environment = const {},
}) async {
  if (!Directory(cwd).existsSync()) {
    throw CodexUnavailable('The project folder is gone', detail: cwd);
  }
  // The login shell's: where Codex is installed, and what it is signed in
  // with.
  final variables = {
    ...await ClaudeEnvironment.of(),
    ...await NetworkProxy.instance.environment(),
    ...environment,
  };
  final executable = locateExecutable(variables, 'codex');
  if (executable == null) {
    throw const CodexUnavailable(
      'Codex is not installed',
      detail:
          'Install it, then try again:\n'
          'npm install -g @openai/codex',
    );
  }
  try {
    final process = await Process.start(
      executable,
      const ['app-server'],
      workingDirectory: cwd,
      environment: variables,
      includeParentEnvironment: Platform.isWindows,
      // An npm shim is a `.cmd`, which only the shell can run.
      runInShell: Platform.isWindows,
    );
    return CodexProcess(process);
  } on ProcessException catch (error) {
    throw CodexUnavailable(
      'Codex could not start',
      detail: '$executable\n${error.message}',
    );
  }
}
