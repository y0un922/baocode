import 'codex_process_stub.dart'
    if (dart.library.io) 'codex_process_io.dart'
    as platform;

/// Codex's side of the adapter (the Adaptee): JSON-RPC 2.0 with
/// `codex app-server` over stdio, one message per line.
abstract interface class CodexTransport {
  /// Responses (`id` + `result`), notifications (`method` + `params`) and
  /// server requests (`id` + `method` + `params`, e.g. approvals); and
  /// last, when the process ends, a [CodexExit.method] message.
  Stream<Map<String, Object?>> get messages;

  /// Writes a request, or the response to a server request.
  void write(Map<String, Object?> message);

  void close();
}

/// The message a transport ends with: the process is gone.
abstract final class CodexExit {
  static const method = 'transport/exit';

  static Map<String, Object?> message(int code, String stderr) => {
    'method': method,
    'params': {'code': code, 'stderr': stderr},
  };
}

/// Codex could not be started.
class CodexUnavailable implements Exception {
  const CodexUnavailable(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message\n$detail';
}

/// Starts `codex app-server` in [cwd], with [environment] besides the
/// user's.
typedef CodexTransportFactory =
    Future<CodexTransport> Function(
      String cwd, {
      Map<String, String> environment,
    });

/// Starts it as a local process; on the web, fails saying so.
Future<CodexTransport> startCodexProcess(
  String cwd, {
  Map<String, String> environment = const {},
}) => platform.startCodexProcess(cwd, environment: environment);
