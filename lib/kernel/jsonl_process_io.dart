import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// A child process spoken to in JSON, one message a line on its stdin and
/// stdout; its stream ends with [exitMessage] once it is gone.
class JsonLinesProcess {
  JsonLinesProcess(this._process, {required this.exitMessage}) {
    _process.stdout
        .transform(_decoder)
        .transform(const LineSplitter())
        .listen(_line, onError: _stderrLine, onDone: _stdoutDone);
    _process.stderr
        .transform(_decoder)
        .transform(const LineSplitter())
        .listen(_stderrLine, onError: _stderrLine);
    unawaited(_process.exitCode.then(_exited));
  }

  static const _decoder = Utf8Decoder(allowMalformed: true);

  final Process _process;

  /// The last message, of how it ended and what it printed on stderr.
  final Map<String, Object?> Function(int code, String stderr) exitMessage;
  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();

  /// The last lines it printed on stderr, to say why it failed.
  final List<String> _stderr = [];
  static const _stderrLines = 30;

  int? _exitCode;
  bool _stdoutClosed = false;

  Stream<Map<String, Object?>> get messages => _messages.stream;

  void _line(String line) {
    if (line.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, Object?>) _messages.add(decoded);
    } on FormatException {
      _stderrLine(line);
    }
  }

  void _stderrLine(Object line) {
    _stderr.add('$line');
    if (_stderr.length > _stderrLines) _stderr.removeAt(0);
  }

  void _stdoutDone() {
    _stdoutClosed = true;
    _finish();
  }

  void _exited(int code) {
    _exitCode = code;
    _finish();
  }

  /// Ends the stream once both the output is read and the process gone,
  /// so its last messages come before the exit.
  void _finish() {
    final code = _exitCode;
    if (code == null || !_stdoutClosed || _messages.isClosed) return;
    _messages
      ..add(exitMessage(code, _stderr.join('\n')))
      ..close();
  }

  void write(Map<String, Object?> message) {
    if (_exitCode != null) return;
    try {
      _process.stdin.writeln(jsonEncode(message));
    } on StateError {
      // Closed under us: the exit message follows.
    }
  }

  Future<void> get exited => _process.exitCode.then((_) {});

  /// Its input closed, it shuts down on its own; one that does not is
  /// killed.
  void close() {
    if (_exitCode != null) return;
    unawaited(_process.stdin.close().catchError((_) {}));
    unawaited(
      _process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          _process.kill();
          return -1;
        },
      ),
    );
  }
}

/// The executable [name] on [environment]'s PATH (on Windows, its npm
/// shim or `.exe`).
String? locateExecutable(Map<String, String> environment, String name) {
  final names = Platform.isWindows ? ['$name.cmd', '$name.exe'] : [name];
  final path = environment['PATH'] ?? environment['Path'] ?? '';
  for (final dir in path.split(Platform.isWindows ? ';' : ':')) {
    if (dir.isEmpty) continue;
    for (final name in names) {
      final candidate = p.join(dir, name);
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return null;
}
