import 'codex_transport.dart';

Future<CodexTransport> startCodexProcess(
  String cwd, {
  Map<String, String> environment = const {},
}) async =>
    throw const CodexUnavailable(
      'Codex runs in the desktop app',
      detail: 'The browser cannot start local processes.',
    );
