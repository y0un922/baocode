import 'pi_process_stub.dart'
    if (dart.library.io) 'pi_process_io.dart'
    as platform;

/// pi's side of the adapter (the Adaptee): `pi --mode rpc`, one JSON
/// record per line on stdin and stdout.
abstract interface class PiTransport {
  /// What pi prints: `response`s, session events and
  /// `extension_ui_request`s; and last, when the process ends, a
  /// [PiExit.type] message.
  Stream<Map<String, Object?>> get messages;

  /// Writes a command, or an `extension_ui_response`.
  void write(Map<String, Object?> message);

  /// Ends the process.
  void close();

  /// Completes once the process is gone, closed or not.
  Future<void> get exited;
}

/// The message a transport ends with: the process is gone.
abstract final class PiExit {
  static const type = 'transport_exit';

  static Map<String, Object?> message(int code, String stderr) => {
    'type': type,
    'code': code,
    'stderr': stderr,
  };
}

/// pi could not be started.
class PiUnavailable implements Exception {
  const PiUnavailable(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message\n$detail';
}

/// Starts pi for one session in [cwd]: the session file [session] goes
/// on, or a new one starts. [environment] is besides the user's.
typedef PiTransportFactory = Future<PiTransport> Function(
  String cwd, {
  String? session,
  Map<String, String> environment,
});

/// Starts pi as a local process; on the web, fails saying so.
Future<PiTransport> startPiProcess(
  String cwd, {
  String? session,
  Map<String, String> environment = const {},
}) => platform.startPiProcess(cwd, session: session, environment: environment);

/// Takes session [file] back to before its user message [fromEnd] from the
/// end of where it is (0: the last), for pi to go on from there once it
/// starts on it again: false when there is no such message. pi must not be
/// running on it.
Future<bool> branchPiSession(String file, int fromEnd) =>
    platform.branchPiSession(file, fromEnd);

/// Copies session [file] into a new session beside it, titled [title]:
/// without its user message [fromEnd] from the end and what follows, when
/// given. Its id and file.
Future<({String id, String path})> copyPiSession(
  String file, {
  int? fromEnd,
  required String title,
}) => platform.copyPiSession(file, fromEnd: fromEnd, title: title);

/// The conversation on the branch of session [file] pi goes on with,
/// oldest first: its messages as `get_messages` gives them, but also those
/// a compaction summed up, it marking where. Read without starting pi;
/// null when it cannot be.
Future<List<Map<String, Object?>>?> readPiHistory(String file) =>
    platform.readPiHistory(file);
